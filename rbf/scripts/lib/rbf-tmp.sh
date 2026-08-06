#!/usr/bin/env bash
# Where large or throwaway build artifacts go.
#
# The internal SSD on this machine runs near-full — it hit 570MB free on
# 2026-08-05 — while the external drive carries a terabyte spare. Anything
# multi-GB and reproducible belongs on the external drive.
#
# This lives in lib/ rather than inside dev.sh for the same reason rbf-zig.sh
# does: `make install-rbf` calls install-rbf.sh directly and never passes
# through dev.sh, so a guard written inside one entrypoint cannot be inherited
# by a second — only a copy can, and nobody copies what they don't know exists.
# install-rbf.sh:193 still hardcodes its own copy of this mount check; it should
# adopt rbf_tmp_dir so there is one answer instead of two.
#
# Degrade, don't fail. When the drive is offline the caller still needs a
# working path — less headroom is recoverable, a build that dies at the
# resolver is not. The warning goes to stderr so stdout stays a bare path,
# safe to capture in "$(...)".

# Resolve (and create) a directory for throwaway artifacts.
#   rbf_tmp_dir                      -> <base>
#   rbf_tmp_dir cmux-rbf/xcresults   -> <base>/cmux-rbf/xcresults
rbf_tmp_dir() {
  local subdir="${1:-}"
  # The default is assigned on its own line, NOT as "${RBF_EXTERNAL_DRIVE:-…}".
  # bash cannot parse an apostrophe inside a ${var:-word} default — "Tom's HDD"
  # there is a hard syntax error, while zsh accepts it happily. Since dev.sh
  # runs under bash and an interactive check runs under zsh, the inline form
  # tests clean and then breaks every `make test`.
  local drive="${RBF_EXTERNAL_DRIVE:-}"
  [[ -n "$drive" ]] || drive="/Volumes/Tom's HDD"
  local base

  if [[ -d "$drive" ]]; then
    base="$drive/tmp"
  else
    base="${TMPDIR:-/tmp}"
    echo "rbf-tmp: '$drive' is not mounted; falling back to $base (near-full internal disk)" >&2
  fi

  [[ -n "$subdir" ]] && base="$base/$subdir"

  mkdir -p "$base" || {
    echo "rbf-tmp: could not create '$base'" >&2
    return 1
  }

  printf '%s\n' "$base"
}

# Refuse to build when DerivedData is a symlink to an unmounted volume.
#
# ~/Library/Developer/Xcode/DerivedData is a symlink onto the external drive
# (machine-wide — Ghostty, magin and six other projects ride it too). Unplug the
# drive and it dangles, and what you get is not "your drive is not mounted": it
# is an xcodebuild failure several hundred lines deep about a path that cannot
# be created, or Xcode quietly materialising a real directory in its place and
# refilling the internal SSD — the exact condition this file exists to prevent,
# now invisible.
#
# Deliberately fails rather than falls back. rbf_tmp_dir degrades because a
# throwaway artifact somewhere else is still a working build; DerivedData is
# where the build IS, so guessing a different location silently discards an
# incremental build and gigabytes of disk. Say the one thing that fixes it.
rbf_require_deriveddata() {
  local dd="$HOME/Library/Developer/Xcode/DerivedData"

  # Not a symlink -> a plain local dir, nothing to verify.
  [[ -L "$dd" ]] || return 0
  # -e follows the link: true means the target resolves.
  [[ -e "$dd" ]] && return 0

  local target
  target="$(readlink "$dd")"
  echo "rbf-tmp: REFUSING — DerivedData points at a volume that is not mounted." >&2
  echo "         $dd" >&2
  echo "      -> $target" >&2
  echo "         Mount that drive and re-run. Building now would either die deep" >&2
  echo "         inside xcodebuild, or refill the internal disk without saying so." >&2
  return 1
}
