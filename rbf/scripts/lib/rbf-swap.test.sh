#!/usr/bin/env bash
# rbf-swap.test.sh — drive the swap helper's routing, quit, swap, and
# ownership logic directly.
#
#   bash rbf/scripts/lib/rbf-swap.test.sh
#
# Like rbf-install-target.test.sh, this is the only honest route to most of
# these paths: the real entry point cannot be aimed at a fake app, and the
# refusal/rollback branches must never be reachable against the real
# /Applications. The seam functions in rbf-swap.sh (app_running, mv, sleep,
# notify, …) exist precisely so this file can simulate a stuck app, a failing
# rename, and a fake clock without touching anything real.
#
# Artifacts live under an external-tmp sandbox per repo policy; every case
# builds its own fixture dir and asserts on filesystem postconditions, not on
# exit codes alone.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rbf/scripts/lib/rbf-swap.sh
source "$LIB_DIR/rbf-swap.sh"

# shellcheck source=rbf/scripts/lib/rbf-testkit.sh
source "$LIB_DIR/rbf-testkit.sh"
# shellcheck source=rbf/scripts/lib/rbf-id-match.sh
source "$LIB_DIR/rbf-id-match.sh"
rbf_test_begin rbf-swap-test
SANDBOX="${RBF_SWAP_TEST_SANDBOX:-$RBF_TEST_SANDBOX}"
mkdir -p "$SANDBOX"

# --- routing ---------------------------------------------------------------
printf 'routing (rbf_swap_mode)\n'

got="$(CMUX_BUNDLE_ID="com.cmuxterm.app.rbf" rbf_swap_mode "com.cmuxterm.app.rbf")"
[[ "$got" == "detached" ]] && ok "hosted by the target -> detached" \
  || bad "hosted by the target" "want detached, got '$got'"

got="$(CMUX_BUNDLE_ID="com.cmuxterm.app" rbf_swap_mode "com.cmuxterm.app.rbf")"
[[ "$got" == "inline" ]] && ok "hosted by upstream cmux -> inline" \
  || bad "hosted by upstream cmux" "want inline, got '$got'"

# LIB_DIR rides the environment: the path contains an apostrophe (Tom's HDD),
# so interpolating it into a quoted -c string is exactly the quoting bug the
# repo's memories warn about.
got="$(env -u CMUX_BUNDLE_ID LIB_DIR="$LIB_DIR" bash -c 'source "$LIB_DIR/rbf-swap.sh"; rbf_swap_mode com.cmuxterm.app.rbf')"
[[ "$got" == "inline" ]] && ok "no CMUX_BUNDLE_ID (Terminal.app) -> inline" \
  || bad "no CMUX_BUNDLE_ID" "want inline, got '$got'"

# --- argument contract -----------------------------------------------------
printf '\nargument contract\n'

err="$(rbf_swap_main --mode inline 2>&1 >/dev/null)"; rc=$?
if [[ $rc -eq 2 && "$err" == *"missing required argument"* ]]; then
  ok "missing arguments refuse with exit 2 and name the gap"
else
  bad "missing arguments" "rc=$rc err=$err"
fi

err="$(rbf_swap_main --mode sideways 2>&1 >/dev/null)"; rc=$?
if [[ $rc -eq 2 ]]; then ok "unknown mode refuses"
else bad "unknown mode" "rc=$rc err=$err"; fi

# --- quit logic, driven through the seams ----------------------------------
# A fake clock: sleep advances FAKE_NOW; app_running consults a schedule.
printf '\nquit logic\n'

run_quit() {
  # $1 = mode, $2 = quit-at (seconds after which the app "quits"; -1 = never)
  FAKE_NOW=0
  QUIT_AT="$2"
  SWAP_MODE="$1"
  SWAP_LOG_FILE="$SANDBOX/quit.log"
  NOTIFICATIONS="$SANDBOX/notifications.$$"
  : > "$NOTIFICATIONS"
  rbf_swap_sleep() { FAKE_NOW=$((FAKE_NOW + ${1%.*})); }
  rbf_swap_app_running() { [[ "$QUIT_AT" -lt 0 || "$FAKE_NOW" -lt "$QUIT_AT" ]]; }
  rbf_swap_request_quit() { :; }
  rbf_swap_sigterm() { SIGTERM_SENT=1; }
  rbf_swap_post_notification() { printf '%s|%s\n' "$1" "$2" >> "$NOTIFICATIONS"; }
  SIGTERM_SENT=0
  rbf_swap_quit_app "/nonexistent/fixture.app" "com.example.fixture" 2>"$SANDBOX/quit.err"
}

if run_quit inline 3; then ok "inline: app quits within timeout -> success"
else bad "inline: app quits within timeout" "returned failure"; fi

if run_quit inline -1; then
  bad "inline: app never quits" "expected refusal, got success"
else
  if grep -q "Refusing to force-quit" "$SANDBOX/quit.err" && [[ $SIGTERM_SENT -eq 1 ]]; then
    ok "inline: stuck app -> SIGTERM then refusal naming the reason"
  else
    bad "inline: stuck app" "stderr or SIGTERM wrong: $(cat "$SANDBOX/quit.err")"
  fi
  if [[ ! -s "$NOTIFICATIONS" ]]; then ok "inline: no notifications posted"
  else bad "inline: no notifications" "got: $(cat "$NOTIFICATIONS")"; fi
fi

if run_quit detached -1; then
  bad "detached: app never quits" "expected refusal, got success"
else
  if grep -q "waiting on a dialog" "$NOTIFICATIONS" && grep -q "install aborted" "$NOTIFICATIONS"; then
    ok "detached: stuck app -> dialog nudge then abort notification"
  else
    bad "detached: stuck app notifications" "got: $(cat "$NOTIFICATIONS")"
  fi
fi

if run_quit detached 30; then
  if grep -q "waiting on a dialog" "$NOTIFICATIONS"; then
    ok "detached: slow quit (30s) -> nudged at 10s, still succeeds"
  else
    bad "detached: slow quit nudge" "no dialog notification: $(cat "$NOTIFICATIONS")"
  fi
else
  bad "detached: slow quit (30s)" "expected success past the inline timeout"
fi

# --- the swap: park, rename, rollback --------------------------------------
printf '\nswap and rollback\n'

