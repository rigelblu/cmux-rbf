#!/usr/bin/env bash
# rbf-testkit.sh — the small shared harness for the keep / restore / installer
# tests (#cm-142.2). Sourced by *.test.sh only; no side effects at source time.
#
# It owns three things the tests would otherwise each copy:
#   - the counters and the one report line, which says what ran: passed, failed,
#     skipped, and, when a test file stops early, that it did not finish
#   - fixture builders: an app bundle with a real Info.plist, the state an app
#     writes under its bundle id, a content-and-name listing for before/after
#     comparison, and a fake `defaults` so no test reads or writes a real
#     preferences domain
#   - nothing that touches a real app or real state. Every builder takes the
#     root it writes under.
#
# bash 3.2 compatible: no associative arrays, no mapfile, no ${var,,}.

RBF_TEST_PASS=0
RBF_TEST_FAIL=0
RBF_TEST_SKIP=0
RBF_TEST_FINISHED=0
RBF_TEST_SANDBOX=""

ok()      { printf '  ok   %s\n' "$1"; RBF_TEST_PASS=$((RBF_TEST_PASS + 1)); }
bad()     { printf '  FAIL %s\n     %s\n' "$1" "$2"; RBF_TEST_FAIL=$((RBF_TEST_FAIL + 1)); }
skipped() { printf '  skip %s\n     %s\n' "$1" "$2"; RBF_TEST_SKIP=$((RBF_TEST_SKIP + 1)); }

# rbf_test_begin <prefix>: make the sandbox (physical path: lsof and realpath
# report /private/var, not /var) and arrange its removal and the closing line.
rbf_test_begin() {
  RBF_TEST_SANDBOX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX")" && pwd -P)"
  trap rbf_test_on_exit EXIT
}

rbf_test_on_exit() {
  local rc=$?
  if [[ $RBF_TEST_FINISHED -eq 0 ]]; then
    printf '\nDID NOT FINISH: %d passed, %d failed, %d skipped before the file stopped (exit %d)\n' \
      "$RBF_TEST_PASS" "$RBF_TEST_FAIL" "$RBF_TEST_SKIP" "$rc"
  fi
  [[ -n "$RBF_TEST_SANDBOX" && -d "$RBF_TEST_SANDBOX" ]] && command rm -rf "${RBF_TEST_SANDBOX:?}"
  return 0
}

# rbf_test_finish: prints the one report line and returns the file's status.
rbf_test_finish() {
  RBF_TEST_FINISHED=1
  printf '\n%d passed, %d failed, %d skipped\n' "$RBF_TEST_PASS" "$RBF_TEST_FAIL" "$RBF_TEST_SKIP"
  [[ $RBF_TEST_FAIL -eq 0 ]]
}

# rbf_test_world <name>: a fresh fixture root with a HOME and an apps dir.
# Prints the root. Callers set HOME to "$root/home" themselves.
rbf_test_world() {
  local root="$RBF_TEST_SANDBOX/world.$1.$RANDOM"
  mkdir -p "$root/home/Library/Application Support/cmux" "$root/home/.config/cmux" \
           "$root/apps" "$root/defaults-store"
  printf '%s' "$root"
}

# rbf_test_make_app <app path> <bundle id> <version> <commit> <marker>
rbf_test_make_app() {
  local app="$1" id="$2" version="$3" commit="$4" marker="$5"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  command rm -f "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy \
    -c "Add :CFBundleIdentifier string $id" \
    -c "Add :RBFVersion string $version" \
    -c "Add :CMUXCommit string $commit" \
    "$app/Contents/Info.plist" >/dev/null 2>&1 || return 1
  printf '%s' "$marker" > "$app/Contents/Resources/marker"
}

# The ten entries the dogfood id writes directly under Application Support/cmux,
# measured 2026-11-22 (brief, Design technical system): the folder, the agent
# journal's database and its two sidecars, and five json files.
RBF_TEST_AS_FILES="agent-journal-@ID@.sqlite3 agent-journal-@ID@.sqlite3-shm agent-journal-@ID@.sqlite3-wal closed-item-history-@ID@.json notification-feed-history-@ID@.json restart-command-summaries-@ID@.json restart-commands-state-@ID@.json session-@ID@.json session-@ID@-previous.json"

