#!/usr/bin/env bash
# rbf-backend-mode.test.sh — rbf_backend_mode_apply's three cases, under `set -euo pipefail`, the strictest
# shell a caller (dev.sh) runs. Each case runs in a fresh bash so no export leaks between them.
# The wiring proof is the real entrypoint: `make build` stops in reload.sh without the call and passes it with.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0
fail=0

probe() {
  env -u CMUX_DEV_BACKEND_MODE "$@" bash -c '
    set -euo pipefail
    . "$1/rbf-backend-mode.sh"
    rbf_backend_mode_apply
    printf "mode=%s note=%s\n" "${CMUX_DEV_BACKEND_MODE-unset}" "${RBF_BACKEND_MODE_NOTE:+set}"
    bash -c "printf \"child=%s\n\" \"\${CMUX_DEV_BACKEND_MODE-unset}\""
  ' _ "$HERE"
}

expect() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$name" "$want" "$got"
  fi
}

expect "unset: defaults to local, says so, and a child process sees it" \
  "$(probe | tr '\n' ' ')" "mode=local note=set child=local "
expect "a value the caller exported wins and nothing is said" \
  "$(probe CMUX_DEV_BACKEND_MODE=remote | tr '\n' ' ')" "mode=remote note= child=remote "
expect "an exported local stays local and nothing is said" \
  "$(probe CMUX_DEV_BACKEND_MODE=local | tr '\n' ' ')" "mode=local note= child=local "

printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
