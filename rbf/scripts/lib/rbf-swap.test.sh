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

SANDBOX="${RBF_SWAP_TEST_SANDBOX:-$(mktemp -d "${TMPDIR:-/tmp}/rbf-swap-test.XXXXXX")}"
mkdir -p "$SANDBOX"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail + 1)); }

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

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
