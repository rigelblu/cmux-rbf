# Choose verification for the change

Run repository commands only from a [trusted checkout](../../../docs/contributor-verification.md#trust-boundary);
even `verify-local.py --help` and `--list` load repository code.

Start with the smallest check that can expose the failure you are fixing. Use
`python3 scripts/verify-local.py --list` to see the fast static checks; run the
full command before a native build or push when those checks apply. A passing
preflight establishes only its named scope. See the [command guide](../../../docs/verification-receipts.md)
for focused reruns and evidence receipts.

For edited Swift, use `python3 scripts/verify-local.py --swift-changed` before
the native build; add a base ref to include committed branch changes. While
repairing syntax, rerun with `--only swift-syntax --swift-changed`. Use
`--swift-stdin0` for piped selections and `--receipt -` for JSON stdout. This
parses only the selected files with the installed compiler;
it does not typecheck imports or execute tests. Contributor-wide setup and
verification guidance belongs in [CONTRIBUTING.md](../../../CONTRIBUTING.md);
the notes here cover the native evidence distinctions needed by this skill.

For docs or portable tooling, validate links/commands and run the affected portable
tests. An app build is needed when native build or runtime behavior changes, not
for every instruction edit. Web changes need their package's checks and live preview.

Native work uses a [tagged build](../../cmux-dev-workflow/references/tagged-builds.md). <!-- cmux-rbf: pruned upstream text — removed 'or the existing CI lane' — there is no CI in this fork, see rbf/AGENTS.md. Reject this hunk on upstream sync. -->
Team members: shared build fleet rules are in cmuxterm-hq.

## Native app versus test compilation

A tagged `reload.sh` build proves the app target built. It says nothing about
whether `cmuxTests`, `cmuxUITests`, package tests or test-only imports compile.
For authorized local native test compilation, the existing wrapper is:

```sh
./scripts/test-unit.sh -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-<tag>-tests" build-for-testing
```

Use `build-for-testing`, not `build`: the latter skips the test target. Like
CI, the wrapper builds `cmuxTests` without a Swift module, so a one-test-file
edit skips a serial ~26 s emit-module step; set `CMUX_TEST_EMIT_MODULE=1` to
keep the module, for example to inspect test frames in lldb. This
still does not execute tests. Execute the focused selection through the supported
test lane and record how many ran; a zero-test invocation is not verification.
Keep test DerivedData separate from the app tag's directory: a failed test build
can leave an unsigned test bundle that breaks the next app CodeSign step.

### In this fork: `make test`

`cmux-unit` is safe locally because it does not launch the app, and it is **the only thing that compiles the unit tests** — the `cmux` scheme does not, and still prints `TEST BUILD SUCCEEDED`. <!-- cmux-rbf: pruned upstream text — removed "prefer CI when practical" — there is no CI in this fork, so `cmux-unit` is not the fallback, it is the gate; see rbf/AGENTS.md. Reject this hunk on upstream sync. -->

```bash
make test                 # preferred — derives the tag from your branch
```

`make test` (→ `rbf/scripts/dev.sh`) pins the `cmux-unit` scheme for you and runs the tests. The raw form, if you need to override anything:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build
```

Two failure modes no exit code will tell you about: **quit any running tagged app first** — otherwise the run dies with "Test runner never began executing tests", exit 65, zero tests run — and `-only-testing:` takes a **class**, not a file, so an unmatched filter runs nothing and still reports `TEST SUCCEEDED`. <!-- cmux-rbf: pruned upstream text — removed "add the repo's GlobalISel workaround flag if required by current project instructions" (upstream now: "retain the current GlobalISel workaround when required by project instructions") — no project instruction names that flag, so the reference was circular; added `make test` and the two silent-failure modes instead. Reject this hunk on upstream sync. -->

<!-- cmux-rbf: pruned upstream text — removed the "Webview, bun and browser tests" section (`scripts/run-linux-tests.sh --ref`, which dispatches `.github/workflows/linux-tests.yml` on Blacksmith) — no workflow fires in this fork; run the affected `bun test` files locally. Reject this hunk on upstream sync. -->

## UI and socket checks

## E2E and UI tests

<!-- cmux-rbf: pruned upstream text — removed "Run through GitHub Actions or the VM: gh workflow run test-e2e.yml" — no workflow fires in this fork; E2E/UI coverage is manual, see the test-suite/ manual suite named in rbf/AGENTS.md. Reject this hunk on upstream sync. --> Never launch an untagged app locally to satisfy socket or UI tests.

## Python socket tests

`tests_v2/` connects to a running cmux instance socket. Locally, point it at a tagged build with `CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock`. Never target an untagged `cmux DEV.app`; it conflicts with the user's running debug instance.

For CLI dogfood use `CMUX_TAG=<tag> scripts/cmux-debug-cli.sh ...`, not the global
`/tmp/cmux-cli` symlink. Confirm the tested artifact is the one you launched.