make_fixture() {
  # A staged app, an existing install, fresh roots. Prints the fixture root.
  local fx="$SANDBOX/fx.$RANDOM"
  mkdir -p "$fx/staging/cmux RBF.app/Contents" "$fx/apps/cmux RBF.app/Contents"
  printf 'new'  > "$fx/staging/cmux RBF.app/Contents/marker"
  printf 'old'  > "$fx/apps/cmux RBF.app/Contents/marker"
  printf '%s' "$fx"
}

# The twelve-flag contract, shaped to a fixture, in ONE place. Every end-to-end
# case below differs only in mode, seam overrides and assertions — which is
# exactly what the case should show. Repeating the flags per case buried that
# difference in sixteen identical lines and made a wrong-but-plausible flag
# edit invisible in a diff.
set_main_args() { # $1 = fixture root, $2 = mode
  MAIN_ARGS=(
    --mode "$2"
    --staged-app "$1/staging/cmux RBF.app"
    --staging-root "$1/staging"
    --rollback-root "$1/rollback"
    --install-path "$1/apps/cmux RBF.app"
    --bundle-id "com.example.fixture"
    --upstream-bundle-id "com.example.upstream"
    --upstream-path "/Applications/example.app"
    --first-install 0
    --rbf-version "0.0.0-test"
    --git-commit "cafef00d"
    --log-file "$1/log"
  )
}

# Every case that fakes a seam runs in its own subshell, so the fake dies with
# the case. Restoring by hand left the file readable only in order: a case
# inserted between a fake and its restore silently inherited the fake, and the
# failure would surface somewhere else entirely.
fx="$(make_fixture)"
if (
  SWAP_MODE=inline SWAP_LOG_FILE="$fx/log"
  rbf_swap_install "$fx/staging/cmux RBF.app" "$fx/apps/cmux RBF.app" "$fx/rollback"
); then
  if [[ "$(cat "$fx/apps/cmux RBF.app/Contents/marker")" == "new" && ! -e "$fx/rollback" ]]; then
    ok "swap installs the new bundle and removes the rollback dir"
  else
    bad "swap postconditions" "marker=$(cat "$fx/apps/cmux RBF.app/Contents/marker" 2>&1) rollback=$(ls "$fx/rollback" 2>&1)"
  fi
else
  bad "swap happy path" "rbf_swap_install failed"
fi

# Fail the SECOND rename (new app in), succeed the third (rollback): the
# previous install must come back.
fx="$(make_fixture)"
out="$(
  (
    SWAP_MODE=inline SWAP_LOG_FILE="$fx/log" MV_CALLS=0
    rbf_swap_mv() {
      MV_CALLS=$((MV_CALLS + 1))
      [[ $MV_CALLS -eq 2 ]] && return 1
      mv "$@"
    }
    rbf_swap_install "$fx/staging/cmux RBF.app" "$fx/apps/cmux RBF.app" "$fx/rollback"
  ) 2>&1
)"; rc=$?
if [[ $rc -ne 0 && "$(cat "$fx/apps/cmux RBF.app/Contents/marker" 2>/dev/null)" == "old" ]]; then
  ok "failed rename rolls the previous install back"
else
  bad "failed rename rollback" "rc=$rc marker=$(cat "$fx/apps/cmux RBF.app/Contents/marker" 2>&1) out=$out"
fi

# Fail renames 2 AND 3: /Applications has no app, and stderr must name the
# parked path the user cannot guess.
fx="$(make_fixture)"
out="$(
  (
    SWAP_MODE=inline SWAP_LOG_FILE="$fx/log" MV_CALLS=0
    rbf_swap_mv() {
      MV_CALLS=$((MV_CALLS + 1))
      [[ $MV_CALLS -ge 2 ]] && return 1
      mv "$@"
    }
    rbf_swap_install "$fx/staging/cmux RBF.app" "$fx/apps/cmux RBF.app" "$fx/rollback"
  ) 2>&1
)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"$fx/rollback/previous.app"* && -d "$fx/rollback/previous.app" ]]; then
  ok "double failure names the parked previous.app and leaves it intact"
else
  bad "double failure" "rc=$rc out=$out"
fi

# --- ownership: trap before claim, claim before quit ------------------------
printf '\nownership handoff (end-to-end inline, sandboxed)\n'

fx="$(make_fixture)"; set_main_args "$fx" inline
(
  source "$LIB_DIR/rbf-swap.sh"
  rbf_swap_app_running() { return 1; }   # not running: quit is a no-op
  SWAP_MIGRATE_SCRIPT="/usr/bin/true"
  rbf_swap_main "${MAIN_ARGS[@]}" > "$fx/stdout" 2>&1
)
rc=$?
if [[ $rc -eq 0 \
      && "$(cat "$fx/apps/cmux RBF.app/Contents/marker")" == "new" \
      && ! -d "$fx/staging" ]]; then
  ok "inline end-to-end: installs, cleans staging via its own trap, exit 0"
else
  bad "inline end-to-end" "rc=$rc staging=$(ls -d "$fx/staging" 2>&1) stdout=$(tail -3 "$fx/stdout" 2>&1)"
fi
if grep -q "✓ installed" "$fx/stdout" && grep -q "skipped (existing install)" "$fx/stdout"; then
  ok "inline end-to-end: summary matches the pre-split format"
else
  bad "inline summary" "$(cat "$fx/stdout")"
fi

# The claim must exist while main runs — that is what the parent polls for.
# Probe it from a seam the flow calls after the claim.
fx="$(make_fixture)"; set_main_args "$fx" inline
(
  source "$LIB_DIR/rbf-swap.sh"
  rbf_swap_app_running() {
    [[ -e "$fx/staging/.rbf-swap-claimed" ]] && : > "$fx/claim-was-present"
    return 1
  }
  SWAP_MIGRATE_SCRIPT="/usr/bin/true"
  rbf_swap_main "${MAIN_ARGS[@]}" >/dev/null 2>&1
)
if [[ -e "$fx/claim-was-present" ]]; then
  ok "ownership claim exists before the quit step (parent can poll it)"
else
  bad "claim ordering" "claim absent when the quit seam ran"
fi

# --- ownership election -----------------------------------------------------
printf '\nownership election (rbf_swap_wait_for_claim)\n'

fx="$SANDBOX/claim.$RANDOM"; mkdir -p "$fx/staging"
mkdir "$fx/staging/.rbf-swap-claimed"
if ( rbf_swap_sleep() { :; }; rbf_swap_wait_for_claim "$fx/staging" 1 ); then
  ok "claim already present -> acknowledged (0)"
else
  bad "claim already present" "returned reclaim"
fi

