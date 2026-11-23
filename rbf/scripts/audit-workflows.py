#!/usr/bin/env python3
"""Count the GitHub workflow files that can start by themselves (#cm-142.3).

    python3 rbf/scripts/audit-workflows.py <rev | folder>

<folder> is the folder that holds the workflow files (.github/workflows), never a
checkout's root; <rev> is a git rev, read from the repo this script lives in (or
the git dir named by RBF_GIT_DIR). Each file's `on:` block is read as YAML, so its
indentation and form don't change the count; every event other than
workflow_dispatch and workflow_call is automatic. A file whose `on:` it can't read
is never counted as manual-only: it gets its own FAIL.

Exit 0: no file can start by itself. Exit 1: one can, or one can't be read.
Exit 2: no workflow files in the input (or bad usage); never a `pass`.

The first line is workflow-triggers.py's count line, word for word, so `diff` of
the two on one rev prints nothing.
"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
import rbf_workflows as wf  # noqa: E402


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print("usage: audit-workflows.py <rev | folder>", file=sys.stderr)
        return 2 if len(argv) != 2 else 0
    target = argv[1]
    if os.path.isdir(target):
        label, files = f"dir {target}", wf.list_folder(target)
    else:
        label, files = f"rev {target}", wf.list_rev(target)
    if not files:
        print(f"error: no workflow files in {target}. Nothing was checked.", file=sys.stderr)
        return 2

    auto, unreadable, scheduled = [], [], 0
    for path, text in files:
        events, reason = wf.classify(text)
        if events is None:
            unreadable.append((path, reason))
            continue
        a = wf.automatic(events)
        if a:
            auto.append((path, ", ".join(a)))
        if "schedule" in events:
            scheduled += 1
    print(f"{label}: workflow files: {len(files)}  with an automatic trigger: {len(auto)}  with a schedule: {scheduled}")
    if not auto and not unreadable:
        print("pass: no workflow file can start by itself")
        return 0

    width = max(len(p) for p, _ in auto + unreadable) + 2
    if auto:
        n = len(auto)
        print(f"FAIL: {n} workflow file{'s' if n != 1 else ''} can start by {'themselves' if n != 1 else 'itself'}")
        for path, ev in auto:
            print(f"  {path.ljust(width)}{ev}")
    if unreadable:
        n = len(unreadable)
        print(f"FAIL: {n} workflow file{'s' if n != 1 else ''} {'have' if n != 1 else 'has'} an on: block this audit can't read")
        for path, reason in unreadable:
            print(f"  {path.ljust(width)}{reason}")
        print("  Fix or remove these by hand: the disarm script refuses a folder with one.")
    else:
        # a rev is not a folder the script can write: name the folder the files live in
        print(f"  Run: python3 rbf/scripts/disarm-workflows.py {target if os.path.isdir(target) else '.github/workflows'}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
