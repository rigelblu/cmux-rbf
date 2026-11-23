---
name: cmux-testing
description: "Choose scoped cmux verification, add behavioral tests, and validate Swift test targets and wiring. Use when adding tests or deciding what local/CI evidence a change needs."
---

# cmux Testing

## Choose the first check

Run repository commands only from a [trusted checkout](../../docs/contributor-verification.md#trust-boundary);
even `verify-local.py --help` and `--list` load repository code.

| Task | Command |
| --- | --- |
| Choose checks and parse changed Swift | `python3 scripts/verify-local.py` |
| Run the full CI static recipe | `python3 scripts/verify-local.py --all` |
| Parse current Swift edits | `python3 scripts/verify-local.py --only swift-syntax --swift-changed` |
| Check new Swift test-file wiring | `python3 scripts/verify-local.py --only test-wiring` |
| See what a UI test did, one frame per action | `scripts/ui-test ClassName` or `scripts/ui-test <run URL>` ([guide](references/ui-test-frames.md)) |
| Render view code to PNGs in seconds, light and dark, without building the app | `scripts/ui-lab/ui-lab.py <harness> [--watch]` ([guide](references/ui-lab.md)) |

<!-- cmux-rbf: pruned upstream text — removed the table rows for dogfooding the app from CI (`scripts/run-e2e.sh --ref`), reading the screenshots CI posts on an app PR, and judging a red web test with `scripts/ci/web_test_verdict.py --pr` — no CI runs here, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->

Add a base ref after `--swift-changed` to include committed changes. Use `--list`
to find other checks and `--help` for options. Parsing checks syntax; it doesn't
typecheck or run tests.

Read the [command guide](../../docs/verification-receipts.md) for piped paths or
JSON receipts. Use the [validation guide](references/local-vs-ci-validation.md)
to choose package, native, web or runtime checks. Docs and portable tooling use
their scoped checks.

## Reproduce and repair

Keep a focused command that fails on the reported symptom, then rerun it after
the repair. Setup failures and zero executed tests don't demonstrate the bug.
Exercise one behavior at a time so a failure identifies what needs fixing.

**Superseded in cmux-rbf — see `rbf/AGENTS.md`.** This fork keeps the red proof but commits once; the two-commit structure below is upstream's.

Keep two commits: first the failing behavioral regression, then the fix. Run
the same focused command on both and record the commit SHAs, the expected
failure and the passing result. A setup failure or zero executed tests is not
regression proof. When the proof is available locally, push both commits
together after the fix passes; a separate hosted CI run on the deliberately
broken intermediate commit is unnecessary. <!-- cmux-rbf: pruned upstream text — removed 'If the failure only reproduces in CI, use that lane and keep its receipts. Required CI and review still apply to the final pushed head.' — no CI in this fork, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->

## Test wiring

New `cmuxTests/*.swift` files need both PBXFileReference and Sources build-phase
membership in `cmux.xcodeproj/project.pbxproj`. Add through Xcode or follow a wired
sibling, then run the wiring check above: an unwired file can otherwise produce
a misleading zero-test pass.

After creating, renaming, or deleting a direct `cmuxTests/*.swift` file, run `./scripts/sync-test-wiring`. It deterministically reconciles the `PBXFileReference`, `PBXBuildFile`, `cmuxTests` group child, and `cmuxTests` Sources membership; `--check` performs the same validation without writing. Foreign target membership is rejected with an explicit diagnostic. New `Sources/**/*.swift` app files are wired with `./scripts/wire-app-sources.py` (`--check` lists unwired ones); UI tests with `--target cmuxUITests --dir cmuxUITests`; run it after any merge that took main's `project.pbxproj`, which drops a branch's app-source entries. **Run `./scripts/lint-pbxproj-test-wiring.sh` yourself — nothing runs it for you.** <!-- cmux-rbf: pruned upstream text — removed 'the workflow-guard-tests CI job runs' — no CI in this fork, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->

## Test quality

- Exercise observable behavior through unit, integration, CLI or end-to-end paths.
- Do not assert source snippets, signatures, AST shape or metadata keys solely
  to mirror implementation. For metadata behavior, inspect the produced artifact
  or execute the code that consumes it.
- Add a small runtime harness when needed; skip a fake regression test if there
  is no meaningful behavioral oracle and explain the limit. See
  [regression and quality](references/regression-and-quality.md) for the judgment call.

## Swift tests

Swift unit/integration targets use Swift Testing (`import Testing`, `@Test`,
`@Suite`, `#expect`, `#require`). Portable Python/shell guards retain their existing
frameworks. UI tests remain XCTest/XCUITest; do not migrate XCUIApplication tests.

New Swift package test targets start on Swift Testing. Prefer parameterized tests
for repeated cases and tags for selection. Use `.serialized` for suites that
require ordering, not locks or sleeps. Migrate an existing XCTest file only when
an edit already crosses it; see [the migration mapping](references/swift-testing-migration.md).

## Native test evidence

An app build does not compile test targets. Package/refactor and public API changes
need the relevant test target compiled, then the selected tests actually executed.
Follow [build-for-testing and execution guidance](references/local-vs-ci-validation.md);
report skipped/unsupported checks explicitly. Here, **build and run the `cmux-unit` scheme yourself** (`make test`) — it is the only gate, and `reload.sh` alone is never proof the tests build.

For remote tmux sizing changes, use the [E2E recipe](references/remote-tmux-sizing-e2e.md).

<!-- cmux-rbf: pruned upstream text — removed 'surfaced only in the tests job', 'or let the tests CI job gate it' and the "PR CI labels" section (`full-ci`, `unit-ci`, PR CI coverage) — no CI in this fork, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->
