# Local vs CI Validation

## `reload.sh`

`reload.sh` builds the Debug app for a tag. It does not compile the test target.

A successful reload proves the app target built. It does not prove:

- `cmuxTests` compile
- `cmuxUITests` compile
- package test targets compile
- test-only imports still resolve

For package/refactor work, treat reload as insufficient by itself.

## Unit test target

`xcodebuild -scheme cmux-unit` is safe because it does not launch the app, and it is **the only thing that compiles the unit tests** — the `cmux` scheme does not, and still prints `TEST BUILD SUCCEEDED`. <!-- cmux-rbf: pruned upstream text — removed "Prefer CI when practical" — there is no CI in this fork, so `cmux-unit` is not the fallback, it is the gate; see rbf/AGENTS.md. Reject this hunk on upstream sync. -->

Use a tagged derived data path:

```bash
make test                 # preferred — derives the tag from your branch
```

`make test` (→ `rbf/scripts/dev.sh`) pins the `cmux-unit` scheme for you. The raw form, if you need to override anything:

```bash
xcodebuild -project cmux.xcodeproj -scheme cmux-unit -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/cmux-<tag> build
```

Two failure modes no exit code will tell you about: **quit any running tagged app first** — otherwise the run dies with "Test runner never began executing tests", exit 65, zero tests run — and `-only-testing:` takes a **class**, not a file, so an unmatched filter runs nothing and still reports `TEST SUCCEEDED`. <!-- cmux-rbf: pruned upstream text — removed "include the repo's known GlobalISel workaround flag if required by current project instructions" — no project instruction names that flag, so the reference was circular; added `make test` and the two silent-failure modes instead. Reject this hunk on upstream sync. -->

## E2E and UI tests

<!-- cmux-rbf: pruned upstream text — removed "E2E and UI tests run via GitHub Actions" and `gh workflow run test-e2e.yml` — no workflow fires in this fork; E2E/UI are not run here, and if you need that coverage it is manual, see the test-suite/ manual suite named in rbf/AGENTS.md. Reject this hunk on upstream sync. -->

Do not launch an untagged app locally to satisfy socket/UI tests.

## Python socket tests

Python socket tests under `tests_v2/` connect to a running cmux instance socket. If they must be run locally, use a tagged build socket:

```bash
CMUX_SOCKET_PATH=/tmp/cmux-debug-<tag>.sock
```

Never launch or target an untagged `cmux DEV.app` for these tests. It can conflict with the user's running debug instance.
