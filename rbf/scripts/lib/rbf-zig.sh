#!/usr/bin/env bash
# rbf-zig.sh — put a Zig 0.15.2 where the ghostty build can find it.
#
#   source rbf/scripts/lib/rbf-zig.sh
#   rbf_ensure_zig [--required]
#
# ghostty pins 0.15.2 exactly (`ZIG_REQUIRED` in scripts/build-ghostty-cli-helper.sh)
# and a stock PATH here carries 0.16.0, which it rejects outright:
#
#   error: zig 0.15.2 is required to build the Ghostty CLI helper
#
# That error arrives ~200 lines into an xcodebuild Run Script phase, wrapped in
# a wall of `export FOO=bar`, so it reads like an Xcode problem rather than a
# PATH problem. Resolve it up front instead.
#
# WHY THIS IS A LIB AND NOT A FUNCTION IN dev.sh, WHICH IS WHERE IT STARTED:
# it was private to dev.sh, so `make build` and `make run` were covered and
# `make install-rbf` — which calls rbf/scripts/install-rbf.sh directly — was not.
# The install failed on exactly this, in exactly this way. A guard that lives
# inside one entrypoint cannot be inherited by a second one; only a copy can,
# and nobody copies what they do not know exists. Same shape as the XcodeProj
# cap, which was patched at `make build`, then `make test`, then `make install`,
# before it moved down into Package.swift where all three see it.
#
# Both levers are set, because the two consumers read different ones:
#   CMUX_ZIG — build-ghostty-cli-helper.sh checks this FIRST and hard-errors if
#              it is the wrong version. Explicit, and cannot be shadowed.
#   PATH     — everything else that just runs `zig`.
#
# (`#cm-4` is the slice that removes this whole problem.)

# Idempotent within a single shell: sourcing twice re-runs the PATH prepend and
# stacks a duplicate entry. Deliberately NOT exported — it would then leak into
# every child process, and it could not help there anyway: the two consumers
# (dev.sh, install-rbf.sh) never share a shell, and an `exec` replaces the
# process, so no in-memory flag survives it. Same-shell double-source is the only
# case this can catch, and the only one that happens.
[[ -n "${RBF_ZIG_SH_LOADED:-}" ]] && return 0
RBF_ZIG_SH_LOADED=1

RBF_ZIG_REQUIRED="${RBF_ZIG_REQUIRED:-0.15.2}"

# Candidates, in priority order. The external-drive entry is machine-specific
# on purpose: it is where the working toolchain actually is on this machine, and
# a wrong-but-portable default would just fail slower. Set CMUX_ZIG to override.
rbf__zig_candidates() {
  printf '%s\n' \
    "${CMUX_ZIG:-}" \
    "${RBF_REPO_ROOT:-.}/.cmux-tools/zig/zig" \
    "/Volumes/Tom's HDD/tmp/cmux-rbf-terminal-units/toolchains/zig-aarch64-macos-0.15.2/zig" \
    "/opt/homebrew/bin/zig" \
    "/usr/local/bin/zig"
}

rbf__zig_version_ok() {
  [[ -x "$1" ]] || return 1
  [[ "$("$1" version 2>/dev/null)" == "$RBF_ZIG_REQUIRED"* ]]
}

# rbf_ensure_zig [--required]
#
# Exports CMUX_ZIG and prepends to PATH when a matching toolchain is found.
# Without --required, a miss warns and returns 0: a cached GhosttyKit may
# already carry the build, so refusing would block work that would have
# succeeded. With --required, a miss is fatal — use it where the build must
# produce a fresh helper and a late failure costs a full Release compile.
rbf_ensure_zig() {
  local strict=0
  [[ "${1:-}" == "--required" ]] && strict=1

  # An explicit CMUX_ZIG that is wrong is an error, never a fallback. Silently
  # using a different toolchain than the one asked for is the "build succeeded,
  # wrong thing built" class this repo keeps getting burned by — and
  # build-ghostty-cli-helper.sh hard-errors on it downstream regardless, so
  # falling through here only moves the failure somewhere less legible.
  if [[ -n "${CMUX_ZIG:-}" ]] && ! rbf__zig_version_ok "$CMUX_ZIG"; then
    echo "rbf-zig: CMUX_ZIG is set but unusable: $CMUX_ZIG" >&2
    echo "         version: $("$CMUX_ZIG" version 2>/dev/null || echo 'not executable')" >&2
    echo "         need $RBF_ZIG_REQUIRED. Not falling back — unset it to search." >&2
    return 1
  fi

  # Already satisfied by whatever is on PATH — leave it alone.
  if command -v zig >/dev/null 2>&1 \
     && rbf__zig_version_ok "$(command -v zig)"; then
    export CMUX_ZIG="${CMUX_ZIG:-$(command -v zig)}"
    return 0
  fi

  local candidate
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    rbf__zig_version_ok "$candidate" || continue
    export CMUX_ZIG="$candidate"
    PATH="$(dirname "$candidate"):$PATH"
    export PATH
    echo "==> zig $RBF_ZIG_REQUIRED from $(dirname "$candidate")"
    return 0
  done < <(rbf__zig_candidates)

  echo "rbf-zig: no Zig $RBF_ZIG_REQUIRED found (PATH zig is '$(zig version 2>/dev/null || echo none)')." >&2
  echo "         ghostty rejects anything else. Set CMUX_ZIG=/path/to/zig." >&2
  echo "         (Not ./scripts/setup.sh — it only suggests 'brew install zig', which gives 0.16.0.)" >&2
  if [[ $strict -eq 1 ]]; then
    echo "         Refusing to start a Release build that would fail in a script phase." >&2
    return 1
  fi
  echo "         A cached GhosttyKit may still let this build succeed — continuing." >&2
  return 0
}
