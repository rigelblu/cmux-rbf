#!/usr/bin/env bash
# restore-rbf-install.sh — go back to the app and the state a kept folder holds
# (#cm-142.2).
#
#   bash rbf/scripts/restore-rbf-install.sh "<kept folder>" [--dry-run]
#
# A kept folder is made by an install with RBF_KEEP_PREVIOUS=1 (a `pre-install-*`
# folder) or by a restore (a `pre-restore-*` folder), both under
#   ~/Library/Application Support/cmux/migration-backups/<bundle id>/
# and holds kept.env, defaults.plist, Library/, config-cmux/ and the app. See
# lib/rbf-keep-state.sh for the shape and lib/rbf-id-match.sh for what "everything
# under the bundle id" means.
#
# RUN IT FROM TERMINAL, WITH THE APP QUIT. It refuses while the app runs, and a
# pane of that app is where you would otherwise type it: quitting the app ends
# every shell in it, this one included. It does not relaunch the app.
#
# WHAT IT DOES, in order:
#   1. checks the folder against itself and refuses, changing nothing, when
#      anything disagrees: no folder, an empty one, no defaults.plist, kept.env or
#      app; an install path that does not end in the kept app's name; a kept app
#      whose bundle id is not the recorded one; a record that names upstream's
#      app; another app at the install path; the app running
#   2. keeps what it is about to replace, by the same rule, in a new
#      `pre-restore-<ts>` folder beside the others (the current app, its defaults
#      domain, every live entry the rule matches, a kept.env)
#   3. puts back all of it, as it was when the old app quit: the app, the defaults
#      domain, and for each entry the rule matches in either place, the live one is
#      removed and the kept one copied in. An entry the folder lacks is removed; an
#      absent app or entry is not a failure
#   4. on any failure after it starts changing things, puts back what it kept, the
#      absences included, from a trap (so a `set -e` exit runs it too); it copies
#      only from the pre-restore folder, which it keeps, and exits 1
# Restoring the pre-restore folder later returns to the build you left.
#
# WHAT IT NEVER WRITES: ~/.config/cmux, ~/.cmuxterm, ~/.local/state/cmux, upstream's
# app or its state, and the copy of the shared state saved before the sync
# (migration-backups/shared-state-pre-sync-*): it names that copy, never puts it
# back. State every cmux app shares is not part of the way back.
#
# Exit: 0 restored (or a dry run); 2 no argument, an empty one or bad usage;
# 1 every other refusal and any failure.
#
# Sourced by the tests (no side effects at source time); `rbf_restore_main` is the
# entry point.

RBF_RESTORE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rbf/scripts/lib/rbf-install-target.sh
source "$RBF_RESTORE_SCRIPT_DIR/lib/rbf-install-target.sh"
# rbf_swap_app_running / rbf_swap_process_pattern: the one way to ask "is the app
# at this path running" (matched by executable, never by argv). Sourcing defines
# functions only; rbf-swap.sh runs nothing unless it is the executed script.
# shellcheck source=rbf/scripts/lib/rbf-swap.sh
source "$RBF_RESTORE_SCRIPT_DIR/lib/rbf-swap.sh"
# shellcheck source=rbf/scripts/lib/rbf-keep-state.sh
source "$RBF_RESTORE_SCRIPT_DIR/lib/rbf-keep-state.sh"

# ---------------------------------------------------------------------------
# Output. Every refusal is `error: <cause>` on stderr, continued on lines
# indented 7 spaces, ending "Nothing was changed.", and a paste line (a path or
# command meant to be copied whole) is printed unindented: a line passed with a
# leading "@" is printed as is.
# ---------------------------------------------------------------------------
rbf_restore_refuse() { # <exit code> <line>...
  local rc="$1" first=1 line; shift
  for line in "$@"; do
    if [[ "$line" == @* ]]; then
      printf '%s\n' "${line#@}" >&2
    elif [[ $first -eq 1 ]]; then
      printf 'error: %s\n' "$line" >&2; first=0
    else
      printf '       %s\n' "$line" >&2
    fi
  done
  exit "$rc"
}

RBF_RESTORE_LIST_LINE='@ls -d "$HOME/Library/Application Support/cmux/migration-backups/"*/pre-*'

