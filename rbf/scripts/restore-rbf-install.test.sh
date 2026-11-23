#!/usr/bin/env bash
# restore-rbf-install.test.sh — drive restore-rbf-install.sh on fixture folders
# (#cm-142.2).
#
#   bash rbf/scripts/restore-rbf-install.test.sh
#
# Every case builds its own world under a sandbox: a HOME, an installed app, the
# state the app wrote under its bundle id, a kept folder shaped as the install's
# keep branch writes it, and a fake `defaults` (RBF_DEFAULTS_BIN) so no test reads
# or writes a real preferences domain. Nothing here touches /Applications, the
# real ~/Library or any real bundle id.
#
# The renders (screen-designs/cm-142/renders-text/04 to 12 and 16) are the output
# contract: the success, dry-run and failed-put-back cases compare whole output,
# with the sample values replaced by the fixture's.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
RESTORE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/restore-rbf-install.sh"
# shellcheck source=rbf/scripts/lib/rbf-testkit.sh
source "$LIB_DIR/rbf-testkit.sh"
# shellcheck source=rbf/scripts/lib/rbf-id-match.sh
source "$LIB_DIR/rbf-id-match.sh"
rbf_test_begin rbf-restore-test

RID="com.example.restoretest"
RNAME="cmux RBF (fx)"
RAPP="$RNAME.app"
KEPT_TS="pre-install-20261124-101503"
SHARED_TS="shared-state-pre-sync-20261123-091500"

# --- world builders -----------------------------------------------------------
# rworld: sets W (the world), KEPT (a kept folder), BK (the backups dir for the
# id), INSTALL (the installed app path). The live state says `two` and the new
# app is 0.35.0; the kept folder says `one` and holds the 0.34.2 app.
rworld() {
  W="$(rbf_test_world restore)"
  INSTALL="$W/apps/$RAPP"
  BK="$W/home/Library/Application Support/cmux/migration-backups/$RID"
  KEPT="$W/store/$KEPT_TS"
  mkdir -p "$KEPT" "$W/home/.cmuxterm" "$W/home/.local/state/cmux"
  printf 'BUNDLE_ID=%s\nINSTALL_PATH=%s\nAPP_NAME=%s\nVERSION=0.34.2\nCOMMIT=acdda8cd1\nDATE=2026-11-24 10:15:03\n' \
    "$RID" "$INSTALL" "$RNAME" > "$KEPT/kept.env"
  printf 'defaults-old' > "$KEPT/defaults.plist"
  rbf_test_make_state "$KEPT" "$RID" one
  rbf_test_make_app "$KEPT/$RAPP" "$RID" 0.34.2 acdda8cd1 old
  mkdir -p "$KEPT/config-cmux"; printf '{"a":1}' > "$KEPT/config-cmux/cmux.json"
  rbf_test_make_state "$W/home" "$RID" two saved
  rbf_test_make_app "$INSTALL" "$RID" 0.35.0 a1b2c3d4e new
  printf '{"a":1}' > "$W/home/.config/cmux/cmux.json"
  printf 'sentinel' > "$W/home/.cmuxterm/sentinel"; printf 'sentinel' > "$W/home/.local/state/cmux/sentinel"
  rbf_test_fake_defaults "$W/bin" "$W/defaults-store"
  printf 'defaults-new' > "$W/defaults-store/$RID.plist"
  # what the new build added, inside the app and inside directory entries: a restore
  # that copies on top of what is live, instead of removing it first, leaves these
  printf 'stale' > "$INSTALL/Contents/Resources/newonly"
  for d in "Application Support/cmux/$RID" "Application Support/$RID" "WebKit/$RID" "HTTPStorages/$RID"; do
    printf 'stale' > "$W/home/Library/$d/newonly"
  done
}
stale_left() { # every new-only file still present, one per line
  local d
  [[ -e "$INSTALL/Contents/Resources/newonly" ]] && printf '%s\n' "$INSTALL/Contents/Resources/newonly"
  for d in "Application Support/cmux/$RID" "Application Support/$RID" "WebKit/$RID" "HTTPStorages/$RID"; do
    [[ -e "$W/home/Library/$d/newonly" ]] && printf '%s\n' "$W/home/Library/$d/newonly"
  done
  return 0
}

# The state of everything a restore may or may not change, minus the folders it
# is allowed to add (pre-restore-*), as one comparable text.
snapshot() {
  { rbf_test_listing "$W/apps" | sed 's/^/apps /'
    rbf_test_listing "$W/home" | grep -v "migration-backups" | sed 's/^/home /'
    rbf_test_listing "$W/defaults-store" | sed 's/^/defaults /'
    rbf_test_listing "$W/store" | sed 's/^/store /'
  }
}

# Run the script for real. Sets RC; output in $W/out and $W/err and $W/all.
run_restore() {
  ( cd "$W" && HOME="$W/home" RBF_DEFAULTS_BIN="$W/bin/defaults" bash "$RESTORE" "$@" > "$W/out" 2> "$W/err" ); RC=$?
}
run_restore_combined() {
  ( cd "$W" && HOME="$W/home" RBF_DEFAULTS_BIN="$W/bin/defaults" bash "$RESTORE" "$@" > "$W/all" 2>&1 ); RC=$?
}
# Run it sourced, after eval'ing $SEAMS, so a seam can be replaced.
run_restore_sourced() {
  (
    export HOME="$W/home" RBF_DEFAULTS_BIN="$W/bin/defaults"
    # shellcheck disable=SC1090
    source "$RESTORE"
    eval "${SEAMS:-:}"
    rbf_restore_main "$@" > "$W/out" 2> "$W/err"
  ); RC=$?
}

