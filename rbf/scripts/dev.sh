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

# Pre-grant TCC permissions for this build's bundle id so a new branch's first
# launch doesn't re-prompt. Fail-soft: every failure inside degrades to the old
# behavior (one prompt pair), never a broken build.
tcc_preseed() {
  # shellcheck source=/dev/null
  if . "$REPO_ROOT/rbf/scripts/lib/rbf-tcc-preseed.sh" 2>/dev/null \
      && declare -f rbf_tcc_preseed >/dev/null; then
    RBF_REPO_ROOT="$REPO_ROOT" rbf_tcc_preseed "$1" || true
  fi
}

# Derive a reload.sh-safe build-id from the branch you are on.
#
# Ask jj first. This repo's primary checkout is jj, and jj keeps git's HEAD
# detached permanently — so `git branch --show-current` is empty there and a
# git-only version silently falls back to the commit sha. That is not a cosmetic
# fallback: the sha changes on every commit, so every commit would mint a fresh
# ~6GB DerivedData directory. So walk back to the nearest bookmark instead —
# see the revset below, and why it is written out rather than aliased.
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
# Lives in rbf/scripts/lib/rbf-zig.sh, not here, because `make install-rbf` reaches
# install-rbf.sh without passing through this file — and when this was a private
# function, that path silently had no Zig guard and died inside an xcodebuild
# script phase. See the lib header.
RBF_REPO_ROOT="$REPO_ROOT"
# shellcheck source=rbf/scripts/lib/rbf-zig.sh
. "$REPO_ROOT/rbf/scripts/lib/rbf-zig.sh"
ensure_zig() { rbf_ensure_zig; }