rbf_restore_not_kept() { # <reason> <folder>
  rbf_restore_refuse 1 "not a kept folder: $1. Nothing was changed." \
    "A kept folder holds kept.env, defaults.plist, Library/ and the app." \
    "The folder given:" "@$2"
}

rbf_restore_no_match() { # <line of the cause>...
  rbf_restore_refuse 1 "the folder doesn't match its own record. Nothing was changed." "$@"
}

# `<id>` for the bundle id in a path, as the renders print it.
rbf_restore_label() { printf '%s' "${1//$RBF_RESTORE_ID/<id>}"; }

# Output once things may change is best effort: a reader that has gone away
# (`restore ... | head`) must neither kill the restore halfway nor fail it, so SIGPIPE
# is ignored from the argument check on and every print here swallows its own failure.
# It prints with /usr/bin/printf, a process of its own: bash's builtin printf keeps the
# bytes a failed write could not deliver and hands them to every `$(...)` it forks next,
# which put a copy of the output inside each captured path list (measured 2026-11-23).
say() { /usr/bin/printf "$@" 2>/dev/null || true; }
sayerr() { /usr/bin/printf "$@" >&2 2>/dev/null || true; }

# A tool's first message line, with the kept folder's and the live ~/Library's paths
# cut off and the bundle id written <id>, so it reads like the item row above it.
# The pattern sits in a variable and the assignment is unquoted: bash 3.2 garbles a
# quoted pattern inside a quoted ${m//"$X/Library/"/} (measured 2026-11-23).
rbf_restore_clean_msg() { # <message>
  local m="${1%%$'\n'*}" p
  if [[ -n "$RBF_RESTORE_FOLDER" ]]; then p="$RBF_RESTORE_FOLDER/Library/"; m=${m//"$p"/}; fi
  if [[ -n "$RBF_RESTORE_PRE" ]]; then p="$RBF_RESTORE_PRE/Library/"; m=${m//"$p"/}; fi
  p="$HOME/Library/"; m=${m//"$p"/}
  m=${m//\/.\//\/}
  rbf_restore_label "$m"
}

# A pre-restore folder's name that does not exist yet: two restores in one second
# must not collide, and a restore is never refused for its timestamp.
rbf_restore_pick_pre() {
  local base cand n=2
  base="$(rbf_keep_backups_dir "$RBF_RESTORE_ID")/pre-restore-$(rbf_keep_timestamp)"
  cand="$base"
  while [[ -e "$cand" ]]; do cand="$base-$n"; n=$((n + 1)); done
  printf '%s' "$cand"
}

# ---------------------------------------------------------------------------
# The items a restore changes, and the one function per item that both puts it
# back (from the kept folder) and undoes it (from the pre-restore folder). An item
# is `app`, `defaults` or `lib|<rel>`.
# ---------------------------------------------------------------------------

# Remove a path, or fail. A removal that did not happen is never ignored: copying
# the kept entry on top of what is left would be a mix of two builds. A folder the
# owner can't write (mode 555) is made writable first, because it is being replaced.
rbf_restore_remove_path() { # <path>
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  chmod -R u+w "$p" 2>/dev/null || true
  command rm -rf "${p:?}" || return 1
  if [[ -e "$p" || -L "$p" ]]; then
    printf "couldn't remove %s\n" "$p" >&2
    return 1
  fi
  return 0
}

# <item> <source folder> <kind>; never writes the source.
#   put     the plan says the kept folder has it: a missing source is a failure,
#           checked before anything is removed, never a quiet removal
#   remove  the plan says the folder has none: remove the live one
#   sync    the undo: make the live item what the pre-restore folder has, absent if
#           it has none. It copies even when a removal failed, so as much as possible
#           is back, and still reports the failure
rbf_restore_item_from() {
  local item="$1" src="$2" kind="$3" rel target source have=0 rmrc=0
  case "$item" in
    defaults)
      rbf_keep_defaults delete "$RBF_RESTORE_ID" >/dev/null 2>&1 || true
      rbf_keep_defaults import "$RBF_RESTORE_ID" "$src/defaults.plist"
      return $? ;;
    app)
      target="${RBF_RESTORE_INSTALL:?}"; source="$src/$RBF_RESTORE_APPDIR"
      [[ -d "$source" ]] && have=1 ;;
    lib\|*)
      rel="${item#lib|}"
      target="${HOME:?}/Library/${rel:?}"; source="$src/Library/$rel"
      [[ -e "$source" || -L "$source" ]] && have=1 ;;
  esac
  if [[ "$kind" == put && $have -eq 0 ]]; then
    printf 'the kept copy is gone: %s\n' "$source" >&2
    return 1
  fi
  rbf_restore_remove_path "$target" || rmrc=1
  [[ "$kind" != remove ]] || return $rmrc
  [[ "$kind" == sync || $rmrc -eq 0 ]] || return 1
  if [[ $have -eq 1 ]]; then
    mkdir -p "$(dirname "$target")" || return 1
    rbf_keep_ditto "$source" "$target" || return 1
  fi
  return $rmrc
}

rbf_restore_item_label() { # <item> -> the text after "put back" / "undone"
  case "$1" in
    app) printf '%s' "$RBF_RESTORE_INSTALL" ;;
    defaults) printf 'defaults <id>' ;;
    lib\|*) rbf_restore_label "${1#lib|}" ;;
  esac
}

