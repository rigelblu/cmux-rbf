# Submodule Safety

Submodule commits can be easy to lose. The parent repository records only a commit SHA, not the branch that made the SHA reachable.

## Safe sequence

1. Enter the submodule.
2. Create or select the intended branch.
3. Commit the submodule changes.
4. Push the submodule commit to the correct remote.
5. Verify the pushed branch contains the commit.
6. Return to the parent repository.
7. Commit the updated submodule pointer.

For Ghostty:

```bash
cd ghostty
git remote -v            # origin = rigelblu/ghostty-rbf (OURS) · manaflow = upstream
git checkout -b <branch>
git commit -am "..."
git push origin <branch>
```

Then confirm the commit is actually published, before any parent commit references it:

```bash
git fetch origin <branch>
git merge-base --is-ancestor HEAD origin/<branch> && echo PUBLISHED
```

<!-- cmux-rbf: pruned upstream text — upstream said `git push manaflow <branch>`, `git fetch manaflow main` / `merge-base ... manaflow/main`, and hedged that "`origin` may be upstream and `manaflow` may be the fork". In cmux-rbf there is nothing to check: `origin` IS ours (rigelblu/ghostty-rbf) and `manaflow` IS upstream. The hedge contradicted skills/cmux-ghostty/SKILL.md, which states it unambiguously, and steered readers of this 'detailed reference' back into pushing at upstream. Reject this hunk on upstream sync. -->

## Detached HEAD hazard

Do not commit submodule changes on a detached HEAD and then update the parent pointer. That creates a parent commit pointing at a SHA that may not be reachable from any remote branch, and a future checkout fails to fetch it. <!-- cmux-rbf: pruned upstream text — removed 'or CI job' — no CI in this fork, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->

Nothing catches this for you: after pushing a submodule commit, verify it is published with `git merge-base --is-ancestor HEAD origin/<branch>` before committing the parent pointer.

## Fork documentation

Keep `docs/ghostty-fork.md` updated when fork changes or conflict notes matter for future upstream merges. The point is to preserve why the fork diverged, not just that it diverged.

## GhosttyKit optimization

Rebuild GhosttyKit.xcframework with ReleaseFast:

```bash
cd ghostty && zig build -Demit-xcframework=true -Dxcframework-target=universal -Doptimize=ReleaseFast
```

Debug or default optimization builds can hide performance characteristics and should not be used for the checked-in framework refresh path.
