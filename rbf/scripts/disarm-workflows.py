#!/usr/bin/env python3
"""Strip every automatic trigger from a folder of GitHub workflow files (#cm-142.3).

    python3 rbf/scripts/disarm-workflows.py <folder>

<folder> is the folder that holds the workflow files (.github/workflows), never a
checkout's root. In each .yml/.yaml file directly in it, every event under `on:`
other than workflow_dispatch and workflow_call is removed (workflow_dispatch is
added when nothing manual is left) and the fork's marker comment is added once.
Nothing else in the file changes: only the `on:` block's lines, and the marker.

It reads every file before it writes any. If one's `on:` can't be read, or an edit
would change more than the block, it names each such file (the ones it can't read
first, then the ones it can't edit safely), changes no file, and exits 1. With no workflow file it exits 2. A second run changes nothing.

Run it on a scratch copy or on the sync's own line, never to "see what it does" on
a tracked folder you don't mean to change. `audit-workflows.py` checks the result.
"""
import os
import shutil
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import rbf_workflows as wf  # noqa: E402


def write_file(path, text):
    tmp = path + ".disarm-tmp"
    with open(tmp, "wb") as f:
        f.write(text.encode("utf-8"))
    shutil.copymode(path, tmp)
    os.replace(tmp, path)


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print("usage: disarm-workflows.py <folder>", file=sys.stderr)
        return 2 if len(argv) != 2 else 0
    folder = argv[1]
    files = wf.list_folder(folder) if os.path.isdir(folder) else []
    if not files:
        print(f"error: no workflow files in {folder}. Nothing was changed.", file=sys.stderr)
        return 2

    # Read and edit everything in memory first: all or nothing.
    plan, bad, unsafe = [], [], []
    for path, text in files:
        if text is None:
            bad.append((path, "not UTF-8 text"))
            continue
        try:
            new, status = wf.disarm_text(text)
            wf.verify_edit(text, new)
        except wf.Unreadable as e:
            bad.append((path, str(e)))
            continue
        except wf.UnsafeEdit as e:
            unsafe.append((path, f"can't edit it safely: {e}"))
            continue
        plan.append((path, text, new, status))
    if bad or unsafe:
        # the same row width the audit prints, so the rows line up with its output
        rows = bad + unsafe + [(p, "") for p, t in files if t is not None and wf.classify(t)[0] is not None and wf.automatic(wf.classify(t)[0])]
        width = max(len(p) for p, _ in rows) + 2
        if bad:
            n = len(bad)
            print(f"error: {n} workflow file{'s' if n != 1 else ''} {'have' if n != 1 else 'has'} an on: block this script can't read.", file=sys.stderr)
        if unsafe:
            n = len(unsafe)
            print(f"error: {n} workflow file{'s' if n != 1 else ''} can't be edited safely.", file=sys.stderr)
        print("       Nothing was changed.", file=sys.stderr)
        for path, reason in bad + unsafe:
            print(f"  {path.ljust(width)}{reason}", file=sys.stderr)
        return 1

    counts = {"disarmed": 0, "marker": 0, "unchanged": 0}
    for path, old, new, status in plan:
        counts[status] += 1
        if new != old:
            write_file(path, new)

    n = len(files)
    print(f"⋯ disarming {n} workflow file{'s' if n != 1 else ''} in {folder}")
    print(f"  {'disarmed':<12}{counts['disarmed']:>6}   automatic triggers removed, marker added")
    print(f"  {'marker added':<12}{counts['marker']:>6}   manual triggers only already")
    print(f"  {'unchanged':<12}{counts['unchanged']:>6}   manual triggers only, marker already there")
    print(f"✓ no workflow file in {folder} can start by itself")
    print(f"  Check it: python3 rbf/scripts/audit-workflows.py {folder}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
