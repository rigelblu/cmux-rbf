---
name: cmux-ghostty
description: "Ghostty submodule and GhosttyKit workflow rules for cmux. Use when modifying the ghostty submodule, rebuilding GhosttyKit.xcframework, updating the parent submodule pointer, or documenting fork conflict notes."
---

# cmux Ghostty

## GhosttyKit builds

When rebuilding GhosttyKit.xcframework, always use Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

## Submodule workflow

<!-- cmux-rbf: pruned upstream text — upstream's remote mapping is INVERTED here (it says origin=upstream, manaflow=fork; in cmux-rbf origin=rigelblu/ghostty-rbf i.e. OURS, manaflow=manaflow-ai i.e. upstream), so `git push manaflow` would push our commits at upstream. Also replaced git with jj per rbf/AGENTS.md. Reject this hunk on upstream sync. -->

Ghostty changes are committed **in the `ghostty` submodule** and pushed to **`origin`**, which in this fork is `rigelblu/ghostty-rbf` (ours). `manaflow` is upstream — never push there.

The submodule is a plain git checkout, not a jj repo, so submodule commands stay git. Everything in the **parent** repo is jj.

```bash
cd ghostty
git remote -v            # origin = rigelblu/ghostty-rbf (OURS) · manaflow = upstream
git checkout -b <branch>
git commit -am "..."
git push origin <branch>
```

**Publish the submodule commit before the parent pointer references it**, and verify rather than trust:

```bash
git fetch origin <branch> && git merge-base --is-ancestor HEAD origin/<branch> && echo PUBLISHED
```

To take upstream ghostty changes, merge `manaflow/main` into your branch (dry-run first — `--no-commit --no-ff` — and read the conflict count before committing).

Then move the parent pointer, in jj:

```bash
cd ..
jj describe -m "fix (ghostty) | <user need> (#cm-N)"   # parent repo is jj
jj bookmark set <bookmark> -r @      # push moves an existing bookmark; it does not create one
jj git push --bookmark <bookmark>
```

Push with **jj**, not `git push`: a branch pushed by git arrives untracked, and jj treats untracked remote bookmarks as immutable — it will hide your own branch from `jj log` and refuse to rewrite it.

## Submodule safety

When modifying a submodule, always push the submodule commit to its remote `main` branch before committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch; the commit can be orphaned and lost.

Verify with:

```bash
cd <submodule> && git merge-base --is-ancestor HEAD origin/main
```

## Detailed reference

- Read [references/submodule-safety.md](references/submodule-safety.md) before committing submodule pointer updates or resolving Ghostty fork conflicts.
