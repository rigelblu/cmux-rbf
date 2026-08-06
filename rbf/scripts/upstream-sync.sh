#!/usr/bin/env bash

# Sync this fork's stack onto its upstream's main branch with jj.
#
# Most conflicts land on upstream files the fork has modified, but add/add and
# delete/rename edge cases still need human judgment. This command classifies
# and reports instead of auto-applying resolutions: re-apply the fork's edits
# deliberately, inspect unexpected fork-owned collisions, then run your verify command.
#
# Requires an 'upstream' git remote carrying the upstream branch (default: main;
# set UPSTREAM_BRANCH to override). A clean rebase is gated on `make test` by
# default; override with UPSTREAM_SYNC_VERIFY_CMD / --verify-cmd, or skip with
# --skip-verify. Quit any running tagged cmux app first or the test run aborts.
#
# cmux notes:
#  - Local 'main' IS the fork's published branch and rides the rebased stack;
#    'main@upstream' tracks manaflow. Nothing here moves local bookmarks.
#  - Submodule pointers (ghostty) conflict on both-sides moves; keep the fork's
#    pointer and take upstream ghostty inside the submodule per CLAUDE.md.

set -euo pipefail

check_only=false
skip_verify=false
log_path=""
verify_cmd="${UPSTREAM_SYNC_VERIFY_CMD:-make test}"

usage() {
  cat <<'USAGE'
Usage: rbf/scripts/upstream-sync.sh [options]

Fetch the 'upstream' remote, rebase this fork's stack onto its main branch, and
report any conflicts with their divergence classification.

Options:
  --check-only        Fetch and report divergence and classification; no rebase.
  --verify-cmd <cmd>  Shell command to run after a clean rebase (default: make test).
  --skip-verify       Skip the verify command after a clean rebase.
  --log-path <path>   Sync log. Default: $HOME/Library/Logs/<repo>-upstream-sync.log.
  -h, --help          Show this help.

Environment:
  UPSTREAM_BRANCH           Upstream branch to track (default: main).
  UPSTREAM_SYNC_VERIFY_CMD  Default for --verify-cmd (falls back to: make test).
USAGE
}

require_value() {
  local option="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "Error: $option requires a value." >&2
    exit 1
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only)
      check_only=true
      shift
      ;;
    --skip-verify)
      skip_verify=true
      shift
      ;;
    --verify-cmd)
      require_value "$1" "${2:-}"
      verify_cmd="$2"
      shift 2
      ;;
    --log-path)
      require_value "$1" "${2:-}"
      log_path="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if ! command -v jj >/dev/null 2>&1; then
  echo "Error: jj (Jujutsu) is not installed or not in PATH." >&2
  exit 1
fi

repo_root="$(jj root 2>/dev/null)" || {
  echo "Error: not inside a jj repository." >&2
  exit 1
}
cd "$repo_root"

# Default the log to the repo's name so several forks don't clobber one shared log.
: "${log_path:=$HOME/Library/Logs/$(basename "$repo_root")-upstream-sync.log}"

mkdir -p "$(dirname "$log_path")"

log() {
  printf '%s\n' "$*" | tee -a "$log_path"
}

run_logged() {
  "$@" 2>&1 | tee -a "$log_path"
}

upstream_branch="${UPSTREAM_BRANCH:-main}"
upstream_ref="${upstream_branch}@upstream"

resolve_stack_tip() {
  local tip

  tip="$(jj log -r 'heads(@::)' --no-graph -T 'commit_id ++ "\n"')"
  if [[ -z "$tip" ]] || [[ "$(printf '%s\n' "$tip" | wc -l | tr -d ' ')" -ne 1 ]]; then
    log "Error: expected exactly one fork stack tip above @; got:"
    log "${tip:-<none>}"
    exit 1
  fi

  stack_tip="$tip"
}

log "== upstream sync =="
log "Started: $(date '+%Y-%m-%d %H:%M:%S %Z')"
log "Repo: $repo_root"
log "Log: $log_path"

log ""
log "== fetch =="
if ! run_logged jj git fetch --remote upstream; then
  log "Error: jj git fetch --remote upstream failed."
  exit 1
fi

if ! jj log -r "$upstream_ref" --no-graph --limit 1 -T '""' >/dev/null 2>&1; then
  log "Error: $upstream_ref not found. Configure the 'upstream' remote with a 'main' branch."
  exit 1
fi

