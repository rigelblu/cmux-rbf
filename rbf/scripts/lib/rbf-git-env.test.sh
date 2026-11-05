#!/usr/bin/env bash
# rbf-git-env.test.sh — prove rbf_git_env_apply makes `git status` work in a jj
# workspace whose `ghostty` is a symlink, and changes nothing anywhere else.
#
#   bash rbf/scripts/lib/rbf-git-env.test.sh
#   /bin/bash rbf/scripts/lib/rbf-git-env.test.sh      # macOS bash 3.2 too
#
# Builds scratch git repos under $TMPDIR whose index records `ghostty` as a
# submodule gitlink: once with a symlink on disk (a jj workspace; the control
# proves `git status` exits 128 there), once with a real directory (the main
# checkout). Each case runs the lib in a fresh `$BASH -c` under
# `set -euo pipefail`, the strictest shell a caller (dev.sh) runs, with every
# GIT_CONFIG_* variable cleared first. RBF_GIT_ENV_LIB points the test at another
# copy of the lib (a no-op stub, a mutation); the default is the lib beside it.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${RBF_GIT_ENV_LIB:-$LIB_DIR/rbf-git-env.sh}"

SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rbf-git-env-test.XXXXXX")" && pwd -P)"
trap 'rm -rf "$SANDBOX"' EXIT

# Keep the machine's own git config out of the control: a global
# diff.ignoreSubmodules would make the failing `git status` pass.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_OPTIONAL_LOCKS=0

pass=0
fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; fail=$((fail + 1)); }

# make_repo <name> <symlink|dir> — a repo whose index records `ghostty` as a gitlink.
make_repo() {
  local r="$SANDBOX/$1"
  mkdir -p "$SANDBOX/target-$1"
  git init -q "$r"
  git -C "$r" update-index --add --cacheinfo 160000,aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,ghostty
  if [[ "$2" == symlink ]]; then
    ln -s "$SANDBOX/target-$1" "$r/ghostty"
  else
    mkdir "$r/ghostty"
  fi
  printf '%s' "$r"
}

# Every GIT_CONFIG_* variable a case may set, cleared before each probe.
UNSET_ARGS=(-u GIT_CONFIG_COUNT)
for n in 0 1 2 3 4 5 6 7 8; do
  UNSET_ARGS+=(-u "GIT_CONFIG_KEY_$n" -u "GIT_CONFIG_VALUE_$n")
done

# probe <repo> [VAR=value ...] — run the lib in a fresh shell and print what it
# left behind. PROBE_TWICE=1 applies a second time. The shell's stderr is
# printed as a final `stderr=[...]` line and `expect` requires it empty.
#
# What each kind of failure looks like here:
#   - `set -u` (a bare ${!k} on a missing pair) kills the shell: no `reached`.
#   - an arithmetic error inside the lib (say 10#abc) does NOT kill it; bash 3.2
#     just carries on with the next line. It only shows on stderr.
#   - the lib printing anything shows on stderr.
# shellcheck disable=SC2016  # the -c script is single-quoted on purpose
probe() {
  local repo="$1"; shift
  local errf="$SANDBOX/probe.err"
  : > "$errf"
  env "${UNSET_ARGS[@]}" "$@" "$BASH" -c '
    set -euo pipefail
    . "$1"
    # Bare calls, as dev.sh makes them: `f || rc=$?` would switch errexit off
    # inside f and hide an abort.
    rbf_git_env_apply "$2"
    if [[ -n "${PROBE_TWICE:-}" ]]; then rbf_git_env_apply "$2"; fi
    git_rc=0
    git -C "$2" status --porcelain >/dev/null 2>&1 || git_rc=$?
    echo "reached=1"
    echo "git_rc=$git_rc"
    echo "count=${GIT_CONFIG_COUNT-unset}"
    echo "key0=${GIT_CONFIG_KEY_0-unset}"
    echo "value0=${GIT_CONFIG_VALUE_0-unset}"
    echo "key1=${GIT_CONFIG_KEY_1-unset}"
    echo "value1=${GIT_CONFIG_VALUE_1-unset}"
    echo "key2=${GIT_CONFIG_KEY_2-unset}"
    echo "value2=${GIT_CONFIG_VALUE_2-unset}"
    echo "key3=${GIT_CONFIG_KEY_3-unset}"
    echo "value3=${GIT_CONFIG_VALUE_3-unset}"
    echo "key8=${GIT_CONFIG_KEY_8-unset}"
    echo "value8=${GIT_CONFIG_VALUE_8-unset}"
    echo "note=[${RBF_GIT_ENV_NOTE:-}]"
  ' probe "$LIB" "$repo" 2>"$errf" || true
  printf 'stderr=[%s]\n' "$(tr '\n' ' ' < "$errf")"
}

