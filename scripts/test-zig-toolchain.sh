#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cmux-zig-toolchain-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

pass_count=0

pass() {
  pass_count=$((pass_count + 1))
  echo "ok ${pass_count} - $1"
}

fail() {
  echo "not ok $((pass_count + 1)) - $1" >&2
  exit 1
}

canonical_path() {
  local path="$1"
  printf '%s/%s\n' "$(cd "$(dirname "$path")" && pwd -P)" "$(basename "$path")"
}

make_fake_zig() {
  local root="$1"
  local version="$2"
  local complete="${3:-1}"
  mkdir -p "$root/bin" "$root/lib/compiler"
  printf '%s\n' "$version" > "$root/version"
  if [[ "$complete" == "1" ]]; then
    : > "$root/lib/compiler/build_runner.zig"
  fi
  cat > "$root/bin/zig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -f "$root/version" ]]; then
  root="$(cd "$(dirname "$0")" && pwd)"
fi
case "${1:-}" in
  version) cat "$root/version" ;;
  env) printf '.{\n    .lib_dir = "%s",\n}\n' "$root/lib" ;;
  *) exit 2 ;;
esac
EOF
  chmod +x "$root/bin/zig"
  printf '%s\n' "$root/bin/zig"
}

assert_override_resolves() {
  local label="$1"
  local version="$2"
  local fake=""
  fake="$(make_fake_zig "$TEST_ROOT/$label" "$version")"
  local actual=""
  actual="$(CMUX_ZIG="$fake" ZIG_REQUIRED=0.16.0 "$SCRIPT_DIR/zig-toolchain.sh" resolve)" \
    || fail "$label resolves"
  [[ "$actual" == "$(canonical_path "$fake")" ]] \
    || fail "$label selected $actual instead of $fake"
  pass "$label resolves"
}

assert_override_rejected() {
  local label="$1"
  local version="$2"
  local complete="${3:-1}"
  local fake=""
  fake="$(make_fake_zig "$TEST_ROOT/$label" "$version" "$complete")"
  local stderr="$TEST_ROOT/$label.stderr"
  if CMUX_ZIG="$fake" ZIG_REQUIRED=0.16.0 "$SCRIPT_DIR/zig-toolchain.sh" resolve \
      > "$TEST_ROOT/$label.stdout" 2> "$stderr"; then
    fail "$label is rejected"
  fi
  grep -Fq "Fix CMUX_ZIG, or unset it and run ./scripts/setup.sh." "$stderr" \
    || fail "$label prints one recovery instruction"
  pass "$label is rejected"
}

assert_override_resolves minimum 0.16.0
assert_override_resolves newer_patch 0.16.3
assert_override_rejected older_patch 0.15.9
assert_override_rejected wrong_series 0.17.0
assert_override_rejected prerelease 0.16.1-dev.12
assert_override_rejected build_metadata 0.16.1+local
assert_override_rejected incomplete 0.16.0 0

valid_system="$(make_fake_zig "$TEST_ROOT/system" 9.9.1)"
invalid_override="$(make_fake_zig "$TEST_ROOT/explicit-invalid" 9.8.9)"
if CMUX_ZIG="$invalid_override" ZIG_REQUIRED=9.9.0 \
    PATH="$(dirname "$valid_system"):/usr/bin:/bin" \
    "$SCRIPT_DIR/zig-toolchain.sh" resolve >/dev/null 2>&1; then
  fail "invalid override never falls back"
fi

invalid_install_count="$TEST_ROOT/invalid-install-count"
invalid_curl_dir="$TEST_ROOT/invalid-curl/bin"
mkdir -p "$invalid_curl_dir"
cat > "$invalid_curl_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' invoked >> "$INVALID_INSTALL_COUNT"
exit 88
EOF
chmod +x "$invalid_curl_dir/curl"
set +e
CMUX_ZIG="$invalid_override" \
  INVALID_INSTALL_COUNT="$invalid_install_count" \
  RUNNER_TEMP="$TEST_ROOT/invalid-install-work" \
  ZIG_REQUIRED=9.9.0 \
  PATH="$invalid_curl_dir:$(dirname "$valid_system"):/usr/bin:/bin" \
  "$SCRIPT_DIR/install-zig-ci.sh" > "$TEST_ROOT/invalid-install.stdout" \
  2> "$TEST_ROOT/invalid-install.stderr"
invalid_install_status=$?
set -e
[[ "$invalid_install_status" -eq 2 && ! -e "$invalid_install_count" ]] \
  || fail "invalid override never falls back"
pass "invalid override never falls back"

