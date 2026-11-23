#!/usr/bin/env bash
# rbf-keep-state.sh — keep an app's state in a folder, and read a kept folder
# back (#cm-142.2). Sourced by rbf-swap.sh (the install's keep branch) and by
# restore-rbf-install.sh, so the two cannot disagree about what "its state" is:
# the restore keeps what it replaces by the same function the install uses.
# No side effects at source time, bash 3.2 compatible.
#
# What is kept is a RULE, not a list (rbf-id-match.sh): the defaults domain, every
# entry directly under ~/Library/Application Support/cmux/ whose name carries
# exactly the bundle id, and the app's own folders under Application Support,
# WebKit, HTTPStorages and Saved Application State. Not kept: ~/Library/Caches/<id>
# (rebuilt by the app), logs, and keychain items (same id before and after, and
# they cannot be copied). ~/.config/cmux is copied for reference only, as
# config-cmux/, and never put back.
#
# A kept folder is:
#   kept.env       the record: BUNDLE_ID, INSTALL_PATH, APP_NAME, VERSION, COMMIT, DATE
#   defaults.plist the defaults domain
#   Library/       the entries above, at the same path under it as under ~/Library
#   config-cmux/   ~/.config/cmux, for reference
#   <name>.app     the app (added by the caller: the swap moves it in, the restore copies it)

# shellcheck source=rbf/scripts/lib/rbf-id-match.sh
source "$(dirname "${BASH_SOURCE[0]}")/rbf-id-match.sh"

# ---------------------------------------------------------------------------
# Seams. The tests replace these (sourced) or point the variable (executed);
# production never does.
# ---------------------------------------------------------------------------
# `ditto` exits 0 after printing "Permission denied" for one file when it copied
# others (measured 2026-11-23: a tree with an unreadable file among readable ones
# exits 0, and with only the unreadable file exits 1). A keep that "succeeds" with
# a file missing is the failure this slice exists to prevent, so any message from
# ditto is a failure.
rbf_keep_ditto() {
  local out rc=0
  out="$(ditto "$@" 2>&1)" || rc=$?
  if [[ $rc -ne 0 || -n "$out" ]]; then
    printf '%s\n' "$out" >&2
    return 1
  fi
  return 0
}
rbf_keep_defaults() { "${RBF_DEFAULTS_BIN:-defaults}" "$@"; }
rbf_keep_timestamp() { date +%Y%m%d-%H%M%S; }
rbf_keep_now() { date '+%Y-%m-%d %H:%M:%S'; }

# Where every kept folder of a bundle id lives: the internal disk, beside the
# backups migrate-rbf-state.sh --force writes. The id rule never matches it:
# `migration-backups` carries no bundle id, and the rule reads only entries
# directly under ~/Library/Application Support/cmux/.
rbf_keep_backups_dir() { # <bundle id>
  printf '%s/Library/Application Support/cmux/migration-backups/%s' "$HOME" "$1"
}

# rbf_keep_install_root <bundle id>
# The one decision install-rbf.sh reads. RBF_KEEP_PREVIOUS=1 prints the folder
# this install keeps into; unset, empty or 0 prints nothing. Any other value is
# refused (return 2): the point of the variable is safety, so "yes" must not
# silently mean "no".
rbf_keep_install_root() {
  case "${RBF_KEEP_PREVIOUS:-}" in
    1) printf '%s/pre-install-%s' "$(rbf_keep_backups_dir "$1")" "$(rbf_keep_timestamp)" ;;
    ''|0) ;;
    *) return 2 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Reading an app and a record
# ---------------------------------------------------------------------------
rbf_keep_plist() { # <app> <key> — the value, or nothing
  /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
}
rbf_keep_app_version() { # <app>
  local v; v="$(rbf_keep_plist "$1" RBFVersion)"
  [[ -n "$v" ]] || v="$(rbf_keep_plist "$1" CFBundleShortVersionString)"
  printf '%s' "${v:-unknown}"
}
rbf_keep_app_commit() { # <app>
  local c; c="$(rbf_keep_plist "$1" CMUXCommit)"
  printf '%s' "${c:-unknown}"
}