norm() { sed -E 's/pre-restore-[0-9]{8}-[0-9]{6}(-[0-9]+)?/pre-restore-TS/g'; }
# The put-back rows of the render, for the world's id and install path.
put_rows() {
  cat <<ROWS
  put back  Application Support/cmux/<id>/
  put back  Application Support/cmux/agent-journal-<id>.sqlite3
  put back  Application Support/cmux/agent-journal-<id>.sqlite3-shm
  put back  Application Support/cmux/agent-journal-<id>.sqlite3-wal
  put back  Application Support/cmux/closed-item-history-<id>.json
  put back  Application Support/cmux/notification-feed-history-<id>.json
  put back  Application Support/cmux/restart-command-summaries-<id>.json
  put back  Application Support/cmux/restart-commands-state-<id>.json
  put back  Application Support/cmux/session-<id>.json
  put back  Application Support/cmux/session-<id>-previous.json
  put back  Application Support/<id>/
  put back  WebKit/<id>/
  put back  HTTPStorages/<id>/
  put back  HTTPStorages/<id>.binarycookies
ROWS
}
head_lines() { # the self-check block, as printed by a restore and a dry run alike
  cat <<HEAD
⋯ checking the folder against itself
  app          $RAPP, 0.34.2 (acdda8cd1)
  bundle id    $RID, written <id> below
  kept         2026-11-24 10:15:03
⋯ keeping what this replaces in pre-restore-TS
⋯ putting back the app and its state, as they were when it quit
  put back  $INSTALL
  put back  defaults <id>
  in ~/Library:
HEAD
}
lib_state() { # the live entries as a comparable text: path, then content
  local rel; rbf_id_library_entries "$RID" "$W/home/Library" | while IFS= read -r rel; do
    printf '%s => %s\n' "$rel" "$(cat "$W/home/Library/$rel/marker" 2>/dev/null || cat "$W/home/Library/$rel" 2>/dev/null)"
  done
}

# =============================================================================
printf 'success (render 04)\n'
rworld
printf '{"a":2}' > "$W/home/.config/cmux/cmux.json"
mkdir -p "$W/home/Library/Application Support/cmux/migration-backups/$SHARED_TS/config-cmux"
printf '{"a":0}' > "$W/home/Library/Application Support/cmux/migration-backups/$SHARED_TS/config-cmux/cmux.json"
SHARED="$W/home/Library/Application Support/cmux/migration-backups/$SHARED_TS"
before_cfg="$(shasum < "$W/home/.config/cmux/cmux.json")"
before_shared="$(rbf_test_listing "$SHARED")"
before_kept="$(rbf_test_listing "$KEPT")"
before_sent="$(rbf_test_listing "$W/home/.cmuxterm"; rbf_test_listing "$W/home/.local/state/cmux")"
live_before="$(rbf_test_listing "$W/home/Library" | grep -v migration-backups)"
run_restore "$KEPT"; rc1=$RC

want="$(head_lines; put_rows)
  removed   Saved Application State/<id>.savedState (the folder has none)
  note: ~/.config/cmux/cmux.json has changed since this folder was kept.
        It was left as it is. The copy kept then is config-cmux/cmux.json
        in the folder above.
  note: the shared state from before the sync's first launch is kept in
        the folder below, and was left as it is. Its cmux.json differs from
        today's too.
$SHARED

✓ restored $RNAME 0.34.2 (acdda8cd1), as it was when it quit
  what it replaced, 0.35.0 (a1b2c3d4e), with its state, is kept in:
$BK/pre-restore-TS
  Restore that folder to go forward again. The app was not opened."
if [[ $RC -eq 0 && "$(norm < "$W/out")" == "$want" && ! -s "$W/err" ]]; then
  ok "output matches render 04: self-check, pre-restore step, put-back rows, removed row, both notes, result block, folder paths whole"
else
  bad "output (render 04)" "rc=$RC err=$(cat "$W/err") $(diff <(printf '%s\n' "$want") <(norm < "$W/out"))"
fi
if [[ "$(cat "$INSTALL/Contents/Resources/marker")" == old && "$(cat "$W/defaults-store/$RID.plist")" == defaults-old \
      && "$(lib_state | grep -vc '=> one$')" == 0 && -z "$(ls -d "$W/home/Library/Saved Application State/$RID.savedState" 2>/dev/null)" ]]; then
  ok "the old app is back, the defaults domain is back, every exact-id entry reads 'one', the saved state the folder lacks is gone"
else
  bad "success postconditions" "app=$(cat "$INSTALL/Contents/Resources/marker") defaults=$(cat "$W/defaults-store/$RID.plist") state=$(lib_state | grep -v '=> one$')"
fi
if [[ $rc1 -eq 0 && -z "$(stale_left)" ]]; then
  ok "what the new build added inside the app and inside each directory entry is gone after the restore (remove, then copy: not copy on top)"
else
  bad "stale files survive a restore" "rc=$rc1 left: $(stale_left)"
fi
PR="$(ls -d "$BK"/pre-restore-* 2>/dev/null | tail -1)"
if [[ "$(ls -d "$BK"/pre-restore-* 2>/dev/null | wc -l | tr -d ' ')" == 1 && -d "$PR" \
      && "$(cat "$PR/$RAPP/Contents/Resources/marker" 2>&1)" == new && "$(cat "$PR/defaults.plist" 2>&1)" == defaults-new \
      && "$(cat "$PR/Library/WebKit/$RID/marker" 2>&1)" == two && -d "$PR/Library/Saved Application State/$RID.savedState" \
      && -f "$PR/kept.env" && -f "$PR/config-cmux/cmux.json" ]] \
   && grep -qxF "VERSION=0.35.0" "$PR/kept.env" && grep -qxF "COMMIT=a1b2c3d4e" "$PR/kept.env" && grep -qxF "BUNDLE_ID=$RID" "$PR/kept.env"; then
  ok "one pre-restore-* folder under migration-backups/<id>/ holds the replaced app, defaults, state (savedState too), config copy and a kept.env"
else
  bad "pre-restore folder" "$(ls -R "$BK" 2>&1 | head -20)"