rbf_restore_row() { # <verb> <item> [trailing slash for a directory]
  local item="$2" label slash=""
  label="$(rbf_restore_item_label "$item")"
  [[ "${3:-}" == dir ]] && slash="/"
  case "$1" in
    "put back") say '  put back  %s%s\n' "$label" "$slash" ;;
    undone)     say '  undone    %s%s\n' "$label" "$slash" ;;
  esac
  return 0
}

# Rows for a list of items, with the `in ~/Library:` row before the first library
# entry. $1 = verb; items on stdin, one per line.
rbf_restore_rows() {
  local verb="$1" item in_lib=0 dir
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    if [[ "$item" == lib\|* && $in_lib -eq 0 ]]; then say '  in ~/Library:\n'; in_lib=1; fi
    dir=""
    if [[ "$item" == lib\|* && -d "$RBF_RESTORE_FOLDER/Library/${item#lib|}" ]]; then dir=dir; fi
    rbf_restore_row "$verb" "$item" "$dir"
  done
}

# The undo, from the EXIT trap. It copies only from the pre-restore folder, and it
# does all of its work before it prints anything: a print that fails can't cut it short.
rbf_restore_undo() {
  local item msg rc failed_item="" failed_msg=""
  # The item in progress when it stopped may be half done: undo it first, with no
  # row (a row says an item was put back, and this one was not). A failure on one
  # item does not stop the others: as much as possible is put back.
  local todo="$RBF_RESTORE_DONE"
  [[ -z "$RBF_RESTORE_CUR" ]] || todo="$RBF_RESTORE_CUR"$'\n'"$todo"
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    rc=0
    msg="$(rbf_restore_item_from "$item" "$RBF_RESTORE_PRE" sync 2>&1)" || rc=$?
    if [[ $rc -ne 0 && -z "$failed_item" ]]; then failed_item="$item"; failed_msg="$msg"; fi
  done <<EOF
$todo
EOF
  if [[ -n "$failed_item" ]]; then
    rbf_restore_undo_failed "$failed_item" "$failed_msg"
  fi
  say '⋯ undoing, from %s\n' "$(basename "$RBF_RESTORE_PRE")"
  printf '%s' "$RBF_RESTORE_DONE" | rbf_restore_rows undone
  say '\n✗ not restored: the app and its state are as they were before this ran\n'
  if [[ -n "$RBF_RESTORE_BEFORE_LABEL" ]]; then
    say '  The app is still %s. The copy taken before this ran is in:\n' "$RBF_RESTORE_BEFORE_LABEL"
  else
    say '  No app was installed before, and none is now. The copy taken before this ran is in:\n'
  fi
  say '%s\n' "$RBF_RESTORE_PRE"
}

rbf_restore_undo_failed() { # <item> <message>
  trap - EXIT
  sayerr 'error: the undo failed at %s: %s\n' "$(rbf_restore_item_label "$1")" "$(rbf_restore_clean_msg "$2")"
  sayerr '       The folder below holds all of what it replaced. It was kept, and\n'
  sayerr '       nothing in it was changed; put the app and its state back from it:\n'
  sayerr '%s\n' "$RBF_RESTORE_PRE"
  exit 1
}

