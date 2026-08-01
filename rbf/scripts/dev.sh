#!/usr/bin/env bash
# Build and run this checkout's dev app without inventing a build-id.
#
# The **build-id** is what `scripts/reload.sh --tag <name>` takes. It decides the
# DerivedData dir, the bundle id suffix, the debug socket and the app name, so
# two dev builds never collide. (It is a component of the bundle id, not a peer
# of it: build-id `cm-18` produces bundle id `com.cmuxterm.app.debug.cm.18` —
# reload.sh maps non-alnum runs to dots, so the hyphen does not survive.)
#
# reload.sh requires one, and picking the name is a decision nobody has an
# opinion about. The branch already is the identifier, so derive it:
# `tom-rigelblu/cm-18` -> `cm-18`.
#
# That is not just less typing. One build dir per branch means switching
# branches never collides, and it makes cleanup *decidable* — DerivedData whose
# branch no longer exists is safe to delete, which is not knowable when build-ids are
# hand-picked names like `fix-blur-effect`. Each of those dirs is multiple GB.
#
# Usage:  rbf/scripts/dev.sh <build|run|build-id|test> [extra reload.sh args...]
# Prefer the Makefile front door: `make run`, `make build`, `make test`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Derive a reload.sh-safe build-id from the branch you are on.
#
# Ask jj first. This repo's primary checkout is jj, and jj keeps git's HEAD
# detached permanently — so `git branch --show-current` is empty there and a
# git-only version silently falls back to the commit sha. That is not a cosmetic
# fallback: the sha changes on every commit, so every commit would mint a fresh
# ~6GB DerivedData directory. `closest_bookmark()` walks back to the nearest
# bookmark, which is the branch you think you are on.
#
# git worktrees (used for isolated builds, since jj workspaces cannot build this
# repo) do have a real branch, so the git path still matters. Detached-and-no-jj
# falls back to the sha, which at least keeps two detached checkouts apart.
slugify() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | sed 's/^-*//; s/-*$//'; }

