#!/usr/bin/env bash
# clean-tmp-builds.sh — list, and selectively remove, the external-tmp build
# directories that `cleanup-dev-builds.sh` cannot see.
#
#   rbf/scripts/clean-tmp-builds.sh                    # list everything, delete nothing
#   rbf/scripts/clean-tmp-builds.sh --remove a b c     # delete exactly these, by name
#
# WHY THIS IS NOT PART OF `clean-builds`, AND MUST NOT BECOME PART OF IT.
# The difference is what is at stake, not how clever the check is. NEITHER tool
# asks whether a branch still exists -- `cleanup-dev-builds.sh` consults neither
# git nor jj, and the Makefile says so where it describes that target. What makes
# it safe to delete on invocation is that everything it removes is REBUILDABLE:
# a `cmux-<build-id>` DerivedData dir is compiler output and nothing else, and
# the three cases you would actually miss -- the running app's build, the most
# recent reload, and your current build-id -- are all checkable at the moment it
# runs. Worst case it costs you a rebuild.
#
# These directories are not that. They are named by TASK
# (`cmux-rbf-cm-9-basetest`, `cmux-rbf-terminal-units-review`), which maps to
# nothing checkable, and several hold git worktrees with UNCOMMITTED work --
# deleting one destroys source that exists nowhere else. So this tool cannot
# decide for you: it shows the list and deletes exactly what you name. A
# `--apply` that removed everything matching a glob would be a different tool
# wearing this one's name.
#
# Two of these directories are LOAD-BEARING and deleting them breaks the build:
#   - the Zig 0.15.2 toolchain            (rbf/scripts/lib/rbf-zig.sh)
#   - the Release install DerivedData     (rbf/scripts/install-rbf.sh)
# An age rule would have deleted the toolchain, which is old precisely BECAUSE
# it is stable. That is why protection here is by reference, not by mtime.
#
# THE PROTECT-LIST IS DERIVED, NOT HARDCODED. Anything the repo mentions by path
# is protected automatically, so a future script that hardcodes a new tmp path
# protects its own directory without anyone remembering to update this file.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Two lines, not `${CMUX_RBF_TMP_BASE:-/Volumes/Tom's HDD/tmp}`: inside
# ${var:-word} the *word* gets its own quote processing even within double
# quotes, so the apostrophe in the volume name opens a single-quoted section
# that never closes and the whole script fails to parse.
TMP_BASE="${CMUX_RBF_TMP_BASE:-}"
[[ -n "$TMP_BASE" ]] || TMP_BASE="/Volumes/Tom's HDD/tmp"
PREFIX="cmux-rbf"

[[ -d "$TMP_BASE" ]] || { printf 'error: external tmp base not found: %s\n' "$TMP_BASE" >&2; exit 1; }

# --- derive the protect-list -------------------------------------------------
# Any top-level tmp dir this repo references by path is live by definition.
# Scanning beats a hardcoded list: the two known cases (rbf-zig.sh's toolchain,
# install-rbf.sh's DerivedData) fall out of it, and so will the next one.
# REFUSE rather than run unprotected if rg is missing. rg lives in a user-local
# prefix here, so a PATH-poor context — launchd, an Xcode script phase, a
# scrubbed agent env — silently produced an EMPTY protect-list and offered the
# Zig toolchain and the install DerivedData as "removable", exit 0, no warning.
# A protection mechanism that fails open is worse than none, because the output
# still looks authoritative.
command -v rg >/dev/null 2>&1 || {
  printf 'error: rg not found — the protect-list is derived by scanning the repo,\n' >&2
  printf '       so without it nothing would be protected and everything would\n' >&2
  printf '       read as removable. Refusing rather than guessing.\n' >&2
  exit 1
}

declare -a PROTECTED=()
while IFS= read -r name; do
  [[ -n "$name" ]] && PROTECTED+=("$name")
done < <(
  # --hidden: .git/worktrees/<name>/gitdir records every registered worktree by
  # absolute path, and without it rg skips the whole of .git.
  rg -o -I --hidden "tmp/${PREFIX}[A-Za-z0-9._-]*" \
     --glob '!rb-drive/**' --glob '!ghostty/**' --glob '!.jj/**' \
     . 2>/dev/null \
  | sed "s|^tmp/||" | sort -u
)

# A registered git worktree is live by definition, and its top-level tmp dir is
# usually NOT referenced by any script — so reference-scanning alone misses it.
# Found by dogfooding: three worktrees (cm-10-green, cm-18-wt, cm-9-reconcile)
# sat inside dirs this tool offered as "removable". Deleting one leaves a stale
# registration that breaks `git worktree list` for every other worktree too.
declare -a WORKTREE_DIRS=()
while IFS= read -r wt; do
  [[ "$wt" == "$TMP_BASE/"* ]] || continue
  rest="${wt#"$TMP_BASE/"}"          # cmux-rbf-x/checkout -> cmux-rbf-x/checkout
  WORKTREE_DIRS+=("${rest%%/*}")     # keep the top-level tmp dir only