rbf_restore_on_exit() {
  local rc=$?
  trap - EXIT
  set +e
  case "$RBF_RESTORE_PHASE" in
    changing)
      if [[ $rc -ne 0 ]]; then
        rbf_restore_undo
        exit 1
      fi ;;
    keeping)
      # an interrupted keep leaves no half-made folder: nothing live has changed yet.
      # Only a folder this run made: another restore in the same second may own the name.
      if [[ $rc -ne 0 && "${RBF_RESTORE_PRE_MADE:-0}" == 1 ]]; then command rm -rf "${RBF_RESTORE_PRE:?}"; fi ;;
  esac
  exit "$rc"
}

# Put one item back (or remove it, as the plan says), or stop: the tool's first
# message line names what failed, then the EXIT trap undoes everything this run changed.
rbf_restore_put() { # <item> <kind: put|remove>
  local item="$1" kind="$2" msg dir="" verb="put back"
  [[ "$kind" == remove ]] && verb="remove"
  RBF_RESTORE_CUR="$item"
  if ! msg="$(rbf_restore_item_from "$item" "$RBF_RESTORE_FOLDER" "$kind" 2>&1)"; then
    [[ "$item" == lib\|* && -d "$RBF_RESTORE_FOLDER/Library/${item#lib|}" ]] && dir=/
    sayerr "error: couldn't %s %s%s: %s\n" "$verb" "$(rbf_restore_item_label "$item")" "$dir" "$(rbf_restore_clean_msg "$msg")"
    exit 1
  fi
  RBF_RESTORE_DONE="${RBF_RESTORE_DONE}${item}"$'\n'
  RBF_RESTORE_CUR=""
  if [[ "$kind" == remove ]]; then
    say '  removed   %s (the folder has none)\n' "$(rbf_restore_item_label "$item")"
  else
    dir=""
    [[ "$item" == lib\|* && -d "$RBF_RESTORE_FOLDER/Library/${item#lib|}" ]] && dir=dir
    rbf_restore_row "put back" "$item" "$dir"
  fi
  return 0
}