fi
if [[ $rc1 -eq 0 && "$before_kept" == "$(rbf_test_listing "$KEPT")" ]]; then ok "the folder restored from is unchanged, byte for byte"
else bad "kept folder changed" "$(diff <(printf '%s\n' "$before_kept") <(rbf_test_listing "$KEPT"))"; fi
if [[ $rc1 -eq 0 && "$before_cfg" == "$(shasum < "$W/home/.config/cmux/cmux.json")" && "$before_shared" == "$(rbf_test_listing "$SHARED")" \
      && "$before_sent" == "$(rbf_test_listing "$W/home/.cmuxterm"; rbf_test_listing "$W/home/.local/state/cmux")" ]]; then
  ok "never writes ~/.config/cmux, ~/.cmuxterm, ~/.local/state/cmux or the shared-state copy"
else
  bad "shared state written" "cfg/shared/sentinels changed"
fi

# the round trip: restoring the pre-restore folder returns to the build left
run_restore "$PR"; rc2=$RC
after_roundtrip="$(rbf_test_listing "$W/home/Library" | grep -v migration-backups)"
if [[ $rc2 -eq 0 && "$(cat "$INSTALL/Contents/Resources/marker")" == new && "$(cat "$W/defaults-store/$RID.plist")" == defaults-new \
      && "$live_before" == "$after_roundtrip" && "$(stale_left | wc -l | tr -d ' ')" == 5 ]]; then
  ok "restoring the pre-restore folder returns to the build left: app, defaults and every entry as before (savedState included)"
else
  bad "round trip" "rc=$rc2 app=$(cat "$INSTALL/Contents/Resources/marker") $(diff <(printf '%s\n' "$live_before") <(printf '%s\n' "$after_roundtrip") | head -10)"
fi

# =============================================================================
printf '\nsecond restore, dry run, absences\n'
rworld
run_restore "$KEPT"; first_rc=$RC; first_state="$(lib_state)"; first_app="$(cat "$INSTALL/Contents/Resources/marker")"
before_kept="$(rbf_test_listing "$KEPT")"
run_restore "$KEPT"
if [[ $first_rc -eq 0 && $RC -eq 0 && "$(lib_state)" == "$first_state" && "$(cat "$INSTALL/Contents/Resources/marker")" == "$first_app" \
      && "$before_kept" == "$(rbf_test_listing "$KEPT")" ]]; then
  ok "a second restore of the same folder exits 0 with the same result, and the folder is unchanged"
else
  bad "second restore" "first=$first_rc second=$RC"
fi

rworld
snap="$(snapshot)"; n_before="$(ls "$W/home/Library/Application Support/cmux/migration-backups" 2>&1 | wc -l | tr -d ' ')"
run_restore "$KEPT" --dry-run
want="⋯ --dry-run: the lines a restore would print. Nothing is changed
$(head_lines; put_rows)
  removed   Saved Application State/<id>.savedState (the folder has none)

--dry-run: nothing was changed."
if [[ $RC -eq 0 && "$(norm < "$W/out")" == "$want" && "$snap" == "$(snapshot)" && ! -e "$BK" ]]; then
  ok "--dry-run prints the render 05 lines, ends '--dry-run: nothing was changed.', and changes no listing (no pre-restore folder either)"
else
  bad "dry run (render 05)" "rc=$RC $(diff <(printf '%s\n' "$want") <(norm < "$W/out")) bk=$(ls "$BK" 2>&1)"
fi
rworld; snap="$(snapshot)"
run_restore --dry-run "$KEPT"
[[ $RC -eq 0 && "$snap" == "$(snapshot)" ]] && ok "--dry-run may come before the folder" || bad "dry run before folder" "rc=$RC"

# absences and an extra entry: no current app, one live file gone, one extra live file
rworld
command rm -rf "${INSTALL:?}" "${W:?}/home/Library/Application Support/cmux/notification-feed-history-$RID.json" \
               "${W:?}/home/Library/Application Support/cmux/restart-command-summaries-$RID.json"
printf 'extra' > "$W/home/Library/Application Support/cmux/closed-item-history-$RID-extra.json"
run_restore "$KEPT"
PR="$(ls -d "$BK"/pre-restore-* 2>/dev/null | tail -1)"
if [[ $RC -eq 0 && "$(cat "$INSTALL/Contents/Resources/marker" 2>&1)" == old \
      && "$(cat "$W/home/Library/Application Support/cmux/notification-feed-history-$RID.json" 2>&1)" == one \
      && "$(cat "$W/home/Library/Application Support/cmux/restart-command-summaries-$RID.json" 2>&1)" == one \
      && ! -e "$W/home/Library/Application Support/cmux/closed-item-history-$RID-extra.json" \
      && "$(cat "$PR/Library/Application Support/cmux/closed-item-history-$RID-extra.json" 2>&1)" == extra \
      && ! -e "$PR/$RAPP" ]]; then
  ok "absences are not failures: the app and the two missing files come back, the extra exact-id file is removed and kept in the pre-restore folder"
else
  bad "absences" "rc=$RC out=$(cat "$W/out") err=$(cat "$W/err")"
fi
if grep -q "^  removed   Application Support/cmux/closed-item-history-<id>-extra.json (the folder has none)$" "$W/out" \
   && grep -q "what it replaced, no app was installed, with its state, is kept in:" "$W/out"; then
  ok "...the removed row and the 'no app was installed' wording are printed"
else
  bad "absence wording" "$(cat "$W/out")"
fi

# neighbours: the nested pair, another app, a cache, an unknown kind
rworld; rbf_test_make_neighbours "$W/home" "$RID"
nb_before="$(rbf_test_listing "$W/home/Library" | grep -E "docktileplugin|control|other|Caches|\.bak|history_")"
run_restore "$KEPT"
nb_after="$(rbf_test_listing "$W/home/Library" | grep -E "docktileplugin|control|other|Caches|\.bak|history_")"
if [[ $RC -eq 0 && -n "$nb_before" && "$nb_before" == "$nb_after" ]]; then
  ok "the nested-id pair, another app's file, the cache and an unknown kind are left exactly as they were"
else
  bad "neighbours touched by the restore" "rc=$RC $(diff <(printf '%s\n' "$nb_before") <(printf '%s\n' "$nb_after"))"
fi

