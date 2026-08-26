#!/usr/bin/env bash

CMUX_ZIG_TOOLCHAIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMUX_ZIG_PROJECT_DIR="$(cd "$CMUX_ZIG_TOOLCHAIN_DIR/.." && pwd)"

# shellcheck source=scripts/ghostty-zig-version.sh
source "$CMUX_ZIG_TOOLCHAIN_DIR/ghostty-zig-version.sh"

cmux_zig_required_version() {
  if [[ -n "${ZIG_REQUIRED:-}" ]]; then
    printf '%s\n' "$ZIG_REQUIRED"
  else
    ghostty_minimum_zig_version "$CMUX_ZIG_PROJECT_DIR"
  fi
}

cmux_zig_local_tool_root() {
  printf '%s\n' "${CMUX_LOCAL_TOOL_ROOT:-$CMUX_ZIG_PROJECT_DIR/.cmux-tools}"
}

cmux_zig_read_lib_dir() {
  local zig_path="$1"
  "$zig_path" env 2>/dev/null | python3 -c 'import json, re, sys
text = sys.stdin.read()
try:
    print(json.loads(text).get("lib_dir", ""))
except Exception:
    match = re.search(r"(?m)^\s*\.lib_dir\s*=\s*\"([^\"]*)\"", text)
    print(match.group(1) if match else "")
'
}

cmux_zig_is_usable() {
  local zig_path="${1:-}"
  local required="${2:-$(cmux_zig_required_version)}"
  local actual=""
  local lib_dir=""

  [[ -x "$zig_path" ]] || return 1
  actual="$("$zig_path" version 2>/dev/null || true)"
  ghostty_zig_version_is_compatible "$actual" "$required" || return 1
  lib_dir="$(cmux_zig_read_lib_dir "$zig_path" || true)"
  [[ -n "$lib_dir" && -f "$lib_dir/compiler/build_runner.zig" ]]
}

cmux_zig_canonical_path() {
  local zig_path="$1"
  local zig_dir=""
  zig_dir="$(cd "$(dirname "$zig_path")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$zig_dir" "$(basename "$zig_path")"
}

cmux_zig_local_candidates() {
  local required="$1"
  local local_root=""
  local candidate=""
  local_root="$(cmux_zig_local_tool_root)/zig"
  printf '%s\n' \
    "$local_root/zig-aarch64-macos-${required}/zig" \
    "$local_root/zig-x86_64-macos-${required}/zig" \
    "$local_root/zig-aarch64-linux-${required}/zig" \
    "$local_root/zig-x86_64-linux-${required}/zig"

  # Prefer the verified minimum above, but also reuse a complete compatible
  # patch that was installed for an earlier build of this checkout.
  for candidate in "$local_root"/zig-*/zig; do
    [[ -e "$candidate" ]] || continue
    printf '%s\n' "$candidate"
  done
}

cmux_zig_system_candidates() {
  local path_entry=""
  case "$(uname -s)" in
    Darwin)
      # Native Apple Silicon Zig can cross-compile both helper slices and avoids
      # newer-SDK linker failures seen with the Rosetta Homebrew installation.
      printf '%s\n' /opt/homebrew/bin/zig
      ;;
  esac

  # Do not stop at `command -v zig`: an incompatible shim early in PATH must
  # not hide a compatible compiler later in PATH.
  local -a path_entries=()
  IFS=: read -r -a path_entries <<< "${PATH:-}"
  for path_entry in "${path_entries[@]}"; do
    [[ -n "$path_entry" ]] || path_entry="."
    printf '%s\n' "$path_entry/zig"
  done
  printf '%s\n' /usr/local/bin/zig
}

cmux_zig_report_invalid_override() {
  local required="$1"
  local actual="not executable"
  if [[ -x "${CMUX_ZIG:-}" ]]; then
    actual="$("$CMUX_ZIG" version 2>/dev/null || echo unreadable)"
  fi
  echo "error: CMUX_ZIG is not a complete Ghostty-compatible Zig: ${CMUX_ZIG:-}" >&2
  echo "       found ${actual}; need stable ${required} or a newer patch in the same major/minor series." >&2
  echo "       Fix CMUX_ZIG, or unset it and run ./scripts/setup.sh." >&2
}

