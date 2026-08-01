# Local vs CI Validation

## `reload.sh`

Proves the app target built. Proves nothing about `cmuxTests`, `cmuxUITests`, package test targets, or test-only imports. For package/refactor work, treat it as insufficient on its own.

## Unit test target

`cmux-unit` is safe locally because it does not launch the app, and it is **the only thing that compiles the unit tests** — the `cmux` scheme does not, and still prints `TEST BUILD SUCCEEDED`. <!-- cmux-rbf: pruned upstream text — removed "prefer CI when practical" — there is no CI in this fork, so `cmux-unit` is not the fallback, it is the gate; see rbf/AGENTS.md. Reject this hunk on upstream sync. -->

```bash
make test                 # preferred — derives the tag from your branch
```

`make test` (→ `rbf/scripts/dev.sh`) pins the `cmux-unit` scheme for you. The raw form, if you need to override anything:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build
```

Two failure modes no exit code will tell you about: **quit any running tagged app first** — otherwise the run dies with "Test runner never began executing tests", exit 65, zero tests run — and `-only-testing:` takes a **class**, not a file, so an unmatched filter runs nothing and still reports `TEST SUCCEEDED`. <!-- cmux-rbf: pruned upstream text — removed "add the repo's GlobalISel workaround flag if required by current project instructions" — no project instruction names that flag, so the reference was circular; added `make test` and the two silent-failure modes instead. Reject this hunk on upstream sync. -->

## E2E and UI tests

<!-- cmux-rbf: pruned upstream text — removed "Run through GitHub Actions or the VM: gh workflow run test-e2e.yml" — no workflow fires in this fork; E2E/UI coverage is manual, see the test-suite/ manual suite named in rbf/AGENTS.md. Reject this hunk on upstream sync. --> Never launch an untagged app locally to satisfy socket or UI tests.

## Python socket tests

`tests_v2/` connects to a running cmux instance socket. Locally, point it at a tagged build with `CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock`. Never target an untagged `cmux DEV.app`; it conflicts with the user's running debug instance.
