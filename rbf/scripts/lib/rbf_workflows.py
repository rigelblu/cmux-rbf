"""rbf_workflows.py: what audit-workflows.py and disarm-workflows.py share (#cm-142.3).

Reading a workflow's `on:` block, listing a folder or a git rev's workflow files,
and the text edit that removes automatic triggers. The two scripts put this folder
on sys.path themselves, because `python3 -I` does not.

An AUTOMATIC trigger is any event under `on:` other than workflow_dispatch and
workflow_call. The `on:` block is read as YAML, never by its lines, so its
indentation and form (a string, a list, a block or flow mapping) do not change the
count. Mapping keys are read as the strings they are written as, the way GitHub
reads `on`: an unquoted `on` is the key `on`, never True, and `On:`, `yes:` or
`true:` is not it. A key written twice in one mapping, under either reading (the
same string, or the same YAML 1.1 boolean: `on` and `On`), makes the file
unreadable, because two readers could take different values from it. A file whose
`on` can't be read is never counted as manual-only: it raises Unreadable with the
reason the audit prints.
"""
import os
import re
import subprocess

import yaml

MANUAL = ("workflow_dispatch", "workflow_call")

# The fork's marker comment, in the words cm-97 put on its 38 disarmed files.
# Any `# cmux-rbf: ... Reject upstream automatic triggers on sync.` counts as the
# marker, so the earlier, purpose-specific wordings are left as they are.
MARKER = ("# cmux-rbf: explicit dispatch only; no automatic triggers in this fork. "
          "Reject upstream automatic triggers on sync.")
MARKER_RE = re.compile(r"#\s*cmux-rbf:.*Reject upstream automatic triggers on sync\.")

ON_LINE_RE = re.compile(r"""^("on"|'on'|on)[ \t]*:(.*)$""")

BOOL_TAG = "tag:yaml.org,2002:bool"
MERGE_TAG = "tag:yaml.org,2002:merge"


class Unreadable(Exception):
    """The file's `on:` block can't be read; str(exc) is the reason the audit prints."""


class UnsafeEdit(Exception):
    """An edit would change more than the `on:` block, or not leave it manual-only."""


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------
class DuplicateKey(yaml.YAMLError):
    """A key written twice in one mapping; `shown` is the key as the audit names it."""

    def __init__(self, shown, line):
        super().__init__(f"{shown}: key twice (line {line})")
        self.shown, self.line = shown, line


class Loader(yaml.SafeLoader):
    """SafeLoader whose mapping keys stay the strings they are written as, and which
    raises DuplicateKey on a key written twice in one mapping: the same string in any
    mapping, and in the top-level mapping (the only place GitHub reads `on`) also the
    same YAML 1.1 boolean (`on` and `On`, `yes`, `true`). A step's `with:` may hold
    `yes:` and `on:`. The key is named as it is written."""

    def construct_document(self, node):
        self._root = node
        return super().construct_document(node)

    def construct_mapping(self, node, deep=False):
        if not isinstance(node, yaml.MappingNode):
            return super().construct_mapping(node, deep=deep)
        top = node is getattr(self, "_root", None)
        strings, bools = set(), set()
        for key_node, _ in node.value:
            if not isinstance(key_node, yaml.ScalarNode) or key_node.tag == MERGE_TAG:
                continue
            as_bool = self.construct_yaml_bool(key_node) if top and key_node.tag == BOOL_TAG else None
            if key_node.value in strings or (as_bool is not None and as_bool in bools):
                raise DuplicateKey(key_node.value, key_node.start_mark.line + 1)
            strings.add(key_node.value)
            if as_bool is not None:
                bools.add(as_bool)
        self.flatten_mapping(node)
        mapping = {}
        for key_node, value_node in node.value:
            if isinstance(key_node, yaml.ScalarNode):
                key = key_node.value
            else:
                key = self.construct_object(key_node, deep=True)
                try:
                    hash(key)
                except TypeError:
                    raise yaml.constructor.ConstructorError(
                        "while constructing a mapping", node.start_mark,
                        "found an unhashable key", key_node.start_mark)
            mapping[key] = self.construct_object(value_node, deep=deep)
        return mapping


def load_all(text):
    return list(yaml.load_all(text, Loader=Loader))


def load_on(text):
    """The `on:` value of one workflow text, or raise Unreadable."""
    try:
        docs = load_all(text)
    except DuplicateKey as e:
        raise Unreadable(str(e))
    except yaml.YAMLError as e:
        mark = getattr(e, "problem_mark", None)
        raise Unreadable(f"not YAML (line {mark.line + 1})" if mark else "not YAML")
    if len(docs) > 1:
        raise Unreadable("not YAML (more than one document)")
    doc = docs[0] if docs else None
    if not isinstance(doc, dict):
        raise Unreadable("top level is not a mapping")
    if "on" not in doc:
        raise Unreadable("no on: key")
    return doc["on"]


