#!/usr/bin/env bash
# rbf-package-tests.sh — run the Swift package tests of a feature that lives in packages (#cm-106).
#
#   source rbf/scripts/lib/rbf-package-tests.sh
#   rbf_run_package_tests <repo-root>      # exit 0 only if every package passed
#
# `make test` builds the app's `cmux-unit` scheme. It never runs a package's own tests, so the workspace-group
# model, layout, coordinators, drop planner and socket logic had no single command. This runs
# `swift test` for the two packages that hold them, prints each package's `Test run with N tests` line, and
# fails if either failed. It does not build or run the app and needs no build-id.
#
# This lives in lib/ rather than inside dev.sh for the reason rbf-zig.sh does: a guard written inside one
# entrypoint cannot be inherited by a second.
#
# The list is the packages whose suites the feature owns. Add a package here when it gets suites that matter to a
# gate; CmuxFoundation is not on it because its test target does not build on this toolchain (an upstream SSH
# file, `SSHPTYReplayOutputFilterTests.swift`), which is why the planner's suites live in CmuxWorkspaces.
RBF_PACKAGE_TEST_PATHS=(
  "Packages/macOS/CmuxWorkspaces"
  "Packages/macOS/CmuxControlSocket"
)

rbf_run_package_tests() {
  local root="$1" failed=0 pkg log status
  local summary=()
  for pkg in "${RBF_PACKAGE_TEST_PATHS[@]}"; do
    log="$(mktemp -t rbf-package-tests)"
    echo "==> swift test: $pkg"
    # Stream the run, and still learn swift's own status: pipefail makes the pipeline fail when swift does.
    local pipefail_before
    pipefail_before="$(set +o | grep pipefail)"
    set -o pipefail
    if swift test --package-path "$root/$pkg" 2>&1 | tee "$log"; then status=0; else status=1; fi
    eval "$pipefail_before"
    local line
    line="$(grep -E 'Test run with [0-9]+ tests' "$log" | tail -1 || true)"
    rm -f "$log"
    if [[ "$status" -ne 0 || -z "$line" ]]; then
      failed=1
      summary+=("FAILED  $pkg  ${line:-(no 'Test run with' line: the package did not build or run)}")
    else
      summary+=("$pkg  $line")
    fi
  done
  echo
  echo "==> package test results"
  printf '    %s\n' "${summary[@]}"
  return "$failed"
}
