# cmux agent notes

# 🔵⋯ Read RBF
Read and use @rbf/AGENTS.md

Keep repo-wide decisions here; procedures belong in [CONTRIBUTING.md](CONTRIBUTING.md),
[area instructions](#area-instructions) and [task skills](skills/README.md).
Read the matching skill before changing an area, then only the references needed.

**Manaflow AI team members and their agents:** read the private [cmuxterm-hq CLAUDE.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/CLAUDE.md) and [AGENTS.md](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/AGENTS.md) before fleet or CI work. They are the entry point for fleet builds, CI routing, agent coordination, and landing rules. Start fleet work at [Fleet and CI: start here](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/FLEET-AND-CI.md). External contributors can ignore this block; those links return 404 for them.

## Verification and isolation

- Before committing, setup or a native build, [choose scoped verification](skills/cmux-testing/references/local-vs-ci-validation.md).
  Start with `python3 scripts/verify-local.py`; docs and portable tooling need no app build.
  Run repository commands only in a [trusted checkout](docs/contributor-verification.md#trust-boundary),
  including `verify-local.py --help`, `--list` and `--repo`. Push does not run checks for you.
- Use [CONTRIBUTING.md](CONTRIBUTING.md#getting-started) for setup. Outside cmuxterm-hq-created
  checkouts, set `CMUX_DEV_BACKEND_MODE=local` for dev builds. Follow [tagged builds](skills/cmux-dev-workflow/references/tagged-builds.md)
  for commands and cache reuse; team fleet tasks start at
  [Fleet and CI: start here](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/build-fleet/FLEET-AND-CI.md).
  Never use bare `xcodebuild` or an untagged `cmux DEV.app`. Clean up only your own tags.
<!-- cmux-rbf: pruned upstream text — removed the `dev-build` label bullet (a fleet dogfood build and a PR link comment for each push): no CI and no fleet build here, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->
- Never quit, kill, relaunch, replace or launch-profile the user's running cmux
  (`/Applications/cmux.app`, `com.cmuxterm.app`), including through a Release build or
  another bundle with that ID. Never set `CMUX_ALLOW_REPLACING_RUNNING_CMUX`; only the
  user may. Reproduce in a tagged build and attach profiling to its PID.
- Dogfood through `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh`, never `/tmp/cmux-cli`.
  Never report raw `.app` paths or `file://` URLs. <!-- cmux-rbf: pruned upstream text — removed 'report the build to the user as a markdown link to http://127.0.0.1:17320/<tag>' (upstream's replacement for the older file:// App-path recipe): no such build server runs in this fork, and a link addresses a bundle that was already built, so it goes stale or names someone else's build. Hand back the make command instead — `make run`, or `make -C <absolute worktree> run` from an agent worktree; see rbf/AGENTS.md. Reject this hunk on upstream sync. -->
- App-linked code (`Sources/`, `CLI/`, `TunnelExtension/` and their packages) must
  remain [Swift 6.0 compatible](skills/cmux-architecture/references/swift-6-0-compatibility.md).

## Area instructions

Read these before working in their scope; nested files may not load automatically:

- `ios/` or `Packages/iOS/`: [ios/AGENTS.md](ios/AGENTS.md).
- `web/` or any cmux Cloud database work: [web/AGENTS.md](web/AGENTS.md).
- `cmux-tui/`: [cmux-tui/AGENTS.md](cmux-tui/AGENTS.md).

## Contributions and publication

Before fixing a bug or adding a feature, search open upstream PRs by symptom or
issue number. Prefer landing an outside contributor's existing PR; push fixups
only when maintainer edits are allowed, and explain the changes. If using their
approach in your own PR, credit them in every such commit with `Co-authored-by`
using their commit email, link your PR from theirs and thank them. Let a human
close it; never close an outside PR without a human-written explanation.

The server directories listed in [LICENSE](LICENSE) (`web/`, `workers/ci-artifacts/`,
`workers/iroh-v2/`, `workers/presence/`, `services/iroh-relay-minter/`,
`cmux-tui/relays/cloudflare-do/`) use the Business Source License, which needs
every outside author's CLA grant. Do not merge a PR that changes those
directories while CLA Assistant is red, and do not copy an outside
contributor's work there under a `Co-authored-by` trailer unless that person
has signed the CLA. Keep code that ships in the macOS or iOS app out of those
directories.

Read [STYLE.md](STYLE.md) before drafting or revising issues, PR descriptions,
RFCs or progress updates. Fill the PR's `## Changelog` section with one
`Added`/`Changed`/`Fixed`/`Removed` line for user-visible changes, otherwise `none`.
Do not edit `CHANGELOG.md` in feature PRs; release tooling owns it.

## CI, review and merge

- **Superseded in cmux-rbf — see @rbf/AGENTS.md.** This fork keeps the red proof but commits once; the separate failing-test commit below is upstream's.
- Commit the failing behavioral regression before its fix; record the same
  focused command's red and green results ([testing policy](skills/cmux-testing/SKILL.md#reproduce-and-repair)).
  A bug-fix PR body names that command, its failure on the base and its pass on the head,
  then an `### Observed / Not run` section: what you ran and saw, then what you only read
  or didn't run. <!-- cmux-rbf: pruned upstream text — removed '`gh-merge-green` warns when a fix PR lacks it' and the bullet on checking executed CI tests on the current SHA and adding `full-ci` — no CI here, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->
- Keep branches current locally with `scripts/merge-main.sh`; follow
  [the merge-main guide](docs/ci/merge-main.md) and never force-push over its merge.
- `gh pr merge` saying "base branch policy prohibits the merge" means the token lacks the `workflow`
  scope or GitHub timed out, not a rule: run `gh auth refresh -h github.com -s workflow`, or merge with
  `gh api -X PUT repos/OWNER/REPO/pulls/N/merge -f merge_method=squash -f sha=SHA`, which names the cause. Never `--admin`.
- Before opening a PR and before merging, check it against [REVIEW.md](REVIEW.md) (draft),
  the mistakes our review history keeps catching.
- Before merge an independent [review subagent](skills/cmux-review/SKILL.md) passes its head.
  Merging app/runtime/UI changes requires the user's explicit approval after dogfood.
  First pass, dogfood, red base and receipts: [dogfood and merge](skills/cmux-review/references/dogfood-and-merge.md).
  Notify with `cmux notify` when a socket is available. <!-- cmux-rbf: pruned upstream text — removed 'it causes no red of its own; base reds, flakes and pending checks don't hold it, and no person approves it', merging with `gh-merge-green`, and waiving a red check with `--override` — no checks or bots ever run here, and the gate that exists is the manual suite plus Tom's dogfood, see rbf/AGENTS.md. The approval sentence is upstream's earlier text, kept. Reject this hunk on upstream sync. -->

## Implementation rules by task

Use these existing owners instead of duplicating their checklists here:

| Touching | Read before editing |
| --- | --- |
| Typing paths, SwiftUI list/store boundaries, rendering, find layering, UTTypes or OS-specific bugs | [cmux-debugging](skills/cmux-debugging/SKILL.md) <!-- cmux-rbf: pruned upstream text — the OS-version pitfall now lives in cmux-debugging's runtime-pitfalls; the CI reference and the AWS M4 Pro builder fleet stay removed there — not reachable from this fork, see rbf/AGENTS.md. Reject this hunk on upstream sync. --> |
| Packages, workspace groups, lockfiles or feature flags | [cmux-architecture](skills/cmux-architecture/SKILL.md). **Run `python3 scripts/check-workspace-package-groups.py --check` yourself after any package move, and `python3 scripts/check-package-resolved-policy.py` after any SwiftPM change — nothing runs them for you.** <!-- cmux-rbf: pruned upstream text — was 'fails on drift', implying CI — no CI here, see rbf/AGENTS.md. Reject this hunk on upstream sync. --> |
| Submodules or GhosttyKit | [cmux-ghostty](skills/cmux-ghostty/SKILL.md) |
| User-facing strings, docs or help | [cmux-localization](skills/cmux-localization/SKILL.md); report the localization audit. Every web message catalog means **all 20 locales under `web/messages/`, not just `en.json`/`ja.json`**. <!-- cmux-rbf: pruned upstream text — upstream said en/ja; that is two of twenty here and would badly under-scope a localization audit. Reject this hunk on upstream sync. --> |
| New cmux shortcuts | [cmux-keyboard-shortcuts](skills/cmux-keyboard-shortcuts/SKILL.md) |
| Tests or target wiring | [cmux-testing](skills/cmux-testing/SKILL.md); run `scripts/sync-test-wiring` after adding, renaming or deleting a `cmuxTests/` file. **Run `./scripts/lint-pbxproj-test-wiring.sh` yourself; nothing runs it for you.** <!-- cmux-rbf: pruned upstream text — removed 'bot reviews' and the `workflow-guard-tests` job — no CI and no review bots here, see rbf/AGENTS.md. Reject this hunk on upstream sync. --> |
| Multiple entrypoints or a bug that tests previously missed | [cmux-shared-behavior](skills/cmux-shared-behavior/SKILL.md); share action/mutation paths, verify every entrypoint, and cover the missed repro |

## Remote CLI relay

For v2 socket methods and remote CLI changes, read [relay authorization](skills/cmux-socket-policy/references/remote-relay-authorization.md).
`RemoteRelayCommandPolicy` defaults to deny. Allowlist only for a needed remote
flow, scoped to the session's objects; command-bearing params stay denied on
every method. The PR must analyze local command/content
execution, access to unowned objects and local-state exposure, and include the
required policy tests and ID scoping. Unsafe local effects must be redesigned.
Never allowlist terminal spawn/respawn without live verification that it executes
on the remote host. An allowlist addition without this analysis blocks review.
