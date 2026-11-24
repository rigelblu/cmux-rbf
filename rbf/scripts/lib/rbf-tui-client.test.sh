#!/usr/bin/env bash
# rbf-tui-client.test.sh — rbf_tui_client_apply's cases, under `set -euo pipefail`, against a scratch git repo with a
# stub resolver. Each case runs in a fresh bash so no export leaks between them. The network is never used.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
pass=0
fail=0
SANDBOX="$(mktemp -d -t rbf-tui-client)"
trap 'command rm -rf "${SANDBOX:?}"' EXIT

# A repo whose HEAD descends from a commit that refs/remotes/upstream/main names.
make_repo() {
  local r="$1"
  mkdir -p "$r/scripts/ci"
  git -C "$r" init -q
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m upstream
  git -C "$r" update-ref refs/remotes/upstream/main HEAD
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fork
}
stub_resolver() { # <repo> <sha or "fail">
  local body
  if [[ "$2" == fail ]]; then body='echo "error: none" >&2; exit 1'; else body="echo $2"; fi
  printf '#!/usr/bin/env bash\n[ "$1" = --head ] || exit 9\necho "$2" > "%s/head-arg"\n%s\n' "$1" "$body" > "$1/scripts/ci/resolve-cmux-tui-client-commit.sh"
  chmod +x "$1/scripts/ci/resolve-cmux-tui-client-commit.sh"
}
probe() { # <repo> [env assignments…]
  local r="$1"; shift
  env -u CMUX_TUI_CLIENT_LOCAL -u CMUX_TUI_CLIENT_MANIFEST_URL "$@" bash -c '
    set -euo pipefail
    . "$1/rbf-tui-client.sh"
    rbf_tui_client_apply "$2"
    printf "url=%s note=%s\n" "${CMUX_TUI_CLIENT_MANIFEST_URL-unset}" "${RBF_TUI_CLIENT_NOTE:+set}"
  ' _ "$HERE" "$r"
}
expect() {
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$3" "$2"; fi
}

SHA=0123456789abcdef0123456789abcdef01234567
R1="$SANDBOX/ok"; make_repo "$R1"; stub_resolver "$R1" "$SHA"
expect "resolves upstream's client for the last merged upstream commit, and says so" \
  "$(probe "$R1")" "url=https://files.cmux.com/cmux-tui/$SHA/manifest.json note=set"
expect "the resolver is asked about the upstream commit, never the fork's HEAD" \
  "$(cat "$R1/head-arg")" "$(git -C "$R1" rev-parse refs/remotes/upstream/main)"
expect "a manifest URL the caller set wins and nothing is said" \
  "$(probe "$R1" CMUX_TUI_CLIENT_MANIFEST_URL=https://example.invalid/m.json)" "url=https://example.invalid/m.json note="
expect "a local client the caller set wins and no URL is exported" \
  "$(probe "$R1" CMUX_TUI_CLIENT_LOCAL=/tmp/cmux-tui)" "url=unset note="
R2="$SANDBOX/noupstream"; make_repo "$R2"; stub_resolver "$R2" "$SHA"; git -C "$R2" update-ref -d refs/remotes/upstream/main
expect "no upstream ref: nothing exported, so reload.sh says why itself" "$(probe "$R2")" "url=unset note="
R3="$SANDBOX/unpublished"; make_repo "$R3"; stub_resolver "$R3" fail
expect "no published client: nothing exported, and the shell is not aborted" "$(probe "$R3")" "url=unset note="

printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