# --- Landmine 3: multi-GB artifacts defaulting to the near-full internal disk --
# Same lib-not-here reasoning as Zig above. See the lib header.
# shellcheck source=rbf/scripts/lib/rbf-tmp.sh
. "$REPO_ROOT/rbf/scripts/lib/rbf-tmp.sh"

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
    rbf_require_deriveddata || exit 1
    check_submodule_sync
    ensure_zig
    tcc_preseed "$BUILD_ID_VALUE"
    # No exec: the preseed must run again AFTER reload.sh. The app swap can
    # race TCC — a prompt answered against a mid-swap process records a
    # one-build cdhash grant the new app never matches (observed 2026-08-05),
    # and the post-pass repairs it so the next launch is silent.
    status=0
    ./scripts/reload.sh --tag "$BUILD_ID_VALUE" "$@" || status=$?
    tcc_preseed "$BUILD_ID_VALUE"
    exit "$status"
    ;;
  run)
    echo "==> build-id: $BUILD_ID_VALUE (from branch)"
    rbf_require_deriveddata || exit 1
    check_submodule_sync
    ensure_zig
    tcc_preseed "$BUILD_ID_VALUE"
    # No exec — see `build` for why the preseed runs again after reload.sh.
    status=0
    ./scripts/reload.sh --tag "$BUILD_ID_VALUE" --launch "$@" || status=$?
    tcc_preseed "$BUILD_ID_VALUE"
    exit "$status"
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
    # Both guards, same as `build` and `run` — omitting them here was a real bug.
    # `cmux-unit.xcscheme` sets buildForTesting="YES" on the app target, so
    # `make test` runs the ghostty script phase and needs Zig 0.15.2 exactly like
    # a build does; without this it dies ~200 lines into an xcodebuild phase
    # while `make build` succeeds. And a stale submodule would link a ghostty the
    # commit does not record — a green test run against code nobody wrote, in the
    # one command this fork calls its gate.
    rbf_require_deriveddata || exit 1
    check_submodule_sync
    ensure_zig
    # The unit-test host is the UNTAGGED "cmux DEV.app" (bundle id
    # com.cmuxterm.app.debug), not the tagged app — seed that id.
    tcc_preseed "com.cmuxterm.app.debug"

    # A running app makes the test runner die with "Test runner never began
    # executing tests", exit 65, ZERO tests run — and nothing in that message
    # says why. Documented in rbf/AGENTS.md, which is no help to someone who has
    # not read it. Detect it and say the fix.
    #
    # BOTH shapes block, and checking only the tagged one was a real gap. The
    # unit-test host is the UNTAGGED "cmux DEV.app" — the tcc_preseed six lines
    # above says so — so an untagged app left running by ANY other worktree
    # occupies the host bundle id. Its name never contains a build-id, so a
    # tagged-only pattern can never match it no matter which build-id you are on.
    # Observed 2026-08-05: a stray untagged app from an unrelated tree wedged a
    # full run at 0% CPU for 49 minutes, with no error until it was killed.
    #
    # `\.app` is escaped because pgrep -f takes a regex — unescaped, `DEV.app`
    # also matches a one-character build-id, so the untagged probe would fire on
    # a tagged app and misname the offender.
    #
    # if/then rather than `pgrep … && flag=1`: under `set -e` a non-matching
    # pgrep makes the && compound return non-zero and kills the script, so the
    # guard would abort exactly when nothing is wrong.
    tagged_running=0
    untagged_running=0
    if pgrep -f "cmux DEV $BUILD_ID_VALUE\.app/Contents/MacOS/" >/dev/null 2>&1; then
      tagged_running=1
    fi
    if pgrep -f "cmux DEV\.app/Contents/MacOS/" >/dev/null 2>&1; then
      untagged_running=1
    fi
    if [[ "$tagged_running" -eq 1 || "$untagged_running" -eq 1 ]]; then
      echo "dev.sh: REFUSING — a 'cmux DEV' app is running:" >&2
      [[ "$tagged_running" -eq 1 ]] \
        && echo "          · cmux DEV $BUILD_ID_VALUE — your build-id" >&2
      [[ "$untagged_running" -eq 1 ]] \
        && echo "          · cmux DEV (untagged) — THE unit-test host, possibly another worktree's" >&2
      echo "        The test runner would die with 'Test runner never began" >&2
      echo "        executing tests', exit 65, and zero tests run — a failure" >&2
      echo "        that looks like broken tests and is not." >&2
      echo "        Running now:" >&2
      pgrep -fl "cmux DEV.*\.app/Contents/MacOS/" 2>/dev/null | sed 's/^/          /' >&2 || true
      echo "        Quit them, then re-run." >&2
      exit 1
    fi

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
    # TCC keys permission grants off the code signature. reload.sh re-signs the
    # tagged app with CMUX_DEV_CODESIGN_IDENTITY so grants survive rebuilds, but
    # this path never goes through reload.sh — Xcode ad-hoc signs the test host
    # ("cmux DEV.app"), whose designated requirement is a cdhash that changes
    # every build, so EVERY `make test` re-prompts for removable-volume and
    # app-data access. Passing the identity here gives the host the same stable
    # identifier-based requirement, so one grant sticks. Unset → ad-hoc, as before.
    sign_args=()
    if [[ -n "${CMUX_DEV_CODESIGN_IDENTITY:-}" ]]; then
      if security find-identity -v -p codesigning 2>/dev/null \
          | grep -Fq "\"$CMUX_DEV_CODESIGN_IDENTITY\""; then
        sign_args+=(CODE_SIGN_IDENTITY="$CMUX_DEV_CODESIGN_IDENTITY" CODE_SIGN_STYLE=Manual)
      else
        echo "dev.sh: warning: CMUX_DEV_CODESIGN_IDENTITY='$CMUX_DEV_CODESIGN_IDENTITY' not in the keychain; test host stays ad-hoc signed (macOS will re-prompt for permissions)" >&2
      fi
    fi
    # xcodebuild writes a ~450MB .xcresult per run into $TMPDIR — on the
    # internal disk — and never removes it. 108 of them (19GB) piled up in five
    # days and helped take the SSD to 570MB free; 47 landed on 2026-08-04 alone.
    # Nothing reported this, because a leak that only shows up as "disk full"
    # three days later reads as an unrelated problem.
    #
    # Two fixes in one line. The path moves to the external drive, AND it is
    # stable per build-id rather than a fresh UUID per run: xcodebuild refuses
    # to write over an existing bundle, so the rm is required regardless, and a
    # stable name is what caps this at one bundle per build-id instead of
    # relocating an unbounded pile onto the other drive.
    #
    # Keep the newest rather than deleting after the run — `make test`'s tail is
    # app-log noise, so a real failure can only be read out of the bundle.
    result_bundle="$(rbf_tmp_dir "cmux-rbf/xcresults")/cmux-$dd_slug.xcresult"
    rm -rf "$result_bundle"
    echo "dev.sh: result bundle -> $result_bundle" >&2

    exec xcodebuild test \
      -project cmux.xcodeproj \
      -scheme cmux-unit \
      -configuration Debug \
      -destination 'platform=macOS' \
      -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/cmux-$dd_slug" \
      -resultBundlePath "$result_bundle" \
      ${resolve_args[@]+"${resolve_args[@]}"} \
      ${sign_args[@]+"${sign_args[@]}"} \
      "$@"
    ;;
  *)
    echo "usage: rbf/scripts/dev.sh <build|run|build-id|test> [extra reload.sh args...]" >&2
    exit 2
    ;;
esac