# ---------------------------------------------------------------------------
rbf_restore_main() {
  set -euo pipefail
  RBF_RESTORE_PHASE=none RBF_RESTORE_CUR="" RBF_RESTORE_DONE="" RBF_RESTORE_BEFORE_LABEL=""
  RBF_RESTORE_PRE="" RBF_RESTORE_FOLDER="" RBF_RESTORE_ID="" RBF_RESTORE_INSTALL="" RBF_RESTORE_APPDIR=""
  local folder="" have_folder=0 dry=0 arg
  for arg in "$@"; do
    case "$arg" in
      --dry-run) dry=1 ;;
      -h|--help)
        printf 'Usage: rbf/scripts/restore-rbf-install.sh "<kept folder>" [--dry-run]\n'
        return 0 ;;
      -?*)
        rbf_restore_refuse 2 "unknown option: $arg. Nothing was changed." \
          'usage: rbf/scripts/restore-rbf-install.sh "<kept folder>" [--dry-run]' ;;
      *)
        if [[ $have_folder -eq 1 ]]; then
          rbf_restore_refuse 2 "give one kept folder, got more than one. Nothing was changed." \
            'usage: rbf/scripts/restore-rbf-install.sh "<kept folder>" [--dry-run]'
        fi
        folder="$arg"; have_folder=1 ;;
    esac
  done
  trap '' PIPE
  if [[ $have_folder -eq 0 ]]; then
    rbf_restore_refuse 2 "no kept folder given. Nothing was changed." \
      'usage: rbf/scripts/restore-rbf-install.sh "<kept folder>" [--dry-run]' \
      "Paste one folder this line lists, whole, in quotes:" "$RBF_RESTORE_LIST_LINE"
  fi
  if [[ -z "$folder" ]]; then
    rbf_restore_refuse 2 "the kept folder is an empty string. Nothing was changed." \
      'A list that matched nothing passes "". Paste one folder this line' \
      "lists, whole, in quotes:" "$RBF_RESTORE_LIST_LINE"
  fi
  while [[ "$folder" == */ && "$folder" != / ]]; do folder="${folder%/}"; done

  # --- the folder, against itself ---------------------------------------------
  [[ -d "$folder" ]] || rbf_restore_not_kept "it doesn't exist" "$folder"
  [[ -f "$folder/defaults.plist" ]] || rbf_restore_not_kept "it has no defaults.plist" "$folder"
  [[ -f "$folder/kept.env" ]] || rbf_restore_not_kept "it has no kept.env" "$folder"
  local appdirs=0 f
  RBF_RESTORE_APPDIR=""
  for f in "$folder"/*.app; do
    if [[ -d "$f" ]]; then appdirs=$((appdirs + 1)); RBF_RESTORE_APPDIR="${f##*/}"; fi
  done
  [[ $appdirs -ge 1 ]] || rbf_restore_not_kept "it holds no app (a .app folder)" "$folder"
  [[ $appdirs -eq 1 ]] || rbf_restore_not_kept "it holds more than one app" "$folder"

  rbf_keep_read_record "$folder/kept.env"
  local key
  for key in BUNDLE_ID INSTALL_PATH APP_NAME; do
    local var="KEPT_$key"
    [[ -n "${!var}" ]] || rbf_restore_no_match "kept.env has no $key line."
  done
  RBF_RESTORE_FOLDER="$folder"
  RBF_RESTORE_ID="$KEPT_BUNDLE_ID"
  RBF_RESTORE_INSTALL="$KEPT_INSTALL_PATH"
  local app_name="$KEPT_APP_NAME" kept_version="$KEPT_VERSION" kept_commit="$KEPT_COMMIT" kept_date="$KEPT_DATE"

  # upstream's id and path come from the channel record, the one place they are written
  local up_id up_path
  up_id="$(source "$RBF_RESTORE_SCRIPT_DIR/lib/rbf-channel.env"; printf '%s' "$UPSTREAM_BUNDLE_ID")"
  up_path="$(source "$RBF_RESTORE_SCRIPT_DIR/lib/rbf-channel.env"; printf '%s' "$UPSTREAM_INSTALL_PATH")"
  if [[ "$RBF_RESTORE_ID" == "$up_id" ]]; then
    rbf_restore_refuse 1 "this folder records upstream's app, $up_id. The restore" \
      "never writes upstream's app or its state. Nothing was changed."
  fi
  local phys up_phys
  phys="$(rbf_physical_path "$RBF_RESTORE_INSTALL")"; up_phys="$(rbf_physical_path "$up_path")"
  if [[ "$phys" == "$up_phys" ]]; then
    rbf_restore_refuse 1 "this folder records upstream's app, $up_path. The restore" \
      "never writes upstream's app or its state. Nothing was changed."
  fi
  case "$phys/" in "$up_phys"/*)
    rbf_restore_refuse 1 "this folder records a path inside upstream's app, $up_path. The restore" \
      "never writes upstream's app or its state. Nothing was changed." ;;
  esac
  case "$RBF_RESTORE_INSTALL" in
    *.app) ;;
    *) rbf_restore_no_match "kept.env's install path is $RBF_RESTORE_INSTALL, which doesn't end" "in .app." ;;
  esac
  if [[ "${RBF_RESTORE_INSTALL##*/}" != "$RBF_RESTORE_APPDIR" ]]; then
    rbf_restore_no_match "kept.env's install path is $RBF_RESTORE_INSTALL, whose last part" \
      "isn't the kept app's name, $RBF_RESTORE_APPDIR."
  fi
  local kept_app_id
  kept_app_id="$(rbf_keep_plist "$folder/$RBF_RESTORE_APPDIR" CFBundleIdentifier)"
  if [[ "$kept_app_id" != "$RBF_RESTORE_ID" ]]; then
    rbf_restore_no_match "the app in the folder has bundle id ${kept_app_id:-(none)}, but kept.env" \
      "records $RBF_RESTORE_ID."
  fi
  local have_app=0 cur_label=""
  if [[ -e "$RBF_RESTORE_INSTALL" || -L "$RBF_RESTORE_INSTALL" ]]; then
    local there_id=""
    [[ -d "$RBF_RESTORE_INSTALL" ]] && there_id="$(rbf_keep_plist "$RBF_RESTORE_INSTALL" CFBundleIdentifier)"
    if [[ "$there_id" != "$RBF_RESTORE_ID" ]]; then
      rbf_restore_refuse 1 "a different app is at $RBF_RESTORE_INSTALL." \
        "Its bundle id is ${there_id:-(none)}, and this folder is for" \
        "$RBF_RESTORE_ID." \
        "Move that app away first. Nothing was changed."
    fi
    have_app=1
    cur_label="$(rbf_keep_app_version "$RBF_RESTORE_INSTALL") ($(rbf_keep_app_commit "$RBF_RESTORE_INSTALL"))"
  fi
  if rbf_swap_app_running "$RBF_RESTORE_INSTALL"; then
    rbf_restore_refuse 1 "$app_name is running. Nothing was changed." \
      "Quit it, then run this line from Terminal, not from one of its panes:" \
      "quitting the app ends every shell in it, this one included."
  fi

  # --- the plan: what is put back and what is removed ---------------------------
  local plan="" rel line
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if [[ -e "$folder/Library/$rel" || -L "$folder/Library/$rel" ]]; then
      plan="${plan}put|lib|${rel}"$'\n'
    else
      plan="${plan}remove|lib|${rel}"$'\n'
    fi
  done <<EOF
