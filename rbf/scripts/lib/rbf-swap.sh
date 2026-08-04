#!/usr/bin/env bash
# rbf-swap.sh — the quit → swap → migrate → report tail of install-rbf.sh (#cm-27).
#
# Sourced by tests (no side effects at source time, same contract as
# rbf-install-target.sh) and executed by install-rbf.sh, which is the only
# real entry point. It runs in one of two modes:
#
#   --mode inline    Run in the foreground with live stdout, behavior matching
#                    the pre-split install-rbf.sh tail. Used whenever the
#                    invoking terminal is NOT hosted by the app being replaced.
#
#   --mode detached  Run as a daemonized orphan (the parent double-forks +
#                    setsid(2)s us — macOS ships no setsid(1) binary), because
#                    the invoking terminal IS hosted by the app being replaced:
#                    quitting that app SIGHUPs its whole PTY, parent included.
#                    All output goes to --log-file; the user hears about the
#                    outcome through macOS notifications and, on success, the
#                    app relaunching itself.
#
# OWNERSHIP CONTRACT (#cm-27 brief, Irreversibles): exactly one process may
# delete STAGING_ROOT, and which one is settled by an ELECTION rather than a
# handoff — see rbf_swap_claim_path below. Our first acts in main are therefore
# installing our own EXIT trap and then CLAIMING; a claim that fails means the
# parent already reclaimed and we must exit touching nothing. The parent's own
# trap defers to an existing claim, so it cannot delete what we own even if it
# fires before it stands down.
#
# An earlier design used a marker file plus a trap disarm and argued the
# overlap was safe because "rm -rf if present is idempotent". It is not: in the
# overlap the staging dir still CONTAINS the app, so a fire there deletes the
# install rather than a leftover. Do not reintroduce that reasoning.
#
# ROLLBACK_ROOT is never deleted by any trap — during the swap it holds the
# only working copy of the app on the machine, and it is removed explicitly
# after the swap succeeds, exactly as before the split.
#
# EVERY VALUE ARRIVES THROUGH THE ARGUMENT CONTRACT. This script does not
# source rbf-install-target.sh / rbf-channel.env — one source of truth per
# value; a helper that re-derives what its parent already resolved is how the
# two processes come to disagree.

set -uo pipefail

# ---------------------------------------------------------------------------
# Seams. Tests override these to simulate a running app, a failing rename, or
# a fake clock; production never does. Each wraps exactly one external effect.
# ---------------------------------------------------------------------------
rbf_swap_app_running() { pgrep -f "$1/Contents/MacOS/" >/dev/null 2>&1; }
rbf_swap_request_quit() { osascript -e "tell application id \"$1\" to quit" >/dev/null 2>&1 || true; }
rbf_swap_sigterm() { pkill -TERM -f "$1/Contents/MacOS/" 2>/dev/null || true; }
rbf_swap_relaunch() { open "$1"; }
rbf_swap_sleep() { sleep "$1"; }
rbf_swap_mv() { mv "$@"; }