first_path_zig="$(make_fake_zig "$TEST_ROOT/path-incompatible" 9.8.7)"
later_path_zig="$(make_fake_zig "$TEST_ROOT/path-compatible" 9.9.4)"
resolved="$(
  CMUX_LOCAL_TOOL_ROOT="$TEST_ROOT/no-local-tools" \
  ZIG_REQUIRED=9.9.0 \
  PATH="$(dirname "$first_path_zig"):$(dirname "$later_path_zig"):/usr/bin:/bin" \
  "$SCRIPT_DIR/zig-toolchain.sh" resolve
)" || fail "compatible Zig later in PATH is selected"
[[ "$resolved" == "$(canonical_path "$later_path_zig")" ]] \
  || fail "compatible Zig later in PATH is selected"
pass "compatible Zig later in PATH is selected"

local_tools="$TEST_ROOT/local-tools"
local_candidate_root="$local_tools/zig/zig-aarch64-macos-9.9.4"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) local_candidate_root="$local_tools/zig/zig-aarch64-macos-9.9.4" ;;
  Darwin-x86_64) local_candidate_root="$local_tools/zig/zig-x86_64-macos-9.9.4" ;;
  Linux-aarch64) local_candidate_root="$local_tools/zig/zig-aarch64-linux-9.9.4" ;;
  Linux-x86_64) local_candidate_root="$local_tools/zig/zig-x86_64-linux-9.9.4" ;;
esac
local_candidate_bin="$(make_fake_zig "$local_candidate_root" 9.9.4)"
cp "$local_candidate_bin" "$local_candidate_root/zig"
chmod +x "$local_candidate_root/zig"
local_candidate="$(canonical_path "$local_candidate_root/zig")"
system_candidate="$(make_fake_zig "$TEST_ROOT/system-precedence" 9.9.2)"
resolved="$(
  CMUX_LOCAL_TOOL_ROOT="$local_tools" \
  ZIG_REQUIRED=9.9.0 \
  PATH="$(dirname "$system_candidate"):/usr/bin:/bin" \
  "$SCRIPT_DIR/zig-toolchain.sh" resolve
)" || fail "compatible checkout-local Zig wins before system Zig"
[[ "$resolved" == "$local_candidate" ]] \
  || fail "compatible checkout-local Zig wins before system Zig"
pass "compatible checkout-local Zig wins before system Zig"

install_tools="$TEST_ROOT/install-tools"
install_count="$TEST_ROOT/install-count"
fake_installer="$TEST_ROOT/fake-installer.sh"
cat > "$fake_installer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "$INSTALL_COUNT" ]] || count="$(cat "$INSTALL_COUNT")"
printf '%s\n' "$((count + 1))" > "$INSTALL_COUNT"
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) name="zig-aarch64-macos-${ZIG_REQUIRED}" ;;
  Darwin-x86_64) name="zig-x86_64-macos-${ZIG_REQUIRED}" ;;
  Linux-aarch64) name="zig-aarch64-linux-${ZIG_REQUIRED}" ;;
  Linux-x86_64) name="zig-x86_64-linux-${ZIG_REQUIRED}" ;;
  *) exit 2 ;;
esac
root="${ZIG_INSTALL_ROOT}/${name}"
mkdir -p "$root/lib/compiler"
: > "$root/lib/compiler/build_runner.zig"
printf '%s\n' "$ZIG_REQUIRED" > "$root/version"
cat > "$root/zig" <<'ZIG'
#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")" && pwd)"
case "${1:-}" in
  version) cat "$root/version" ;;
  env) printf '.{\n    .lib_dir = "%s",\n}\n' "$root/lib" ;;
  *) exit 2 ;;
esac
ZIG
chmod +x "$root/zig"
EOF
chmod +x "$fake_installer"

first_install="$(
  INSTALL_COUNT="$install_count" \
  CMUX_ZIG_INSTALLER="$fake_installer" \
  CMUX_LOCAL_TOOL_ROOT="$install_tools" \
  ZIG_REQUIRED=9.9.0 \
  PATH="/usr/bin:/bin" \
  "$SCRIPT_DIR/zig-toolchain.sh" install
)" || fail "fresh checkout-local install"
[[ -x "$first_install" && "$(cat "$install_count")" == "1" ]] \
  || fail "fresh checkout-local install"
pass "fresh checkout-local install"

second_install="$(
  INSTALL_COUNT="$install_count" \
  CMUX_ZIG_INSTALLER="$fake_installer" \
  CMUX_LOCAL_TOOL_ROOT="$install_tools" \
  ZIG_REQUIRED=9.9.0 \
  PATH="/usr/bin:/bin" \
  "$SCRIPT_DIR/zig-toolchain.sh" install
)" || fail "checkout-local install is idempotent"
[[ "$second_install" == "$first_install" && "$(cat "$install_count")" == "1" ]] \
  || fail "checkout-local install is idempotent"
pass "checkout-local install is idempotent"

echo "1..${pass_count}"