# cmux.json notes
rworld; run_restore "$KEPT"
if [[ $RC -eq 0 ]] && ! grep -q "cmux.json" "$W/out" && ! grep -q "shared state" "$W/out"; then
  ok "cmux.json unchanged and no shared-state copy: neither note is printed"
else
  bad "no notes" "$(cat "$W/out")"
fi
rworld
mkdir -p "$W/home/Library/Application Support/cmux/migration-backups/$SHARED_TS/config-cmux"
printf '{"a":1}' > "$W/home/Library/Application Support/cmux/migration-backups/$SHARED_TS/config-cmux/cmux.json"
run_restore "$KEPT"
if [[ $RC -eq 0 ]] && grep -q "the shared state from before the sync's first launch is kept in" "$W/out" \
   && grep -qxF "$W/home/Library/Application Support/cmux/migration-backups/$SHARED_TS" "$W/out" \
   && ! grep -q "differs from today's" "$W/out" && ! grep -q "has changed since this folder was kept" "$W/out"; then
  ok "a shared-state copy that exists is named, path whole; no 'differs' sentence when its cmux.json matches"
else
  bad "shared copy, same json" "$(cat "$W/out")"
fi
rworld
mkdir -p "$W/home/Library/Application Support/cmux/migration-backups/$SHARED_TS/config-cmux"
printf '{"a":0}' > "$W/home/Library/Application Support/cmux/migration-backups/$SHARED_TS/config-cmux/cmux.json"
run_restore "$KEPT"
if grep -qx "        today's\." "$W/out" && grep -q "Its cmux.json differs from$" "$W/out" && ! grep -q "today's too" "$W/out"; then
  ok "a differing shared-state copy says so ('differs from today's.' with no 'too' when the kept copy matches)"
else
  bad "shared copy differs" "$(cat "$W/out")"
fi

# =============================================================================
printf '\nrefusals (renders 06 to 12): each says error:, Nothing was changed., and changes no listing\n'
refusal_check() { # <label> <want rc> <stderr must contain> [more contains...]
  local label="$1" want_rc="$2" needle; shift 2
  local after; after="$(snapshot)"
  if [[ $RC -eq $want_rc && "$after" == "$SNAP" && ! -e "$BK" ]] \
     && grep -q '^error: ' "$W/err" && grep -q 'Nothing was changed\.' "$W/err"; then
    for needle in "$@"; do
      grep -qF -- "$needle" "$W/err" || { bad "$label" "stderr lacks '$needle': $(cat "$W/err")"; return; }
    done
    ok "$label"
  else
    bad "$label" "rc=$RC (want $want_rc) listing-same=$([[ "$after" == "$SNAP" ]] && echo yes || echo no) pre-restore=$(ls -d "$BK"/pre-restore-* 2>&1 | head -2) err=$(cat "$W/err")"
  fi
}

rworld; SNAP="$(snapshot)"; run_restore
want="error: no kept folder given. Nothing was changed.
       usage: rbf/scripts/restore-rbf-install.sh \"<kept folder>\" [--dry-run]
       Paste one folder this line lists, whole, in quotes:
ls -d \"\$HOME/Library/Application Support/cmux/migration-backups/\"*/pre-*"
[[ "$(cat "$W/err")" == "$want" && -z "$(cat "$W/out")" ]] && refusal_check "no argument: render 06 text exactly, exit 2" 2 \
  || bad "no argument (render 06)" "rc=$RC $(diff <(printf '%s\n' "$want") "$W/err")"

rworld; SNAP="$(snapshot)"; run_restore ""
want="error: the kept folder is an empty string. Nothing was changed.
       A list that matched nothing passes \"\". Paste one folder this line
       lists, whole, in quotes:
ls -d \"\$HOME/Library/Application Support/cmux/migration-backups/\"*/pre-*"
[[ "$(cat "$W/err")" == "$want" ]] && refusal_check "an empty argument: render 07 text exactly, exit 2" 2 \
  || bad "empty argument (render 07)" "rc=$RC $(diff <(printf '%s\n' "$want") "$W/err")"

rworld; SNAP="$(snapshot)"; run_restore "$KEPT" --bogus
refusal_check "an unknown option is refused, exit 2" 2 "--bogus"
rworld; SNAP="$(snapshot)"; run_restore "$KEPT" "$KEPT"
refusal_check "two folders are refused, exit 2" 2 "one kept folder"

rworld; SNAP="$(snapshot)"; command rm -f "${KEPT:?}/defaults.plist"; SNAP="$(snapshot)"; run_restore "$KEPT"
want="error: not a kept folder: it has no defaults.plist. Nothing was changed.
       A kept folder holds kept.env, defaults.plist, Library/ and the app.
       The folder given:
$KEPT"
[[ "$(cat "$W/err")" == "$want" ]] && refusal_check "a folder without defaults.plist: render 08 text exactly, exit 1" 1 \
  || bad "no defaults.plist (render 08)" "rc=$RC $(diff <(printf '%s\n' "$want") "$W/err")"

rworld; SNAP="$(snapshot)"; run_restore "$W/store/does-not-exist"
refusal_check "a folder that does not exist is refused" 1 "not a kept folder" "does-not-exist"
rworld; command rm -f "${KEPT:?}/kept.env"; SNAP="$(snapshot)"; run_restore "$KEPT"
refusal_check "a folder without kept.env is refused" 1 "not a kept folder" "kept.env"
rworld; command rm -rf "${KEPT:?}/$RAPP"; SNAP="$(snapshot)"; run_restore "$KEPT"
refusal_check "a folder without the app bundle is refused" 1 "not a kept folder" ".app"

rworld; N="$RAPP" perl -pi -e 's/\Q$ENV{N}\E$/x.txt/' "$KEPT/kept.env"; SNAP="$(snapshot)"; run_restore "$KEPT"
want="error: the folder doesn't match its own record. Nothing was changed.
       kept.env's install path is $W/apps/x.txt, which doesn't end
       in .app."
[[ "$(cat "$W/err")" == "$want" ]] && refusal_check "an install path that does not end in .app: render 09 text exactly, exit 1" 1 \
  || bad "install path not .app (render 09)" "rc=$RC $(diff <(printf '%s\n' "$want") "$W/err")"

