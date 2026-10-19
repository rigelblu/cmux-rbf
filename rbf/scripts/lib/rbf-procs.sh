#!/usr/bin/env bash
# rbf-procs.sh — find a running app by its EXECUTABLE, never by its argv.
#
# Sourced by dev.sh and rbf-swap.sh. No side effects at source time.
#
# WHY NOT `pgrep -f <app path>`: -f matches the whole argv of every process,
# so any process that merely MENTIONS the path matches — an agent whose prompt
# names "cmux DEV cm-73.app/Contents/MacOS/", a shell running a grep for it.
# Observed 2026-10-18 (#cm-73.15/.16): dev.sh refused `make test` because a
# Codex process's prompt held the path, then printed `pgrep -fl` of the match —
# that process's full argv, auth token included — into a test log. The same
# pattern drove rbf-swap.sh's `pkill -TERM -f`, so an install could SIGTERM an
# agent that had the install path in its prompt.
#
# So: pgrep -f stays as a cheap pre-filter, and each candidate is kept only if
# its executable — the first `txt` entry lsof reports, symlinks resolved —
# matches. A regex anchored on argv cannot do this: the app's own executable is
# "cmux DEV" (a space), and a parent dir can hold spaces too.
#
# Callers print the pid and executable path this returns. Never print argv.

# rbf_app_pids <ERE matched against the executable path>
# Prints "<pid> <executable>" per match, one per line. Exit 0 always.
rbf_app_pids() {
  local re="$1" pid exe
  for pid in $(pgrep -f -- "$re" 2>/dev/null); do
    # awk reads to the end, never `exit`s: a Debug cmux's listing runs to
    # ~475 KB, and stopping early SIGPIPEs lsof — under the callers'
    # `set -euo pipefail` that 141 ended dev.sh mid-message.
    exe="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | awk '/^n/ && !found { print substr($0, 2); found = 1 }')" || true
    [[ -n "$exe" && "$exe" =~ $re ]] && printf '%s %s\n' "$pid" "$exe"
  done
  return 0
}

# rbf_app_running <ERE> — exit 0 when at least one process's executable matches.
rbf_app_running() { [[ -n "$(rbf_app_pids "$1")" ]]; }
