#!/usr/bin/env bash
# rbf-zig.sh — expose the repository Zig resolver to every RBF build entrypoint.
#
# This remains a library because make build/run/test enter through dev.sh while
# make install-rbf enters through install-rbf.sh. The selection and validation
# live in scripts/zig-toolchain.sh, shared with setup.sh, reload.sh, the Ghostty
# CLI helper, and install-zig-ci.sh.

[[ -n "${RBF_ZIG_SH_LOADED:-}" ]] && return 0
RBF_ZIG_SH_LOADED=1

rbf__zig_repo_root() {
  if [[ -n "${RBF_REPO_ROOT:-}" ]]; then
    printf '%s\n' "$RBF_REPO_ROOT"
  else
    cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd
  fi
}

RBF_ZIG_REPO_ROOT="$(rbf__zig_repo_root)"
# shellcheck source=/dev/null
source "$RBF_ZIG_REPO_ROOT/scripts/zig-toolchain.sh"
RBF_ZIG_REQUIRED="${RBF_ZIG_REQUIRED:-$(cmux_zig_required_version)}"

rbf__zig_version_ok() {
  cmux_zig_is_usable "$1" "$RBF_ZIG_REQUIRED"
}

# rbf_ensure_zig [--required]
#
# The option remains accepted for existing callers. Selection now fails early
# for every build path: setup is the only path that installs, and all later
# entrypoints resolve the same complete compiler or point back to setup.
rbf_ensure_zig() {
  if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != "--required" ) ]]; then
    echo "usage: rbf_ensure_zig [--required]" >&2
    return 2
  fi

  local resolved=""
  resolved="$(cmux_zig_resolve)" || return $?

  export CMUX_ZIG="$resolved"
  PATH="$(dirname "$resolved"):$PATH"
  export PATH
  echo "==> Using Zig $("$resolved" version) at $resolved"
}