derive_build_id() {
  # BUILD_ID is the user-facing override; it is the same value reload.sh takes
  # as --tag. One name, so nothing has to be translated between help and command.
  # `make run BUILD=x` is a near-miss on BUILD_ID and make accepts any VAR=
  # without complaint, so it is a silent no-op. Say so rather than quietly
  # building something the caller did not ask for.
  if [[ -n "${BUILD:-}" && -z "${BUILD_ID:-}" ]]; then
    echo "dev.sh: BUILD='$BUILD' is not a variable this reads — did you mean BUILD_ID='$BUILD'?" >&2
    echo "        Ignoring it and deriving the build-id from your branch." >&2
  fi
  if [[ -n "${BUILD_ID:-}" ]]; then
    printf '%s' "$(slugify "$BUILD_ID")"
    return
  fi
  local name=""
  if [[ -d .jj ]] && command -v jj >/dev/null 2>&1; then
    # Inline `heads(::@ & bookmarks())` rather than the `closest_bookmark()`
    # alias: that alias lives in one developer's private ~/.config/jj, so anyone
    # else (or an agent with a scrubbed config) silently got `detached-<sha>` —
    # a new ~6GB DerivedData dir per commit, the exact bug this function exists
    # to prevent. `++ "\n"` separates bookmarks; without it a commit carrying
    # two of them yields one concatenated blob.
    # --ignore-working-copy: never let a build-id lookup snapshot or mutate jj state.
    name="$(jj log --ignore-working-copy --no-graph --no-pager \
              -r 'heads(::@ & bookmarks())' -T 'bookmarks ++ "\n"' 2>/dev/null \
            | tr ' ' '\n' | sed 's/\*$//' \
            | grep -v '^$' | grep -vE '(^|/)zz-' | head -1)"
  fi
  [[ -z "$name" ]] && name="$(git branch --show-current 2>/dev/null || true)"
  if [[ -z "$name" ]]; then
    local sha
    sha="$(git rev-parse --short HEAD 2>/dev/null || true)"
    [[ -n "$sha" ]] || sha="unknown"
    # Loudly, because this path silently costs ~6GB of DerivedData per commit.
    echo "dev.sh: no bookmark or branch found — using build-id 'detached-$sha'." >&2
    echo "        Each commit will get its own DerivedData dir. Pass BUILD_ID=<name> to pin one." >&2
    printf 'detached-%s' "$sha"
    return
  fi
  # Keep the last path segment: `tom-rigelblu/cm-18` -> `cm-18`.
  printf '%s' "$(slugify "${name##*/}")"
}

BUILD_ID_VALUE="$(derive_build_id)"
[[ -n "$BUILD_ID_VALUE" ]] || { echo "dev.sh: could not derive a build-id" >&2; exit 1; }

# --- Landmine 1: XcodeProj resolves forward and breaks the build --------------
# `Packages/macOS/CMUXProjectModel/Package.swift` declares XcodeProj as
# `from: "9.0.0"` — an open upper bound — so any build that lets SwiftPM resolve
# freely will drift the tracked lockfile from 9.13.0 to 9.15.0. 9.15.0 adds a
# `.fileSystemSynchronizedGroup` case and `XcodeProjectAdapter.swift:706` stops
# being exhaustive, so the build fails to compile.
#
# It is nastier than it sounds: the build that *does* the bump usually succeeds,
# and the next one fails, so it presents as "it worked yesterday."
# `reload.sh:715` already honours this env var; default it on so a plain
# `make run` is reproducible. Set it to 0 when you genuinely add a dependency.
export CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION="${CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION:-1}"

# --- Landmine 2: ghostty needs Zig 0.15.2 exactly -----------------------------
# A stock PATH usually has 0.16.0, which ghostty rejects outright. If a matching
# toolchain is already discoverable, leave PATH alone; otherwise adopt a known
# 0.15.2 if one is on this machine. Fail loudly rather than 200 lines deep in a
# build log — it warns and continues, since a cached GhosttyKit may still
# carry the build. (`#cm-4` is the slice that removes this whole problem.)
ensure_zig() {
  if command -v zig >/dev/null 2>&1 && [[ "$(zig version 2>/dev/null)" == 0.15.2* ]]; then
    return
  fi
  local candidate
  for candidate in \
    "${CMUX_ZIG:-}" \
    "$REPO_ROOT/.cmux-tools/zig/zig" \
    /Volumes/Tom\'s\ HDD/tmp/cmux-rbf-terminal-units/toolchains/zig-aarch64-macos-0.15.2/zig
  do
    [[ -n "$candidate" && -x "$candidate" ]] || continue
    if [[ "$("$candidate" version 2>/dev/null)" == 0.15.2* ]]; then
      PATH="$(dirname "$candidate"):$PATH"
      export PATH
      echo "==> zig 0.15.2 from $(dirname "$candidate")"
      return
    fi
  done
  echo "dev.sh: no Zig 0.15.2 found (PATH zig is '$(zig version 2>/dev/null || echo none)')." >&2
  echo "        ghostty rejects anything else. Set CMUX_ZIG=/path/to/zig." >&2
  echo "        (Not ./scripts/setup.sh — it only suggests 'brew install zig', which gives 0.16.0.)" >&2
  echo "        A cached GhosttyKit may still let this build succeed — continuing." >&2
}

# --- Guard: submodule parked behind the pointer the commit records ------------
# The pointer moves with a merge or rebase; the submodule working directory does
# not follow on its own. `ensure-ghosttykit.sh` keys its artifact cache on the
# **checked-out** SHA, so a stale checkout silently links an old GhosttyKit and
# the build succeeds, signs, and launches the wrong renderer. That is exactly how
# the #cm-18 typing fix got built out of a tree that already contained it.
#
# Nothing else detects this: `jj st` shows a clean tree and xcodebuild prints
# SUCCESS. Refuse rather than warn — a wrong build here costs a full rebuild plus
# however long it takes to notice you are testing code you did not write.
check_submodule_sync() {
  local sub="ghostty" recorded actual        # .gitmodules declares only this one
  [[ -d "$sub/.git" || -f "$sub/.git" ]] || return 0
  # In a jj checkout git HEAD is detached at the working-copy commit, which is
  # still the right tree to read the recorded pointer from.
  recorded="$(git ls-tree HEAD "$sub" 2>/dev/null | awk '{print $3}')"
  actual="$(git -C "$sub" rev-parse HEAD 2>/dev/null || true)"
  [[ -n "$recorded" && -n "$actual" ]] || return 0
  [[ "$recorded" == "$actual" ]] && return 0
  echo "dev.sh: REFUSING TO BUILD — '$sub' is not at the commit this tree records." >&2
  echo "        recorded:    ${recorded:0:12}" >&2
  echo "        checked out: ${actual:0:12}" >&2
  echo "        A build would link the checked-out version and silently succeed." >&2
  echo "        Fix:  git -C $sub checkout ${recorded:0:12}" >&2
  exit 1
}

cmd="${1:-run}"
[[ $# -gt 0 ]] && shift || true

case "$cmd" in
  build-id)
    echo "$BUILD_ID_VALUE"
    ;;
  build)
    echo "==> build-id: $BUILD_ID_VALUE (from branch)"
    check_submodule_sync
    ensure_zig
    exec ./scripts/reload.sh --tag "$BUILD_ID_VALUE" "$@"
    ;;
  run)
    echo "==> build-id: $BUILD_ID_VALUE (from branch)"
    check_submodule_sync
    ensure_zig
    exec ./scripts/reload.sh --tag "$BUILD_ID_VALUE" --launch "$@"
    ;;
  test)
    # The `cmux` scheme compiles no unit tests and still prints TEST BUILD
    # SUCCEEDED, so this pins `cmux-unit` — see rbf/AGENTS.md. There is no CI
    # behind this; running it here is the only gate.
    #
    # Reuse reload.sh's own slug for the DerivedData path. Deriving it here
    # instead diverges on any build-id with a capital, an underscore or a dot
    # (`Fix_Thing` -> reload.sh `cmux-fix-thing`, naive `cmux-Fix_Thing`), which
    # means two multi-GB dirs, a full rebuild on every `make test`, and a name
    # cleanup-dev-builds.sh cannot map back to a build-id.
    dd_slug="$BUILD_ID_VALUE"
    # shellcheck source=/dev/null
    if . scripts/lib/mobile-attach.sh 2>/dev/null && declare -f cmux_attach__slug_raw >/dev/null; then
      dd_slug="$(cmux_attach__slug_raw "$BUILD_ID_VALUE")"
    fi
    # xcodebuild has never heard of CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION —
    # only reload.sh translates it into a flag. Invoking xcodebuild directly
    # would let SwiftPM resolve freely and drift the lockfile, so `make test`
    # would re-arm the landmine `make build` disarms.
    resolve_args=()
    [[ "${CMUX_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION:-}" == "1" ]] \
      && resolve_args+=(-disableAutomaticPackageResolution)
    exec xcodebuild test \
      -project cmux.xcodeproj \
      -scheme cmux-unit \
      -configuration Debug \
      -destination 'platform=macOS' \
      -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-$dd_slug" \
      "${resolve_args[@]}" \
      "$@"
    ;;
  *)
    echo "usage: rbf/scripts/dev.sh <build|run|build-id|test> [extra reload.sh args...]" >&2
    exit 2
    ;;
esac