# Print one complete, compatible Zig. An explicit invalid CMUX_ZIG is always an
# error and never falls through to a different compiler.
cmux_zig_resolve() {
  local quiet=0
  if [[ "${1:-}" == "--quiet" ]]; then
    quiet=1
  elif [[ $# -gt 0 ]]; then
    echo "usage: cmux_zig_resolve [--quiet]" >&2
    return 2
  fi

  local required=""
  local candidate=""
  local canonical=""
  local seen=" "
  required="$(cmux_zig_required_version)" || return 1

  if [[ -n "${CMUX_ZIG:-}" ]]; then
    if cmux_zig_is_usable "$CMUX_ZIG" "$required"; then
      cmux_zig_canonical_path "$CMUX_ZIG"
      return 0
    fi
    cmux_zig_report_invalid_override "$required"
    return 2
  fi

  while IFS= read -r candidate; do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    canonical="$(cmux_zig_canonical_path "$candidate")" || continue
    [[ "$seen" == *" $canonical "* ]] && continue
    seen="${seen}${canonical} "
    if cmux_zig_is_usable "$canonical" "$required"; then
      printf '%s\n' "$canonical"
      return 0
    fi
  done < <(cmux_zig_local_candidates "$required"; cmux_zig_system_candidates)

  if [[ "$quiet" -eq 0 ]]; then
    echo "error: no complete Ghostty-compatible Zig found." >&2
    echo "       Need stable ${required} or a newer patch in the same major/minor series." >&2
    echo "       Run ./scripts/setup.sh to install a verified checkout-local toolchain." >&2
  fi
  return 1
}

cmux_zig_install() {
  local resolved=""
  local status=0
  if resolved="$(cmux_zig_resolve --quiet)"; then
    echo "==> Reusing Zig $("$resolved" version) at $resolved" >&2
    printf '%s\n' "$resolved"
    return 0
  else
    status=$?
  fi
  [[ "$status" -ne 2 ]] || return 2

  local required=""
  local install_script="${CMUX_ZIG_INSTALLER:-$CMUX_ZIG_TOOLCHAIN_DIR/install-zig-ci.sh}"
  local local_root=""
  local work_parent="${CMUX_ZIG_WORK_PARENT:-${TMPDIR:-/tmp}/cmux-zig-local}"
  required="$(cmux_zig_required_version)" || return 1
  local_root="$(cmux_zig_local_tool_root)/zig"

  echo "==> Installing verified Zig ${required} for this checkout" >&2
  env \
    CMUX_ZIG= \
    GITHUB_ENV= \
    GITHUB_PATH= \
    RUNNER_TEMP="$work_parent" \
    ZIG_FORCE_LOCAL_INSTALL=1 \
    ZIG_INSTALL_ROOT="$local_root" \
    ZIG_REQUIRED="$required" \
    "$install_script" >&2

  if ! resolved="$(cmux_zig_resolve)"; then
    echo "error: checkout-local Zig installation did not produce a usable toolchain." >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

cmux_zig_usage() {
  cat <<'EOF'
Usage: ./scripts/zig-toolchain.sh <resolve|install>

Commands:
  resolve  Print the selected complete, Ghostty-compatible Zig.
  install  Reuse a compatible Zig or install the verified minimum in .cmux-tools.

CMUX_ZIG is an explicit override. If it is invalid, the command fails instead
of silently choosing another compiler.
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  case "${1:-}" in
    resolve)
      [[ $# -eq 1 ]] || { cmux_zig_usage >&2; exit 2; }
      cmux_zig_resolve
      ;;
    install)
      [[ $# -eq 1 ]] || { cmux_zig_usage >&2; exit 2; }
      cmux_zig_install
      ;;
    -h | --help)
      cmux_zig_usage
      ;;
    *)
      cmux_zig_usage >&2
      exit 2
      ;;
  esac
fi
