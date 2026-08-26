#!/usr/bin/env bash
# Regression coverage for recorded-gitlink.sh.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/recorded-gitlink.sh
source "$LIB_DIR/recorded-gitlink.sh"

pass=0
fail=0

ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail + 1)); }

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/cmux-recorded-gitlink.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

git_root="$tmp_root/git"
git init -q "$git_root"

empty_tree="$(git -C "$git_root" mktree </dev/null)"
ghost_sha="$(
  printf 'ghost\n' \
    | GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid \
      GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
      git -C "$git_root" commit-tree "$empty_tree"
)"
git -C "$git_root" update-index --add --cacheinfo "160000,$ghost_sha,ghostty"
tree_sha="$(git -C "$git_root" write-tree)"
parent_sha="$(
  printf 'parent\n' \
    | GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid \
      GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid \
      git -C "$git_root" commit-tree "$tree_sha"
)"
git -C "$git_root" update-ref refs/heads/main "$parent_sha"
git -C "$git_root" symbolic-ref HEAD refs/heads/main

got="$(cmux_recorded_gitlink_sha "$git_root" ghostty)"
if [[ "$got" == "$ghost_sha" ]]; then
  ok "reads a gitlink from a Git checkout"
else
  bad "reads a gitlink from a Git checkout" "want $ghost_sha, got $got"
fi

git clone -q --bare "$git_root" "$tmp_root/backing.git"
jj git init --git-repo "$tmp_root/backing.git" "$tmp_root/primary" >/dev/null
jj -R "$tmp_root/primary" workspace add "$tmp_root/linked" -r main >/dev/null

if [[ -e "$tmp_root/linked/.git" ]]; then
  bad "linked JJ fixture has no .git" "fixture unexpectedly created Git metadata"
else
  ok "linked JJ fixture has no .git"
fi

got="$(cmux_recorded_gitlink_sha "$tmp_root/linked" ghostty)"
if [[ "$got" == "$ghost_sha" ]]; then
  ok "reads a gitlink from a linked JJ workspace"
else
  bad "reads a gitlink from a linked JJ workspace" "want $ghost_sha, got $got"
fi

if cmux_recorded_gitlink_sha "$tmp_root/linked" missing >/dev/null 2>&1; then
  bad "missing gitlink fails closed" "resolver unexpectedly returned success"
else
  ok "missing gitlink fails closed"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
