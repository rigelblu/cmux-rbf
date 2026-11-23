#!/usr/bin/env bash
# rbf-id-match.test.sh — prove the one exact-bundle-id rule (#cm-142.2).
#
#   bash rbf/scripts/lib/rbf-id-match.test.sh
#
# The rule decides which entries under ~/Library/Application Support/cmux/ belong
# to a bundle id. A wrong match there makes the restore remove another app's
# file, so the nested pairs (`<id>` with `<id>.docktileplugin`, `…cm.142` with
# `…cm.142.control`) and the closed extension list are the cases that matter.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rbf/scripts/lib/rbf-testkit.sh
source "$LIB_DIR/rbf-testkit.sh"
# shellcheck source=rbf/scripts/lib/rbf-id-match.sh
source "$LIB_DIR/rbf-id-match.sh"
rbf_test_begin rbf-id-match-test

ID="com.cmuxterm.app.debug.rbf.dogfood"

expect_kind() { # <id> <name> <want> <label>
  local got; got="$(rbf_id_entry_kind "$1" "$2")"
  [[ "$got" == "$3" ]] && ok "$4" || bad "$4" "kind of '$2' for '$1': want $3, got '$got'"
}

printf 'rbf_id_entry_kind: what belongs to the id\n'
expect_kind "$ID" "$ID"                                  match "the bare id (the folder) matches"
expect_kind "$ID" "$ID.json"                             match "<id>.json matches"
expect_kind "$ID" "$ID.sqlite3"                          match "<id>.sqlite3 matches"
expect_kind "$ID" "$ID.sqlite3-shm"                      match "<id>.sqlite3-shm matches"
expect_kind "$ID" "$ID.sqlite3-wal"                      match "<id>.sqlite3-wal matches"
expect_kind "$ID" "session-$ID.json"                     match "session-<id>.json matches"
expect_kind "$ID" "session-$ID-previous.json"            match "session-<id>-previous.json matches (the '-' case)"
expect_kind "$ID" "agent-journal-$ID.sqlite3-wal"        match "agent-journal-<id>.sqlite3-wal matches"
expect_kind "$ID" "closed-item-history-$ID-extra.json"   match "an exact-id file with a '-' suffix matches"
expect_kind "$ID" "notification-feed-history-$ID.json"   match "notification-feed-history-<id>.json matches"
expect_kind "$ID" "restart-commands-state-$ID.json"      match "restart-commands-state-<id>.json matches"
expect_kind "$ID" "restart-command-summaries-$ID.json"   match "restart-command-summaries-<id>.json matches"

printf '\nnested ids: a longer id that only starts with ours is not ours\n'
expect_kind "$ID" "$ID.docktileplugin"                   unknown-kind "<id>.docktileplugin is logged, not matched (nested pair)"
expect_kind "com.cmuxterm.app.debug.cm.142" "com.cmuxterm.app.debug.cm.142.control" unknown-kind "…cm.142.control is not …cm.142's (nested pair)"
expect_kind "com.cmuxterm.app.debug.cm.142.control" "com.cmuxterm.app.debug.cm.142" other "the shorter id is not the longer id's"
expect_kind "$ID" "session-$ID.docktileplugin.json"      unknown-kind "session-<id>.docktileplugin.json is logged, not matched"
expect_kind "$ID" "agent-journal-$ID.control.sqlite3"    unknown-kind "a '.word' before a known extension is an unknown kind"

printf '\nthe id appears, but after a character other than the start or a '-': logged, never kept or removed\n'
expect_kind "$ID" "history_$ID.json"                     unknown-kind "history_<id>.json (a store kind that joins with '_') is logged"
expect_kind "$ID" "backup.$ID.json"                      unknown-kind "backup.<id>.json is logged"
expect_kind "$ID" "session-x$ID.json"                    unknown-kind "session-x<id>.json is logged"
expect_kind "$ID" "org.example.$ID"                      unknown-kind "a name that ends in our id after a '.' is logged"
expect_kind "$ID" "x${ID}x"                              other "the id inside a longer id (alphanumeric on both sides) is another id's"
expect_kind "$ID" "history_${ID}2.json"                  other "an id that runs on into a longer id after an odd prefix is another id's"

printf '\nthe extension list is closed\n'
expect_kind "$ID" "$ID.json.bak"                         unknown-kind "<id>.json.bak is an unknown kind"
expect_kind "$ID" "$ID.JSON"                             unknown-kind "<id>.JSON is an unknown kind (case counts)"
expect_kind "$ID" "$ID.bak"                              unknown-kind "<id>.bak is an unknown kind"
expect_kind "$ID" "session-$ID.bak"                      unknown-kind "session-<id>.bak is an unknown kind"
expect_kind "$ID" "$ID.sqlite3-journal"                  unknown-kind "<id>.sqlite3-journal is an unknown kind"
expect_kind "$ID" "$ID."                                 unknown-kind "<id>. with nothing after the dot is an unknown kind"