rworld
W="$W" perl -pi -e 's/^INSTALL_PATH=.*$/INSTALL_PATH=$ENV{W}\/apps\/Other Name.app/' "$KEPT/kept.env"; SNAP="$(snapshot)"; run_restore "$KEPT"
refusal_check "an install path whose last part is not the kept app's name is refused" 1 "doesn't match its own record" "Other Name.app" "$RAPP"

rworld; /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.example.s21other' "$KEPT/$RAPP/Contents/Info.plist"; SNAP="$(snapshot)"; run_restore "$KEPT"
refusal_check "a kept app whose CFBundleIdentifier is not the recorded id is refused" 1 "doesn't match its own record" "com.example.s21other" "$RID"

rworld; ID="$RID" perl -pi -e 's/\Q$ENV{ID}\E$/com.cmuxterm.app/' "$KEPT/kept.env"; SNAP="$(snapshot)"; run_restore "$KEPT"
want="error: this folder records upstream's app, com.cmuxterm.app. The restore
       never writes upstream's app or its state. Nothing was changed."
[[ "$(cat "$W/err")" == "$want" ]] && refusal_check "a kept.env that records upstream's id: render 10 text exactly, exit 1" 1 \
  || bad "upstream id (render 10)" "rc=$RC $(diff <(printf '%s\n' "$want") "$W/err")"

rworld; W="$W" perl -pi -e 's/^INSTALL_PATH=.*$/INSTALL_PATH=\/Applications\/cmux.app/' "$KEPT/kept.env"; SNAP="$(snapshot)"; run_restore "$KEPT"
want="error: this folder records upstream's app, /Applications/cmux.app. The restore
       never writes upstream's app or its state. Nothing was changed."
[[ "$(cat "$W/err")" == "$want" ]] && refusal_check "a kept.env whose install path is upstream's app is refused the same way (exact text)" 1 \
  || bad "upstream path" "rc=$RC $(diff <(printf '%s\n' "$want") "$W/err")"
rworld; W="$W" perl -pi -e 's/^INSTALL_PATH=.*$/INSTALL_PATH=\/Applications\/cmux.app\/Contents\/Inner.app/' "$KEPT/kept.env"; SNAP="$(snapshot)"; run_restore "$KEPT"
refusal_check "...and so is a path inside upstream's app, said as inside" 1 "upstream's app" "inside"

rworld; command rm -rf "${INSTALL:?}"; rbf_test_make_app "$INSTALL" com.example.other 9.9 zzz other; SNAP="$(snapshot)"; run_restore "$KEPT"
want="error: a different app is at $INSTALL.
       Its bundle id is com.example.other, and this folder is for
       $RID.
       Move that app away first. Nothing was changed."
[[ "$(cat "$W/err")" == "$want" ]] && refusal_check "a different app at the install path: render 11 text exactly, exit 1" 1 \
  || bad "different app (render 11)" "rc=$RC $(diff <(printf '%s\n' "$want") "$W/err")"

# the app running, through rbf_app_running's seam (render 12)
rworld; SNAP="$(snapshot)"; SEAMS='rbf_app_running() { return 0; }'; run_restore_sourced "$KEPT"
want="error: $RNAME is running. Nothing was changed.
       Quit it, then run this line from Terminal, not from one of its panes:
       quitting the app ends every shell in it, this one included."
[[ "$(cat "$W/err")" == "$want" ]] && refusal_check "the app running: render 12 text exactly, names Terminal, exit 1" 1 "Terminal" \
  || bad "app running (render 12)" "rc=$RC $(diff <(printf '%s\n' "$want") "$W/err")"
rworld; SNAP="$(snapshot)"; SEAMS='rbf_app_running() { return 1; }'; run_restore_sourced "$KEPT"
[[ $RC -eq 0 && "$(cat "$INSTALL/Contents/Resources/marker")" == old ]] \
  && ok "the same sourced run with the app not running restores (control for the seam)" || bad "running seam control" "rc=$RC err=$(cat "$W/err")"
rworld; SNAP="$(snapshot)"; SEAMS='rbf_app_running() { return 0; }'; run_restore_sourced "$KEPT" --dry-run
refusal_check "a dry run refuses while the app runs too" 1 "is running"

# the app running, for real: a copy of /bin/sleep inside the fixture app
rworld; SNAP=""
mkdir -p "$INSTALL/Contents/MacOS"; command cp -f /bin/sleep "$INSTALL/Contents/MacOS/cmuxfx"
if codesign -s - -f "$INSTALL/Contents/MacOS/cmuxfx" 2>/dev/null; then
  "$INSTALL/Contents/MacOS/cmuxfx" 30 & SLEEPER=$!
  sleep 0.4
  SNAP="$(snapshot)"; run_restore "$KEPT"
  kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null
  refusal_check "a real process running from the install path is found by its executable and refused" 1 "is running"
else
  skipped "a real process running from the install path" "codesign -s - failed here; the seam case above still ran"
fi

# =============================================================================
printf '\na failure partway puts everything back (render 16)\n'
if [[ "$(id -u)" == 0 ]]; then
  skipped "failure partway" "running as root: chmod 000 would not stop ditto"
else
  rworld
  chmod 000 "$KEPT/Library/WebKit/$RID/marker"
  command rm -f "${W:?}/home/Library/Application Support/cmux/restart-command-summaries-$RID.json"
  snap="$(snapshot)"; n0="$(ls -d "$BK"/pre-restore-* 2>/dev/null | wc -l | tr -d ' ')"
  run_restore_combined "$KEPT"
  PF="$(ls -d "$BK"/pre-restore-* 2>/dev/null | tail -1)"
  if [[ $RC -eq 1 && "$snap" == "$(snapshot)" ]]; then
    ok "exits 1 and the app, defaults, state and absences are exactly as before it ran (listing byte-identical, the missing file still missing)"
  else
    bad "failure partway: nothing changed" "rc=$RC $(diff <(printf '%s\n' "$snap") <(snapshot) | head -10)"
  fi
  want="$(head_lines)
  put back  Application Support/cmux/<id>/
  put back  Application Support/cmux/agent-journal-<id>.sqlite3
  put back  Application Support/cmux/agent-journal-<id>.sqlite3-shm
  put back  Application Support/cmux/agent-journal-<id>.sqlite3-wal
  put back  Application Support/cmux/closed-item-history-<id>.json
  put back  Application Support/cmux/notification-feed-history-<id>.json
  put back  Application Support/cmux/restart-command-summaries-<id>.json
  put back  Application Support/cmux/restart-commands-state-<id>.json
  put back  Application Support/cmux/session-<id>.json
  put back  Application Support/cmux/session-<id>-previous.json
  put back  Application Support/<id>/
