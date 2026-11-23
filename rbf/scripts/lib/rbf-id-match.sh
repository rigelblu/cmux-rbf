#!/usr/bin/env bash
# rbf-id-match.sh — the one rule for "this entry belongs to this bundle id"
# (#cm-142.2). Sourced by rbf-keep-state.sh, so by the install's keep branch
# and by restore-rbf-install.sh; neither restates it. No side effects at source
# time, bash 3.2 compatible.
#
# WHY A RULE AND NOT A LIST. An app writes more under its bundle id than any
# list of stores remembers (the agent journal, the notification history and the
# restart-command state were each added after the first list), so what is kept
# is "everything under the id", and this file says what that means.
#
# EXACTLY THE ID. Bundle ids nest: `com.cmuxterm.app.debug.rbf.dogfood` is the
# start of `…dogfood.docktileplugin`, and `…cm.142` is the start of
# `…cm.142.control`. A name belongs to the id when the id is preceded by the
# start of the name or a `-`, and followed by the end of the name, a `-`, or one
# of the file kinds the app writes under that folder:
#
#     .json   .sqlite3   .sqlite3-shm   .sqlite3-wal
#
# A `.` followed by anything else starts a longer id, or a store kind this list
# does not know; and the id after some other character (`history_<id>.json`) is a
# kind this rule does not know either. Each is `unknown-kind`: the keep logs it and
# leaves it where it is, the restore leaves it alone, so a kind added later shows up
# in the install log instead of going missing from the way back. Only a name whose
# id runs on into a longer id (an alphanumeric right after it) or that lacks the id
# is `other`: another app's. A wrong match here makes the restore remove another
# app's file, so the list is closed on purpose.
#
# The id is literal text everywhere below, never a pattern.

# rbf_id_entry_kind <bundle id> <entry name>
# Prints one of: match | unknown-kind | other
#
#   match         the id follows the start of the name or a '-', and is followed by the
#                 end of the name, a '-', or one of the four file kinds
#   other         the id is not there, or runs on into a longer id (an alphanumeric
#                 right after it): another app's
#   unknown-kind  the id is there, and it is neither of those: `<id>.docktileplugin`,
#                 `history_<id>.json`, `backup.<id>.json`. Logged by the keep, never
#                 kept and never removed, so a store kind this rule does not know yet
#                 shows up instead of going missing
rbf_id_entry_kind() {
  local id="$1" name="$2" head="" tail rest best=other
  if [[ -z "$id" || -z "$name" || "$name" != *"$id"* ]]; then
    printf 'other'
    return 0
  fi
  tail="$name"
  while [[ -n "$tail" ]]; do
    if [[ "$tail" == "$id"* ]]; then
      rest="${tail#"$id"}"
      case "$rest" in
        [A-Za-z0-9]*) ;;
        *)
          if [[ -z "$head" || "$head" == *- ]]; then
            case "$rest" in
              ''|-*|.json|.sqlite3|.sqlite3-shm|.sqlite3-wal) printf 'match'; return 0 ;;
            esac
          fi
          best=unknown-kind ;;
      esac
    fi
    head="$head${tail:0:1}"
    tail="${tail:1}"
  done
  printf '%s' "$best"
}

# The order an entry is shown in. The folder named by the bare id comes first,
# then the files; within the files the order swaps '.' and '-' so
# `session-<id>.json` precedes `session-<id>-previous.json` (the order of the
# renders). One place, so keep, restore and dry-run print the same list.
rbf_id__sort_key() { # <id> <name>
  local k
  if [[ "$2" == "$1" ]]; then printf '0'; return 0; fi
  k="${2//./$'\001'}"; k="${k//-/.}"; k="${k//$'\001'/-}"
  printf '1%s' "$k"
}

# rbf_id__names_under_cmux <library root>: the names directly under
# `Application Support/cmux/`, one per line.
rbf_id__names_under_cmux() {
  local as="$1/Application Support/cmux" f
  [[ -d "$as" ]] || return 0
  for f in "$as"/* "$as"/.[!.]*; do
    [[ -e "$f" || -L "$f" ]] && printf '%s\n' "${f##*/}"
  done
  return 0
}

# rbf_id_library_entries <bundle id> <library root>
# Prints, relative to <library root>, every entry that belongs to the id and
# exists: first those directly under `Application Support/cmux/` that the rule
# says `match`, then the five fixed places. Prints nothing for an absent root.
rbf_id_library_entries() {
  local id="$1" lib="$2" name rel tab
  tab="$(printf '\t')"
  [[ -n "$id" ]] || return 0
  rbf_id__names_under_cmux "$lib" | while IFS= read -r name; do
    [[ "$(rbf_id_entry_kind "$id" "$name")" == match ]] || continue
    printf '%s\t%s\n' "$(rbf_id__sort_key "$id" "$name")" "$name"
  done | LC_ALL=C sort -t "$tab" -k1,1 | while IFS="$tab" read -r _ name; do
    printf 'Application Support/cmux/%s\n' "$name"
  done
  for rel in "Application Support/$id" "WebKit/$id" "HTTPStorages/$id" \
             "HTTPStorages/$id.binarycookies" "Saved Application State/$id.savedState"; do
    if [[ -e "$lib/$rel" || -L "$lib/$rel" ]]; then printf '%s\n' "$rel"; fi
  done
}

# rbf_id_unknown_entries <bundle id> <library root>
# Prints the NAME of each entry directly under `Application Support/cmux/` that
# the rule says is `unknown-kind`, sorted. These are logged, never kept or removed.
rbf_id_unknown_entries() {
  local id="$1" lib="$2" name
  [[ -n "$id" ]] || return 0
  rbf_id__names_under_cmux "$lib" | while IFS= read -r name; do
    [[ "$(rbf_id_entry_kind "$id" "$name")" == unknown-kind ]] && printf '%s\n' "$name"
  done | LC_ALL=C sort
  return 0
}

# rbf_id_library_union <bundle id> <library root A> <library root B>
# The entries of either root, each once, in the same order as above: what the
# restore walks, so an entry only the live state has (to remove) and an entry
# only the kept folder has (to put back) are both on the list.
rbf_id_library_union() {
  local id="$1" a="$2" b="$3" name rel tab
  tab="$(printf '\t')"
  [[ -n "$id" ]] || return 0
  { rbf_id__names_under_cmux "$a"; rbf_id__names_under_cmux "$b"; } | while IFS= read -r name; do
    [[ "$(rbf_id_entry_kind "$id" "$name")" == match ]] || continue
    printf '%s\t%s\n' "$(rbf_id__sort_key "$id" "$name")" "$name"
  done | LC_ALL=C sort -u -t "$tab" -k1,1 | while IFS="$tab" read -r _ name; do
    printf 'Application Support/cmux/%s\n' "$name"
  done
  for rel in "Application Support/$id" "WebKit/$id" "HTTPStorages/$id" \
             "HTTPStorages/$id.binarycookies" "Saved Application State/$id.savedState"; do
    if [[ -e "$a/$rel" || -L "$a/$rel" || -e "$b/$rel" || -L "$b/$rel" ]]; then printf '%s\n' "$rel"; fi
  done
}