printf '\nnot ours at all\n'
expect_kind "$ID" "${ID}x"                               other "<id>x is another id"
expect_kind "$ID" "${ID}2.json"                          other "<id>2.json is another id"
expect_kind "$ID" "${ID}_x"                              unknown-kind "<id>_x: the id, then a character that is neither a '-' nor a '.', is logged"
expect_kind "$ID" "session-com.example.other.json"       other "another app's file"
expect_kind "$ID" "migration-backups"                    other "migration-backups carries no id"
expect_kind "$ID" ""                                     other "an empty name"
expect_kind ""    "session-.json"                        other "an empty id matches nothing"
expect_kind "a.b" "axb.json"                             other "the id is literal text, not a pattern ('.' is a dot)"
expect_kind "a.b" "a.b.json"                             match "a literal dot in the id matches itself"
expect_kind "a+b" "a+b.json"                             match "regex characters in the id are literal"

printf '\nrbf_id_library_entries: what the keep and the restore walk\n'
W="$(rbf_test_world listing)"
HOMEDIR="$W/home"
rbf_test_make_state "$HOMEDIR" "$ID" one saved
rbf_test_make_neighbours "$HOMEDIR" "$ID"
got="$(rbf_id_library_entries "$ID" "$HOMEDIR/Library")"
want="Application Support/cmux/$ID
Application Support/cmux/agent-journal-$ID.sqlite3
Application Support/cmux/agent-journal-$ID.sqlite3-shm
Application Support/cmux/agent-journal-$ID.sqlite3-wal
Application Support/cmux/closed-item-history-$ID.json
Application Support/cmux/notification-feed-history-$ID.json
Application Support/cmux/restart-command-summaries-$ID.json
Application Support/cmux/restart-commands-state-$ID.json
Application Support/cmux/session-$ID.json
Application Support/cmux/session-$ID-previous.json
Application Support/$ID
WebKit/$ID
HTTPStorages/$ID
HTTPStorages/$ID.binarycookies
Saved Application State/$ID.savedState"
[[ "$got" == "$want" ]] && ok "lists exactly the exact-id entries, in the render's order, fixed paths after" \
  || bad "library listing" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got"))"

[[ "$got" != *docktileplugin* && "$got" != *Caches* && "$got" != *other* && "$got" != *.bak* && "$got" != *control* ]] \
  && ok "never lists the nested pair, another app's file, a cache or an unknown kind" \
  || bad "neighbours listed" "$got"

W2="$(rbf_test_world empty)"
got="$(rbf_id_library_entries "$ID" "$W2/home/Library")"
[[ -z "$got" ]] && ok "an empty library lists nothing (absences are not entries)" || bad "empty library" "$got"
got="$(rbf_id_library_entries "$ID" "$W2/home/NoSuchLibrary" 2>&1)"
[[ -z "$got" ]] && ok "a library root that does not exist lists nothing" || bad "missing library" "$got"

printf '\nrbf_id_unknown_entries: what is logged, never kept or removed\n'
got="$(rbf_id_unknown_entries "$ID" "$HOMEDIR/Library")"
want="agent-journal-$ID.control.sqlite3
$ID.docktileplugin
history_$ID.json
session-$ID.bak
session-$ID.docktileplugin.json"
[[ "$got" == "$want" ]] && ok "lists each entry whose name has the id then '.' and an unknown word, by name" \
  || bad "unknown listing" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got"))"

W3="$(rbf_test_world clean)"
rbf_test_make_state "$W3/home" "$ID" one
got="$(rbf_id_unknown_entries "$ID" "$W3/home/Library")"
[[ -z "$got" ]] && ok "a clean library has no unknown kinds" || bad "clean unknown" "$got"

printf '\nrbf_id_library_union: what the restore walks (folder and live together)\n'
WA="$(rbf_test_world unionA)"; WB="$(rbf_test_world unionB)"
rbf_test_make_state "$WA/home" "$ID" one
rbf_test_make_state "$WB/home" "$ID" two saved
printf 'x' > "$WB/home/Library/Application Support/cmux/closed-item-history-$ID-extra.json"
rbf_test_make_neighbours "$WB/home" "$ID"
command rm -f "$WA/home/Library/Application Support/cmux/session-$ID-previous.json"
got="$(rbf_id_library_union "$ID" "$WA/home/Library" "$WB/home/Library")"
want="Application Support/cmux/$ID
Application Support/cmux/agent-journal-$ID.sqlite3
Application Support/cmux/agent-journal-$ID.sqlite3-shm
Application Support/cmux/agent-journal-$ID.sqlite3-wal
Application Support/cmux/closed-item-history-$ID.json
Application Support/cmux/closed-item-history-$ID-extra.json
Application Support/cmux/notification-feed-history-$ID.json
Application Support/cmux/restart-command-summaries-$ID.json
Application Support/cmux/restart-commands-state-$ID.json
Application Support/cmux/session-$ID.json
Application Support/cmux/session-$ID-previous.json
Application Support/$ID
WebKit/$ID
HTTPStorages/$ID
HTTPStorages/$ID.binarycookies
Saved Application State/$ID.savedState"
[[ "$got" == "$want" ]] && ok "the union lists each exact-id entry of either root once, in the render's order, and no neighbour" \
  || bad "library union" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got"))"
got="$(rbf_id_library_union "$ID" "$WA/home/NoLibrary" "$WA/home/AlsoNoLibrary")"
[[ -z "$got" ]] && ok "the union of two absent roots is empty" || bad "empty union" "$got"

rbf_test_finish