fx="$SANDBOX/claim.$RANDOM"; mkdir -p "$fx/staging"
if ( rbf_swap_sleep() { :; }; rbf_swap_wait_for_claim "$fx/staging" 1 ); then
  bad "no claim ever" "expected reclaim (1), got acknowledged"
else
  if [[ -d "$fx/staging/.rbf-swap-claimed" ]]; then
    ok "timeout -> parent reclaims; a later helper claim must now fail"
  else
    bad "timeout reclaim" "claim dir not created by the reclaiming parent"
  fi
fi

# The helper claims between the parent's last poll and its reclaim mkdir —
# the window the election exists to make safe. The fake clock creates the
# claim on its final tick.
fx="$SANDBOX/claim.$RANDOM"; mkdir -p "$fx/staging"
if (
  RACE_LEFT=3
  rbf_swap_sleep() {
    RACE_LEFT=$((RACE_LEFT - 1))
    [[ $RACE_LEFT -eq 0 ]] && mkdir "$fx/staging/.rbf-swap-claimed" 2>/dev/null
    :
  }
  rbf_swap_wait_for_claim "$fx/staging" 1
); then
  ok "helper claims in the race window -> acknowledged, not reclaimed"
else
  bad "race window" "parent reclaimed over a live helper claim"
fi

# A helper that finds the claim taken exits without touching the app.
fx="$(make_fixture)"; set_main_args "$fx" detached
mkdir "$fx/staging/.rbf-swap-claimed"
(
  source "$LIB_DIR/rbf-swap.sh"
  rbf_swap_app_running() { : > "$fx/app-was-touched"; return 1; }
  SWAP_MIGRATE_SCRIPT="/usr/bin/true"
  rbf_swap_main "${MAIN_ARGS[@]}" >/dev/null 2>&1
)
rc=$?
if [[ $rc -ne 0 && ! -e "$fx/app-was-touched" && -d "$fx/staging/cmux RBF.app" ]]; then
  ok "reclaimed helper exits untouched: no quit attempt, staging left to the owner"
else
  bad "reclaimed helper" "rc=$rc touched=$([[ -e "$fx/app-was-touched" ]] && echo y || echo n) staging=$(ls "$fx/staging" 2>&1)"
fi

# Abort path THROUGH MAIN deletes staging via the helper's own trap — the
# coverage the quit-unit tests cannot give (they bypass main and its trap).
fx="$(make_fixture)"; set_main_args "$fx" detached
(
  source "$LIB_DIR/rbf-swap.sh"
  rbf_swap_app_running() { return 0; }   # stuck forever
  rbf_swap_sleep() { :; }
  rbf_swap_request_quit() { :; }
  rbf_swap_sigterm() { :; }
  rbf_swap_post_notification() { :; }
  SWAP_MIGRATE_SCRIPT="/usr/bin/true"
  rbf_swap_main "${MAIN_ARGS[@]}" >/dev/null 2>&1
)
rc=$?
if [[ $rc -ne 0 && ! -d "$fx/staging" && "$(cat "$fx/apps/cmux RBF.app/Contents/marker")" == "old" ]]; then
  ok "stuck-quit abort through main: staging deleted by the helper's trap, install untouched"
else
  bad "stuck-quit abort through main" "rc=$rc staging=$(ls -d "$fx/staging" 2>&1) marker=$(cat "$fx/apps/cmux RBF.app/Contents/marker" 2>&1)"
fi

# --- detached terminal states ----------------------------------------------
printf '\ndetached end-to-end (sandboxed)\n'

fx="$(make_fixture)"; set_main_args "$fx" detached
(
  source "$LIB_DIR/rbf-swap.sh"
  rbf_swap_app_running() { return 1; }
  rbf_swap_relaunch() { : > "$fx/relaunched"; }
  rbf_swap_post_notification() { printf '%s|%s\n' "$1" "$2" >> "$fx/notifications"; }
  SWAP_MIGRATE_SCRIPT="/usr/bin/true"
  rbf_swap_main "${MAIN_ARGS[@]}" > "$fx/stdout" 2>&1
)
rc=$?
if [[ $rc -eq 0 && -e "$fx/relaunched" ]] && grep -q "installed" "$fx/notifications"; then
  ok "detached success: relaunches the app and posts the success notification"
else
  bad "detached success" "rc=$rc relaunched=$([[ -e "$fx/relaunched" ]] && echo y || echo n) notif=$(cat "$fx/notifications" 2>&1)"
fi
if grep -q "=== rbf-swap" "$fx/stdout"; then
  ok "detached run opens with the delimited log header"
else
  bad "detached log header" "$(head -1 "$fx/stdout")"
fi

# --- the parent's launch block ----------------------------------------------
# This block used to sit inline in install-rbf.sh, where nothing could reach
# it — it was the feature's weakest claim at release (verdict, 2026-08-04).
printf '\nparent launch block (rbf_swap_launch_detached)\n'

fx="$SANDBOX/launch.$RANDOM"; mkdir -p "$fx/staging"
if (
  rbf_swap_sleep() { :; }
  rbf_swap_spawn_daemon() { mkdir "$fx/staging/.rbf-swap-claimed"; }   # claims at once
  rbf_swap_launch_detached "$fx/staging" "$fx/log" 1 /bin/true
); then
  ok "helper claims immediately -> acknowledged (0)"
else
  bad "immediate claim" "returned reclaim"
fi

fx="$SANDBOX/launch.$RANDOM"; mkdir -p "$fx/staging"
if (
  TICKS=0
  rbf_swap_sleep() {   # claims on the 3rd poll — slow, but inside the timeout
    TICKS=$((TICKS + 1))
    [[ $TICKS -eq 3 ]] && mkdir "$fx/staging/.rbf-swap-claimed" 2>/dev/null
    :
  }
  rbf_swap_spawn_daemon() { :; }
  rbf_swap_launch_detached "$fx/staging" "$fx/log" 1 /bin/true
); then
  ok "helper claims late but within the timeout -> acknowledged"
else
  bad "late claim" "parent reclaimed over a helper still starting"
fi

fx="$SANDBOX/launch.$RANDOM"; mkdir -p "$fx/staging"
: > "$fx/staging/payload"
if (
  rbf_swap_sleep() { :; }
  rbf_swap_spawn_daemon() { :; }   # never starts
  rbf_swap_launch_detached "$fx/staging" "$fx/log" 1 /bin/true
); then
  bad "helper never claims" "expected reclaim (1), got acknowledged"
