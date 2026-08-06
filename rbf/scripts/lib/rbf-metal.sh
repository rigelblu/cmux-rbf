#!/usr/bin/env bash
# rbf-metal.sh — find a Metal compiler ghostty's shader build can actually run.
#
#   source rbf/scripts/lib/rbf-metal.sh
#   rbf_ensure_metal_toolchain [--required]
#   TOOLCHAINS="$CMUX_METAL_TOOLCHAIN" <the one command that compiles shaders>
#
# The Metal compiler ships as its OWN toolchain, separate from Xcode's, and
# `xcrun` only runs it when the component's build version matches Xcode's. When
# they drift you get, from a perfectly ordinary shell:
#
#   error: cannot execute tool 'metal' due to missing Metal Toolchain;
#          use: xcodebuild -downloadComponent MetalToolchain
#
# The advice in that message is wrong when the component is already installed:
# re-downloading re-installs the same mismatched build. Observed 2026-08-10 with
# Xcode 17A5241o against MetalToolchain 17A5241l — `xcodebuild -showComponent`
# reported `Status: installed`, the cryptex was mounted, and the toolchain's own
# `metal` binary ran fine when invoked by absolute path. Only `xcrun` refused.
#
# Naming the toolchain explicitly is what fixes it. Two things that do NOT:
#   - `unset TOOLCHAINS` — right for an Xcode Run Script phase, which pins
#     TOOLCHAINS=XcodeDefault (see scripts/build-ghostty-cli-helper.sh), but a
#     plain shell already has it unset and still fails.
#   - putting the toolchain's bin dir on PATH — `xcrun` resolves tools itself.
#     `xcrun --find metal` even prints the right path while refusing to run it.
#
# WHY THIS EXPORTS CMUX_METAL_TOOLCHAIN AND NOT TOOLCHAINS:
# `xcodebuild` reads TOOLCHAINS as a build setting and would try to build the
# whole app with the Metal toolchain, which has no Swift compiler.
# rbf/scripts/install-rbf.sh:290 already passes TOOLCHAINS="" defensively for
# exactly that reason. So this exports the identifier only, and each caller
# scopes it to the single command that needs it. Do not `export TOOLCHAINS`.
#
# WHY THIS IS A LIB: same reason as rbf-zig.sh. `make build`/`run`/`test` reach
# ghostty through dev.sh, `make install-rbf` never does. A guard inside one
# entrypoint cannot be inherited by a second; only a copy can, and nobody copies
# what they do not know exists.
[[ -n "${RBF_METAL_SH_LOADED:-}" ]] && return 0
RBF_METAL_SH_LOADED=1

# Can the Metal compiler actually run? $1 is a TOOLCHAINS value; empty means
# "whatever the ambient environment already selects".
rbf__metal_runs() {
  local toolchain="${1:-}"
  if [[ -n "$toolchain" ]]; then
    TOOLCHAINS="$toolchain" xcrun -sdk macosx metal --version >/dev/null 2>&1
  else
    xcrun -sdk macosx metal --version >/dev/null 2>&1
  fi
}

# The installed Metal toolchain's identifier, e.g. com.apple.dt.toolchain.Metal.32023.
rbf__metal_identifier() {
  local id
  id="$(xcodebuild -showComponent MetalToolchain 2>/dev/null \
        | awk -F': ' '/Toolchain Identifier/ { print $2; exit }' \
        | tr -d '[:space:]')"
  if [[ -n "$id" ]]; then
    printf '%s' "$id"
    return 0
  fi

  # Fallback: read it off the downloaded toolchain itself. `-showComponent` is
  # newer than the toolchain layout, so this keeps working if the flag changes.
  local plist
  for plist in "$HOME/Library/Developer/DVTDownloads/MetalToolchain/mounts"/*/Metal.xctoolchain/ToolchainInfo.plist; do
    [[ -f "$plist" ]] || continue
    id="$(plutil -extract Identifier raw "$plist" 2>/dev/null)"
    [[ -n "$id" ]] && { printf '%s' "$id"; return 0; }
  done
  return 1
}

# rbf_ensure_metal_toolchain [--required]
#
# Exports CMUX_METAL_TOOLCHAIN: the identifier to pass as TOOLCHAINS for a
# shader build, or empty when the ambient default already works. Without
# --required a miss warns and returns 0, because a cached GhosttyKit may carry
# the shaders already and refusing would block work that would have succeeded.
rbf_ensure_metal_toolchain() {
  local strict=0
  [[ "${1:-}" == "--required" ]] && strict=1

  if rbf__metal_runs ""; then
    export CMUX_METAL_TOOLCHAIN=""
    return 0
  fi

  local id
  if id="$(rbf__metal_identifier)" && [[ -n "$id" ]] && rbf__metal_runs "$id"; then
    export CMUX_METAL_TOOLCHAIN="$id"
    echo "==> metal via $id (Xcode's own selection is broken; see rbf-metal.sh)"
    return 0
  fi

  echo "rbf-metal: no runnable Metal compiler." >&2
  echo "           Xcode:     $(xcodebuild -version 2>/dev/null | sed -n 2p)" >&2
  echo "           component: $(xcodebuild -showComponent MetalToolchain 2>/dev/null | tr '\n' ' ')" >&2
  echo "           Shader compilation will fail. Do NOT -downloadComponent if it" >&2
  echo "           already reports installed; that reinstalls the same mismatch." >&2
  export CMUX_METAL_TOOLCHAIN=""
  if [[ $strict -eq 1 ]]; then
    echo "           Refusing to start a build whose shader step cannot run." >&2
    return 1
  fi
  echo "           A cached GhosttyKit may still carry the shaders — continuing." >&2
  return 0
}