error: couldn't put back WebKit/<id>/: ditto: WebKit/<id>/marker: Permission denied
⋯ undoing, from pre-restore-TS
  undone    $INSTALL
  undone    defaults <id>
  in ~/Library:
  undone    Application Support/cmux/<id>/
  undone    Application Support/cmux/agent-journal-<id>.sqlite3
  undone    Application Support/cmux/agent-journal-<id>.sqlite3-shm
  undone    Application Support/cmux/agent-journal-<id>.sqlite3-wal
  undone    Application Support/cmux/closed-item-history-<id>.json
  undone    Application Support/cmux/notification-feed-history-<id>.json
  undone    Application Support/cmux/restart-command-summaries-<id>.json
  undone    Application Support/cmux/restart-commands-state-<id>.json
  undone    Application Support/cmux/session-<id>.json
  undone    Application Support/cmux/session-<id>-previous.json
  undone    Application Support/<id>/

✗ not restored: the app and its state are as they were before this ran
  The app is still 0.35.0 (a1b2c3d4e). The copy taken before this ran is in:
$BK/pre-restore-TS"
  got="$(norm < "$W/all")"
  if [[ "$got" == "$want" ]]; then
    ok "output matches render 16: put-back rows up to the failure, error naming the item, undoing, undone rows in order, ✗ not restored, folder path whole"
  else
    bad "failure output (render 16)" "$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got"))"
  fi
  if [[ "$(grep -c '^error:' "$W/all")" == 1 && "$(grep -c '^  put back  ' "$W/all")" -ge 1 && "$(ls -d "$BK"/pre-restore-* | wc -l | tr -d ' ')" == $((n0 + 1)) \
        && "$(cat "$PF/$RAPP/Contents/Resources/marker")" == new && "$(tail -1 "$W/all")" == "$PF" ]]; then
    ok "...one new pre-restore folder is kept, holds the replaced app, and its path is the last line"
  else
    bad "failure keeps the pre-restore folder" "n=$(ls -d "$BK"/pre-restore-* | wc -l) PF=$PF tail=$(tail -1 "$W/all")"
  fi
  chmod 644 "$KEPT/Library/WebKit/$RID/marker"

  # failure at the very first item: the app itself can't be read
  rworld
  chmod 000 "$KEPT/$RAPP/Contents/Resources/marker"
  snap="$(snapshot)"
  run_restore_combined "$KEPT"
  if [[ $RC -eq 1 && "$snap" == "$(snapshot)" ]] && grep -q "^error: couldn't put back $INSTALL: " "$W/all" \
     && grep -q '^✗ not restored' "$W/all" && ! grep -q '^  put back  ' "$W/all" && ! grep -q '^  undone    ' "$W/all"; then
    ok "a failure at the first item (the app) undoes the half-copied app: listing identical, no put-back or undone rows"
  else
    bad "failure at the first item" "rc=$RC $(diff <(printf '%s\n' "$snap") <(snapshot) | head -10) out=$(cat "$W/all")"
  fi
  chmod 644 "$KEPT/$RAPP/Contents/Resources/marker"

  # the undo failing too: ditto from a pre-restore folder fails
  rworld
  chmod 000 "$KEPT/Library/WebKit/$RID/marker"
  SEAMS='rbf_keep_ditto() { case "$1" in *"/pre-restore-"*) echo "ditto: undo boom" >&2; return 1 ;; esac; ditto "$@"; }'
  run_restore_sourced "$KEPT"
  PF="$(ls -d "$BK"/pre-restore-* 2>/dev/null | tail -1)"
  if [[ $RC -eq 1 && -d "$PF" && "$(cat "$PF/$RAPP/Contents/Resources/marker")" == new ]] \
     && grep -q '^error: the undo failed at ' "$W/err" && grep -q "holds all of what it replaced" "$W/err"; then
    ok "if the undo fails too: 'error: the undo failed at <item>', the pre-restore folder is kept and said to hold what was replaced, exit 1"
  else
    bad "undo failure" "rc=$RC out=$(cat "$W/out") err=$(cat "$W/err")"
  fi
  chmod 644 "$KEPT/Library/WebKit/$RID/marker"
fi

# =============================================================================
printf '\nfix round 1: removal, SIGPIPE, plan, interruption (cold review of 7ea1eb8261)\n'

# --- a failed removal is never ignored ----------------------------------------
# A directory the owner can't write (mode 555) is made writable by the restore, which
# is replacing it anyway: it restores, and nothing stale is left.
rworld
mkdir -p "$INSTALL/Contents/Locked"; echo stale > "$INSTALL/Contents/Locked/newonly"; chmod 555 "$INSTALL/Contents/Locked"
mkdir -p "$W/home/Library/WebKit/$RID/Locked"; echo stale > "$W/home/Library/WebKit/$RID/Locked/newonly"; chmod 555 "$W/home/Library/WebKit/$RID/Locked"
run_restore "$KEPT"
if [[ $RC -eq 0 && "$(cat "$INSTALL/Contents/Resources/marker")" == old && ! -e "$INSTALL/Contents/Locked" \
      && ! -e "$W/home/Library/WebKit/$RID/Locked" && -z "$(stale_left)" ]]; then
  ok "a mode-555 directory inside the live app and inside a live entry does not stop the restore, and is gone afterwards"