else
  if [[ -d "$fx/staging/.rbf-swap-claimed" && -e "$fx/staging/payload" ]]; then
    ok "helper never claims -> parent reclaims, and staging is still the parent's to delete"
  else
    bad "never-claims reclaim" "claim=$(ls -d "$fx/staging/.rbf-swap-claimed" 2>&1) payload=$(ls "$fx/staging/payload" 2>&1)"
  fi
fi

# The one property a fake cannot prove: a REAL daemon is in its OWN process
# group and outlives the shell that spawned it. The process-group check is what
# makes this test discriminate — a subshell exiting does not signal its
# children, so "it finished" alone is equally true of a plain `nohup ... &`,
# and a mutation stripping the double-fork/setsid went UNCAUGHT until this
# assertion was added (2026-08-04). Process-group isolation is exactly what
# makes the helper immune to a signal aimed at the dying app's group.
fx="$SANDBOX/launch.$RANDOM"; mkdir -p "$fx/staging"
cat > "$fx/helper.sh" <<HELPER
#!/bin/bash
mkdir "$fx/staging/.rbf-swap-claimed" 2>/dev/null
ps -o pgid= -p \$\$ | tr -d ' ' > "$fx/daemon-pgid"
sleep 2
printf 'outlived-my-parent\n' > "$fx/done"
HELPER
chmod +x "$fx/helper.sh"
spawner_pgid="$(ps -o pgid= -p $$ | tr -d ' ')"
(   # a subshell standing in for the parent: it spawns, then exits immediately
  rbf_swap_spawn_daemon "$fx/log" /bin/bash "$fx/helper.sh"
)
waited=0
while [[ ! -e "$fx/done" && $waited -lt 100 ]]; do sleep 0.1; waited=$((waited + 1)); done
if [[ -e "$fx/done" && "$(cat "$fx/done")" == "outlived-my-parent" ]]; then
  ok "real daemon outlives the shell that spawned it"
else
  bad "daemon survival" "no output after $((waited / 10))s; macOS has no setsid(1) — check the python double-fork"
fi
daemon_pgid="$(cat "$fx/daemon-pgid" 2>/dev/null)"
if [[ -n "$daemon_pgid" && "$daemon_pgid" != "$spawner_pgid" ]]; then
  ok "real daemon runs in its own process group (setsid(2) took effect)"
else
  bad "daemon process group" "daemon pgid='$daemon_pgid' equals the spawner's ('$spawner_pgid') — it would die with the app's group"
fi

# --- relaunch environment --------------------------------------------------
printf '\nrelaunch environment (real seam, recorder instead of open)\n'

# The install usually runs from an agent inside cmux or herdr. A relaunch that
# passes that environment on gives the new app — and every tab it opens — the
# agent's CMUX_* and HERDR_* variables (2026-09-17: every tab then refused herdr
# as "nested", and restore started duplicate agents).
fx="$SANDBOX/relaunch-env"; mkdir -p "$fx/bin"
cat > "$fx/bin/open" <<'RECORDER'
#!/bin/bash
env > "${0%/bin/open}/env"
printf '%s\n' "$@" > "${0%/bin/open}/args"
RECORDER
chmod +x "$fx/bin/open"
# PATH reaches the recorder for a bare `open`; RBF_SWAP_OPEN for the fixed seam.
env HERDR_ENV=1 HERDR_PANE_ID=w1:p1 HERDR_SOCKET_PATH=/tmp/herdr.sock \
  CMUX_SURFACE_ID=0000 CMUX_SOCKET_PATH=/tmp/cmux.sock CMUX_SOCKET_CAPABILITY=secret \
  PATH="$fx/bin:$PATH" RBF_SWAP_OPEN="$fx/bin/open" LIB_DIR="$LIB_DIR" \
  bash -c 'source "$LIB_DIR/rbf-swap.sh"; rbf_swap_relaunch "/Applications/Fake RBF.app"'
leaked="$(grep -E '^(HERDR|CMUX)_' "$fx/env" 2>/dev/null | cut -d= -f1 | tr '\n' ' ')"
if [[ -s "$fx/env" && -z "$leaked" ]] && grep -qx "HOME=$HOME" "$fx/env" \
  && [[ "$(cat "$fx/args")" == "/Applications/Fake RBF.app" ]]; then
  ok "relaunch hands the app a Dock-like environment: no CMUX_*/HERDR_*, HOME kept, app path passed"
else
  bad "relaunch environment" "leaked: ${leaked:-none}; env recorded: $([[ -s "$fx/env" ]] && echo y || echo n); args: $(cat "$fx/args" 2>&1)"
fi

# --- the keep branch (#cm-142.2) ---------------------------------------------
# `--keep-previous-root <folder>` keeps the replaced app and everything it owns
# under its bundle id, after the quit and before anything under the install
# volume moves. Every case runs in its own subshell with HOME pointing at a
# fixture and a fake `defaults`, so nothing real is read or written.
printf '\nkeep branch (--keep-previous-root)\n'

KID="com.example.keeptest"
KNAME="cmux RBF (fx)"

# A world: HOME, an installed old app, a staged new one, the state the old app
# wrote under KID, a config file, and a fake defaults domain. $1 = with
# neighbours (nested ids, another app, a cache, an unknown kind) yes|no.
keep_world() {
  local w; w="$(rbf_test_world keep)"
  rbf_test_make_app "$w/apps/$KNAME.app" "$KID" 0.34.2 acdda8cd1 old
  mkdir -p "$w/staging"
  rbf_test_make_app "$w/staging/$KNAME.app" "$KID" 0.35.0 a1b2c3d4e new
  rbf_test_make_state "$w/home" "$KID" one
  [[ "${1:-no}" == yes ]] && rbf_test_make_neighbours "$w/home" "$KID"
  printf '{"shortcuts":1}' > "$w/home/.config/cmux/cmux.json"
  rbf_test_fake_defaults "$w/bin" "$w/defaults-store"
  printf 'defaults-one' > "$w/defaults-store/$KID.plist"
  printf '%s' "$w"
}

# The argument contract shaped to a keep world; $3 (optional) adds the keep root.
keep_args() { # <world> <mode> [keep root]
  MAIN_ARGS=(
    --mode "$2"
    --staged-app "$1/staging/$KNAME.app"
    --staging-root "$1/staging"
    --rollback-root "$1/rollback"
    --install-path "$1/apps/$KNAME.app"
    --bundle-id "$KID"
    --app-name "$KNAME"
    --upstream-bundle-id "com.example.upstream"
    --upstream-path "/Applications/example.app"
    --first-install 0
    --rbf-version "0.0.0-test"
    --git-commit "cafef00d"
    --log-file "$1/log"
  )
  [[ -n "${3:-}" ]] && MAIN_ARGS+=(--keep-previous-root "$3")
  return 0
}

