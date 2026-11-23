#!/usr/bin/env python3
"""Tests for rbf/scripts/audit-workflows.py and rbf/scripts/disarm-workflows.py (#cm-142.3).

    python3 -I rbf/scripts/workflows.test.py

Both scripts are driven as a user drives them (subprocess, a folder, an exit
status), on fixture folders under a sandbox, plus scratch copies of the pin's and
main's workflow files read out of git when those revs exist in the repo. The
disarm script is never run on a tracked .github/workflows folder.

The last line counts what ran: passed, failed, skipped. A file that stops early
prints DID NOT FINISH instead.
"""
import difflib
import filecmp
import importlib.util
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
AUDIT = os.path.join(HERE, "audit-workflows.py")
DISARM = os.path.join(HERE, "disarm-workflows.py")
LIBDIR = os.path.join(HERE, "lib")
REPO = os.path.dirname(os.path.dirname(HERE))
PIN = "3167a90f59ad463401336086fdc4a07580a0dcc0"
PRE = "ee0dc596698f1f9138403ebd41472fd3fea77722"
OLD_AUDIT = "/Volumes/tom-ssd/tmp/cm-142/tools/workflow-triggers.py"
ZERO = "0" * 40

MARKER = ("# cmux-rbf: explicit dispatch only; no automatic triggers in this fork. "
          "Reject upstream automatic triggers on sync.")


def run(script, *args, cwd=None, env=None):
    e = dict(os.environ)
    if env:
        e.update(env)
    r = subprocess.run([sys.executable, "-I", script, *args], capture_output=True, text=True, cwd=cwd, env=e)
    return r.returncode, r.stdout, r.stderr


def git_has(rev):
    return subprocess.run(["git", "-C", REPO, "cat-file", "-e", rev + "^{commit}"], capture_output=True).returncode == 0


