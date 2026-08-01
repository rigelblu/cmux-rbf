#!/usr/bin/env bash
# migrate-rbf-state.sh — copy workspaces and layout from upstream's cmux into
# the RBF channel, once.
#
# SIGN-IN IS NOT COPYABLE AND IS NOT ATTEMPTED. Auth tokens live in the keychain
# under a service name derived from the bundle id
# (KeychainStackTokenStore.serviceName(bundleIdentifier:)), so a separate bundle
# cannot see them by construction -- no file copy fixes it, and the codebase
# already documents this for tagged builds: "a tagged build is a separate bundle
# (separate keychain), so it starts signed out" (MacAuthComposition.swift:93-94).
# credentials.json is NOT the token store; on this machine it is an empty {}.
# Expect to sign in to cmux RBF once, by hand.
#
#   rbf/scripts/migrate-rbf-state.sh [--reclone] [--force] [--dry-run]
#
# WHY THIS IS ITS OWN COMMAND, not a branch inside install-rbf.sh:
# install runs on every release, the clone runs once. Braided together there was
# nowhere for recovery to live, so the docs told the user "your RBF is empty,
# here is why, do not re-run to force a clone" -- and then stopped. A documented
# dead end. Splitting them creates the place for the way out.
#
# Note the asymmetry with the installer, which is deliberate: install-rbf.sh
# takes no target flags because aiming it is dangerous. This takes flags because
# re-running it IS the recovery path -- which also means its guards are reachable
# through its real entry point and need no hidden seam to be testable.
#
# WHAT IS NOT COPIED, AND DOES NOT NEED TO BE:
# ~/.config/cmux/cmux.json resolves from $HOME, not the bundle id, so shortcuts,
# customSidebars and sidebarAppearance are already shared by both apps. Only
# bundle-id-scoped state lands here.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rbf/scripts/lib/rbf-install-target.sh
source "$SCRIPT_DIR/lib/rbf-install-target.sh"

RECLONE=0
FORCE=0
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: rbf/scripts/migrate-rbf-state.sh [--reclone] [--force] [--dry-run]

Copy bundle-id-scoped state from upstream's cmux into the RBF channel.
Run with no flags, it copies only stores that are still empty -- so it is safe
after an interrupted first install and does nothing on a healthy one.

Options:
  --reclone   Re-copy stores that are empty. Same as no flags; state it when
              recovering so the intent is on the record.
  --force     Overwrite stores that already hold RBF data. Destructive: it
              replaces workspaces created in RBF since the install.
  --dry-run   Report what each store would do. Writes nothing.
  -h, --help  Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --reclone) RECLONE=1; shift ;;
    --force)   FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

rbf_channel_load "$SCRIPT_DIR/lib" || exit 1
rbf_assert_safe_target || exit 1

APP_SUPPORT="$HOME/Library/Application Support/cmux"
SRC_ID="$UPSTREAM_BUNDLE_ID"
DST_ID="$RBF_BUNDLE_ID"

# The bundle-id-scoped stores. They land independently, so the guard is
# per-store: a half-clone would otherwise refuse the fix while offering only
# --force, which destroys what it protects.
#
# FIVE stores, not three. The session snapshot is the one that actually holds
# your workspaces (SessionSnapshotRepository.swift:168 --
# "$APP_SUPPORT/session-<bundleid>.json"), and an earlier version of this script
# copied closed-item-history-<bundleid>.json from the SAME directory while
# missing it. The install reported "cloned 3/3" and RBF opened with no
# workspaces: a migration that is complete by its own count and wrong in fact.
STORE_LABELS=("UserDefaults domain" "Application Support" "closed-item history" "session snapshot" "session snapshot (prev)")

store_src() {
  case "$1" in
    0) printf '%s' "$SRC_ID" ;;
    1) printf '%s' "$APP_SUPPORT/$SRC_ID" ;;
    2) printf '%s' "$APP_SUPPORT/closed-item-history-$SRC_ID.json" ;;
    3) printf '%s' "$APP_SUPPORT/session-$SRC_ID.json" ;;
    4) printf '%s' "$APP_SUPPORT/session-$SRC_ID-previous.json" ;;
  esac
}
store_dst() {
  case "$1" in
    0) printf '%s' "$DST_ID" ;;
    1) printf '%s' "$APP_SUPPORT/$DST_ID" ;;
    2) printf '%s' "$APP_SUPPORT/closed-item-history-$DST_ID.json" ;;
    3) printf '%s' "$APP_SUPPORT/session-$DST_ID.json" ;;
    4) printf '%s' "$APP_SUPPORT/session-$DST_ID-previous.json" ;;
  esac
}

# "Present" means the destination holds real data, not merely that a path
# exists. An empty domain and a missing domain are the same thing to a user.
store_present() {
  local idx="$1" dst
  dst="$(store_dst "$idx")"
  case "$idx" in
    0) [[ -n "$(defaults read "$dst" 2>/dev/null)" ]] ;;
    1) [[ -d "$dst" ]] && [[ -n "$(ls -A "$dst" 2>/dev/null)" ]] ;;
    *) [[ -s "$dst" ]] ;;
  esac
}
store_src_present() {
  local idx="$1" src
  src="$(store_src "$idx")"
  case "$idx" in
    0) [[ -n "$(defaults read "$src" 2>/dev/null)" ]] ;;
    1) [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null)" ]] ;;
    *) [[ -s "$src" ]] ;;
  esac
}