# Run rbf_swap_main in a subshell against a world. Extra seam overrides come in
# as the body of $SEAMS, a string of shell evaluated after sourcing. Output goes
# to $1/stdout and $1/stderr; the return status is main's.
run_keep_main() { # <world>  (MAIN_ARGS and SEAMS already set)
  (
    export HOME="$1/home" RBF_DEFAULTS_BIN="$1/bin/defaults"
    # shellcheck disable=SC1091
    source "$LIB_DIR/rbf-swap.sh"
    rbf_swap_app_running() { return 1; }
    rbf_swap_post_notification() { printf '%s|%s\n' "$1" "$2" >> "$W_NOTIFY"; }
    rbf_swap_relaunch() { printf '%s\n' "$1" >> "$W_RELAUNCH"; }
    SWAP_MIGRATE_SCRIPT="/usr/bin/true"
    W_NOTIFY="$1/notifications"; W_RELAUNCH="$1/relaunched"
    eval "${SEAMS:-:}"
    rbf_swap_main "${MAIN_ARGS[@]}" > "$1/stdout" 2> "$1/stderr"
  )
}

KEEP_TS="pre-install-20261124-101503"

# --- control: no keep asked, nothing about keeping appears --------------------
W="$(keep_world no)"; keep_args "$W" inline; SEAMS=""
run_keep_main "$W"; rc=$?
want="⋯ quitting a running $KNAME
⋯ installing

✓ installed
  $W/apps/$KNAME.app
  rbf version  0.0.0-test (cafef00d)
  bundle id    $KID
  state        skipped (existing install)
  upstream     /Applications/example.app — untouched"
if [[ $rc -eq 0 && "$(cat "$W/stdout")" == "$want" && ! -e "$W/home/Library/Application Support/cmux/migration-backups" \
      && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == new && ! -e "$W/rollback" ]]; then
  ok "no keep asked: output is the existing format, no keep folder, rollback folder removed"
else
  bad "no keep asked" "rc=$rc stdout: $(diff <(printf '%s\n' "$want") "$W/stdout")"
fi

# --- the keep, inline, exact log (render 01) -----------------------------------
W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" inline "$KEEP"; SEAMS=""
before="$(rbf_test_listing "$W/home/Library" | grep -v migration-backups)"
run_keep_main "$W"; rc=$?
after="$(rbf_test_listing "$W/home/Library" | grep -v migration-backups)"
want="⋯ quitting a running $KNAME
⋯ keeping its state under $KID: 15 entries
⋯ installing
⋯ keeping the previous app with its state

✓ installed
  $W/apps/$KNAME.app
  rbf version  0.0.0-test (cafef00d)
  bundle id    $KID
  state        skipped (existing install)
  upstream     /Applications/example.app — untouched
  kept         0.34.2 (acdda8cd1), the app it replaced, with its state, in:
$KEEP"
if [[ "$(cat "$W/stdout")" == "$want" ]]; then
  ok "the install log matches render 01: quit, keep (15 entries), installing, keep the app, ✓ installed with the kept row and the folder whole"
else
  bad "install log (render 01)" "rc=$rc $(diff <(printf '%s\n' "$want") "$W/stdout")"
fi
if [[ $rc -eq 0 && "$(cat "$KEEP/$KNAME.app/Contents/Resources/marker" 2>&1)" == old \
      && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == new && ! -e "$W/rollback" ]]; then
  ok "previous bundle is at <keep>/<name>.app, the new one is installed, the rollback folder is gone"
else
  bad "keep postconditions" "rc=$rc kept=$(cat "$KEEP/$KNAME.app/Contents/Resources/marker" 2>&1) installed=$(cat "$W/apps/$KNAME.app/Contents/Resources/marker" 2>&1) rollback=$(ls -d "$W/rollback" 2>&1)"
fi
if [[ $rc -eq 0 && -d "$KEEP" && "$before" == "$after" ]]; then
  ok "the keep only reads the live state: ~/Library is byte-identical before and after"
else
  bad "live state changed by the keep" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
fi

# kept.env: the first file, parsed not sourced; values with spaces and parens.
if [[ -f "$KEEP/kept.env" ]] \
   && grep -qxF "BUNDLE_ID=$KID" "$KEEP/kept.env" \
   && grep -qxF "INSTALL_PATH=$W/apps/$KNAME.app" "$KEEP/kept.env" \
   && grep -qxF "APP_NAME=$KNAME" "$KEEP/kept.env" \
   && grep -qxF "VERSION=0.34.2" "$KEEP/kept.env" \
   && grep -qxF "COMMIT=acdda8cd1" "$KEEP/kept.env" \
   && grep -qE '^DATE=[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' "$KEEP/kept.env"; then
  ok "kept.env records bundle id, install path, app name, version, commit and date (spaces and parens intact)"
else
  bad "kept.env" "$(cat "$KEEP/kept.env" 2>&1)"
fi

# The folder's layout: defaults.plist, the mirrored Library/, config-cmux/.
lib_want="Application Support/cmux/$KID
Application Support/cmux/agent-journal-$KID.sqlite3
Application Support/cmux/agent-journal-$KID.sqlite3-shm
Application Support/cmux/agent-journal-$KID.sqlite3-wal
Application Support/cmux/closed-item-history-$KID.json
Application Support/cmux/notification-feed-history-$KID.json
Application Support/cmux/restart-command-summaries-$KID.json
Application Support/cmux/restart-commands-state-$KID.json
Application Support/cmux/session-$KID.json
Application Support/cmux/session-$KID-previous.json
Application Support/$KID
WebKit/$KID
HTTPStorages/$KID
HTTPStorages/$KID.binarycookies"
lib_got="$(rbf_id_library_entries "$KID" "$KEEP/Library")"
if [[ "$lib_got" == "$lib_want" && "$(cat "$KEEP/Library/WebKit/$KID/marker")" == one \
      && "$(cat "$KEEP/Library/Application Support/cmux/session-$KID.json")" == one ]]; then
  ok "Library/ mirrors ~/Library: every exact-id entry at the same relative path, contents intact"
else
  bad "Library mirror" "$(diff <(printf '%s\n' "$lib_want") <(printf '%s\n' "$lib_got"))"