resolve_stack_tip

fork_base="$(jj log -r "heads(::${stack_tip} & ::${upstream_ref})" --no-graph -T 'commit_id ++ "\n"')"
if [[ -z "$fork_base" ]] || [[ "$(printf '%s\n' "$fork_base" | wc -l | tr -d ' ')" -ne 1 ]]; then
  log "Error: expected exactly one merge base between the fork stack tip and ${upstream_ref}; got:"
  log "${fork_base:-<none>}"
  exit 1
fi

upstream_new_count="$(jj log -r "${fork_base}..${upstream_ref}" --no-graph -T '"."' | wc -c | tr -d ' ')"
stack_count="$(jj log -r "${fork_base}..${stack_tip}" --no-graph -T '"."' | wc -c | tr -d ' ')"

log ""
log "== divergence =="
log "Merge base: $(jj log -r "$fork_base" --no-graph -T 'commit_id.short() ++ " " ++ description.first_line()')"
log "Upstream tip: $(jj log -r "$upstream_ref" --no-graph -T 'commit_id.short() ++ " " ++ description.first_line()')"
log "Fork stack tip: $(jj log -r "$stack_tip" --no-graph -T 'commit_id.short() ++ " " ++ description.first_line()')"
log "New upstream commits since base: $upstream_new_count"
log "Fork stack commits to transplant: $stack_count"

owned_files=""
hooked_files=""
deleted_files=""

# Submodule pointers need their own conflict advice: jj cannot materialize a
# conflict inside a gitlink, and the fork's pointer must win (upstream's
# submodule changes are taken inside the submodule, not at the pointer).
submodule_paths="$(git config --file .gitmodules --get-regexp '^submodule\..*\.path$' 2>/dev/null | awk '{print $2}' || true)"

parse_rename_or_copy_paths() {
  local display_path="$1"
  local prefix
  local renamed
  local suffix
  local old_middle
  local new_middle

  if [[ "$display_path" == *"{"* && "$display_path" == *" => "* && "$display_path" == *"}"* ]]; then
    prefix="${display_path%%\{*}"
    renamed="${display_path#*\{}"
    suffix="${renamed#*\}}"
    renamed="${renamed%%\}*}"
    old_middle="${renamed%% => *}"
    new_middle="${renamed#* => }"
    printf '%s\n%s\n' "${prefix}${old_middle}${suffix}" "${prefix}${new_middle}${suffix}"
    return 0
  fi

  if [[ "$display_path" == *" => "* ]]; then
    printf '%s\n%s\n' "${display_path%% => *}" "${display_path#* => }"
    return 0
  fi

  return 1
}

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  status="${line%% *}"
  rest="${line#* }"
  case "$status" in
    A)
      owned_files="${owned_files}${rest}"$'\n'
      ;;
    M)
      hooked_files="${hooked_files}${rest}"$'\n'
      ;;
    D)
      deleted_files="${deleted_files}${rest}"$'\n'
      ;;
    R)
      if paths="$(parse_rename_or_copy_paths "$rest")"; then
        old_path="$(printf '%s\n' "$paths" | sed -n '1p')"
        new_path="$(printf '%s\n' "$paths" | sed -n '2p')"
        owned_files="${owned_files}${new_path}"$'\n'
        deleted_files="${deleted_files}${old_path}"$'\n'
      else
        hooked_files="${hooked_files}${rest}"$'\n'
      fi
      ;;
    C)
      if paths="$(parse_rename_or_copy_paths "$rest")"; then
        new_path="$(printf '%s\n' "$paths" | sed -n '2p')"
        owned_files="${owned_files}${new_path}"$'\n'
      else
        owned_files="${owned_files}${rest}"$'\n'
      fi
      ;;
  esac
done < <(jj diff --from "$fork_base" --to "$stack_tip" --summary)

count_lines() {
  if [[ -z "$1" ]]; then
    echo 0
  else
    printf '%s' "$1" | grep -c '' | tr -d ' '
  fi
}

log ""
log "== classification =="
log "Fork-owned files (unexpected if conflicted): $(count_lines "$owned_files")"
log "Upstream files the fork modifies (conflicts land here): $(count_lines "$hooked_files")"
printf '%s' "$hooked_files" | while IFS= read -r file; do
  [[ -n "$file" ]] && log "  edit: $file"
done
log "Deleted by fork: $(count_lines "$deleted_files")"