# field <probe output> <name> — one value from probe's output; empty when absent.
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# expect <case> <probe output> name=value ... — every pair must match, and the
# probe's stderr must be empty.
expect() {
  local name="$1" out="$2" pair want got miss=""
  shift 2
  for pair in "$@"; do
    want="${pair#*=}"
    got="$(field "$out" "${pair%%=*}")"
    [[ "$got" == "$want" ]] || miss="$miss ${pair%%=*}: want [$want] got [$got];"
  done
  got="$(field "$out" stderr)"
  [[ "$got" == "[]" ]] || miss="$miss stderr: want [] got $got;"
  if [[ -z "$miss" ]]; then ok "$name"; else bad "$name" "${miss# }  (output: $(printf '%s' "$out" | tr '\n' ' '))"; fi
}

NOTE='[diff.ignoreSubmodules=all (ghostty is a symlink; see rbf-git-env.sh)]'

SYM="$(make_repo sym symlink)"
REAL="$(make_repo real dir)"

printf 'rbf-git-env.test.sh (%s, lib: %s)\n' "$BASH_VERSION" "$LIB"

# --- control -------------------------------------------------------------------
# Without the lib, git refuses the symlinked gitlink. If this does not exit 128,
# the fixture is wrong and every case below proves nothing.
rc=0
msg="$(env -u GIT_CONFIG_COUNT git -C "$SYM" status --porcelain 2>&1)" || rc=$?
if [[ "$rc" -eq 128 && "$msg" == *"not to be a symbolic link"* ]]; then
  ok "control: git status exits 128 on a symlinked gitlink"
else
  bad "control: git status exits 128 on a symlinked gitlink" "exit $rc: $msg"
fi

# --- the fix -------------------------------------------------------------------
out="$(probe "$SYM")"
expect "symlinked ghostty: git status exits 0 after apply" "$out" \
  reached=1 git_rc=0 count=1 key0=diff.ignoreSubmodules value0=all "note=$NOTE"

out="$(probe "$REAL")"
expect "real ghostty directory: nothing changes" "$out" \
  reached=1 count=unset key0=unset value0=unset "note=[]"

out="$(probe "$SYM" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=cat)"
expect "an existing entry is kept and ours lands at index 1" "$out" \
  reached=1 git_rc=0 count=2 key0=core.pager value0=cat key1=diff.ignoreSubmodules value1=all "note=$NOTE"

out="$(probe "$SYM" PROBE_TWICE=1)"
expect "a second apply adds no duplicate" "$out" \
  reached=1 git_rc=0 count=1 key1=unset value1=unset "note=$NOTE"

out="$(probe "$SYM" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.ignoreSubmodules GIT_CONFIG_VALUE_0=all)"
expect "the hand-typed prefix is not duplicated, and the note still prints" "$out" \
  reached=1 git_rc=0 count=1 key1=unset "note=$NOTE"

out="$(probe "$SYM" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.ignoreSubmodules GIT_CONFIG_VALUE_0=dirty)"
expect "the same key with another value does not count as present; ours lands at index 1" "$out" \
  reached=1 git_rc=0 count=2 key0=diff.ignoreSubmodules value0=dirty key1=diff.ignoreSubmodules value1=all "note=$NOTE"

out="$(probe "$SYM" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=DIFF.IgnoreSubmodules GIT_CONFIG_VALUE_0=all)"
expect "an upper-case key with value all is found, so nothing is added" "$out" \
  reached=1 count=1 key1=unset "note=$NOTE"

out="$(probe "$SYM" GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=diff.ignoreSubmodules GIT_CONFIG_VALUE_0=all \
  GIT_CONFIG_KEY_1=diff.ignoreSubmodules GIT_CONFIG_VALUE_1=none)"
expect "the last entry wins: an earlier =all under a later =none gets ours appended" "$out" \
  reached=1 git_rc=0 count=3 key2=diff.ignoreSubmodules value2=all "note=$NOTE"

out="$(probe "$SYM" GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=diff.ignoreSubmodules GIT_CONFIG_VALUE_0=all \
  GIT_CONFIG_KEY_1=core.pager GIT_CONFIG_VALUE_1=cat)"
expect "an earlier =all with another entry after it still gets ours appended" "$out" \
  reached=1 git_rc=0 count=3 key1=core.pager key2=diff.ignoreSubmodules value2=all "note=$NOTE"

out="$(probe "$SYM" GIT_CONFIG_COUNT=08)"
expect "a count with a leading zero is read as decimal, not octal" "$out" \
  reached=1 count=9 key8=diff.ignoreSubmodules value8=all "note=$NOTE"

out="$(probe "$SYM" GIT_CONFIG_COUNT=abc)"
expect "a non-numeric count leaves every variable untouched and returns 0" "$out" \
  reached=1 count=abc key0=unset value0=unset key1=unset "note=[]"

out="$(probe "$SYM" GIT_CONFIG_COUNT=3 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=cat)"
expect "a count larger than the pairs set does not abort the shell, returns 0" "$out" \
  reached=1 count=4 key3=diff.ignoreSubmodules value3=all "note=$NOTE"

printf '%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