# rbf_test_make_state <home> <id> <marker> [savedstate]
rbf_test_make_state() {
  local home="$1" id="$2" marker="$3" saved="${4:-}" lib f
  lib="$home/Library"
  mkdir -p "$lib/Application Support/cmux/$id" "$lib/Application Support/$id" \
           "$lib/WebKit/$id" "$lib/HTTPStorages/$id"
  printf '%s' "$marker" > "$lib/Application Support/cmux/$id/marker"
  printf '%s' "$marker" > "$lib/Application Support/$id/marker"
  printf '%s' "$marker" > "$lib/WebKit/$id/marker"
  printf '%s' "$marker" > "$lib/HTTPStorages/$id/marker"
  printf '%s' "$marker" > "$lib/HTTPStorages/$id.binarycookies"
  for f in $RBF_TEST_AS_FILES; do
    printf '%s' "$marker" > "$lib/Application Support/cmux/${f//@ID@/$id}"
  done
  if [[ -n "$saved" ]]; then
    mkdir -p "$lib/Saved Application State/$id.savedState"
    printf '%s' "$marker" > "$lib/Saved Application State/$id.savedState/data"
  fi
}

# rbf_test_make_neighbours <home> <id>: what must never be touched. Another app
# whose id merely starts with ours (a nested id), another app entirely, a cache,
# and a store kind the rule does not know.
rbf_test_make_neighbours() {
  local home="$1" id="$2" as
  as="$home/Library/Application Support/cmux"
  mkdir -p "$as/$id.docktileplugin" "$as/${id%.*}.control-other" "$home/Library/Caches/$id" \
           "$home/Library/WebKit/$id.docktileplugin"
  printf 'nested' > "$as/$id.docktileplugin/marker"
  printf 'nested' > "$as/session-$id.docktileplugin.json"
  printf 'nested' > "$as/agent-journal-$id.control.sqlite3"
  printf 'other'  > "$as/session-com.example.other.json"
  printf 'cache'  > "$home/Library/Caches/$id/marker"
  printf 'nested' > "$home/Library/WebKit/$id.docktileplugin/marker"
  printf 'unknown' > "$as/session-$id.bak"
  printf 'unknown' > "$as/history_$id.json"
}

# rbf_test_listing <root>: every file (name and content hash) and directory
# under <root>, sorted, for byte-level before/after comparison. Modes are
# included so a chmod shows.
rbf_test_listing() {
  local root="$1" p
  [[ -e "$root" ]] || { printf '(absent)\n'; return 0; }
  (
    cd "$root" || exit 1
    find . \( -type f -o -type d -o -type l \) | LC_ALL=C sort | while IFS= read -r p; do
      if [[ -L "$p" ]]; then printf 'link %s -> %s\n' "$p" "$(readlink "$p")"
      elif [[ -f "$p" ]]; then
        if [[ -r "$p" ]]; then printf 'file %s %s %s\n' "$(stat -f %Lp "$p")" "$(shasum < "$p" | cut -d' ' -f1)" "$p"
        else printf 'file %s unreadable %s\n' "$(stat -f %Lp "$p")" "$p"; fi
      else printf 'dir  %s %s\n' "$(stat -f %Lp "$p")" "$p"
      fi
    done
  )
}

# rbf_test_fake_defaults <dir> <store>: an executable `defaults` that keeps each
# domain as <store>/<domain>.plist, so no test touches real preferences.
# export <domain> <file>   writes the stored plist, or an empty dict when absent
# import <domain> <file>   stores the file
# delete <domain>          removes it; exits 1 when absent, like the real one
# read <domain> <key>      not needed here
rbf_test_fake_defaults() {
  local dir="$1" store="$2"
  mkdir -p "$dir" "$store"
  cat > "$dir/defaults" <<FAKE
#!/bin/bash
store="$store"
case "\$1" in
  export)
    if [[ -e "\$store/\$2.plist" ]]; then cp "\$store/\$2.plist" "\$3"
    else printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict/></plist>\n' > "\$3"; fi ;;
  import) cp "\$3" "\$store/\$2.plist" ;;
  delete) [[ -e "\$store/\$2.plist" ]] || { echo "Domain \$2 does not exist" >&2; exit 1; }; rm -f "\$store/\$2.plist" ;;
  *) echo "fake defaults: unsupported: \$*" >&2; exit 2 ;;
esac
FAKE
  chmod +x "$dir/defaults"
}