$(rbf_id_library_union "$RBF_RESTORE_ID" "$folder/Library" "$HOME/Library")
EOF
  local pre; pre="$(rbf_restore_pick_pre)"
  RBF_RESTORE_PRE="$pre"

  # A kept folder inside the app or inside an entry this restore replaces would be
  # deleted by it: refuse before anything changes.
  local fphys
  fphys="$(cd "$folder" && pwd -P)"
  rbf_restore_inside "$fphys" "$RBF_RESTORE_INSTALL"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    rbf_restore_inside "$fphys" "$HOME/Library/${line##*|}"
  done <<EOF
$plan
EOF

  # --- the lines a restore prints (and a dry run too) ---------------------------
  [[ $dry -eq 0 ]] || say '⋯ --dry-run: the lines a restore would print. Nothing is changed\n'
  say '⋯ checking the folder against itself\n'
  say '  %-13s%s, %s (%s)\n' "app" "$RBF_RESTORE_APPDIR" "${kept_version:-unknown}" "${kept_commit:-unknown}"
  say '  %-13s%s, written <id> below\n' "bundle id" "$RBF_RESTORE_ID"
  say '  %-13s%s\n' "kept" "${kept_date:-unknown}"
  say '⋯ keeping what this replaces in %s\n' "$(basename "$pre")"
  say '⋯ putting back the app and its state, as they were when it quit\n'

  local kind rest item
  if [[ $dry -eq 1 ]]; then
    rbf_restore_row "put back" app
    rbf_restore_row "put back" defaults
    local in_lib=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      kind="${line%%|*}"; rest="${line#*|}"; item="lib|${rest#lib|}"
      if [[ $in_lib -eq 0 ]]; then say '  in ~/Library:\n'; in_lib=1; fi
      if [[ "$kind" == remove ]]; then
        say '  removed   %s (the folder has none)\n' "$(rbf_restore_item_label "$item")"
      elif [[ -d "$folder/Library/${item#lib|}" ]]; then rbf_restore_row "put back" "$item" dir
      else rbf_restore_row "put back" "$item"; fi
    done <<EOF
