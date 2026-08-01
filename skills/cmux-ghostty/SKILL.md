---
name: cmux-ghostty
description: "Ghostty submodule and GhosttyKit workflow rules for cmux. Use when modifying the ghostty submodule, rebuilding GhosttyKit.xcframework, updating the parent submodule pointer, or documenting fork conflict notes."
---

# cmux Ghostty

## GhosttyKit builds

Always rebuild the xcframework with Release optimizations:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

## Submodule workflow

<!-- cmux-rbf: pruned upstream text — upstream's remote guidance points at manaflow-ai/ghostty as the fork to push to; in cmux-rbf `origin` is rigelblu/ghostty-rbf (OURS) and `manaflow` is upstream, so pushing at a manaflow remote would push our commits at upstream. Upstream-of-upstream (ghostty-org) is not our merge source either — we take upstream ghostty via `manaflow/main`. Also parent-repo git -> jj per rbf/AGENTS.md. Reject this hunk on upstream sync. -->

Ghostty changes are committed **in the `ghostty` submodule** and pushed to **`origin`**, which in this fork is `rigelblu/ghostty-rbf` (ours). `manaflow` is upstream — never push there. Keep `docs/ghostty-fork.md` current with fork changes and conflict notes.

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

For any submodule (ghostty, `vendor/bonsplit`, `homebrew-cmux`), push the submodule commit to its remote branch **before** committing the updated pointer in the parent repo. Never commit on a detached HEAD or a temporary branch: the parent then points at a SHA unreachable from any remote branch, and a future checkout fails to fetch it. <!-- cmux-rbf: pruned upstream text — removed 'or CI job' — no CI in this fork, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->

Verify the commit is reachable from the branch the pointer should track, using the remote you just pushed to:

```bash
cd ghostty && git fetch origin main && git merge-base --is-ancestor HEAD origin/main
```

## Detailed reference

- [references/submodule-safety.md](references/submodule-safety.md): the ordered safe sequence and fork documentation expectations.