done < <(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')

is_protected() {
  local d="$1" p
  for p in "${PROTECTED[@]:-}"; do [[ "$d" == "$p" ]] && return 0; done
  for p in "${WORKTREE_DIRS[@]:-}"; do [[ "$d" == "$p" ]] && return 0; done
  return 1
}

why_protected() {
  local d="$1" p
  for p in "${WORKTREE_DIRS[@]:-}"; do
    [[ "$d" == "$p" ]] && { printf 'holds a registered git worktree'; return; }
  done
  printf 'referenced by %s' "$(rg -l -I --glob '!rb-drive/**' --glob '!ghostty/**' \
     --glob '!.jj/**' "tmp/$d" . 2>/dev/null | head -1)"
}

# --- collect -----------------------------------------------------------------
declare -a DIRS=()
while IFS= read -r d; do DIRS+=("$d"); done < <(
  find "$TMP_BASE" -maxdepth 1 -type d -name "${PREFIX}*" 2>/dev/null | sort
)
[[ ${#DIRS[@]} -gt 0 ]] || { echo "no ${PREFIX}* directories under $TMP_BASE"; exit 0; }

MODE="list"
declare -a WANTED=()
if [[ "${1:-}" == "--remove" ]]; then
  MODE="remove"; shift
  WANTED=("$@")
  [[ ${#WANTED[@]} -gt 0 ]] || {
    printf 'error: --remove needs at least one directory name.\n' >&2
    printf '       Run with no arguments to see the list.\n' >&2
    exit 2
  }
elif [[ $# -gt 0 ]]; then
  printf 'error: unknown option: %s\n' "$1" >&2; exit 2
fi

if [[ "$MODE" == "list" ]]; then
  # Print the base path. Without it these are 60 bare names you cannot `ls`,
  # and a dogfooder learned the parent directory by accident, from an unrelated
  # command's output.
  printf 'external tmp base: %s\n\n' "$TMP_BASE"
  printf '%-46s %8s  %-12s %s\n' "DIRECTORY" "SIZE" "LAST TOUCHED" "STATE"
  removable_kb=0
  protected_kb=0
  for d in "${DIRS[@]}"; do
    n="$(basename "$d")"
    sz="$(du -sh "$d" 2>/dev/null | awk '{print $1}')"
    mt="$(stat -f '%Sm' -t '%Y-%m-%d' "$d" 2>/dev/null)"
    kb="$(du -sk "$d" 2>/dev/null | awk '{print $1}')"
    if is_protected "$n"; then
      printf '%-46s %8s  %-12s PROTECTED — %s\n' "$n" "$sz" "$mt" "$(why_protected "$n")"
      protected_kb=$((protected_kb + ${kb:-0}))
    else
      printf '%-46s %8s  %-12s removable\n' "$n" "$sz" "$mt"
      removable_kb=$((removable_kb + ${kb:-0}))
    fi
  done
  echo
  # The job here is reclaiming disk, so the number that decides whether it is
  # worth doing has to be on screen. 60 alphabetical rows do not add themselves.
  printf 'removable: %s across %d dir(s)   ·   protected: %s\n' \
    "$(awk -v k="$removable_kb" 'BEGIN{printf "%.1f GB", k/1048576}')" \
    "$((${#DIRS[@]} - $(printf '%s\n' "${PROTECTED[@]:-}" "${WORKTREE_DIRS[@]:-}" | sort -u | grep -c . )))" \
    "$(awk -v k="$protected_kb" 'BEGIN{printf "%.1f GB", k/1048576}')"
  echo
  echo "Nothing was deleted. To remove, name them explicitly:"
  echo "  make clean-tmp REMOVE=\"<dir> <dir> …\""
  echo
  echo "Protection is derived: a directory this repo references by path is never offered."
  exit 0
fi

# --- remove, by explicit name only -------------------------------------------
declare -a TO_DELETE=()
for w in "${WANTED[@]}"; do
  w="${w%/}"; w="$(basename "$w")"
  target="$TMP_BASE/$w"
  if [[ ! -d "$target" ]]; then
    printf 'error: no such directory: %s\n' "$target" >&2; exit 1
  fi
  if [[ "$w" != ${PREFIX}* ]]; then
    printf 'error: refusing — %s is not a %s* directory\n' "$w" "$PREFIX" >&2; exit 1
  fi
  if is_protected "$w"; then
    printf 'error: refusing — %s %s\n' "$w" "$(why_protected "$w")" >&2
    printf '       If it is genuinely dead, drop the worktree or the reference first,\n' >&2
    printf '       then re-run. This tool will not decide that for you.\n' >&2
    exit 1
  fi
  TO_DELETE+=("$target")
done

# Count what actually went, not what was planned. Reporting the plan meant a
# read-only volume or an immutable flag produced "done — 1 removed", exit 0, and
# a directory still on disk: the user believes the space came back.
removed=0
failed=0
for t in "${TO_DELETE[@]}"; do
  sz="$(du -sh "$t" 2>/dev/null | awk '{print $1}')"
  if rm -rf "$t"; then
    printf '  removed %-44s %s\n' "$(basename "$t")" "$sz"
    removed=$((removed + 1))
  else
    printf '  FAILED  %-44s %s\n' "$(basename "$t")" "$sz" >&2
    failed=$((failed + 1))
  fi
done
printf '\ndone — %d removed' "$removed"
[[ $failed -gt 0 ]] && printf ', %d FAILED (still on disk)' "$failed"
printf '\n'
[[ $failed -eq 0 ]]