$plan
EOF
    rbf_restore_notes "$folder"
    say '\n--dry-run: nothing was changed.\n'
    return 0
  fi

  # --- keep what this replaces --------------------------------------------------
  # The traps come first: an interrupted keep removes the folder it made, and only once
  # `mkdir` has made it (RBF_RESTORE_PRE_MADE), never one of the same name. kept.env is
  # written LAST, as the mark that the folder is complete (the self-check above refuses
  # a folder without it).
  local why
  RBF_RESTORE_DONE="" RBF_RESTORE_CUR="" RBF_RESTORE_PRE_MADE=0
  trap rbf_restore_on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  RBF_RESTORE_PHASE=keeping
  mkdir -p "$(dirname "$pre")" && mkdir "$pre" \
    || rbf_restore_refuse 1 "couldn't make the folder $pre. Nothing was changed."
  RBF_RESTORE_PRE_MADE=1
  if ! { rbf_keep_plan "$RBF_RESTORE_ID" && rbf_keep_state_into "$pre" "$RBF_RESTORE_ID"; }; then
    # (an apostrophe inside a ${var:-word} default is a syntax error in bash 3.2)
    why="${RBF_KEEP_ERR:-}"
    [[ -n "$why" ]] || why="couldn't keep the state"
    command rm -rf "${pre:?}"
    rbf_restore_refuse 1 "couldn't keep what this replaces: $why. Nothing was changed."
  fi
  if [[ $have_app -eq 1 ]]; then
    if ! why="$(rbf_keep_ditto "$RBF_RESTORE_INSTALL" "$pre/$RBF_RESTORE_APPDIR" 2>&1)"; then
      command rm -rf "${pre:?}"
      rbf_restore_refuse 1 "couldn't keep what this replaces: couldn't copy the current app: ${why%%$'\n'*}. Nothing was changed."
    fi
  fi
  if ! rbf_keep_write_record "$pre" "$RBF_RESTORE_ID" "$RBF_RESTORE_INSTALL" "$app_name" \
       "$([[ $have_app -eq 1 ]] && rbf_keep_app_version "$RBF_RESTORE_INSTALL" || printf none)" \
       "$([[ $have_app -eq 1 ]] && rbf_keep_app_commit "$RBF_RESTORE_INSTALL" || printf none)"; then
    command rm -rf "${pre:?}"
    rbf_restore_refuse 1 "couldn't keep what this replaces: couldn't write $pre/kept.env. Nothing was changed."
  fi

  # --- put it all back; from here a failure undoes itself -----------------------
  RBF_RESTORE_BEFORE_LABEL="$cur_label"
  RBF_RESTORE_PHASE=changing

  rbf_restore_put app put
  rbf_restore_put defaults put
  local in_lib2=0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    kind="${line%%|*}"; rest="${line#*|}"; item="lib|${rest#lib|}"
    if [[ $in_lib2 -eq 0 ]]; then say '  in ~/Library:\n'; in_lib2=1; fi
    rbf_restore_put "$item" "$kind"
  done <<EOF
$plan
EOF
  RBF_RESTORE_PHASE=done
  trap - EXIT

  rbf_restore_notes "$folder"
  say '\n✓ restored %s %s (%s), as it was when it quit\n' "$app_name" "${kept_version:-unknown}" "${kept_commit:-unknown}"
  if [[ -n "$cur_label" ]]; then
    say '  what it replaced, %s, with its state, is kept in:\n' "$cur_label"
    say '%s\n' "$pre"
    say '  Restore that folder to go forward again. The app was not opened.\n'
  else
    say '  what it replaced, no app was installed, with its state, is kept in:\n'
    say '%s\n' "$pre"
    say "  It holds no app, so it can't be restored by itself. The app was not opened.\n"
  fi
  return 0
}

# Refuse when the kept folder (physical path <folder>) is the path or inside it.
rbf_restore_inside() { # <physical kept folder> <path this restore replaces>
  local p
  p="$(rbf_physical_path "$2")"
  case "$1/" in
    "$p"/*)
      rbf_restore_refuse 1 "the kept folder is inside $p, which this restore replaces." \
        "It would be deleted with it. Move the kept folder somewhere else first." \
        "Nothing was changed." ;;
  esac
  return 0
}

# The two notes about state a restore never writes: ~/.config/cmux/cmux.json when
# it differs from the copy the folder kept, and the copy of the shared state saved
# before the sync's first launch (named, never put back).
rbf_restore_notes() { # <kept folder>
  local folder="$1" live_cfg="$HOME/.config/cmux/cmux.json" shared="" d changed=0
  if [[ -f "$folder/config-cmux/cmux.json" ]] && ! cmp -s "$folder/config-cmux/cmux.json" "$live_cfg"; then
    changed=1
    say '  note: ~/.config/cmux/cmux.json has changed since this folder was kept.\n'
    say '        It was left as it is. The copy kept then is config-cmux/cmux.json\n'
    say '        in the folder above.\n'
  fi
  for d in "$HOME/Library/Application Support/cmux/migration-backups/shared-state-pre-sync-"*; do
    [[ -d "$d" ]] && shared="$d"
  done
  if [[ -n "$shared" ]]; then
    say "  note: the shared state from before the sync's first launch is kept in\n"
    if [[ -f "$shared/config-cmux/cmux.json" ]] && ! cmp -s "$shared/config-cmux/cmux.json" "$live_cfg"; then
      say '        the folder below, and was left as it is. Its cmux.json differs from\n'
      if [[ $changed -eq 1 ]]; then say "        today's too.\n"; else say "        today's.\n"; fi
    else
      say '        the folder below, and was left as it is.\n'
    fi
    say '%s\n' "$shared"
  fi
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  rbf_restore_main "$@"
fi