else
  bad "mode 555 directories" "rc=$RC app=$(cat "$INSTALL/Contents/Resources/marker" 2>&1) locked=$(ls -d "$INSTALL/Contents/Locked" "$W/home/Library/WebKit/$RID/Locked" 2>&1) err=$(cat "$W/err")"
fi
chmod -R u+w "$W" 2>/dev/null

# A removal that cannot be done (an immutable file) is a failure: it is never ignored,
# nothing is copied on top of a half-removed entry, and everything is put back.
for where in app entry; do
  rworld
  if [[ $where == app ]]; then target="$INSTALL/Contents/Resources/locked-file"; else target="$W/home/Library/WebKit/$RID/locked-file"; fi
  echo locked > "$target"
  if chflags uchg "$target" 2>/dev/null; then
    snap="$(snapshot)"
    run_restore_combined "$KEPT"
    chflags -R nouchg "$W" 2>/dev/null
    after="$(snapshot)"
    if [[ $RC -eq 1 && "$snap" == "$after" && "$(cat "$INSTALL/Contents/Resources/marker")" == new ]] \
       && grep -q "^error: " "$W/all" && ! grep -q '^✓ restored' "$W/all"; then
      ok "an immutable file inside the live $where makes the restore fail (exit 1, no ✓ restored), and the live state is exactly as before"
    else
      bad "failed removal ignored ($where)" "rc=$RC out=$(tail -12 "$W/all") $(diff <(printf '%s\n' "$snap") <(printf '%s\n' "$after") | head -10)"
    fi
  else
    chflags -R nouchg "$W" 2>/dev/null
    skipped "an immutable file inside the live $where" "chflags uchg is not allowed here"
  fi
  chflags -R nouchg "$W" 2>/dev/null; chmod -R u+w "$W" 2>/dev/null
done

# --- SIGPIPE can't kill a restore halfway --------------------------------------
# The reader going away does not stop the restore: printing is best effort once things
# change, and the restore runs to the end. The result is the full restore, never a mix.
rworld
( cd "$W" && HOME="$W/home" RBF_DEFAULTS_BIN="$W/bin/defaults" /bin/bash "$RESTORE" "$KEPT" 2>/dev/null | head -8 >/dev/null )
sleep 0.5
PRP="$(ls -d "$BK"/pre-restore-* 2>/dev/null | tail -1)"
if [[ "$(cat "$INSTALL/Contents/Resources/marker")" == old && "$(lib_state | grep -vc '=> one$')" == 0 \
      && "$(cat "$W/defaults-store/$RID.plist")" == defaults-old && -z "$(stale_left)" && -f "$PRP/kept.env" ]]; then
  ok "restore | head -8: the reader goes away and the restore still finishes, whole: app, defaults and every entry restored, the pre-restore folder complete"
else
  bad "SIGPIPE mid-restore" "app=$(cat "$INSTALL/Contents/Resources/marker") state=$(lib_state | grep -v '=> one$' | head -3) defaults=$(cat "$W/defaults-store/$RID.plist") pre=$PRP"
fi
# and when it does fail with the reader gone, the undo still runs
if [[ "$(id -u)" != 0 ]]; then
  rworld
  chmod 000 "$KEPT/Library/WebKit/$RID/marker"; snap="$(snapshot)"
  ( cd "$W" && HOME="$W/home" RBF_DEFAULTS_BIN="$W/bin/defaults" /bin/bash "$RESTORE" "$KEPT" 2>/dev/null | head -3 >/dev/null )
  sleep 0.5
  if [[ "$snap" == "$(snapshot)" ]]; then
    ok "a failing restore whose reader has gone away still undoes everything (listing identical)"
  else
    bad "undo after SIGPIPE" "$(diff <(printf '%s\n' "$snap") <(snapshot) | head -6)"
  fi
  chmod 644 "$KEPT/Library/WebKit/$RID/marker"
fi

# --- a kept folder inside what the restore replaces -----------------------------
rworld
INNER="$W/home/Library/Application Support/$RID/my-backup"
mkdir -p "$(dirname "$INNER")"; command cp -R "$KEPT" "$INNER"
printf 'BUNDLE_ID=%s\nINSTALL_PATH=%s\nAPP_NAME=%s\nVERSION=0.34.2\nCOMMIT=acdda8cd1\nDATE=2026-11-24 10:15:03\n' "$RID" "$INSTALL" "$RNAME" > "$INNER/kept.env"
KEPT="$INNER"; BK="$W/home/Library/Application Support/cmux/migration-backups/$RID"; SNAP="$(snapshot)"
run_restore "$INNER"
refusal_check "a kept folder inside an entry the restore removes is refused before anything changes, and says so" 1 "inside" "$W/home/Library/Application Support/$RID"
[[ -d "$INNER" ]] && ok "...and the kept folder is still there" || bad "inner kept folder deleted" "gone"
rworld
INNER="$INSTALL/Contents/my-backup"; command cp -R "$KEPT" "$INNER"
SNAP="$(snapshot)"; run_restore "$INNER"
refusal_check "a kept folder inside the installed app is refused the same way" 1 "inside" "$INSTALL"

# --- put follows the plan: a source that vanishes is a failure ------------------
if true; then
  rworld
  snap="$(snapshot | grep -v '^store ')"
  SEAMS='rbf_keep_ditto() { if [[ "$1" == "'"$KEPT"'/Library/Application Support/'"$RID"'" ]]; then command rm -rf "'"$KEPT"'/Library/WebKit/'"$RID"'"; fi; ditto "$@"; }'
  run_restore_sourced "$KEPT"
  after="$(snapshot | grep -v '^store ')"
  if [[ $RC -eq 1 && "$snap" == "$after" ]] && ! grep -q '✓ restored' "$W/out"; then
    ok "an entry the plan says to put back whose source has gone is a failure, not a removal: exit 1 and the live state is put back"
  else
    bad "put follows the plan" "rc=$RC $(diff <(printf '%s\n' "$snap") <(printf '%s\n' "$after") | head -6) out=$(tail -5 "$W/out")"
  fi
fi