def on_region(lines):
    """(start, end) line indexes of the top-level `on:` block, end exclusive: from the
    `on` key to the next top-level key. Written here, not imported, so the test does
    not trust the code it checks."""
    start = None
    for i, l in enumerate(lines):
        if re.match(r"""^("on"|'on'|on)\s*:""", l):
            start = i
            break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        l = lines[j]
        if l.strip() and not l.startswith((" ", "\t", "#", "\r", "\n")):
            end = j
            break
    return start, end


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="rbf-workflows-test.", dir=os.environ.get("TMPDIR") or None)
        self.tmp = os.path.realpath(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def folder(self, name, files):
        d = os.path.join(self.tmp, name)
        os.makedirs(d, exist_ok=True)
        for fn, text in files.items():
            mode = "wb" if isinstance(text, bytes) else "w"
            with open(os.path.join(d, fn), mode, **({} if mode == "wb" else {"newline": ""})) as f:
                f.write(text)
        return d

    def audit(self, target, cwd=None, env=None):
        return run(AUDIT, target, cwd=cwd, env=env)

    def disarm(self, *args, cwd=None):
        return run(DISARM, *args, cwd=cwd)

    def read(self, d, fn):
        with open(os.path.join(d, fn), newline="") as f:
            return f.read()


JOBS = "jobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n"


def wf(on_block, name="x"):
    return f"name: {name}\n{on_block}{JOBS}"


# ---------------------------------------------------------------------------
class AuditTests(Base):
    def test_a1_pass_output_is_render_14(self):
        d = self.folder("w", {"a.yml": wf("on:\n  workflow_dispatch:\n"), "b.yaml": wf("on:\n  workflow_call:\n")})
        rc, out, err = self.audit("w", cwd=self.tmp)
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(out, "dir w: workflow files: 2  with an automatic trigger: 0  with a schedule: 0\n"
                              "pass: no workflow file can start by itself\n")

    def test_a2_fail_output_is_render_15(self):
        self.folder("w", {
            "actions-artifact-prune.yml": wf("on:\n  schedule:\n    - cron: '0 0 * * *'\n  workflow_dispatch:\n"),
            "backend-migrations.yml": wf("on:\n  pull_request_target:\n  merge_group:\n"),
            "ok.yml": wf("on:\n  workflow_dispatch:\n"),
        })
        rc, out, err = self.audit("w", cwd=self.tmp)
        self.assertEqual(rc, 1)
        self.assertEqual(err, "")
        self.assertEqual(out,
            "dir w: workflow files: 3  with an automatic trigger: 2  with a schedule: 1\n"
            "FAIL: 2 workflow files can start by themselves\n"
            "  w/actions-artifact-prune.yml  schedule\n"
            "  w/backend-migrations.yml      merge_group, pull_request_target\n"
            "  Run: python3 rbf/scripts/disarm-workflows.py w\n")

    def test_a2b_singular_wording(self):
        self.folder("w", {"a.yml": wf("on: push\n")})
        rc, out, _ = self.audit("w", cwd=self.tmp)
        self.assertEqual(rc, 1)
        self.assertIn("FAIL: 1 workflow file can start by itself\n", out)

    def planted(self):
        return self.folder("planted", {
            "four-space.yml": 'on:\n    push:\n        branches: [main]\n    schedule:\n        - cron: "0 0 * * *"\njobs: {}\n',
            "seq.yml": "on:\n  - push\njobs: {}\n",
            "no-on.yml": "name: no-on\njobs: {}\n",
            "broken.yml": "on:\n  push:\n    branches: [main\njobs: {\n",
        })

    def test_a3_planted_folder_is_render_17(self):
        d = self.planted()
        rc, out, err = self.audit(d)
        self.assertEqual(rc, 1)
        self.assertEqual(err, "")
        p = d + "/"
        want = (
            f"dir {d}: workflow files: 4  with an automatic trigger: 2  with a schedule: 1\n"
            "FAIL: 2 workflow files can start by themselves\n"
            f"  {p}four-space.yml  push, schedule\n"
            f"  {p}seq.yml{' ' * 9}push\n"
            "FAIL: 2 workflow files have an on: block this audit can't read\n"
            f"  {p}broken.yml{' ' * 6}@BROKEN@\n"
            f"  {p}no-on.yml{' ' * 7}no on: key\n"
            "  Fix or remove these by hand: the disarm script refuses a folder with one.\n")
        got = re.sub(r"not YAML \(line \d+\)", "@BROKEN@", out)
        self.assertEqual(got, want)
        self.assertRegex(out, r"broken\.yml {6}not YAML \(line 4\)\n")

    def test_a3b_row_width_covers_the_longest_row_of_either_group(self):
        self.folder("w", {"a.yml": wf("on: push\n"), "a-much-longer-name.yml": "name: x\njobs: {}\n"})
        rc, out, _ = self.audit("w", cwd=self.tmp)
        w = len("w/a-much-longer-name.yml") + 2
        self.assertIn("  " + "w/a.yml".ljust(w) + "push\n", out)
        self.assertIn("  " + "w/a-much-longer-name.yml".ljust(w) + "no on: key\n", out)

    def test_a4_every_on_form_reads_the_same(self):
        forms = {
            "two.yml": "on:\n  push:\n    branches: [main]\n  workflow_dispatch:\n",
            "four.yml": "on:\n    push:\n        branches: [main]\n    workflow_dispatch:\n",
            "blocklist.yml": "on:\n  - push\n  - workflow_dispatch\n",
            "scalar.yml": "on: push\n",
            "flowlist.yml": "on: [push, workflow_dispatch]\n",
            "flowmap.yml": "on: {push: {branches: [main]}, workflow_dispatch: {}}\n",
            "quoted.yml": '"on":\n  push:\n',
            "single.yml": "'on':\n  push:\n",
            "comment.yml": "on: # when\n  push: # always\n",
        }
        self.folder("w", {k: wf(v) for k, v in forms.items()})
        rc, out, err = self.audit("w", cwd=self.tmp)
        self.assertEqual(rc, 1, out + err)
        rows = dict(re.findall(r"^  w/(\S+)\s+(.*)$", out, re.M))
        for k in forms:
            self.assertEqual(rows.get(k), "push", f"{k}: {out}")
        self.assertIn(f"workflow files: {len(forms)}  with an automatic trigger: {len(forms)}", out)

    def test_a5_manual_only_passes(self):
        self.folder("w", {
            "a.yml": wf("on:\n  workflow_dispatch:\n    inputs:\n      x:\n        type: string\n  workflow_call:\n    inputs:\n      y:\n        type: string\n"),
            "b.yml": wf("on: workflow_dispatch\n"),
            "c.yml": wf("on: [workflow_call, workflow_dispatch]\n"),
        })
        rc, out, err = self.audit("w", cwd=self.tmp)
        self.assertEqual(rc, 0, out + err)

    def test_a6_cannot_read_is_never_counted_manual_only(self):
        files = {
            "broken.yml": "on:\n  push:\n    branches: [main\njobs: {\n",
            "no-on.yml": "name: n\njobs: {}\n",
            "null-on.yml": "on:\njobs: {}\n",
            "num-on.yml": "on: 5\njobs: {}\n",
            "toplist.yml": "- a\n- b\n",
            "empty.yml": "",
            "twodocs.yml": "on: workflow_dispatch\n---\non: push\n",
            "listmix.yml": "on:\n  - push\n  - {a: b}\njobs: {}\n",
        }
        self.folder("w", files)
        rc, out, err = self.audit("w", cwd=self.tmp)
        self.assertEqual(rc, 1, out)
        self.assertNotIn("pass", out)
        self.assertIn(f"FAIL: {len(files)} workflow files have an on: block this audit can't read", out)
        rows = {m[0]: m[1] for m in re.findall(r"^  w/(\S+)\s+(.*)$", out, re.M)}
        self.assertEqual(set(rows), set(files))
        self.assertTrue(rows["broken.yml"].startswith("not YAML (line "), rows)
        self.assertEqual(rows["no-on.yml"], "no on: key")
        self.assertEqual(rows["null-on.yml"], "on: is empty")
        self.assertEqual(rows["toplist.yml"], "top level is not a mapping")
        self.assertEqual(rows["empty.yml"], "top level is not a mapping")
        self.assertIn("on: is not a string, a list or a mapping", rows["num-on.yml"])
        self.assertTrue(rows["twodocs.yml"].startswith("not YAML"), rows)
        self.assertIn("on: list item is not a string", rows["listmix.yml"])

    def test_a7_no_workflow_files_is_exit_2_never_pass(self):
        os.makedirs(os.path.join(self.tmp, "empty"))
        self.folder("other", {"readme.md": "x", "script.sh": "x"})
        os.makedirs(os.path.join(self.tmp, "nested", "sub"))
        with open(os.path.join(self.tmp, "nested", "sub", "a.yml"), "w") as f:
            f.write(wf("on: push\n"))
        for target in ("empty", "other", "nested", "does-not-exist", ZERO):
            rc, out, err = self.audit(target, cwd=self.tmp)
            self.assertEqual(rc, 2, (target, out, err))
            self.assertNotIn("pass", out)
            self.assertEqual(err, f"error: no workflow files in {target}. Nothing was checked.\n")
            self.assertEqual(out, "")

    def test_a7b_arguments(self):
        rc, out, err = run(AUDIT)
        self.assertEqual(rc, 2)
        self.assertIn("usage:", err)
        rc, out, err = run(AUDIT, "a", "b")
        self.assertEqual(rc, 2)

    def make_repo(self, files_by_commit):
        repo = os.path.join(self.tmp, "repo")
        subprocess.run(["git", "init", "-q", repo], check=True)
        revs = []
        for files in files_by_commit:
            wd = os.path.join(repo, ".github", "workflows")
            shutil.rmtree(wd, ignore_errors=True)
            os.makedirs(wd)
            for fn, text in files.items():
                with open(os.path.join(wd, fn), "w") as f:
                    f.write(text)
            subprocess.run(["git", "-C", repo, "add", "-A"], check=True)
            subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c",
                            "--allow-empty"], check=True)
            revs.append(subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip())
        return repo, revs

    def test_a8_rev_mode(self):
        repo, revs = self.make_repo([
            {"a.yml": wf("on:\n  push:\n  schedule:\n    - cron: '1 1 * * *'\n"), "b.yml": wf("on: workflow_dispatch\n")},
            {"a.yml": wf("on: workflow_dispatch\n")},
        ])
        env = {"RBF_GIT_DIR": os.path.join(repo, ".git")}
        rc, out, err = self.audit(revs[0], env=env)
        self.assertEqual(rc, 1, out + err)
        self.assertEqual(out.splitlines()[0], f"rev {revs[0]}: workflow files: 2  with an automatic trigger: 1  with a schedule: 1")
        self.assertIn("  .github/workflows/a.yml  push, schedule", out)
        self.assertIn(f"Run: python3 rbf/scripts/disarm-workflows.py .github/workflows\n", out)
        rc, out, err = self.audit(revs[1], env=env)
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(out, f"rev {revs[1]}: workflow files: 1  with an automatic trigger: 0  with a schedule: 0\n"
                              "pass: no workflow file can start by itself\n")
        rc, out, err = self.audit(ZERO, env=env)
        self.assertEqual((rc, out), (2, ""))

    def test_a8b_rev_first_line_equals_the_first_version(self):
        if not os.path.exists(OLD_AUDIT):
            self.skipTest("workflow-triggers.py is not on this machine")
        repo, revs = self.make_repo([{"a.yml": wf("on:\n  push:\n  schedule:\n    - cron: '1 1 * * *'\n"), "b.yml": wf("on: workflow_dispatch\n")}])
        src = open(OLD_AUDIT).read().replace('G = "/Volumes/tom-ssd/src/rb/cmux-rbf/.git"', f'G = "{repo}/.git"')
        old = os.path.join(self.tmp, "old-audit.py")
        with open(old, "w") as f:
            f.write(src)
        want = subprocess.run([sys.executable, old, revs[0]], capture_output=True, text=True).stdout.splitlines()[0]
        _, out, _ = self.audit(revs[0], env={"RBF_GIT_DIR": os.path.join(repo, ".git")})
        self.assertEqual(out.splitlines()[0], want)

    def test_a9_real_revs(self):
        if not (git_has(PIN) and git_has(PRE)):
            self.skipTest("the pin or main is not in this repo")
        for rev, want in ((PIN, (226, 140, 60)), (PRE, (67, 0, 0))):
            rc, out, err = self.audit(rev)
            first = out.splitlines()[0]
            self.assertEqual(first, f"rev {rev}: workflow files: {want[0]}  with an automatic trigger: {want[1]}  with a schedule: {want[2]}")
            self.assertEqual(rc, 0 if want[1] == 0 else 1)
            if os.path.exists(OLD_AUDIT):
                old = subprocess.run([sys.executable, OLD_AUDIT, rev], capture_output=True, text=True).stdout.splitlines()[0]
                self.assertEqual(first, old)

    def test_a10_extensions_and_schedule(self):
        self.folder("w", {"a.yaml": wf("on:\n  push:\n"), "b.yml": wf("on:\n  schedule:\n    - cron: '1 1 * * *'\n"),
                          "c.txt": wf("on: push\n"), "d.yml.bak": wf("on: push\n")})
        os.makedirs(os.path.join(self.tmp, "w", "sub"))
        with open(os.path.join(self.tmp, "w", "sub", "e.yml"), "w") as f:
            f.write(wf("on: push\n"))
        rc, out, _ = self.audit("w", cwd=self.tmp)
        self.assertEqual(out.splitlines()[0], "dir w: workflow files: 2  with an automatic trigger: 2  with a schedule: 1")