copy_store() {
  local idx="$1" src dst tmp
  src="$(store_src "$idx")"
  dst="$(store_dst "$idx")"
  case "$idx" in
    0)
      tmp="$(mktemp -t rbf-defaults)" || return 1
      defaults export "$src" "$tmp" || { rm -f "$tmp"; return 1; }
      defaults import "$dst" "$tmp" || { rm -f "$tmp"; return 1; }
      rm -f "$tmp"
      ;;
    1)
      mkdir -p "$(dirname "$dst")" || return 1
      rm -rf "$dst" || return 1
      # ditto preserves resource forks and permissions; cp -R does not.
      ditto "$src" "$dst" || return 1
      ;;
    *)
      mkdir -p "$(dirname "$dst")" || return 1
      ditto "$src" "$dst" || return 1
      ;;
  esac
}

# RBF rewrites its session snapshot when it quits, so copying underneath a
# running app is silently undone. Refuse rather than appear to succeed.
#
# The path comes from the channel record, not a literal: this test was hardcoded
# to "/Applications/cmux RBF.app" while $RBF_INSTALL_PATH was already loaded
# above, so editing the record would have moved the install and left this guard
# watching a path nothing runs from -- it would have passed, always, silently.
# rbf_physical_path matches what the installer's own pgrep uses.
RBF_RUNNING_PATH="$(rbf_physical_path "$RBF_INSTALL_PATH")"
if [[ $DRY_RUN -eq 0 ]] && pgrep -f "$RBF_RUNNING_PATH/Contents/MacOS/" >/dev/null 2>&1; then
  printf 'error: cmux RBF is running — quit it first.\n' >&2
  printf '       It rewrites its session snapshot on quit, which would undo\n' >&2
  printf '       this migration without any error being reported.\n' >&2
  exit 1
fi

printf 'migrate-rbf-state: %s -> %s\n' "$SRC_ID" "$DST_ID"
[[ $DRY_RUN -eq 1 ]] && printf '  (dry run — nothing will be written)\n'
printf '\n'

cloned=0; preserved=0; skipped=0; failed=0
overwrite_list=()

for idx in 0 1 2 3 4; do
  label="${STORE_LABELS[$idx]}"

  if ! store_src_present "$idx"; then
    printf '  skip      %-22s upstream has none to copy\n' "$label"
    skipped=$((skipped + 1))
    continue
  fi

  if store_present "$idx" && [[ $FORCE -eq 0 ]]; then
    printf '  preserve  %-22s RBF already holds data here\n' "$label"
    preserved=$((preserved + 1))
    overwrite_list+=("$label")
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    if store_present "$idx"; then
      printf '  WOULD OVERWRITE %-16s (--force)\n' "$label"
    else
      printf '  would copy %-21s\n' "$label"
    fi
    cloned=$((cloned + 1))
    continue
  fi

  if copy_store "$idx"; then
    printf '  copied    %-22s\n' "$label"
    cloned=$((cloned + 1))
  else
    printf '  FAILED    %-22s see errors above\n' "$label" >&2
    failed=$((failed + 1))
  fi
done

printf '\n'
if [[ $failed -gt 0 ]]; then
  printf 'result: FAILED — %d copied, %d failed. RBF state may be partial.\n' "$cloned" "$failed" >&2
  printf '        Re-run this command; stores that succeeded are left alone.\n' >&2
  exit 1
fi

if [[ ${#overwrite_list[@]} -gt 0 && $RECLONE -eq 1 && $FORCE -eq 0 ]]; then
  printf 'note: %d store(s) were preserved because RBF already holds data:\n' "${#overwrite_list[@]}"
  for label in "${overwrite_list[@]}"; do printf '        - %s\n' "$label"; done
  printf '      That is the guard working. Passing --force would overwrite exactly\n'
  printf '      those, including any workspaces created in RBF since install.\n'
fi

if [[ $DRY_RUN -eq 1 ]]; then
  # Never report a past-tense verb for work that did not happen — this summary
  # is what a later reader quotes as evidence of what the install did.
  printf 'result: would %s (%d to copy, %d preserved, %d skipped) — nothing written\n' \
    "$([[ $RECLONE -eq 1 ]] && echo reclone || echo clone)" "$cloned" "$preserved" "$skipped"
elif [[ $cloned -gt 0 ]]; then
  printf 'result: %s (%d copied, %d preserved, %d skipped)\n' \
    "$([[ $RECLONE -eq 1 ]] && echo recloned || echo cloned)" "$cloned" "$preserved" "$skipped"
else
  printf 'result: preserved (%d preserved, %d skipped) — nothing needed copying\n' "$preserved" "$skipped"
fi