# rbf_keep_write_record <folder> <bundle id> <install path> <app name> <version> <commit>
rbf_keep_write_record() {
  {
    printf 'BUNDLE_ID=%s\n' "$2"
    printf 'INSTALL_PATH=%s\n' "$3"
    printf 'APP_NAME=%s\n' "$4"
    printf 'VERSION=%s\n' "$5"
    printf 'COMMIT=%s\n' "$6"
    printf 'DATE=%s\n' "$(rbf_keep_now)"
  } > "$1/kept.env"
}

# rbf_keep_read_record <kept.env>
# Parsed, never sourced: the values hold spaces and parentheses. Each line is
# KEY=value, split at the first '='. Sets KEPT_BUNDLE_ID, KEPT_INSTALL_PATH,
# KEPT_APP_NAME, KEPT_VERSION, KEPT_COMMIT, KEPT_DATE (empty when absent).
rbf_keep_read_record() {
  local line key value
  KEPT_BUNDLE_ID="" KEPT_INSTALL_PATH="" KEPT_APP_NAME="" KEPT_VERSION="" KEPT_COMMIT="" KEPT_DATE=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      BUNDLE_ID)    KEPT_BUNDLE_ID="$value" ;;
      INSTALL_PATH) KEPT_INSTALL_PATH="$value" ;;
      APP_NAME)     KEPT_APP_NAME="$value" ;;
      VERSION)      KEPT_VERSION="$value" ;;
      COMMIT)       KEPT_COMMIT="$value" ;;
      DATE)         KEPT_DATE="$value" ;;
    esac
  done < "$1"
}

# ---------------------------------------------------------------------------
# Keeping
# ---------------------------------------------------------------------------

# rbf_keep_plan <bundle id>
# Reads ~/Library and sets what a keep would copy, without copying:
#   RBF_KEEP_RELS     the entries, relative to ~/Library, one per line
#   RBF_KEEP_UNKNOWN  the unknown-kind names, one per line
#   RBF_KEEP_COUNT    the defaults domain plus the entries
rbf_keep_plan() {
  RBF_KEEP_RELS="$(rbf_id_library_entries "$1" "$HOME/Library")"
  RBF_KEEP_UNKNOWN="$(rbf_id_unknown_entries "$1" "$HOME/Library")"
  if [[ -n "$RBF_KEEP_RELS" ]]; then
    RBF_KEEP_COUNT=$(( $(printf '%s\n' "$RBF_KEEP_RELS" | wc -l | tr -d ' ') + 1 ))
  else
    RBF_KEEP_COUNT=1
  fi
}

# rbf_keep_state_into <folder> <bundle id>
# Copies the defaults domain, every entry rbf_keep_plan listed and ~/.config/cmux
# into an existing <folder>. Returns 1 with RBF_KEEP_ERR set on the first failure;
# the caller removes the folder, because it made it.
rbf_keep_state_into() {
  local dest="$1" id="$2" rel msg
  RBF_KEEP_ERR=""
  msg="$(rbf_keep_defaults export "$id" "$dest/defaults.plist" 2>&1)" \
    || { RBF_KEEP_ERR="couldn't keep defaults $id: $msg"; return 1; }
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    mkdir -p "$(dirname "$dest/Library/$rel")" \
      || { RBF_KEEP_ERR="couldn't make $(dirname "$dest/Library/$rel")"; return 1; }
    msg="$(rbf_keep_ditto "$HOME/Library/$rel" "$dest/Library/$rel" 2>&1)" \
      || { RBF_KEEP_ERR="couldn't keep ${rel//$id/<id>}: $msg"; return 1; }
  done <<EOF
$RBF_KEEP_RELS
EOF
  if [[ -d "$HOME/.config/cmux" ]]; then
    msg="$(rbf_keep_ditto "$HOME/.config/cmux" "$dest/config-cmux" 2>&1)" \
      || { RBF_KEEP_ERR="couldn't keep ~/.config/cmux: $msg"; return 1; }
  fi
  return 0
}