# ---------------------------------------------------------------------------
class DisarmTests(Base):
    def snapshot(self, d):
        out = {}
        for fn in sorted(os.listdir(d)):
            p = os.path.join(d, fn)
            if os.path.isfile(p):
                with open(p, "rb") as f:
                    out[fn] = f.read()
        return out

    def test_d1_automatic_stripped_manual_kept_in_every_form(self):
        keep = "  workflow_dispatch:\n    inputs:\n      x:\n        description: keep me\n"
        cases = {
            "two.yml": "on:\n  push:\n    branches: [main]\n  pull_request:\n    paths:\n      - a/**\n" + keep,
            "four.yml": "on:\n    push:\n        branches: [main]\n    schedule:\n        - cron: '1 1 * * *'\n    workflow_call:\n        inputs:\n            y:\n                type: string\n",
            "blocklist.yml": "on:\n  - push\n  - workflow_dispatch\n",
            "scalar.yml": "on: push\n",
            "flowlist.yml": "on: [push, pull_request, workflow_call]\n",
            "flowmap.yml": "on: {push: {branches: [main]}, workflow_dispatch: {inputs: {x: {type: string}}}}\n",
            "quoted.yml": '"on":\n  push:\n  workflow_dispatch:\n',
            "comments.yml": "on:\n  # why push\n  push:\n    branches: [main]\n\n  # nightly\n  schedule:\n    - cron: '1 1 * * *'\n  workflow_dispatch:\n",
            "only-auto.yml": "on:\n  push:\n  schedule:\n    - cron: '1 1 * * *'\n",
            "inline-comment.yml": "on: # trigger\n  push:\n",
        }
        d = self.folder("w", {k: wf(v) for k, v in cases.items()})
        rc, out, err = self.disarm("w", cwd=self.tmp)
        self.assertEqual(rc, 0, out + err)
        rc, aout, _ = self.audit("w", cwd=self.tmp)
        self.assertEqual(rc, 0, aout)
        import yaml
        def events(t):
            doc = yaml.safe_load(t)
            on = doc.get(True, doc.get("on"))
            if isinstance(on, str): return {on: None}
            if isinstance(on, list): return {e: None for e in on}
            return on
        for k in cases:
            before, after = yaml.safe_load(wf(cases[k])), yaml.safe_load(self.read(d, k))
            ev0, ev1 = events(wf(cases[k])), events(self.read(d, k))
            manual0 = {e: v for e, v in ev0.items() if e in ("workflow_dispatch", "workflow_call")}
            manual1 = {e: v for e, v in ev1.items() if e in ("workflow_dispatch", "workflow_call")}
            for e, v in manual0.items():
                self.assertIn(e, manual1, k)
                self.assertEqual(manual1[e], v, f"{k}: {e}'s config changed")
            self.assertEqual(set(ev1) - set(manual0), {"workflow_dispatch"} if not manual0 else set(), k)
            before.pop(True, None); before.pop("on", None); after.pop(True, None); after.pop("on", None)
            self.assertEqual(before, after, f"{k}: something outside on: changed")
            self.assertEqual(self.read(d, k).count(MARKER), 1, k)
        # a comment above an event goes with that event, and the kept event keeps its place
        text = self.read(d, "comments.yml")
        self.assertNotIn("why push", text)
        self.assertNotIn("nightly", text)
        self.assertIn("on:\n  " + MARKER + "\n  workflow_dispatch:\n", text)

    def test_d2_marker_once_and_second_run_changes_nothing(self):
        d = self.folder("w", {"a.yml": wf("on:\n  push:\n  workflow_dispatch:\n"), "b.yml": wf("on:\n  workflow_dispatch:\n")})
        self.assertEqual(self.disarm("w", cwd=self.tmp)[0], 0)
        first = self.snapshot(d)
        rc, out, err = self.disarm("w", cwd=self.tmp)
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.snapshot(d), first)
        self.assertIn("  unchanged        2   manual triggers only, marker already there\n", out)
        for fn, b in first.items():
            self.assertEqual(b.decode().count(MARKER), 1, fn)

    def test_d3_manual_only_files(self):
        old_marker = "# cmux-rbf: explicit dispatch only; no automatic CI in this fork. Reject upstream automatic triggers on sync."
        with_old = f"name: x\non:\n  {old_marker}\n  workflow_dispatch:\n" + JOBS
        bare = wf("on:\n  workflow_dispatch:\n")
        d = self.folder("w", {"marked.yml": with_old, "bare.yml": bare})
        rc, out, err = self.disarm("w", cwd=self.tmp)
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.read(d, "marked.yml"), with_old, "an existing fork marker counts and the file is byte-identical")
        new = self.read(d, "bare.yml")
        self.assertEqual(new, bare.replace("on:\n", "on:\n  " + MARKER + "\n", 1))
        self.assertIn("  marker added     1   manual triggers only already\n", out)
        self.assertIn("  unchanged        1   manual triggers only, marker already there\n", out)
        self.assertIn("  disarmed         0   automatic triggers removed, marker added\n", out)

    def test_d4_summary_is_render_13(self):
        files = {f"auto{i}.yml": wf("on:\n  push:\n  schedule:\n    - cron: '1 1 * * *'\n") for i in range(3)}
        files.update({f"manual{i}.yml": wf("on:\n  workflow_dispatch:\n") for i in range(2)})
        self.folder(".github/workflows", files)
        rc, out, err = self.disarm(".github/workflows", cwd=self.tmp)
        self.assertEqual((rc, err), (0, ""))
        self.assertEqual(out,
            "⋯ disarming 5 workflow files in .github/workflows\n"
            "  disarmed         3   automatic triggers removed, marker added\n"
            "  marker added     2   manual triggers only already\n"
            "  unchanged        0   manual triggers only, marker already there\n"
            "✓ no workflow file in .github/workflows can start by itself\n"
            "  Check it: python3 rbf/scripts/audit-workflows.py .github/workflows\n")
        rc, out, err = self.disarm(".github/workflows", cwd=self.tmp)
        self.assertEqual(out,
            "⋯ disarming 5 workflow files in .github/workflows\n"
            "  disarmed         0   automatic triggers removed, marker added\n"
            "  marker added     0   manual triggers only already\n"
            "  unchanged        5   manual triggers only, marker already there\n"
            "✓ no workflow file in .github/workflows can start by itself\n"
            "  Check it: python3 rbf/scripts/audit-workflows.py .github/workflows\n")

    def test_d5_only_the_on_block_and_the_marker_change(self):
        text = ("# top comment\nname: CI   # trailing\n\nenv:\n  A: 1\n\non:\n  # why\n  push:\n    branches: [main]\n  pull_request:\n"
                "  workflow_dispatch:\n\n# between\npermissions:\n  contents: read\n" + JOBS + "# end comment\n")
        for label, t in (("lf", text), ("crlf", text.replace("\n", "\r\n")), ("nofinal", text.rstrip("\n"))):
            d = self.folder("w-" + label, {"a.yml": t})
            os.chmod(os.path.join(d, "a.yml"), 0o755)
            rc, out, err = self.disarm("w-" + label, cwd=self.tmp)
            self.assertEqual(rc, 0, err)
            new = self.read(d, "a.yml")
            old_l, new_l = t.split("\n"), new.split("\n")
            r = on_region(old_l)
            changed_old = [i for tag, i1, i2, _, _ in difflib.SequenceMatcher(None, old_l, new_l, autojunk=False).get_opcodes()
                           if tag != "equal" for i in range(i1, max(i2, i1 + 1))]
            self.assertTrue(all(r[0] <= i < r[1] for i in changed_old), (label, changed_old, r))
            self.assertEqual(new.count(MARKER), 1, label)
            self.assertEqual(new.endswith("\n"), t.endswith("\n"), label)
            self.assertEqual("\r\n" in new, "\r\n" in t, label)
            self.assertEqual(new.replace("\r\n", "\n").split("\n")[0:6], t.replace("\r\n", "\n").split("\n")[0:6], label)
            self.assertEqual(stat.S_IMODE(os.stat(os.path.join(d, "a.yml")).st_mode), 0o755, "file mode kept")
            self.assertIn("# between\npermissions:", new.replace("\r\n", "\n"))
            self.assertTrue(new.replace("\r\n", "\n").rstrip("\n").endswith("# end comment"))

    def test_d6_unreadable_file_refuses_and_changes_nothing(self):
        planted = TestPlanted.make(self)
        before = self.snapshot(planted)
        copy = os.path.join(self.tmp, "planted-copy")
        shutil.copytree(planted, copy)
        rc, out, err = self.disarm(copy)
        self.assertEqual(rc, 1)
        self.assertEqual(out, "")
        p = copy + "/"
        want = ("error: 2 workflow files have an on: block this script can't read.\n"
                "       Nothing was changed.\n"
                f"  {p}broken.yml{' ' * 6}@BROKEN@\n"
                f"  {p}no-on.yml{' ' * 7}no on: key\n")
        self.assertEqual(re.sub(r"not YAML \(line \d+\)", "@BROKEN@", err), want)
        self.assertEqual(self.snapshot(copy), before, "the readable files must not be written either")
        self.assertTrue(filecmp.dircmp(planted, copy).same_files)

    def test_d6b_readable_files_alone_are_disarmed_then_pass(self):
        planted = TestPlanted.make(self)
        r = os.path.join(self.tmp, "readable")
        os.makedirs(r)
        for fn in ("four-space.yml", "seq.yml"):
            shutil.copy(os.path.join(planted, fn), r)
        rc, out, err = self.disarm(r)
        self.assertEqual(rc, 0, err)
        rc, out, err = self.audit(r)
        self.assertEqual(rc, 0, out + err)
        self.assertIn("workflow files: 2  with an automatic trigger: 0", out)

    def test_d7_no_workflow_files_and_arguments(self):
        os.makedirs(os.path.join(self.tmp, "empty"))
        rc, out, err = self.disarm("empty", cwd=self.tmp)
        self.assertEqual((rc, out), (2, ""))
        self.assertEqual(err, "error: no workflow files in empty. Nothing was changed.\n")
        self.assertEqual(self.disarm("missing", cwd=self.tmp)[0], 2)
        rc, out, err = self.disarm()
        self.assertEqual(rc, 2)
        self.assertIn("usage:", err)
        self.assertEqual(self.disarm("a", "b")[0], 2)

    def test_d8_extensions(self):
        d = self.folder("w", {"a.yaml": wf("on: push\n"), "c.txt": "on: push\n", "d.yml.bak": wf("on: push\n")})
        os.makedirs(os.path.join(d, "sub"))
        with open(os.path.join(d, "sub", "e.yml"), "w") as f:
            f.write(wf("on: push\n"))
        rc, out, err = self.disarm("w", cwd=self.tmp)
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.read(d, "c.txt"), "on: push\n")
        self.assertEqual(self.read(d, "d.yml.bak"), wf("on: push\n"))
        self.assertEqual(self.read(d, "sub/e.yml"), wf("on: push\n"))
        self.assertIn(MARKER, self.read(d, "a.yaml"))

    def test_d9_an_edit_that_breaks_the_file_is_refused(self):
        spec = importlib.util.spec_from_file_location("rbf_workflows", os.path.join(LIBDIR, "rbf_workflows.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        old = wf("on:\n  push:\n  workflow_dispatch:\n")
        good = wf("on:\n  " + MARKER + "\n  workflow_dispatch:\n")
        mod.verify_edit(old, good)  # fine
        for bad in (wf("on:\n  push:\n  workflow_dispatch:\n"),                     # still automatic
                    wf("on:\n  workflow_dispatch:\n").replace("runs-on", "runs_on"),  # jobs changed
                    wf("on:\n  workflow_call:\n"),                                   # manual set changed
                    "name: x\non:\n  workflow_dispatch:\n jobs: [\n"):                # not YAML
            with self.assertRaises(Exception, msg=bad):
                mod.verify_edit(old, bad)

    def test_d10_real_pin_copy(self):
        if not (git_has(PIN) and git_has(PRE)):
            self.skipTest("the pin or main is not in this repo")
        scratch = os.path.join(self.tmp, "pin")
        os.makedirs(scratch)
        arch = subprocess.run(["git", "-C", REPO, "archive", PIN, ".github/workflows"], capture_output=True)
        subprocess.run(["tar", "-x", "-C", scratch], input=arch.stdout, check=True)
        untouched = os.path.join(self.tmp, "untouched")
        shutil.copytree(scratch, untouched)
        wfdir = os.path.join(scratch, ".github", "workflows")
        rc, out, err = self.audit(wfdir)
        self.assertEqual(out.splitlines()[0], f"dir {wfdir}: workflow files: 226  with an automatic trigger: 140  with a schedule: 60")
        rc, out, err = self.disarm(wfdir)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out, f"⋯ disarming 226 workflow files in {wfdir}\n"
            "  disarmed       140   automatic triggers removed, marker added\n"
            "  marker added    86   manual triggers only already\n"
            "  unchanged        0   manual triggers only, marker already there\n"
            f"✓ no workflow file in {wfdir} can start by itself\n"
            f"  Check it: python3 rbf/scripts/audit-workflows.py {wfdir}\n")
        rc, out, err = self.audit(wfdir)
        self.assertEqual((rc, out.splitlines()[0]), (0, f"dir {wfdir}: workflow files: 226  with an automatic trigger: 0  with a schedule: 0"))
        old_dir = os.path.join(untouched, ".github", "workflows")
        import yaml
        for fn in sorted(os.listdir(wfdir)):
            new = open(os.path.join(wfdir, fn), newline="").read()
            old = open(os.path.join(old_dir, fn), newline="").read()
            self.assertGreaterEqual(len(re.findall(r"cmux-rbf: .*Reject upstream automatic triggers on sync\.", new)), 1, fn)
            old_l, new_l = old.split("\n"), new.split("\n")
            r = on_region(old_l)
            ch = [i for tag, i1, i2, _, _ in difflib.SequenceMatcher(None, old_l, new_l, autojunk=False).get_opcodes()
                  if tag != "equal" for i in range(i1, max(i2, i1 + 1))]
            self.assertTrue(all(r[0] <= i < r[1] for i in ch), (fn, ch, r))
            a, b = yaml.safe_load(old), yaml.safe_load(new)
            a.pop(True, None); a.pop("on", None); b.pop(True, None); b.pop("on", None)
            self.assertEqual(a, b, f"{fn}: outside on: changed")
        before = {fn: open(os.path.join(wfdir, fn), "rb").read() for fn in os.listdir(wfdir)}
        rc, out, err = self.disarm(wfdir)
        self.assertEqual(rc, 0)
        self.assertEqual({fn: open(os.path.join(wfdir, fn), "rb").read() for fn in os.listdir(wfdir)}, before)
        self.assertIn("  unchanged      226   manual triggers only, marker already there\n", out)
        # main's 67 files: already manual only, the fork's markers already there
        main = os.path.join(self.tmp, "main")
        os.makedirs(main)
        arch = subprocess.run(["git", "-C", REPO, "archive", PRE, ".github/workflows"], capture_output=True)
        subprocess.run(["tar", "-x", "-C", main], input=arch.stdout, check=True)
        md = os.path.join(main, ".github", "workflows")
        rc, out, _ = self.audit(md)
        self.assertEqual((rc, out.splitlines()[0]), (0, f"dir {md}: workflow files: 67  with an automatic trigger: 0  with a schedule: 0"))


# ---------------------------------------------------------------------------
# Fix round 1 (cold review of a721ed56ed)
# ---------------------------------------------------------------------------
def load_lib():
    spec = importlib.util.spec_from_file_location("rbf_workflows_under_test", os.path.join(LIBDIR, "rbf_workflows.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class FixRound1Tests(Base):
    def make_tree_repo(self, files):
        """A one-commit repo whose files are given by path under .github/workflows/."""
        repo = os.path.join(self.tmp, "trepo")
        subprocess.run(["git", "init", "-q", repo], check=True)
        for rel, text in files.items():
            p = os.path.join(repo, ".github", "workflows", rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(text)
        subprocess.run(["git", "-C", repo, "add", "-A"], check=True)
        subprocess.run(["git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "c"], check=True)
        rev = subprocess.run(["git", "-C", repo, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        return repo, rev

    def old_audit_first_line(self, repo, rev):
        src = open(OLD_AUDIT).read().replace('G = "/Volumes/tom-ssd/src/rb/cmux-rbf/.git"', f'G = "{repo}/.git"')
        old = os.path.join(self.tmp, "old-audit.py")
        with open(old, "w") as f:
            f.write(src)
        return subprocess.run([sys.executable, old, rev], capture_output=True, text=True).stdout.splitlines()[0]

    def snapshot_bytes(self, d):
        return {fn: open(os.path.join(d, fn), "rb").read() for fn in sorted(os.listdir(d))}

    # --- 1. rev mode reads every filename -------------------------------------------
    def test_f1_rev_mode_reads_a_non_ascii_name_and_a_quote(self):
        repo, rev = self.make_tree_repo({"déploy.yml": wf("on: push\n"), 'q"uote.yml': wf("on: push\n"),
                                         "ok.yml": wf("on: workflow_dispatch\n")})
        rc, out, err = self.audit(rev, env={"RBF_GIT_DIR": os.path.join(repo, ".git")})
        self.assertEqual(rc, 1, out + err)
        self.assertEqual(out.splitlines()[0], f"rev {rev}: workflow files: 3  with an automatic trigger: 2  with a schedule: 0")
        self.assertIn(".github/workflows/déploy.yml", out)
        self.assertIn('.github/workflows/q"uote.yml', out)
        if os.path.exists(OLD_AUDIT):
            self.assertEqual(self.old_audit_first_line(repo, rev), out.splitlines()[0], "workflow-triggers.py counts the same")

    # --- 5. only files directly in .github/workflows, in both modes -----------------
    def test_f5_a_nested_file_is_not_counted_in_either_mode(self):
        files = {"a.yml": wf("on: push\n"), "sub/nested.yml": wf("on: push\n"), "sub/deeper/x.yaml": wf("on: push\n")}
        repo, rev = self.make_tree_repo(files)
        want = f"rev {rev}: workflow files: 1  with an automatic trigger: 1  with a schedule: 0"
        rc, out, err = self.audit(rev, env={"RBF_GIT_DIR": os.path.join(repo, ".git")})
        self.assertEqual(out.splitlines()[0], want, out + err)
        rc, out, err = self.audit(os.path.join(repo, ".github", "workflows"))
        self.assertIn("workflow files: 1  with an automatic trigger: 1", out.splitlines()[0])
        if os.path.exists(OLD_AUDIT):
            self.assertEqual(self.old_audit_first_line(repo, rev), want, "workflow-triggers.py counts the same")

    # --- 2. the disarm never deletes the fork's marker ------------------------------
    def test_f2_the_marker_above_a_readded_event_survives_and_a_second_run_is_unchanged(self):
        shapes = {
            "a.yml": f"name: x\non:\n  {MARKER}\n  push:\n    branches: [main]\n  workflow_dispatch:\njobs: {{}}\n",
            "b.yml": f"name: x\non:\n  {MARKER}\n  push:\n    branches: [main]\njobs: {{}}\n",
            "between.yml": f"name: x\non:\n  workflow_dispatch:\n  {MARKER}\n  push:\n  schedule:\n    - cron: '1 1 * * *'\njobs: {{}}\n",
            "list.yml": f"name: x\non:\n  {MARKER}\n  - push\njobs: {{}}\n",
        }
        d = self.folder("w", shapes)
        rc, out, err = self.disarm("w", cwd=self.tmp)
        self.assertEqual(rc, 0, err)
        for fn in shapes:
            new = self.read(d, fn)
            self.assertEqual(new.count(MARKER), 1, f"{fn}:\n{new}")
            self.assertEqual(list(load_lib().read_events(new)), ["workflow_dispatch"], f"{fn}:\n{new}")
        first = self.snapshot_bytes(d)
        rc, out, err = self.disarm("w", cwd=self.tmp)
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.snapshot_bytes(d), first)
        self.assertIn(f"  {'unchanged':<12}{len(shapes):>6}   manual triggers only, marker already there\n", out)

    def test_f2b_an_edit_without_the_marker_is_refused(self):
        mod = load_lib()
        old = wf("on:\n  push:\n  workflow_dispatch:\n")
        with self.assertRaises(mod.UnsafeEdit):
            mod.verify_edit(old, wf("on:\n  workflow_dispatch:\n"))

    # --- 3. `on` read the way GitHub does; a duplicate key is refused ----------------
    DUPLICATES = {
        "on-then-On.yml": "on:\n  push:\nOn:\n  workflow_dispatch:\njobs: {}\n",
        "on-then-yes.yml": "on:\n  push:\njobs: {}\nyes:\n  workflow_dispatch:\n",
        "on-then-true.yml": "on:\n  push:\njobs: {}\ntrue:\n  workflow_dispatch:\n",
        "indented-twice.yml": "  on:\n    push:\n  jobs: {}\n  on:\n    workflow_dispatch:\n",
        "quoted-escape.yml": '"on":\n  push:\njobs: {}\n"o\\x6e":\n  workflow_dispatch:\n',
        "single-and-double.yml": "'on':\n  push:\njobs: {}\n\"on\" :\n  workflow_dispatch:\n",
        "event-twice.yml": "on:\n  push:\n  workflow_dispatch:\n  push:\njobs: {}\n",
    }

    def test_f3_a_duplicate_key_is_a_cannot_read_fail_and_a_disarm_refusal(self):
        for fn, text in self.DUPLICATES.items():
            d = self.folder("dup-" + fn, {fn: text})
            rc, out, err = self.audit(d)
            self.assertEqual(rc, 1, f"{fn}: {out}{err}")
            self.assertIn("FAIL: 1 workflow file has an on: block this audit can't read", out, fn)
            self.assertNotIn("pass", out, fn)
            self.assertIn("twice", out, fn)
            before = self.snapshot_bytes(d)
            rc, out, err = self.disarm(d)
            self.assertEqual((rc, out), (1, ""), f"{fn}: {err}")
            self.assertIn(f"{d}/{fn}", err)
            self.assertIn("twice", err, fn)
            self.assertEqual(self.snapshot_bytes(d), before, fn)

    def test_f3b_on_alone_in_each_spelling_reads_and_a_bool_lookalike_is_not_on(self):
        mod = load_lib()
        for text in ("on: push\n", '"on": push\n', "'on': push\n", "  on: push\n"):
            self.assertEqual(mod.read_events(text), {"push": None}, text)
        for text in ("On: push\n", "true: push\n", "yes: push\n"):
            with self.assertRaises(mod.Unreadable, msg=text):
                mod.read_events(text)

    def test_f3c_a_duplicate_is_named_as_written_and_bool_keys_matter_only_at_the_top(self):
        mod = load_lib()
        with self.assertRaises(mod.Unreadable) as cm:
            mod.read_events(self.DUPLICATES["on-then-On.yml"])
        self.assertEqual(str(cm.exception), "On: key twice (line 3)")
        # a step's `with:` may hold `yes:` and `on:`: GitHub reads `on` only at the top
        step = wf("on: workflow_dispatch\n").replace("      - run: echo hi\n",
                                                     "      - uses: a/b@v1\n        with:\n          yes: 1\n          on: 2\n")
        self.assertEqual(mod.read_events(step), {"workflow_dispatch": None})
        d = self.folder("w", {"step.yml": step})
        rc, out, err = self.audit(d)
        self.assertEqual(rc, 0, out + err)
        # the same string twice is refused at any depth
        with self.assertRaises(mod.Unreadable):
            mod.read_events(step.replace("          on: 2\n", "          on: 2\n          on: 3\n"))

    def test_f6b_a_marker_on_the_on_line_is_carried_down(self):
        old_words = "# cmux-rbf: explicit dispatch only; no automatic CI in this fork. Reject upstream automatic triggers on sync."
        d = self.folder("w", {"a.yml": wf(f"on: [push, workflow_dispatch] {old_words}\n")})
        rc, out, err = self.disarm("w", cwd=self.tmp)
        self.assertEqual(rc, 0, err)
        new = self.read(d, "a.yml")
        self.assertEqual(new, wf(f"on:\n  {old_words}\n  workflow_dispatch:\n"))
        self.assertNotIn(MARKER, new)

    # --- 6. the refusal names both kinds of row --------------------------------------
    def test_f6_the_refusal_header_covers_cannot_read_and_cannot_edit(self):
        self.folder("w", {
            "anchor.yml": "on:\n  push: &p\n    branches: [main]\n  workflow_dispatch:\njobs:\n  a:\n    x: *p\n",
            "no-on.yml": "name: n\njobs: {}\n",
        })
        rc, out, err = self.disarm("w", cwd=self.tmp)
        self.assertEqual((rc, out), (1, ""))
        w = len("w/anchor.yml") + 2
        self.assertEqual(err,
            "error: 1 workflow file has an on: block this script can't read.\n"
            "error: 1 workflow file can't be edited safely.\n"
            "       Nothing was changed.\n"
            f"  {'w/no-on.yml'.ljust(w)}no on: key\n"
            f"  {'w/anchor.yml'.ljust(w)}can't edit it safely: the edited file no longer reads: not YAML (line 6)\n")


class TestPlanted:
    @staticmethod
    def make(tc):
        return AuditTests.planted(tc)


# ---------------------------------------------------------------------------
class Result(unittest.TextTestResult):
    pass


def main():
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=2, resultclass=Result)
    finished = False
    try:
        res = runner.run(suite)
        finished = True
    finally:
        if not finished:
            print("\nDID NOT FINISH: the test file stopped early")
    failed = len(res.failures) + len(res.errors)
    skipped = len(res.skipped)
    passed = res.testsRun - failed - skipped
    print(f"\n{passed} passed, {failed} failed, {skipped} skipped")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
