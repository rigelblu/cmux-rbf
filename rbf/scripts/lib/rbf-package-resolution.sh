#!/usr/bin/env bash
# rbf-package-resolution.sh — keep xcodebuild on the pinned Swift package versions (#cm-142.1).
#
#   source rbf/scripts/lib/rbf-package-resolution.sh
#   rbf_package_resolution_apply
#   xcodebuild … ${RBF_PACKAGE_RESOLUTION_ARGS[@]+"${RBF_PACKAGE_RESOLUTION_ARGS[@]}"} … build
#   [[ -n "$RBF_PACKAGE_RESOLUTION_NOTE" ]] && echo "==> packages $RBF_PACKAGE_RESOLUTION_NOTE"
#
# SYMPTOM. `rbf/scripts/install-rbf.sh` (make install-rbf, install-dogfood) resolved packages forward
# and rewrote cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved (2026-11-23:
# swift-asn1 1.7.3 → 1.7.5 and a new originHash). The install then builds against versions no test ran
# with, and leaves the lockfile changed in the working copy.
#
# CAUSE. xcodebuild has never heard of CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION. dev.sh defaults it to 1,
# and reload.sh and dev.sh's test path turn it into `-disableAutomaticPackageResolution`. The install
# script calls xcodebuild itself and never passes through dev.sh, so nothing turned it into the flag there.
#
# THE FIX. rbf_package_resolution_apply defaults CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION to 1 exactly
# as dev.sh does (`:-1`, so unset or empty both mean 1), exports it, and fills RBF_PACKAGE_RESOLUTION_ARGS
# with `-disableAutomaticPackageResolution` when the value is 1. Any other value (0, say) is the caller
# asking for a forward resolve: the array stays empty and RBF_PACKAGE_RESOLUTION_NOTE says so.
#
# Why a lib: rbf/AGENTS.md's landmine rule. A guard written inside one entrypoint is not inherited by a
# second; dev.sh's copy never reached install-rbf.sh. dev.sh keeps its own lines for now.

rbf_package_resolution_apply() {
  export CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION="${CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION:-1}"
  RBF_PACKAGE_RESOLUTION_ARGS=()
  if [[ "$CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION" == "1" ]]; then
    RBF_PACKAGE_RESOLUTION_ARGS=(-disableAutomaticPackageResolution)
    RBF_PACKAGE_RESOLUTION_NOTE="pinned to Package.resolved (-disableAutomaticPackageResolution)"
  else
    RBF_PACKAGE_RESOLUTION_NOTE="automatic resolution ON (CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION=${CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION}): Package.resolved may change"
  fi
}