def on_events(on):
    """{event: config} from an `on:` value (a string, a list or a mapping)."""
    if on is None:
        raise Unreadable("on: is empty")
    if isinstance(on, str):
        return {on: None}
    if isinstance(on, list):
        out = {}
        for item in on:
            if not isinstance(item, str):
                raise Unreadable("on: list item is not a string")
            out[item] = None
        return out
    if isinstance(on, dict):
        out = {}
        for k, v in on.items():
            if not isinstance(k, str):
                raise Unreadable("on: has an event name that is not a string")
            out[k] = v
        return out
    raise Unreadable("on: is not a string, a list or a mapping")


def read_events(text):
    """{event: config} of a workflow text, or raise Unreadable."""
    return on_events(load_on(text))


def automatic(events):
    return sorted(e for e in events if e not in MANUAL)


def other_keys(text):
    """The document minus its `on` key, to check that nothing outside on: changed."""
    doc = load_all(text)[0]
    doc.pop("on", None)
    return doc


def classify(text):
    """(events, None) or (None, reason)."""
    if text is None:
        return None, "not UTF-8 text"
    try:
        return read_events(text), None
    except Unreadable as e:
        return None, str(e)


# ---------------------------------------------------------------------------
# Listing: a folder, or a git rev's .github/workflows
# ---------------------------------------------------------------------------
def _is_workflow_name(name):
    return name.endswith((".yml", ".yaml"))


def decode(raw):
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def list_folder(folder):
    """[(display path, text or None)] for the .yml/.yaml files directly in folder."""
    prefix = folder.rstrip("/")
    out = []
    for name in sorted(os.listdir(folder)):
        p = os.path.join(folder, name)
        if _is_workflow_name(name) and os.path.isfile(p):
            with open(p, "rb") as f:
                out.append((f"{prefix}/{name}", decode(f.read())))
    return out


def _git(args):
    gd = os.environ.get("RBF_GIT_DIR")
    if gd:
        base = ["git", "--git-dir", gd]
    else:
        repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))
        base = ["git", "-C", repo]
    return subprocess.run(base + args, capture_output=True)


WORKFLOWS_DIR = ".github/workflows/"


def list_rev(rev):
    """[(path, text or None)] for the workflow files of a git rev; [] when the rev or folder is absent.

    Names are read NUL-separated (`-z`), so a name git would quote (non-ASCII, a
    `"`) arrives as it is; and only files directly in .github/workflows/ count, as
    GitHub reads them (a subfolder's files are not workflows)."""
    r = _git(["ls-tree", "-r", "-z", "--name-only", rev, WORKFLOWS_DIR])
    if r.returncode != 0:
        return []
    out = []
    for raw in sorted(r.stdout.split(b"\0")):
        name = os.fsdecode(raw)
        rest = name[len(WORKFLOWS_DIR):] if name.startswith(WORKFLOWS_DIR) else ""
        if not rest or "/" in rest or not _is_workflow_name(rest):
            continue
        s = _git(["show", f"{rev}:{name}"])
        shown = raw.decode("utf-8", "replace")
        out.append((shown, decode(s.stdout) if s.returncode == 0 else None))
    return out


# ---------------------------------------------------------------------------
# Editing
# ---------------------------------------------------------------------------
def _blank(l):
    return not l.strip()


def _comment(l):
    return l.lstrip().startswith("#")


def _content(l):
    return not (_blank(l) or _comment(l))


def _indent(l):
    return len(l) - len(l.lstrip(" "))


def _find_region(lines):
    """(start, end, full_end): the `on:` line; one past its last content line; one past
    the last line before the next top-level key (trailing comments and blanks included)."""
    start = None
    for i, l in enumerate(lines):
        if ON_LINE_RE.match(l.rstrip("\r")):
            start = i
            break
    if start is None:
        raise Unreadable("no on: key")
    rest = re.sub(r"(^|\s)#.*$", "", ON_LINE_RE.match(lines[start].rstrip("\r")).group(2)).strip()
    full_end = len(lines)
    for j in range(start + 1, len(lines)):
        l = lines[j].rstrip("\r")
        if _blank(l) or l.startswith((" ", "\t", "#")):
            continue
        if not rest and l.startswith("-"):
            continue          # a block list written at the key's own indent
        full_end = j
        break
    end = start + 1
    for j in range(start + 1, full_end):
        if _content(lines[j]):
            end = j + 1
    return start, end, full_end


_KEY_RE = re.compile(r"""^\s*(?:"([^"]*)"|'([^']*)'|([^\s:#]+))\s*:""")


def _key_name(line):
    m = _KEY_RE.match(line.rstrip("\r"))
    return (m.group(1) or m.group(2) or m.group(3)) if m else None


