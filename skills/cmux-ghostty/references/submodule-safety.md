# Submodule Safety

The parent repository records only a commit SHA, not the branch that makes the SHA reachable, so submodule commits are easy to lose.

## Safe sequence

1. Enter the submodule.
2. Create or select the intended branch (never a detached HEAD).
3. Commit the submodule changes.
4. Push to `origin`. <!-- cmux-rbf: pruned upstream text — upstream said `.gitmodules` points every submodule at `manaflow-ai/*`; in cmux-rbf `origin` is rigelblu/ghostty-rbf (OURS) and `manaflow` is upstream — pushing at a manaflow remote would push our commits at upstream. Reject this hunk on upstream sync. --> In this fork `origin` is `rigelblu/ghostty-rbf` (ours); `manaflow` is upstream — never push there.
5. Verify the pushed branch contains the commit, checking the branch you actually pushed rather than always `main`: `git merge-base --is-ancestor HEAD <remote>/<branch>`.
6. Return to the parent repository and commit the updated pointer.

Skipping step 4 or 5 produces a parent commit pointing at an orphaned SHA that a future checkout cannot fetch. <!-- cmux-rbf: pruned upstream text — removed 'or CI job' — no CI in this fork, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->

Nothing catches this for you: after pushing a submodule commit, verify it is published with `git merge-base --is-ancestor HEAD origin/<branch>` before committing the parent pointer.

## Fork documentation

Keep `docs/ghostty-fork.md` updated when fork changes or conflict notes matter for a future upstream merge. Record why the fork diverged, not just that it did.
