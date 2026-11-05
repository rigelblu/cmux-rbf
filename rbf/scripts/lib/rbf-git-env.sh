#!/usr/bin/env bash
# rbf-git-env.sh — let `git status` work in a jj workspace whose `ghostty` is a symlink.
#
#   source rbf/scripts/lib/rbf-git-env.sh
#   rbf_git_env_apply "$REPO_ROOT"
#   [[ -n "$RBF_GIT_ENV_NOTE" ]] && echo "==> git $RBF_GIT_ENV_NOTE"
#
# SYMPTOM. `make build|run|test|install-rbf` in a jj workspace dies in the
# "Build wireguard-go" Xcode phase with
#
#   go: error obtaining VCS status: exit status 128
#   error: expected submodule path 'ghostty' not to be a symbolic link
#
# CAUSE. A jj workspace here points `ghostty` at the main checkout's submodule
# directory with a symlink, while the git index still records `ghostty` as a
# submodule (gitlink). git refuses to look through a symlink where it expects a
# submodule, so `git status --porcelain` exits 128. Go runs exactly that to stamp
# the binary (scripts/build-wireguard-go.sh, upstream's), and treats the failure
# as fatal. Workspaces with no `.git` at all never hit it: git finds no repo, Go
# skips the stamp. The failure can also appear only after jj rewrites the index.
#
# WHY NOT `-buildvcs=false`. The script sets GOFLAGS inside its own `env` call
# (build-wireguard-go.sh:123), so nothing exported from here reaches it. It does
# inherit GIT_CONFIG_*, which is git's documented way to pass config with no file.
#
# THE FIX. Export `diff.ignoreSubmodules=all` through GIT_CONFIG_COUNT/KEY_n/VALUE_n
# for this one build: `git status` then skips submodules, exits 0, and Go builds.
# The setting lives only in the process environment. reload.sh launches the tagged
# app through `env -i`, so the running app never sees it, and nothing is written
# to any git config file.
#
# WHEN IT APPLIES. Only when "$1/ghostty" is a symlink. No git call: the check
# cannot fail in the state it exists to fix. A real submodule directory (the main
# checkout, or a git worktree set up by the four-step recipe) is left alone, so a
# guard that reads git there sees exactly what it saw before.
#
# APPEND, NEVER OVERWRITE. Keys go at the next index after any GIT_CONFIG_COUNT
# already exported, so a caller's own entries keep working. git uses the last
# entry for a key, so ours, being last, wins. The one thing read is the last
# entry: if it is already diff.ignoreSubmodules=all (agents used to type that as
# a prefix), nothing is added and the note is still set, because it says what is
# in effect, not who set it. An earlier =all with other entries after it gets
# ours appended, a harmless duplicate. One read, no loop: scanning every index
# set the note while a later `=none` won, and hung on a huge count.
#
# A MALFORMED OR OVERSIZED COUNT is the caller's env, already broken without this
# fix, and it breaks things before this lib runs: jj reads GIT_CONFIG_* too and
# fails on it, so `derive_build_id` falls back to `detached-unknown` (checked
# 2026-11-05: `make help` still exits 0). Here, a count that is not a whole number
# leaves every variable as it was, sets no note and returns 0; git's own `bogus
# count in GIT_CONFIG_COUNT` stands and fails the build seconds in, at
# scripts/ensure-ghosttykit.sh, before anything is removed. A count larger than
# the pairs set reads the missing pairs as empty and appends at index <count>;
# git's own `missing config key` stands. The note is set then too, although git
# refuses the whole environment. That is the caller's miscount, not a claim this
# lib can check.
#
# EVERY INDIRECT READ USES A DEFAULT. dev.sh runs `set -euo pipefail` and
# install-rbf.sh `set -uo pipefail`; a bare "${!k}" on a missing pair aborts the
# caller's shell. So: "${!k:-}", always.
#
# CONTRACT. Never prints, never exits, always returns 0. Sets RBF_GIT_ENV_NOTE to
# the text below when the setting is in effect, empty otherwise; the entrypoint
# prints it. The lib itself prints nothing because `dev.sh build-id` writes the
# build-id alone to stdout and other scripts read it.
#
# WHY THIS IS A LIB: same reason as rbf-zig.sh and rbf-metal.sh. `make
# build`/`run`/`test` reach the build through dev.sh, `make install-rbf` never
# does. A guard inside one entrypoint cannot be inherited by a second; only a
# copy can, and nobody copies what they do not know exists.
[[ -n "${RBF_GIT_ENV_SH_LOADED:-}" ]] && return 0
RBF_GIT_ENV_SH_LOADED=1

# shellcheck disable=SC2034  # read by the sourcing entrypoint
RBF_GIT_ENV_NOTE=""
readonly RBF_GIT_ENV_NOTE_TEXT="diff.ignoreSubmodules=all (ghostty is a symlink; see rbf-git-env.sh)"

# rbf_git_env_apply <repo_root>
rbf_git_env_apply() {
  local repo_root="${1:-}" count k v key
  # shellcheck disable=SC2034  # read by the sourcing entrypoint
  RBF_GIT_ENV_NOTE=""

  [[ -n "$repo_root" && -L "$repo_root/ghostty" ]] || return 0

  count="${GIT_CONFIG_COUNT:-0}"
  [[ "$count" =~ ^[0-9]+$ ]] || return 0
  count=$((10#$count))

  if (( count > 0 )); then
    k="GIT_CONFIG_KEY_$((count - 1))"
    v="GIT_CONFIG_VALUE_$((count - 1))"
    key="$(printf '%s' "${!k:-}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$key" == "diff.ignoresubmodules" && "${!v:-}" == "all" ]]; then
      # shellcheck disable=SC2034
      RBF_GIT_ENV_NOTE="$RBF_GIT_ENV_NOTE_TEXT"
      return 0
    fi
  fi

  export "GIT_CONFIG_KEY_$count=diff.ignoreSubmodules"
  export "GIT_CONFIG_VALUE_$count=all"
  export GIT_CONFIG_COUNT=$((count + 1))
  # shellcheck disable=SC2034
  RBF_GIT_ENV_NOTE="$RBF_GIT_ENV_NOTE_TEXT"
  return 0
}