def _yaml_block(event, cfg, indent, cr):
    if cfg is None:
        return [" " * indent + event + ":" + cr]
    body = yaml.safe_dump({event: cfg}, default_flow_style=False, sort_keys=False).rstrip("\n").split("\n")
    return [" " * indent + l + cr for l in body]


def disarm_text(text):
    """(new_text, status), status 'disarmed' | 'marker' | 'unchanged'.

    Strips every automatic event from the `on:` block and adds the marker comment
    once. Only the lines of the block change: everything else, including line
    endings, the final newline and comments outside the block, is kept. Raises
    Unreadable when the file's `on:` can't be read."""
    events = read_events(text)
    auto = automatic(events)
    cr = "\r" if "\r\n" in text else ""
    lines = text.split("\n")
    start, end, full_end = _find_region(lines)
    marker_there = any(MARKER_RE.search(l) for l in lines[start:full_end])
    if not auto and marker_there:
        return text, "unchanged"

    on_line = lines[start].rstrip("\r")
    rest_nc = re.sub(r"(^|\s)#.*$", "", ON_LINE_RE.match(on_line).group(2)).strip()
    body = lines[start + 1:end]
    first = next((l for l in body if _content(l)), None)
    is_map = rest_nc == "" and first is not None and not first.lstrip().startswith("-")

    if is_map:
        # block mapping: one segment per event; a comment directly above an event goes with it
        b = _indent(first)
        keyidx = [i for i, l in enumerate(body) if _content(l) and _indent(l) == b]
        starts = []
        for n, ki in enumerate(keyidx):
            floor = 0
            if n:
                floor = max(i for i in range(keyidx[n - 1], ki) if _content(body[i])) + 1
            s = ki
            while s - 1 >= floor and _comment(body[s - 1]):
                s -= 1
            starts.append(s)
        new_body = list(body[:starts[0]])
        for n, ki in enumerate(keyidx):
            seg = body[starts[n]:(starts[n + 1] if n + 1 < len(starts) else len(body))]
            if _key_name(body[ki]) in MANUAL:
                new_body += seg
            else:
                # the fork's marker never goes with an event it sits next to
                new_body += [l for l in seg if MARKER_RE.search(l)]
        if not any(_key_name(body[ki]) in MANUAL for ki in keyidx):
            new_body.append(" " * b + "workflow_dispatch:" + cr)
        if not marker_there:
            new_body.insert(0, " " * b + MARKER + cr)
        new_region = [lines[start]] + new_body
    elif not auto:
        # manual-only in a list, string or flow form: keep the form, put the marker under it
        new_region = lines[start:end] + ["  " + MARKER + cr]
    else:
        # automatic events in a list, string or flow form: rebuild as a block mapping of the manual ones
        kept = {e: c for e, c in events.items() if e in MANUAL} or {"workflow_dispatch": None}
        key = ON_LINE_RE.match(on_line).group(1)
        new_region = [key + ":" + cr]
        # a marker inside the rebuilt lines is kept as it is, and one on the `on:` line itself
        # is carried down under it; one after them stays where it is
        inside = [l for l in lines[start + 1:end] if MARKER_RE.search(l)]
        on_marker = MARKER_RE.search(on_line)
        if on_marker:
            inside.insert(0, "  " + on_line[on_marker.start():] + cr)
        if inside:
            new_region += inside
        elif not any(MARKER_RE.search(l) for l in lines[end:full_end]):
            new_region.append("  " + MARKER + cr)
        for e, c in kept.items():
            new_region += _yaml_block(e, c, 2, cr)

    new_text = "\n".join(lines[:start] + new_region + lines[end:])
    return new_text, ("disarmed" if auto else "marker")


def verify_edit(old, new):
    """Raise UnsafeEdit unless `new` is `old` with only its `on:` block changed: it
    still reads, no automatic event is left, the manual events and their
    configuration are the same (workflow_dispatch added when none was left), the rest
    of the document is equal, and a file that was manual-only gained at most the
    marker line."""
    try:
        ev_old = read_events(old)
        ev_new = read_events(new)
    except Unreadable as e:
        raise UnsafeEdit(f"the edited file no longer reads: {e}")
    if automatic(ev_new):
        raise UnsafeEdit("an automatic trigger is left: " + ", ".join(automatic(ev_new)))
    if not any(MARKER_RE.search(l) for l in new.split("\n")):
        raise UnsafeEdit("the fork's marker comment is missing")
    want = {e: c for e, c in ev_old.items() if e in MANUAL} or {"workflow_dispatch": None}
    if ev_new != want:
        raise UnsafeEdit("the manual events or their configuration changed")
    if other_keys(old) != other_keys(new):
        raise UnsafeEdit("something outside on: changed")
    if not automatic(ev_old) and new != old:
        without = [l for l in new.split("\n") if l.strip() != MARKER]
        if "\n".join(without) != old:
            raise UnsafeEdit("a manual-only file changed by more than its marker line")