fi
if [[ "$(cat "$KEEP/defaults.plist" 2>&1)" == defaults-one ]]; then
  ok "defaults.plist is the defaults domain, exported after the quit"
else
  bad "defaults.plist" "$(cat "$KEEP/defaults.plist" 2>&1)"
fi
if cmp -s "$KEEP/config-cmux/cmux.json" "$W/home/.config/cmux/cmux.json"; then
  ok "config-cmux/ holds a copy of ~/.config/cmux (for reference), same bytes"
else
  bad "config-cmux" "$(ls -R "$KEEP/config-cmux" 2>&1)"
fi
if [[ -z "$(ls -d "$KEEP"/Library/Caches* 2>/dev/null)" ]]; then
  ok "caches are not kept"
else
  bad "caches kept" "$(ls "$KEEP/Library")"
fi

# --- exact id: the nested pair and neighbours ----------------------------------
W="$(keep_world yes)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" inline "$KEEP"; SEAMS=""
before="$(rbf_test_listing "$W/home/Library" | grep -v migration-backups)"
run_keep_main "$W"; rc=$?
after="$(rbf_test_listing "$W/home/Library" | grep -v migration-backups)"
kept_names="$(cd "$KEEP/Library" && find . -type f -o -type d | LC_ALL=C sort | tr '\n' ' ')"
if [[ $rc -eq 0 && "$kept_names" != *docktileplugin* && "$kept_names" != *"session-com.example.other"* \
      && "$kept_names" != *Caches* && "$kept_names" != *".bak"* && "$kept_names" != *control* && "$kept_names" != *history_* \
      && "$(cat "$KEEP/Library/WebKit/$KID/marker" 2>&1)" == one ]]; then
  ok "a fixture with a nested-id pair keeps only the exact id's entries"
else
  bad "nested-id pair kept" "rc=$rc kept: $kept_names"
fi
if [[ $rc -eq 0 && -d "$KEEP" && "$before" == "$after" ]]; then
  ok "the nested pair, another app's file, the cache and the unknown kind are all still live, untouched"
else
  bad "neighbours touched" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
fi
want_unknown="  not kept, unknown kind: agent-journal-$KID.control.sqlite3
  not kept, unknown kind: $KID.docktileplugin
  not kept, unknown kind: history_$KID.json
  not kept, unknown kind: session-$KID.bak
  not kept, unknown kind: session-$KID.docktileplugin.json"
got_unknown="$(sed -n 3,7p "$W/stdout")"
if [[ "$got_unknown" == "$want_unknown" && "$(sed -n 8p "$W/stdout")" == "⋯ installing" ]]; then
  ok "each unknown kind is logged under the keep step, once, and left where it is (render 03)"
else
  bad "unknown kinds logged" "got: $(sed -n 1,8p "$W/stdout")"
fi
if [[ "$(sed -n 2p "$W/stdout")" == "⋯ keeping its state under $KID: 15 entries" ]]; then
  ok "unknown kinds are not counted among the kept entries"
else
  bad "entry count with unknown kinds" "$(sed -n 2p "$W/stdout")"
fi

# --- the folder is made only after the quit ------------------------------------
W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" inline "$KEEP"
SEAMS='QC=0
rbf_swap_sleep() { :; }
rbf_swap_app_running() { if [[ $QC -lt 2 ]]; then QC=$((QC + 1)); [[ -e "$KEEP" ]] && : > "$W/folder-while-running"; return 0; fi; return 1; }
rbf_swap_request_quit() { [[ -e "$KEEP" ]] && : > "$W/folder-at-quit-request"; return 0; }'
run_keep_main "$W"; rc=$?
if [[ $rc -eq 0 && ! -e "$W/folder-at-quit-request" && ! -e "$W/folder-while-running" && -d "$KEEP" ]]; then
  ok "the keep folder is made only after the quit: absent while the app runs and when the quit is requested, present after"
else
  bad "folder made after the quit" "rc=$rc at-request=$([[ -e "$W/folder-at-quit-request" ]] && echo yes || echo no) while-running=$([[ -e "$W/folder-while-running" ]] && echo yes || echo no) present=$([[ -d "$KEEP" ]] && echo yes || echo no)"
fi

# --- a refused quit makes no folder, not even the parent -----------------------
W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" detached "$KEEP"
SEAMS='rbf_swap_app_running() { return 0; }
rbf_swap_sleep() { :; }
rbf_swap_request_quit() { :; }
rbf_swap_sigterm() { :; }'
run_keep_main "$W"; rc=$?
if [[ $rc -ne 0 && ! -e "$KEEP" && ! -e "$W/home/Library/Application Support/cmux/migration-backups" \
      && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == old ]] && grep -q "Refusing to force-quit" "$W/stderr"; then
  ok "a refused quit makes no keep folder, and the installed app is untouched"
else
  bad "refused quit" "rc=$rc keep=$(ls -d "$KEEP" 2>&1) backups=$(ls "$W/home/Library/Application Support/cmux" 2>&1)"
fi

# --- a failing save: nothing swapped, no folder, old app relaunched ------------
W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" detached "$KEEP"
SEAMS='MV_CALLS=0
rbf_swap_mv() { MV_CALLS=$((MV_CALLS + 1)); : > "'"$W"'/mv-called"; mv "$@"; }
rbf_keep_ditto() { case "$2" in *"/Library/WebKit/"*) echo "ditto: boom" >&2; return 1 ;; esac; ditto "$@"; }'
run_keep_main "$W"; rc=$?
if [[ $rc -ne 0 && ! -e "$KEEP" && ! -e "$W/mv-called" && ! -e "$W/rollback" \
      && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == old ]] && grep -q "boom" "$W/stderr"; then
  ok "a failing save removes the keep folder and renames nothing: the installed bundle is still the old one"
else
  bad "failing save" "rc=$rc keep=$(ls -d "$KEEP" 2>&1) mv=$([[ -e "$W/mv-called" ]] && echo called || echo no) installed=$(cat "$W/apps/$KNAME.app/Contents/Resources/marker" 2>&1)"
fi
if [[ "$(cat "$W/relaunched" 2>&1)" == "$W/apps/$KNAME.app" ]] \
   && grep -q "install failed|" "$W/notifications" && grep -q "did not happen" "$W/notifications" \
   && grep -q "boom" "$W/notifications" && grep -q "^error: " "$W/stderr"; then
  ok "failed save, detached: the old app is relaunched, the notification says the install did not happen and why"
else
  bad "failed save reporting" "relaunch=$(cat "$W/relaunched" 2>&1) notify=$(cat "$W/notifications" 2>&1) stderr=$(cat "$W/stderr")"
