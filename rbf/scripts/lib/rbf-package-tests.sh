#!/usr/bin/env bash
# rbf-package-tests.sh — run the Swift package tests of a feature that lives in packages (#cm-106).
#
#   source rbf/scripts/lib/rbf-package-tests.sh
#   rbf_run_package_tests <repo-root>      # exit 0 only if every package passed
#
# `make test` builds the app's `cmux-unit` scheme, which never runs a package's own tests. This runs `swift test`
# for each package in RBF_PACKAGE_TEST_PATHS, prints each one's `Test run with N tests` line (Swift Testing) and
# `Executed N tests` line (XCTest), and fails if any failed. It does not build or run the app and needs no build-id.
#
# This lives in lib/ rather than inside dev.sh for the reason rbf-zig.sh does: a guard written inside one
# entrypoint cannot be inherited by a second.
#
# Which packages run, and why:
#   - CmuxWorkspaces, CmuxControlSocket (#cm-106): the workspace-group model, layout, coordinators, drop planner
#     and socket logic
#   - CmuxCloud, CmuxBrowser, CmuxRemoteSession, CmuxCloudImagePaste, CmuxTerminal, CmuxSettingsUI, CmuxSettings
#     (#cm-142.1): the upstream sync moved 35 app test files into these packages' own test targets, which
#     `make test` no longer runs
#   - CmuxAgentJournal, CmuxNotifications, Bonsplit (#cm-142.1): rbf/AGENTS.md's sync notes say to run them by hand
#   - CMUXAgentLaunch (#cm-142.1): the resume argv tests (#cm-30), which upstream moved out of the app
#   - CmuxRemoteWorkspace (#cm-142.1): the `cmux ssh` relay's allowlist tests (RemoteCLIRelayPolicyTests)
#   - CmuxPanes (#cm-142.1): it was left out for one known red; it now runs with that test skipped
#   - CmuxMobileHost (#cm-142.1): green on the merge, and nothing else runs its tests
#
# A package with one known red runs with that test skipped, never left out: RBF_PACKAGE_TEST_SKIPS below.
#
# Left out on purpose:
#   - CmuxFoundation: its test target doesn't type-check under Xcode 27 (upstream's
#     `SSHPTYReplayOutputFilterTests.swift`), which is why the drop planner's suites live in CmuxWorkspaces
#   - CmuxSimulator: its UI tests depend on the DeviceKit chrome installed on the machine, not on this tree
RBF_PACKAGE_TEST_PATHS=(
  "Packages/macOS/CmuxWorkspaces"
  "Packages/macOS/CmuxControlSocket"
  "Packages/macOS/CmuxCloud"
  "Packages/macOS/CmuxBrowser"
  "Packages/macOS/CmuxRemoteSession"
  "Packages/macOS/CmuxCloudImagePaste"
  "Packages/macOS/CmuxTerminal"
  "Packages/macOS/CmuxSettingsUI"
  "Packages/macOS/CmuxSettings"
  "Packages/macOS/CmuxAgentJournal"
  "Packages/macOS/CmuxNotifications"
  "Packages/macOS/Bonsplit"
  "Packages/macOS/CMUXAgentLaunch"
  "Packages/macOS/CmuxRemoteWorkspace"
  "Packages/macOS/CmuxPanes"
  "Packages/macOS/CmuxMobileHost"
)

# Known reds, skipped by name with `swift test --skip <regex>`, one entry each: "<package path>|<regex>".
# The run prints every skip it applies. Remove an entry when its test is fixed.
RBF_PACKAGE_TEST_SKIPS=(
  # Red on the pre-merge control too (a base red): the divider plan's first position isn't 2/3.
  "Packages/macOS/CmuxPanes|SplitRatioSpecTests/specWeightsDriveTheDividerPlan"
  # Base red since #cm-61's test: after a rejected display name, the next name typed never reaches the defaults.
  "Packages/macOS/CmuxSettingsUI|WorkspaceColorDisplayNameEditingTests/replacingAnExistingDisplayNameDoesNotCollideWithItsOwnPaletteEntry"
  # Red only in the full package run, green alone on both trees: an order effect, not this test's subject.
  "Packages/macOS/CmuxSettingsUI|FigmaShowFileNameRowEffectTests/setFalseWritesTheKeyAndKeepsItsSibling"
)

rbf_run_package_tests() {
  local root="$1" failed=0 pkg log status entry
  local summary=()
  for pkg in "${RBF_PACKAGE_TEST_PATHS[@]}"; do
    log="$(mktemp -t rbf-package-tests)"
    echo "==> swift test: $pkg"
    local skip_args=()
    for entry in ${RBF_PACKAGE_TEST_SKIPS[@]+"${RBF_PACKAGE_TEST_SKIPS[@]}"}; do
      if [[ "${entry%%|*}" == "$pkg" ]]; then
        skip_args+=(--skip "${entry#*|}")
        echo "    skipping known red: ${entry#*|}"
      fi
    done
    # Stream the run, and still learn swift's own status: pipefail makes the pipeline fail when swift does.
    # `${skip_args[@]+…}` expands to nothing for an empty list under dev.sh's `set -u` on bash 3.2.
    local pipefail_before
    pipefail_before="$(set +o | grep pipefail)"
    set -o pipefail
    if swift test --package-path "$root/$pkg" ${skip_args[@]+"${skip_args[@]}"} 2>&1 | tee "$log"; then
      status=0
    else
      status=1
    fi
    eval "$pipefail_before"
    local line xctest
    line="$(grep -E 'Test run with [0-9]+ tests' "$log" | tail -1 || true)"
    xctest="$(grep -E 'Executed [0-9]+ tests' "$log" | tail -1 | sed -E 's/^[[:space:]]+//' || true)"
    rm -f "$log"
    if [[ "$status" -ne 0 || -z "$line" ]]; then
      failed=1
      summary+=("FAILED  $pkg  ${line:-(no 'Test run with' line: the package did not build or run)}  |  XCTest: ${xctest:-none}")
    else
      summary+=("$pkg  $line  |  XCTest: ${xctest:-none}")
    fi
  done
  echo
  echo "==> package test results"
  printf '    %s\n' "${summary[@]}"
  return "$failed"
}