# --- the keeping phase: an interrupted keep leaves no half-made folder -----------
rworld
snap="$(snapshot)"
SEAMS='rbf_keep_state_into() { sh -c "kill -TERM \$PPID"; sleep 2; return 0; }'
run_restore_sourced "$KEPT"
if [[ $RC -ne 0 && -z "$(ls -d "$BK"/pre-restore-* 2>/dev/null)" && "$snap" == "$(snapshot)" ]]; then
  ok "an interrupted keep into pre-restore-* removes the half-made folder and changes nothing live"
else
  bad "interrupted keep" "rc=$RC pre=$(ls -d "$BK"/pre-restore-* 2>&1) $(diff <(printf '%s\n' "$snap") <(snapshot) | head -4)"
fi
rworld
SEAMS='eval "$(declare -f rbf_keep_state_into | sed "1s/.*/rbf_keep_state_into_orig ()/")"
rbf_keep_state_into() { [[ -e "$1/kept.env" ]] && : > "'"$W"'/record-first"; rbf_keep_state_into_orig "$@"; }'
run_restore_sourced "$KEPT"
PRP="$(ls -d "$BK"/pre-restore-* 2>/dev/null | tail -1)"
if [[ $RC -eq 0 && ! -e "$W/record-first" && -f "$PRP/kept.env" ]]; then
  ok "kept.env is written last in a pre-restore folder: it is the mark that the folder is complete"
else
  bad "kept.env last" "rc=$RC first=$([[ -e "$W/record-first" ]] && echo yes || echo no)"
fi

# --- wording: what a pre-restore folder with no app can do -----------------------
rworld
command rm -rf "${INSTALL:?}"
run_restore "$KEPT"
if [[ $RC -eq 0 ]] && grep -q "holds no app" "$W/out" && ! grep -q "Restore that folder to go forward again" "$W/out"; then
  ok "a restore that replaced no app says its pre-restore folder holds no app and can't itself be restored"
else
  bad "no-app wording" "$(tail -6 "$W/out")"
fi

# --- render 16's error line carries the item label, not the raw path and id ------
if [[ "$(id -u)" != 0 ]]; then
  rworld
  chmod 000 "$KEPT/Library/WebKit/$RID/marker"
  run_restore_combined "$KEPT"
  chmod 644 "$KEPT/Library/WebKit/$RID/marker"
  errline="$(grep "^error: couldn't put back" "$W/all")"
  if [[ "$errline" == "error: couldn't put back WebKit/<id>/: ditto: WebKit/<id>/marker: Permission denied" ]]; then
    ok "the error line prints the item label (WebKit/<id>/) and the tool's message with the id as <id>, no raw kept path"
  else
    bad "render 16 error line" "$errline"
  fi
fi

# --- the tool's message is cleaned the same under bash 3.2, whatever the paths hold ----
# (bash 3.2 garbles a quoted pattern inside a quoted ${m//"$X/..."/} assignment)
clean_case() { # <kept folder> <home> <message> <want>
  local got
  got="$(RBF_RESTORE_ID=com.example.id RBF_RESTORE_FOLDER="$1" RBF_RESTORE_PRE="" HOME="$2" \
         bash -c 'source "$1" && rbf_restore_clean_msg "$2"' _ "$RESTORE" "$3")"
  [[ "$got" == "$4" ]] && ok "clean message: $4" || bad "clean message" "want: $4 got: $got"
}
clean_case /x/kept /x/home 'ditto: /x/kept/Library/WebKit/com.example.id/./secret: Permission denied' 'ditto: WebKit/<id>/secret: Permission denied'
clean_case /x/kept /x/home "couldn't remove /x/home/Library/WebKit/com.example.id" "couldn't remove WebKit/<id>"
clean_case '/x/ke*pt' /x/home 'ditto: /x/ke*pt/Library/WebKit/com.example.id/./a: no' 'ditto: WebKit/<id>/a: no'
clean_case '/x/ke*pt' /x/home 'ditto: /x/keXpt/Library/WebKit/a: no' 'ditto: /x/keXpt/Library/WebKit/a: no'

# --- the listing the snapshots compare shows a folder's mode --------------------------
rworld
l1="$(rbf_test_listing "$INSTALL")"; chmod 555 "$INSTALL/Contents/Resources"; l2="$(rbf_test_listing "$INSTALL")"; chmod 755 "$INSTALL/Contents/Resources"
[[ "$l1" != "$l2" ]] && ok "rbf_test_listing shows a folder's mode, so a 555 folder left at 755 is seen" || bad "listing folder modes" "$l2"

# --- two restores in one second: the keep never removes a folder it did not make ------
rworld
OTHER="$BK/pre-restore-20990101-000000"; mkdir -p "$OTHER"; printf "another restore's copy" > "$OTHER/kept.env"
snap="$(snapshot)"
SEAMS='rbf_restore_pick_pre() { printf "%s" "'"$OTHER"'"; }'
run_restore_sourced "$KEPT"
if [[ $RC -eq 1 && "$(cat "$OTHER/kept.env" 2>&1)" == "another restore's copy" && "$snap" == "$(snapshot)" ]] \
   && grep -q "Nothing was changed" "$W/err"; then
  ok "a pre-restore folder another restore made in the same second is left alone; this run refuses and changes nothing"
else
  bad "keep race" "rc=$RC other=$(ls -la "$OTHER" 2>&1 | head -3) err=$(cat "$W/err")"
fi

# --- the script is runnable as printed ---------------------------------------------
[[ -x "$RESTORE" ]] && ok "restore-rbf-install.sh is executable" || bad "restore script mode" "$(ls -l "$RESTORE")"
rworld
( cd "$W" && HOME="$W/home" RBF_DEFAULTS_BIN="$W/bin/defaults" "$RESTORE" --dry-run "$KEPT" > "$W/out" 2>&1 ); RC=$?
[[ $RC -eq 0 ]] && ok "it runs directly (./restore-rbf-install.sh), not only through bash" || bad "direct run" "rc=$RC $(cat "$W/out")"

rbf_test_finish