fi

# ditto exits 0 when it skips one unreadable file among others, so the keep must
# treat its message as a failure (measured 2026-11-23); a keep that skipped a file
# and carried on is the failure this slice exists to prevent.
if [[ "$(id -u)" == 0 ]]; then
  skipped "an unreadable file among others fails the save" "running as root: chmod 000 would not stop ditto"
else
  W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
  keep_args "$W" inline "$KEEP"; SEAMS=""
  # the unreadable file sits one folder down, after a readable one: the shape
  # (measured) in which ditto reports Permission denied and still exits 0
  mkdir -p "$W/home/Library/WebKit/$KID/sub"
  printf 'x' > "$W/home/Library/WebKit/$KID/sub/other-file"; chmod 000 "$W/home/Library/WebKit/$KID/sub/other-file"
  run_keep_main "$W"; rc=$?
  chmod 644 "$W/home/Library/WebKit/$KID/sub/other-file"
  if [[ $rc -ne 0 && ! -e "$KEEP" && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == old && ! -e "$W/rollback" ]] \
     && grep -q "Permission denied" "$W/stderr"; then
    ok "an unreadable file among readable ones fails the save (real ditto exits 0 there): no folder, old app still installed"
  else
    bad "unreadable file skipped by ditto" "rc=$rc keep=$(ls -d "$KEEP" 2>&1) stderr=$(cat "$W/stderr")"
  fi
fi

# the defaults export failing is a failing save too
W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" inline "$KEEP"
SEAMS='RBF_DEFAULTS_BIN=/usr/bin/false'
run_keep_main "$W"; rc=$?
if [[ $rc -ne 0 && ! -e "$KEEP" && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == old && ! -e "$W/rollback" ]] \
   && grep -qi "defaults" "$W/stderr"; then
  ok "a failing defaults export fails the save the same way: no folder, old app still installed"
else
  bad "failing defaults export" "rc=$rc keep=$(ls -d "$KEEP" 2>&1)"
fi

# --- a failing swap that rolls back removes the keep folder ---------------------
W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" detached "$KEEP"
SEAMS='MV_CALLS=0
rbf_swap_mv() { MV_CALLS=$((MV_CALLS + 1)); [[ $MV_CALLS -eq 2 ]] && return 1; mv "$@"; }'
run_keep_main "$W"; rc=$?
if [[ $rc -ne 0 && ! -e "$KEEP" && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == old ]] \
   && grep -q "rolled back to the previous install" "$W/stderr" && [[ "$(cat "$W/relaunched" 2>&1)" == "$W/apps/$KNAME.app" ]]; then
  ok "a failing swap that rolls back removes the keep folder and leaves the old app installed"
else
  bad "failing swap rollback" "rc=$rc keep=$(ls -d "$KEEP" 2>&1) installed=$(cat "$W/apps/$KNAME.app/Contents/Resources/marker" 2>&1)"
fi

W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" inline "$KEEP"
SEAMS='MV_CALLS=0
rbf_swap_mv() { MV_CALLS=$((MV_CALLS + 1)); [[ $MV_CALLS -ge 2 ]] && return 1; mv "$@"; }'
run_keep_main "$W"; rc=$?
if [[ $rc -ne 0 && ! -e "$KEEP" && -d "$W/rollback/previous.app" ]] && grep -qF "$W/rollback/previous.app" "$W/stderr"; then
  ok "rollback also failing: the keep folder is removed too, and previous.app is named"
else
  bad "double failure with keep" "rc=$rc keep=$(ls -d "$KEEP" 2>&1) stderr=$(cat "$W/stderr")"
fi

# the same two failures through rbf_swap_install alone (no main, so no EXIT trap):
# rbf_swap_die itself must remove the keep folder this run made
W="$(keep_world no)"; KEEP="$W/keepdir/$KEEP_TS"
out="$(
  (
    SWAP_MODE=inline SWAP_LOG_FILE="$W/log" SWAP_KEEP_ROOT="$KEEP" SWAP_KEEP_MADE=1 MV_CALLS=0
    mkdir -p "$KEEP"; printf x > "$KEEP/kept.env"
    rbf_swap_mv() { MV_CALLS=$((MV_CALLS + 1)); [[ $MV_CALLS -eq 2 ]] && return 1; mv "$@"; }
    rbf_swap_install "$W/staging/$KNAME.app" "$W/apps/$KNAME.app" "$W/rollback"
  ) 2>&1
)"; rc=$?
if [[ $rc -ne 0 && ! -e "$KEEP" && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == old ]]; then
  ok "rbf_swap_die removes the keep folder its run made (checked through rbf_swap_install alone, with no EXIT trap to do it)"
else
  bad "die drops the keep folder" "rc=$rc keep=$(ls -d "$KEEP" 2>&1) out=$out"
fi
W="$(keep_world no)"; KEEP="$W/keepdir/$KEEP_TS"
( SWAP_MODE=inline SWAP_LOG_FILE="$W/log" SWAP_KEEP_ROOT="$KEEP" SWAP_KEEP_MADE=0; mkdir -p "$KEEP"
  rbf_swap_install "$W/staging/$KNAME.app" "$W/apps/$KNAME.app" "$W/rollback" ) >/dev/null 2>&1; rc=$?
if [[ $rc -eq 0 && -d "$KEEP" && -d "$KEEP/$KNAME.app" ]]; then
  ok "a keep folder this run did not make is never removed, and a finished swap keeps it (the old app moved in)"
else
  bad "finished swap keeps the folder" "rc=$rc keep=$(ls "$KEEP" 2>&1)"
fi

# --- a failing move of the old app into the folder ------------------------------
W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" detached "$KEEP"
SEAMS='MV_CALLS=0
rbf_swap_mv() { MV_CALLS=$((MV_CALLS + 1)); [[ $MV_CALLS -eq 3 ]] && return 1; mv "$@"; }'
run_keep_main "$W"; rc=$?
if [[ "$(cat "$W/rollback/previous.app/Contents/Resources/marker" 2>&1)" == old \
      && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == new && ! -e "$KEEP/$KNAME.app" ]]; then
  ok "a failing move of the old app into the folder leaves it in the rollback folder; the new app stays installed; the old app is never deleted"
else
  bad "failing move into the folder" "rc=$rc rollback=$(ls "$W/rollback" 2>&1) installed=$(cat "$W/apps/$KNAME.app/Contents/Resources/marker" 2>&1)"
