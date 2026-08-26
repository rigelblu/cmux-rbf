#!/usr/bin/env bash
# Read a gitlink from this checkout's recorded tree.
#
# A normal Git checkout can ask `git ls-tree HEAD` directly. A linked JJ
# workspace has no `.git`, but its working-copy commit still lives in the
# repository's backing Git object store. Resolve that store through JJ's
# workspace metadata so build guards inspect the tree being built instead of
# depending on an agent-local PATH shim.

cmux_recorded_gitlink_sha() {
  [[ $# -eq 2 ]] || return 2

  local repo_root="$1"
  local gitlink_path="$2"
  local entry=""
  local sha=""

  if [[ -d "$repo_root/.git" || -f "$repo_root/.git" ]]; then
    entry="$(git -C "$repo_root" ls-tree HEAD -- "$gitlink_path" 2>/dev/null || true)"
    sha="$(printf '%s\n' "$entry" | awk '$1 == "160000" && $2 == "commit" { print $3; exit }')"
    if [[ -n "$sha" ]]; then
      printf '%s\n' "$sha"
      return 0
    fi
  fi

  [[ -d "$repo_root/.jj" ]] || return 1
  command -v jj >/dev/null 2>&1 || return 1

  local jj_marker="$repo_root/.jj/repo"
  local jj_repo=""
  if [[ -d "$jj_marker" ]]; then
    jj_repo="$(cd "$jj_marker" 2>/dev/null && pwd -P)" || return 1
  elif [[ -f "$jj_marker" ]]; then
    local jj_target
    jj_target="$(<"$jj_marker")"
    [[ -n "$jj_target" ]] || return 1
    jj_repo="$(cd "$(dirname "$jj_marker")" 2>/dev/null && cd "$jj_target" 2>/dev/null && pwd -P)" || return 1
  else
    return 1
  fi

  local git_target_file="$jj_repo/store/git_target"
  [[ -f "$git_target_file" ]] || return 1

  local git_target
  local git_dir
  git_target="$(<"$git_target_file")"
  [[ -n "$git_target" ]] || return 1
  if [[ "$git_target" == /* ]]; then
    git_dir="$git_target"
  else
    git_dir="$(cd "$(dirname "$git_target_file")" 2>/dev/null && cd "$git_target" 2>/dev/null && pwd -P)" || return 1
  fi

  local jj_commit
  jj_commit="$(
    jj -R "$repo_root" log --ignore-working-copy --no-graph --no-pager \
      -r @ -T 'commit_id' 2>/dev/null || true
  )"
  [[ -n "$jj_commit" ]] || return 1

  entry="$(git --git-dir="$git_dir" ls-tree "$jj_commit" -- "$gitlink_path" 2>/dev/null || true)"
  sha="$(printf '%s\n' "$entry" | awk '$1 == "160000" && $2 == "commit" { print $3; exit }')"
  [[ -n "$sha" ]] || return 1
  printf '%s\n' "$sha"
}
