#!/usr/bin/env bash
# rbf-install-target.test.sh — drive the resolver's guards directly.
#
#   bash rbf/scripts/lib/rbf-install-target.test.sh
#
# This is the ONLY place the refusal paths are reachable. The installer takes no
# target flags by design, so there is no end-to-end route to them — testing the
# unit is not a convenience here, it is the only honest option. See the brief's
# Decisions log (2026-08-01).
#
# Every case asserts on the RETURN CODE and on stderr naming the offending
# value. A guard that refuses without saying which field is wrong sends the
# operator hunting, so "it refused" alone is not a pass.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rbf/scripts/lib/rbf-install-target.sh
source "$LIB_DIR/rbf-install-target.sh"

pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail + 1)); }

# --- lexical normalization -------------------------------------------------
# These feed the guards below; if normalization is wrong, every refusal is
# unreliable in a way the refusal tests alone would not reveal.
check_norm() {
  local input="$1" want="$2" got
  got="$(rbf_lexical_normalize "$input")"
  if [[ "$got" == "$want" ]]; then ok "normalize $input -> $want"
  else bad "normalize $input" "want '$want', got '$got'"; fi
}

printf 'lexical normalization\n'
check_norm "/Applications/cmux.app"            "/Applications/cmux.app"
check_norm "/Applications/cmux.app/"           "/Applications/cmux.app"
check_norm "/Applications//cmux.app"           "/Applications/cmux.app"
check_norm "/Applications/./cmux.app"          "/Applications/cmux.app"
check_norm "/Applications/foo/../cmux.app"     "/Applications/cmux.app"
check_norm "/Applications/a/b/../../cmux.app"  "/Applications/cmux.app"
check_norm "/"                                 "/"
check_norm "/Applications/cmux RBF.app"        "/Applications/cmux RBF.app"

# --- the guard: hostile channel records ------------------------------------
# Each sets the record fields directly rather than editing the file, so the
# real rbf-channel.env is never mutated by a test run.
refuses() {
  local label="$1" path="$2" app_id="$3" plug_id="$4" want_in_stderr="$5"
  local err rc
  err="$(
    UPSTREAM_INSTALL_PATH="/Applications/cmux.app" \
    UPSTREAM_BUNDLE_ID="com.cmuxterm.app" \
    rbf_assert_safe_target "$path" "$app_id" "$plug_id" 2>&1 >/dev/null
  )"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    bad "$label" "expected refusal, got exit 0"
  elif [[ "$err" != *"$want_in_stderr"* ]]; then
    bad "$label" "refused, but stderr never named '$want_in_stderr': $err"
  else
    ok "$label"
  fi
}

printf '\nguard refuses upstream-shaped records\n'
refuses "upstream bundle id" \
  "/Applications/cmux RBF.app" "com.cmuxterm.app" "com.cmuxterm.app.rbf.docktileplugin" \
  "com.cmuxterm.app"
refuses "upstream install path" \
  "/Applications/cmux.app" "com.cmuxterm.app.rbf" "com.cmuxterm.app.rbf.docktileplugin" \
  "upstream"
refuses "upstream install path, trailing slash" \
  "/Applications/cmux.app/" "com.cmuxterm.app.rbf" "com.cmuxterm.app.rbf.docktileplugin" \
  "upstream"
refuses "upstream install path via .." \
  "/Applications/x/../cmux.app" "com.cmuxterm.app.rbf" "com.cmuxterm.app.rbf.docktileplugin" \
  "upstream"
refuses "path inside upstream's bundle" \
  "/Applications/cmux.app/Contents/MacOS" "com.cmuxterm.app.rbf" "com.cmuxterm.app.rbf.docktileplugin" \
  "inside upstream"
refuses "plugin id collapsed onto app id" \
  "/Applications/cmux RBF.app" "com.cmuxterm.app.rbf" "com.cmuxterm.app.rbf" \
  "must differ"
refuses "plugin id is upstream's" \
  "/Applications/cmux RBF.app" "com.cmuxterm.app.rbf" "com.cmuxterm.app" \
  "must differ"
refuses "target is not an .app bundle" \
  "/Applications/cmux-rbf" "com.cmuxterm.app.rbf" "com.cmuxterm.app.rbf.docktileplugin" \
  "not an .app"
refuses "empty install path" \
  "" "com.cmuxterm.app.rbf" "com.cmuxterm.app.rbf.docktileplugin" \
  "incomplete"

# --- the guard accepts the real record --------------------------------------
printf '\nguard accepts the shipped record\n'
if (
  UPSTREAM_INSTALL_PATH="/Applications/cmux.app" \
  UPSTREAM_BUNDLE_ID="com.cmuxterm.app" \
  rbf_assert_safe_target "/Applications/cmux RBF.app" \
    "com.cmuxterm.app.rbf" "com.cmuxterm.app.rbf.docktileplugin" 2>/dev/null
); then ok "accepts the real channel values"
else bad "accepts the real channel values" "guard refused a safe target"; fi

# The end-to-end path: load the actual rbf-channel.env and resolve through it.
# Catches a record that drifts into an unsafe shape without anyone editing code.
printf '\nshipped rbf-channel.env resolves\n'
out="$(rbf_resolve_install_target "$LIB_DIR" 2>&1)"
rc=$?
if [[ $rc -ne 0 ]]; then
  bad "rbf-channel.env resolves cleanly" "exit $rc: $out"
else
  ok "rbf-channel.env resolves cleanly"
  for key in RBF_APP_NAME RBF_BUNDLE_ID RBF_PLUGIN_BUNDLE_ID RBF_INSTALL_PATH \
             RBF_ICON_SET RBF_VERSION_PLIST_KEY; do
    if [[ "$out" == *"${key}="* ]]; then ok "resolver reports $key"
    else bad "resolver reports $key" "absent from output"; fi
  done
  if [[ "$out" == *"RBF_BUNDLE_ID=com.cmuxterm.app.rbf"* ]]; then
    ok "resolved app id is the RBF channel's"
  else
    bad "resolved app id" "unexpected: $out"
  fi
  if [[ "$out" == *"RBF_PLUGIN_BUNDLE_ID=com.cmuxterm.app.rbf.docktileplugin"* ]]; then
    ok "resolved plugin id is distinct from the app id"
  else
    bad "resolved plugin id" "unexpected: $out"
  fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