if [[ "$check_only" == true ]]; then
  log ""
  log "Check-only mode complete; no rebase performed."
  exit 0
fi

if [[ -n "$(jj diff --summary)" ]]; then
  log ""
  log "Error: working copy has changes; commit them before syncing."
  exit 1
fi

pre_op="$(jj op log --no-graph --limit 1 -T 'id.short(12)')"

log ""
log "== provenance =="
log "Pre-rebase operation: $pre_op (undo rebase/local-history changes with: jj op restore $pre_op)"
log "Pre-rebase stack tip: $stack_tip"
log "Pre-rebase change map:"
run_logged jj log -r "${fork_base}..${stack_tip}" --no-graph -T 'change_id.short() ++ " " ++ commit_id.short() ++ " " ++ description.first_line() ++ "\n"'

log ""
log "== rebase =="
# The fork stack lives on the fork's main (jj trunk()), so jj marks it immutable.
# Transplant-and-force-push is this fork's sync model; the merge-base check above
# guarantees only fork commits are rewritten, so overriding immutability is safe.
if ! run_logged jj rebase -b @ -d "$upstream_ref" --ignore-immutable; then
  log "Error: jj rebase failed. Undo rebase/local-history changes with: jj op restore $pre_op"
  exit 1
fi

resolve_stack_tip
conflicted_revs="$(jj log -r "conflicts() & ${upstream_ref}..${stack_tip}" --no-graph --reversed -T 'change_id.short() ++ "\n"')"

if [[ -z "$conflicted_revs" ]]; then
  log "Rebase complete - no conflicts."
  # Local 'main' is the fork's published branch; it followed the rebased stack.
  # Never point it at upstream — 'main@upstream' already tracks that.

  if [[ -n "$submodule_paths" ]]; then
    log ""
    log "Submodules: jj does not update submodule checkouts. Verify pointers vs checkouts with: git submodule status"
  fi

  log ""
  log "== verify =="
  if [[ "$skip_verify" == true ]]; then
    log "Skipping verify (--skip-verify)."
  elif [[ -z "$verify_cmd" ]]; then
    log "No verify command configured — set UPSTREAM_SYNC_VERIFY_CMD or pass --verify-cmd to gate on build/test."
  else
    log "Running verify command: $verify_cmd"
    if ! run_logged bash -c "$verify_cmd"; then
      log "Error: verify command failed after rebase. Inspect, or undo rebase/local-history changes with: jj op restore $pre_op"
      exit 1
    fi
  fi

  log ""
  log "Sync complete."
  exit 0
fi

log ""
log "== conflicts =="
log "Conflicted revisions (reported bottom-up so fixes propagate to descendants):"
printf '%s' "$conflicted_revs" | while IFS= read -r rev; do
  [[ -z "$rev" ]] && continue
  log ""
  log "$(jj log -r "$rev" --no-graph -T 'change_id.short() ++ " " ++ commit_id.short() ++ " " ++ description.first_line()')"
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if printf '%s' "$submodule_paths" | grep -Fxq "$file"; then
      log "  $file - submodule pointer: keep the FORK's pointer (jj restore it from the fork side); take upstream's submodule changes inside the submodule by merging its upstream remote, then bump the pointer deliberately"
    elif printf '%s' "$hooked_files" | grep -Fxq "$file"; then
      log "  $file - fork edit: accept upstream's new version, then re-apply the fork's change on top"
    elif printf '%s' "$owned_files" | grep -Fxq "$file"; then
      log "  $file - UNEXPECTED: upstream collided with a fork-owned file; inspect manually"
    elif printf '%s' "$deleted_files" | grep -Fxq "$file"; then
      log "  $file - deleted or renamed by fork: decide whether to keep upstream's file or preserve the fork deletion/rename"
    else
      log "  $file - UNKNOWN: not in divergence inventory; inspect manually before choosing either side"
    fi
  done < <(jj log -r "$rev" --no-graph -T 'self.conflicted_files().map(|entry| entry.path() ++ "\n").join("")')
done

log ""
log "Resolve with: jj edit <rev>, fix the files, then continue up the stack."
if [[ -n "$submodule_paths" ]]; then
  log "Submodules: jj does not update submodule checkouts. After resolving, verify with: git submodule status"
fi
log "Undo rebase/local-history changes with: jj op restore $pre_op"
log "After resolving all conflicts, rerun your verify command${verify_cmd:+: $verify_cmd}."
exit 1