# Notifications are detached-mode only: inline has a live terminal, and a
# banner duplicating stdout would train the user to ignore banners. The mode
# gate lives HERE and the delivery lives in the seam below, so tests that stub
# delivery still exercise the gate — a stub that replaced the whole function
# would be asserting its own behavior.
rbf_swap_notify() {
  [[ "$SWAP_MODE" == "detached" ]] || return 0
  rbf_swap_post_notification "$1" "$2"
}
rbf_swap_post_notification() {
  osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Routing. Called by install-rbf.sh (which sources this file) to decide the
# mode; kept here so the decision and its consumer live in one place and the
# test can drive it directly.
# ---------------------------------------------------------------------------
rbf_swap_mode() {
  local rbf_bundle_id="$1"
  if [[ "${CMUX_BUNDLE_ID:-}" == "$rbf_bundle_id" ]]; then
    printf 'detached'
  else
    printf 'inline'
  fi
}

rbf_swap_step() { printf '⋯ %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Ownership election. The helper CLAIMS staging by mkdir'ing a sentinel dir —
# one atomic syscall, no check-then-act gap — and the parent, if its wait
# times out, RECLAIMS by attempting the same mkdir. Exactly one side ever
# wins, so exactly one side ever deletes staging or proceeds against the app.
# This replaced a marker-file design whose poll-timeout had a window where
# both processes held an rm -rf over a staging dir still containing the app
# (cold code review, 2026-08-04, MEDIUM).
# ---------------------------------------------------------------------------
rbf_swap_claim_path() { printf '%s/.rbf-swap-claimed' "$1"; }

# Parent side: wait for the helper's claim. Returns 0 = helper owns staging
# (acknowledged handoff); 1 = we reclaimed it (helper never started — its own
# later claim attempt will fail and it will exit without touching anything).
#
# Takes SECONDS and derives the poll count, so the interval is this function's
# private business — a caller passing deciseconds would have to be kept in step
# with it, and the prose around the call site would silently lie the first time
# either changed.
rbf_swap_wait_for_claim() {
  local staging_root="$1" timeout_s="${2:-30}"
  local claim; claim="$(rbf_swap_claim_path "$staging_root")"
  local polls=$((timeout_s * 10)) waited=0
  while [[ ! -e "$claim" && $waited -lt $polls ]]; do
    rbf_swap_sleep 0.1; waited=$((waited + 1))
  done
  [[ -e "$claim" ]] && return 0
  if mkdir "$claim" 2>/dev/null; then
    return 1
  fi
  # The helper claimed in the race window between our last poll and the
  # mkdir — it owns staging; treat the handoff as acknowledged.
  return 0
}

# ---------------------------------------------------------------------------
# Parent side of the detached handoff. Lives HERE, not inline in
# install-rbf.sh, for two reasons this repo has already paid for: a guard
# written inside one entrypoint cannot be inherited by a second (rbf/AGENTS.md
# — the XcodeProj and Zig gates each had to be rediscovered at every
# entrypoint), and a block sitting inline in a script that drives xcodebuild is
# unreachable by any test. Split out, the election's parent half is drivable
# with a fake helper.
# ---------------------------------------------------------------------------

# Daemonize: double-fork + setsid(2), because macOS ships no setsid(1). This is
# a seam — tests replace it with a fake that claims immediately, late or never
# — and it is ALSO exercised for real by the survives-its-parent test, which is
# the one property a fake can never prove.
rbf_swap_spawn_daemon() { # $1 = log file; rest = argv to exec detached
  local log_file="$1"; shift
  nohup /usr/bin/env python3 -c '
import os, sys
if os.fork() > 0:
    os._exit(0)
os.setsid()
os.execv(sys.argv[1], sys.argv[1:])
' "$@" </dev/null >>"$log_file" 2>&1 &
  disown
}

# Launch the helper, then settle ownership. Returns 0 when the helper owns
# staging (handoff acknowledged), 1 when WE reclaimed it — in which case the
# helper can no longer act, and the caller owns both the cleanup and the
# report. The caller keeps those two jobs because only it knows how to reach
# the user it still has.
rbf_swap_launch_detached() { # $1 staging_root, $2 log, $3 timeout_s, rest = argv
  local staging_root="$1" log_file="$2" timeout_s="$3"; shift 3
  rbf_swap_spawn_daemon "$log_file" "$@"
  rbf_swap_wait_for_claim "$staging_root" "$timeout_s"
}

# Staging cleanup is deliberately NOT done here — the EXIT trap owns it, so
# every exit path gets it rather than only the ones routed through die.
#
# NOTE the asymmetry with rbf_swap_quit_app, which RETURNS non-zero and lets
# main decide: rbf_swap_install dies in place instead, because each of its
# failure branches owns a different notification text (restored / parked at a
# path you cannot guess), and hoisting that decision to main would separate
# each message from the branch that knows it.
rbf_swap_die() {
  printf 'error: %s\n' "$1" >&2
  rbf_swap_notify "cmux RBF install failed" "${2:-$1 — see $SWAP_LOG_FILE}"
  exit 1
}

rbf_swap_cleanup() {
  [[ -n "${SWAP_STAGING_ROOT:-}" && -d "$SWAP_STAGING_ROOT" ]] && rm -rf "$SWAP_STAGING_ROOT"
  return 0
}

# ---------------------------------------------------------------------------
# Quit the running app, or refuse. Inline behavior is the pre-split tail
# verbatim: osascript → wait 10s → SIGTERM → 2s → refuse with the terminal
# intact. Detached stretches the wait to 60s and narrates through
# notifications, because nobody is watching stdout — but it still never
# force-quits: a cmux that will not quit is usually holding a confirm-close
# or unsaved-state dialog, and SIGKILL discards the workspaces this installer
# exists to keep.
# ---------------------------------------------------------------------------
rbf_swap_quit_app() {
  local install_path="$1" bundle_id="$2" mode="${3:-${SWAP_MODE:-inline}}"
  local timeout notified=0 waited=0

  # The step line prints unconditionally, matching the pre-split script —
  # inline output parity is a promise (brief: one deliberate difference only).
  rbf_swap_step "quitting a running cmux RBF"
  rbf_swap_app_running "$install_path" || return 0
  rbf_swap_request_quit "$bundle_id"

  if [[ "$mode" == "detached" ]]; then timeout=60; else timeout=10; fi

  while rbf_swap_app_running "$install_path"; do
    [[ $waited -ge $timeout ]] && break
    if [[ "$mode" == "detached" && $waited -ge 10 && $notified -eq 0 ]]; then
      rbf_swap_notify "cmux RBF is waiting on a dialog" \
        "Dismiss it to continue the install."
      notified=1
    fi
    rbf_swap_sleep 1; waited=$((waited + 1))
  done

  if rbf_swap_app_running "$install_path"; then
    rbf_swap_sigterm "$install_path"
    rbf_swap_sleep 2
  fi

  if rbf_swap_app_running "$install_path"; then
    printf 'error: cmux RBF is still running after %ds and a SIGTERM.\n' "$timeout" >&2
    printf '       Refusing to force-quit — it is probably holding an unsaved-state\n' >&2
    printf '       or confirm-close dialog, and killing it would discard workspaces.\n' >&2
    printf '       Quit it by hand, then re-run. Nothing was written; the existing\n' >&2
    printf '       install at %s is untouched.\n' "$install_path" >&2
    rbf_swap_notify "cmux RBF install aborted" \
      "The app never quit (a dialog?). Nothing was changed. See $SWAP_LOG_FILE"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The swap itself — park the old bundle, rename the new one in, roll back on
# failure. Same-volume renames throughout; structure unchanged from the
# pre-split install-rbf.sh.
# ---------------------------------------------------------------------------
rbf_swap_install() {
  local staged_app="$1" install_path="$2" rollback_root="$3"
  local previous=""

  [[ -d "$staged_app" ]] || rbf_swap_die "staged app missing at $staged_app — nothing was installed"

  if [[ -d "$install_path" ]]; then
    mkdir -p "$rollback_root" || rbf_swap_die "cannot create the rollback dir: $rollback_root"
    previous="$rollback_root/previous.app"
    rbf_swap_mv "$install_path" "$previous" || rbf_swap_die "could not move the existing install aside"
  fi

  if ! rbf_swap_mv "$staged_app" "$install_path"; then
    if [[ -n "$previous" ]]; then
      if rbf_swap_mv "$previous" "$install_path"; then
        printf 'rolled back to the previous install\n' >&2
        rmdir "$rollback_root" 2>/dev/null || true
        # Detached, the app was already quit and the terminal is dead — a
        # restore that leaves nothing running strands the user. Relaunch the
        # restored bundle before reporting failure (cold review, 2026-08-04).
        if [[ "$SWAP_MODE" == "detached" ]]; then rbf_swap_relaunch "$install_path" || true; fi
        rbf_swap_die "failed to move the new app into place" \
          "Swap failed; your previous install was restored and relaunched. See $SWAP_LOG_FILE"
      else
        # Both moves failed, so /Applications has no app. Say exactly where the
        # old one is; this is the case the rollback dir exists for, and a path
        # the user cannot guess.
        printf 'error: rollback ALSO failed. Your previous install is intact at:\n' >&2
        printf '       %s\n' "$previous" >&2
        printf '       Move it back by hand; nothing else will clean it up.\n' >&2
        rbf_swap_die "failed to move the new app into place" \
          "Swap AND rollback failed. Previous app parked at $previous — see $SWAP_LOG_FILE"
      fi
    fi
    rbf_swap_die "failed to move the new app into place"
  fi

  # The swap succeeded, so the old bundle is no longer the only copy of a
  # working app. Removed explicitly here rather than by the EXIT trap — if this
  # line is never reached, the previous install is still on disk and
  # recoverable by hand, which is the entire point of keeping it outside
  # STAGING_ROOT.
  [[ -n "$previous" ]] && rm -rf "$rollback_root"
  return 0
}

# ---------------------------------------------------------------------------
# First-install state migration. ${PIPESTATUS[0]} rather than the pipeline's
# own status, for the reason documented at length in the pre-split script:
# the correctness of this line must not live 300 lines away in a `pipefail`
# nothing here names.
# ---------------------------------------------------------------------------
rbf_swap_migrate() {
  local first_install="$1" upstream_bundle_id="$2"
  SWAP_MIGRATION_RESULT="skipped (existing install)"
  if [[ "$first_install" -eq 1 ]]; then
    rbf_swap_step "migrating state from upstream (first install only)"
    bash "$SWAP_MIGRATE_SCRIPT" 2>&1 | sed 's/^/  /'
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
      SWAP_MIGRATION_RESULT="migrated from $upstream_bundle_id"
    else
      SWAP_MIGRATION_RESULT="FAILED — run rbf/scripts/migrate-rbf-state.sh --reclone"
    fi
  fi
}

rbf_swap_usage() {
  cat <<'USAGE'
Usage (from install-rbf.sh only): rbf-swap.sh --mode inline|detached \
  --staged-app P --staging-root P --rollback-root P --install-path P \
  --bundle-id ID --upstream-bundle-id ID --upstream-path P \
  --first-install 0|1 --rbf-version V --git-commit SHA --log-file P

install-rbf.sh picks the mode: inline (live output, any ordinary terminal)
or detached (daemonized; log + notifications + relaunch) when the invoking
terminal is hosted by the app being replaced.
USAGE
}

rbf_swap_main() {
  SWAP_MODE="" SWAP_STAGED_APP="" SWAP_STAGING_ROOT="" SWAP_ROLLBACK_ROOT=""
  SWAP_INSTALL_PATH="" SWAP_BUNDLE_ID="" SWAP_UPSTREAM_BUNDLE_ID=""
  SWAP_UPSTREAM_PATH="" SWAP_FIRST_INSTALL="" SWAP_RBF_VERSION=""
  SWAP_GIT_COMMIT="" SWAP_LOG_FILE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --mode)                SWAP_MODE="$2"; shift 2 ;;
      --staged-app)          SWAP_STAGED_APP="$2"; shift 2 ;;
      --staging-root)        SWAP_STAGING_ROOT="$2"; shift 2 ;;
      --rollback-root)       SWAP_ROLLBACK_ROOT="$2"; shift 2 ;;
      --install-path)        SWAP_INSTALL_PATH="$2"; shift 2 ;;
      --bundle-id)           SWAP_BUNDLE_ID="$2"; shift 2 ;;
      --upstream-bundle-id)  SWAP_UPSTREAM_BUNDLE_ID="$2"; shift 2 ;;
      --upstream-path)       SWAP_UPSTREAM_PATH="$2"; shift 2 ;;
      --first-install)       SWAP_FIRST_INSTALL="$2"; shift 2 ;;
      --rbf-version)         SWAP_RBF_VERSION="$2"; shift 2 ;;
      --git-commit)          SWAP_GIT_COMMIT="$2"; shift 2 ;;
      --log-file)            SWAP_LOG_FILE="$2"; shift 2 ;;
      *) printf 'error: rbf-swap.sh: unknown option: %s\n\n' "$1" >&2; rbf_swap_usage >&2; return 2 ;;
    esac
  done

  local key
  for key in SWAP_MODE SWAP_STAGED_APP SWAP_STAGING_ROOT SWAP_ROLLBACK_ROOT \
             SWAP_INSTALL_PATH SWAP_BUNDLE_ID SWAP_UPSTREAM_BUNDLE_ID \
             SWAP_UPSTREAM_PATH SWAP_FIRST_INSTALL SWAP_RBF_VERSION \
             SWAP_GIT_COMMIT SWAP_LOG_FILE; do
    if [[ -z "${!key}" ]]; then
      printf 'error: rbf-swap.sh: missing required argument for %s\n\n' "$key" >&2
      rbf_swap_usage >&2
      return 2
    fi
  done
  case "$SWAP_MODE" in inline|detached) ;; *)
    printf 'error: rbf-swap.sh: --mode must be inline or detached, got: %s\n' "$SWAP_MODE" >&2
    return 2 ;;
  esac

  SWAP_MIGRATE_SCRIPT="${SWAP_MIGRATE_SCRIPT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/migrate-rbf-state.sh}"

  # OWNERSHIP TRANSFER, in this order: trap first, claim second. The claim
  # (atomic mkdir — see rbf_swap_claim_path) tells the parent we own staging;
  # claiming before the trap exists would open a window where the parent has
  # stood down and we cannot clean. If the claim FAILS, the parent already
  # reclaimed ownership (our startup outlasted its wait) — we own nothing and
  # must exit without touching the app or the filesystem.
  trap rbf_swap_cleanup EXIT
  if [[ "$SWAP_MODE" == "detached" ]]; then
    # Belt to setsid's braces: the quit below tears down the PTY session we
    # came from; an ignored HUP costs nothing if setsid already isolated us.
    trap '' HUP
    printf '=== rbf-swap %s — rbf %s (%s), first_install=%s ===\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$SWAP_RBF_VERSION" "$SWAP_GIT_COMMIT" "$SWAP_FIRST_INSTALL"
  fi
  if ! mkdir "$(rbf_swap_claim_path "$SWAP_STAGING_ROOT")" 2>/dev/null; then
    trap - EXIT
    printf 'error: ownership of %s was already claimed — the installer reclaimed the handoff.\n' "$SWAP_STAGING_ROOT" >&2
    printf '       Exiting without touching the app or staging.\n' >&2
    return 1
  fi

  rbf_swap_quit_app "$SWAP_INSTALL_PATH" "$SWAP_BUNDLE_ID" || return 1

  rbf_swap_step "installing"
  rbf_swap_install "$SWAP_STAGED_APP" "$SWAP_INSTALL_PATH" "$SWAP_ROLLBACK_ROOT"

  rbf_swap_migrate "$SWAP_FIRST_INSTALL" "$SWAP_UPSTREAM_BUNDLE_ID"

  printf '\n✓ installed\n'
  printf '  %s\n' "$SWAP_INSTALL_PATH"
  printf '  rbf version  %s (%s)\n' "$SWAP_RBF_VERSION" "$SWAP_GIT_COMMIT"
  printf '  bundle id    %s\n' "$SWAP_BUNDLE_ID"
  printf '  state        %s\n' "$SWAP_MIGRATION_RESULT"
  printf '  upstream     %s — untouched\n' "$SWAP_UPSTREAM_PATH"

  if [[ "$SWAP_MODE" == "detached" ]]; then
    rbf_swap_relaunch "$SWAP_INSTALL_PATH" || true
    rbf_swap_notify "cmux RBF $SWAP_RBF_VERSION installed" \
      "Swap complete; the app has relaunched. Log: $SWAP_LOG_FILE"
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  rbf_swap_main "$@"
fi
