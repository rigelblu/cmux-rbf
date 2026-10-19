#!/usr/bin/env bash
# rbf-procs.test.sh — prove rbf_app_pids matches an app by its executable and
# never by a process that only mentions the app path in its argv.
#
#   bash rbf/scripts/lib/rbf-procs.test.sh
#
# Runs real processes: a copy of /bin/sleep inside a fake app bundle (the
# match), and a bash whose argv names that bundle (the decoy — the shape of an
# agent whose prompt holds the path). A unique id keeps both clear of any real
# cmux app.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rbf/scripts/lib/rbf-procs.sh
source "$LIB_DIR/rbf-procs.sh"
# shellcheck source=rbf/scripts/lib/rbf-swap.sh
source "$LIB_DIR/rbf-swap.sh"

# pwd -P: lsof reports the resolved path, and $TMPDIR sits behind /var -> /private/var.
SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rbf-procs-test.XXXXXX")" && pwd -P)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]}"; do pkill -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail + 1)); }

ID="t$$"
# A dogfood-shaped name: a space and regex characters, like "cmux RBF (dogfood).app".
APP="$SANDBOX/cmux DEV ($ID).app"
EXE="$APP/Contents/MacOS/cmux DEV"
mkdir -p "$APP/Contents/MacOS"
cp /bin/sleep "$EXE"
# A copied platform binary is SIGKILLed at launch; an ad-hoc signature lets it run.
codesign -s - -f "$EXE" 2>/dev/null

PAT="$(rbf_swap_process_pattern "$APP")"

# --- decoy only ---------------------------------------------------------------
printf 'decoy: argv names the app, executable is bash\n'
bash -c 'sleep 30; :' decoy "$EXE --token=SECRET" &
PIDS+=($!)
sleep 0.3

pgrep -f -- "$PAT" >/dev/null 2>&1 && ok "pgrep -f alone matches the decoy (the bug this guards)" \
  || bad "decoy setup" "pgrep -f should see the decoy's argv; the test proves nothing without it"

got="$(rbf_app_pids "$PAT")"
[[ -z "$got" ]] && ok "rbf_app_pids ignores the decoy" \
  || bad "rbf_app_pids ignores the decoy" "got: $got"
rbf_app_running "$PAT" && bad "rbf_app_running ignores the decoy" "said running" \
  || ok "rbf_app_running ignores the decoy"

# --- the real executable ------------------------------------------------------
printf 'match: the executable is inside the app\n'
"$EXE" 30 &
real=$!
PIDS+=("$real")
sleep 0.3

got="$(rbf_app_pids "$PAT")"
[[ "$got" == "$real $EXE" ]] && ok "rbf_app_pids returns exactly the app's pid and executable" \
  || bad "rbf_app_pids finds the app" "want '$real $EXE', got '$got'"
[[ "$got" != *SECRET* ]] && ok "output carries no argv" \
  || bad "output carries no argv" "got: $got"
rbf_app_running "$PAT" && ok "rbf_app_running sees the app" \
  || bad "rbf_app_running sees the app" "said not running"

# --- a big app's lsof output, under dev.sh's shell options ------------------
# A Debug cmux maps hundreds of dylibs: lsof printed 475,729 bytes for one
# test host, far past a pipe buffer. awk stopping at the first line then
# SIGPIPEs lsof, and under `set -euo pipefail` that 141 killed dev.sh's
# "Running now" list (`make test` exited 141, 2026-10-18, #cm-73.17 fix1-2).
printf 'big lsof output under set -euo pipefail\n'
big="$(
  set -euo pipefail
  lsof() { printf 'p%s\nn%s\n' "$real" "$EXE"; { yes "n/usr/lib/libfake.dylib" | head -c 2000000; } || true; }
  rbf_app_pids "$PAT"; echo "status=$?"
)" || true
[[ "$big" == *"status=0"* && "$big" == *"$real $EXE"* ]] && ok "rbf_app_pids survives a big lsof listing" \
  || bad "rbf_app_pids survives a big lsof listing" "got: ${big:-<nothing; the subshell died>}"

# --- the swap seams use the helper ------------------------------------------
printf 'rbf-swap seams\n'
rbf_swap_sigterm "$APP"
sleep 0.3
kill -0 "$real" 2>/dev/null && bad "rbf_swap_sigterm stops the app" "pid $real still alive" \
  || ok "rbf_swap_sigterm stops the app"
decoy_alive=0
kill -0 "${PIDS[0]}" 2>/dev/null && decoy_alive=1
[[ $decoy_alive -eq 1 ]] && ok "rbf_swap_sigterm leaves the decoy alone" \
  || bad "rbf_swap_sigterm leaves the decoy alone" "decoy pid ${PIDS[0]} was killed"
rbf_swap_app_running "$APP" && bad "rbf_swap_app_running after the app quit" "said running (decoy?)" \
  || ok "rbf_swap_app_running is false with only the decoy left"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
