#!/usr/bin/env bash
# rbf-package-resolution.test.sh — prove rbf_package_resolution_apply pins xcodebuild to Package.resolved
# by default, and leaves it free only when the caller asks (#cm-142.1).
#
#   bash rbf/scripts/lib/rbf-package-resolution.test.sh
#   /bin/bash rbf/scripts/lib/rbf-package-resolution.test.sh      # macOS bash 3.2 too
#
# Each case runs the lib in a fresh `$BASH -c` under `set -euo pipefail`, the strictest shell a caller
# runs, with CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION unset, empty, 1 or 0. The probe expands the array
# the way install-rbf.sh does (safe when empty under `set -u` on bash 3.2) and prints the arguments one per
# bracket. RBF_PACKAGE_RESOLUTION_LIB points the test at another copy of the lib (a no-op stub, a
# mutation); the default is the lib beside it.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${RBF_PACKAGE_RESOLUTION_LIB:-$LIB_DIR/rbf-package-resolution.sh}"

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail + 1)); }

# probe [VAR=value] — run the lib in a fresh shell; print `args=[…] env=[…] note=[…]` and the shell's stderr.
probe() {
  local out
  out="$(env -u CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION "$@" "$BASH" -c '
    set -euo pipefail
    . "$1"
    rbf_package_resolution_apply
    a=""
    for x in ${RBF_PACKAGE_RESOLUTION_ARGS[@]+"${RBF_PACKAGE_RESOLUTION_ARGS[@]}"}; do a="$a[$x]"; done
    printf "args=%s env=[%s] note=[%s]\n" "$a" "$CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION" "${RBF_PACKAGE_RESOLUTION_NOTE:-}"
    printf "reached\n"
  ' probe "$LIB" 2>&1)" || true
  printf '%s' "$out"
}

# expect <name> <output> <args> <env> <note-substring>
expect() {
  local name="$1" out="$2" args="$3" envv="$4" note="$5"
  if [[ "$out" != *"reached"* ]]; then bad "$name" "the shell died: $out"; return; fi
  if [[ "$out" != *"args=$args env=[$envv]"* ]]; then bad "$name" "want args=$args env=[$envv], got: $out"; return; fi
  if [[ "$out" != *"$note"* ]]; then bad "$name" "note lacks '$note': $out"; return; fi
  if [[ "$(printf '%s\n' "$out" | grep -v -e '^args=' -e '^reached$' || true)" != "" ]]; then
    bad "$name" "unexpected stderr: $out"; return
  fi
  ok "$name"
}

echo "rbf-package-resolution.test.sh ($BASH, ${BASH_VERSION})"
expect "unset: pinned, as dev.sh defaults it" \
  "$(probe)" "[-disableAutomaticPackageResolution]" "1" "pinned to Package.resolved"
expect "empty: pinned (dev.sh's :-1 reads empty as unset)" \
  "$(probe CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION=)" "[-disableAutomaticPackageResolution]" "1" "pinned to Package.resolved"
expect "1: pinned" \
  "$(probe CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION=1)" "[-disableAutomaticPackageResolution]" "1" "pinned to Package.resolved"
expect "0: the caller's forward resolve; no flag, and the note says the lockfile may change" \
  "$(probe CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION=0)" "" "0" "Package.resolved may change"

# The wiring: install-rbf.sh sources the lib and passes the array on its xcodebuild line. Text checks,
# because running the script builds the app.
INSTALL="$LIB_DIR/../install-rbf.sh"
if grep -q 'source "$SCRIPT_DIR/lib/rbf-package-resolution.sh"' "$INSTALL" && grep -q '^rbf_package_resolution_apply$' "$INSTALL"; then
  ok "install-rbf.sh sources the lib and applies it"
else
  bad "install-rbf.sh sources the lib and applies it" "no source line or no rbf_package_resolution_apply call"
fi
n_xb="$(grep -c '^xcodebuild \\$' "$INSTALL" || true)"
n_args="$(grep -c 'RBF_PACKAGE_RESOLUTION_ARGS\[@\]+' "$INSTALL" || true)"
if [[ "$n_xb" -ge 1 && "$n_args" -eq "$n_xb" ]]; then
  ok "every xcodebuild call in install-rbf.sh ($n_xb) carries the array"
else
  bad "every xcodebuild call in install-rbf.sh carries the array" "xcodebuild calls: $n_xb, array uses: $n_args"
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