fi
if grep -qF "$W/rollback/previous.app" "$W/stderr" "$W/stdout" && grep -qF "$W/rollback/previous.app" "$W/notifications" \
   && [[ -f "$KEEP/kept.env" ]] && grep -qF "as \"$KNAME.app\" before a restore takes it" "$W/stdout"; then
  ok "...and the log and the notification name that path; the kept state stays"
else
  bad "failing move reporting" "stderr=$(cat "$W/stderr") stdout=$(tail -4 "$W/stdout") notify=$(cat "$W/notifications" 2>&1)"
fi

# --- the notification (render 02), detached success -----------------------------
W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" detached "$KEEP"; SEAMS=""
run_keep_main "$W"; rc=$?
want_note="$KNAME 0.0.0-test installed|Kept the previous app: $KEEP_TS. Swap complete; the app has relaunched. Log: $W/log"
if [[ $rc -eq 0 && "$(cat "$W/notifications" 2>&1)" == "$want_note" && "$(cat "$W/relaunched")" == "$W/apps/$KNAME.app" ]]; then
  ok "the success notification starts 'Kept the previous app: <folder name>.' (render 02) and the app relaunches"
else
  bad "notification (render 02)" "rc=$rc got: $(cat "$W/notifications" 2>&1)"
fi
if head -1 "$W/stdout" | grep -q '^=== rbf-swap '; then
  ok "detached keep run still opens with the delimited log header"
else
  bad "detached header" "$(head -2 "$W/stdout")"
fi

# --- keep asked, nothing installed yet -------------------------------------------
W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
command rm -rf "$W/apps/$KNAME.app"
keep_args "$W" inline "$KEEP"; SEAMS=""
run_keep_main "$W"; rc=$?
if [[ $rc -eq 0 && ! -e "$KEEP" && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == new ]] \
   && ! grep -q '  kept  ' "$W/stdout"; then
  ok "keep asked on a machine with no app installed: no folder, no kept row, the install goes on"
else
  bad "keep with nothing installed" "rc=$rc keep=$(ls -d "$KEEP" 2>&1) stdout=$(cat "$W/stdout")"
fi

# --- argument contract: the keep root must be absolute ---------------------------
W="$(keep_world no)"; keep_args "$W" inline "relative/pre-install-1"; SEAMS=""
run_keep_main "$W"; rc=$?
if [[ $rc -eq 2 && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == old ]] && grep -q "keep-previous-root must be an absolute path" "$W/stderr"; then
  ok "a relative --keep-previous-root is refused with exit 2, app untouched"
else
  bad "relative keep root" "rc=$rc stderr=$(cat "$W/stderr")"
fi

# --- RBF_BUILD_ONLY=1: the swap step refuses to start (stop two) ------------------
W="$(keep_world no)"; KEEP="$W/home/Library/Application Support/cmux/migration-backups/$KID/$KEEP_TS"
keep_args "$W" detached "$KEEP"
SEAMS='export RBF_BUILD_ONLY=1
rbf_swap_app_running() { : > "'"$W"'/quit-seam-called"; return 1; }
rbf_swap_request_quit() { : > "'"$W"'/quit-seam-called"; }
rbf_swap_sigterm() { : > "'"$W"'/quit-seam-called"; }'
run_keep_main "$W"; rc=$?
if [[ $rc -ne 0 && ! -e "$W/quit-seam-called" && ! -e "$KEEP" && ! -e "$W/staging/.rbf-swap-claimed" \
      && -d "$W/staging/$KNAME.app" && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == old ]] \
   && grep -q "RBF_BUILD_ONLY" "$W/stderr"; then
  ok "RBF_BUILD_ONLY=1: rbf_swap_main returns non-zero and says why; the installed app is unchanged, the quit seam never ran, nothing was claimed"
else
  bad "RBF_BUILD_ONLY refusal" "rc=$rc quit-seam=$([[ -e "$W/quit-seam-called" ]] && echo called || echo no) claim=$([[ -e "$W/staging/.rbf-swap-claimed" ]] && echo yes || echo no) stderr=$(cat "$W/stderr")"
fi

# without RBF_BUILD_ONLY the same arguments run (the control for the refusal)
W="$(keep_world no)"; keep_args "$W" inline; SEAMS='export RBF_BUILD_ONLY=0'
run_keep_main "$W"; rc=$?
[[ $rc -eq 0 && "$(cat "$W/apps/$KNAME.app/Contents/Resources/marker")" == new ]] \
  && ok "RBF_BUILD_ONLY=0 does not refuse" || bad "RBF_BUILD_ONLY control" "rc=$rc"

# --- rbf_keep_install_root: the one decision install-rbf.sh reads ------------------
printf '\nrbf_keep_install_root\n'
got="$(HOME=/h env -u RBF_KEEP_PREVIOUS bash -c 'source "$1"; rbf_keep_install_root com.x.y' _ "$LIB_DIR/rbf-keep-state.sh")"
[[ -z "$got" ]] && ok "RBF_KEEP_PREVIOUS unset: no keep root" || bad "keep root unset" "got '$got'"
got="$(HOME=/h RBF_KEEP_PREVIOUS=0 bash -c 'source "$1"; rbf_keep_install_root com.x.y' _ "$LIB_DIR/rbf-keep-state.sh")"
[[ -z "$got" ]] && ok "RBF_KEEP_PREVIOUS=0: no keep root" || bad "keep root 0" "got '$got'"
got="$(HOME=/h RBF_KEEP_PREVIOUS=1 bash -c 'source "$1"; rbf_keep_install_root com.x.y' _ "$LIB_DIR/rbf-keep-state.sh")"
if [[ "$got" =~ ^/h/Library/Application\ Support/cmux/migration-backups/com\.x\.y/pre-install-[0-9]{8}-[0-9]{6}$ ]]; then
  ok "RBF_KEEP_PREVIOUS=1: ~/Library/Application Support/cmux/migration-backups/<id>/pre-install-<YYYYMMDD-HHMMSS>"
else
  bad "keep root shape" "got '$got'"
fi
HOME=/h RBF_KEEP_PREVIOUS=yes bash -c 'source "$1"; rbf_keep_install_root com.x.y' _ "$LIB_DIR/rbf-keep-state.sh" >/dev/null 2>&1; rc=$?
[[ $rc -ne 0 ]] && ok "any other RBF_KEEP_PREVIOUS value is refused, not read as no" || bad "keep root junk value" "rc=$rc"

rbf_test_finish
