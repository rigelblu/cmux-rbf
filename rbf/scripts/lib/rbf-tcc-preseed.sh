# rbf-tcc-preseed.sh — pre-grant TCC permissions for a dev build's bundle id.
#
# Why: TCC keys grants on (bundle id, designated requirement). Every branch
# mints a fresh bundle id (com.cmuxterm.app.debug.<slug>), so the first launch
# of every branch's build re-prompts for persistent grants such as removable-volume access
# even though the app is signed with the stable CMUX_DEV_CODESIGN_IDENTITY.
# macOS offers no supported cross-bundle-id pre-grant without MDM, so this
# clones the user's existing grants (the rows Tom already approved for a
# previous dev bundle id) to the new bundle id in the user TCC database,
# keyed to a csreq compiled for the new id + the stable cert. tccd verifies
# the launched app against that csreq, so only apps signed with our identity
# can consume the grant.
#
# EVERY failure path returns 0 with a warning: no FDA, no identity, schema
# surprise — the build must never break over a convenience. Worst case is
# what happened before this script existed: one prompt pair per branch.
#
# Lives in rbf/scripts/lib/ per rbf/AGENTS.md: guards written inside one
# entrypoint don't get inherited by the next; a lib does.

# rbf_tcc_preseed <build-id-or-bundle-id>
rbf_tcc_preseed() {
  local target="$1"
  local db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
  # Standalone callers use the same stable default as make/reload/install.
  # The helper only defines functions; sourcing it does not change permissions.
  local signing_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/rbf-signing.sh"
  # shellcheck source=rbf/scripts/lib/rbf-signing.sh
  source "$signing_lib"
  if ! rbf_configure_dev_signing; then
    echo "rbf-tcc-preseed: stable signing unavailable; skipping" >&2
    return 0
  fi

  [[ -n "$target" ]] || { echo "rbf-tcc-preseed: no build-id given; skipping" >&2; return 0; }

  # Bundle id: passed through if already one, else derived exactly as
  # reload.sh does (sanitize_bundle -> cmux_attach__bundle_seg).
  local bundle_id
  if [[ "$target" == com.cmuxterm.app.* ]]; then
    bundle_id="$target"
  else
    local seg=""
    # shellcheck source=/dev/null
    if . "${RBF_REPO_ROOT:-.}/scripts/lib/mobile-attach.sh" 2>/dev/null \
        && declare -f cmux_attach__bundle_seg >/dev/null; then
      seg="$(cmux_attach__bundle_seg "$target")"
    fi
    [[ -n "$seg" ]] || { echo "rbf-tcc-preseed: could not derive bundle segment for '$target'; skipping" >&2; return 0; }
    bundle_id="com.cmuxterm.app.debug.${seg}"
  fi

  # Cert SHA1 of the stable identity (what "certificate leaf = H..." names).
  local cert_hash="$RBF_DEV_CODESIGN_CERT_HASH"

  # User TCC.db needs the calling process to hold Full Disk Access.
  if ! sqlite3 "$db" "SELECT 1 FROM access LIMIT 1;" >/dev/null 2>&1; then
    echo "rbf-tcc-preseed: cannot read $db — grant Full Disk Access to this terminal app (System Settings > Privacy & Security) to preseed new build IDs; new IDs may prompt until then; skipping" >&2
    return 0
  fi

  # Template = an already-user-approved cmux dev client. Its row set IS the
  # discovery of persistent services to seed. App Data is an exception:
  # its consent is session-only and cannot be copied across app restarts.
  local template
  # auth_value: 2 = persistent Allow; 0 = Deny. App Data value 5 is
  # session consent, not a durable grant (Apple WWDC23, session 10053).
  template="$(sqlite3 "$db" "SELECT client FROM access WHERE client = 'com.cmuxterm.app.debug' AND auth_value = 2 AND service <> 'kTCCServiceSystemPolicyAppData' LIMIT 1;")"
  [[ -n "$template" ]] || template="$(sqlite3 "$db" \
    "SELECT client FROM access WHERE client LIKE 'com.cmuxterm.app.debug%' AND auth_value = 2 AND service <> 'kTCCServiceSystemPolicyAppData' ORDER BY last_modified DESC LIMIT 1;")"
  [[ -n "$template" ]] || { echo "rbf-tcc-preseed: no approved cmux dev grants to clone yet (approve one build's prompts first); skipping" >&2; return 0; }

  # csreq for the new bundle id + stable cert, as a hex blob for SQL.
  local req tmp csreq_hex
  req="identifier \"$bundle_id\" and certificate leaf = H\"$cert_hash\""
  tmp="$(mktemp)" || return 0
  if ! csreq -r="$req" -b "$tmp" 2>/dev/null; then
    rm -f "$tmp"; echo "rbf-tcc-preseed: csreq compile failed; skipping" >&2; return 0
  fi
  csreq_hex="$(xxd -p "$tmp" | tr -d '\n')"
  rm -f "$tmp"

  # App Data consent is session-only. RBF tagged reload preserves the FDA-
  # approved invoking terminal's responsibility instead of requiring FDA for
  # each build ID. Independent Finder launches have their own attribution.
  # Never clone App Data consent or create system Full Disk Access grants.

  # Repair rows whose stored requirement can never match a future build:
  # - NULL csreq: tccd saves that when Allow is clicked while the bundle is
  #   being rewritten mid-build (observed live, 2026-08-05)
  # - cdhash-pinned or otherwise stale csreq: recorded from an ad-hoc build
  #   before stable signing (observed on com.cmuxterm.app.debug.main — every
  #   rebuild re-prompted despite an allow row)
  # Either way the user's Allow decision stands; only the identity key is
  # rewritten to the stable requirement. Runs before the template
  # short-circuit below so the target's own rows get repaired too.
  sqlite3 "$db" "UPDATE access SET csreq = X'$csreq_hex' WHERE client = '$bundle_id' AND service <> 'kTCCServiceSystemPolicyAppData' AND (csreq IS NULL OR hex(csreq) <> upper('$csreq_hex'));" 2>/dev/null || true
  # tccd serves grants from an in-memory cache; without a bounce it keeps
  # answering from the stale rows AND writes them back over the repair on the
  # next user Allow (observed 2026-08-05 15:30). Bounce on every invocation,
  # including repair-only ones — it respawns instantly on demand.
  killall tccd 2>/dev/null || true

  [[ "$template" == "$bundle_id" ]] && return 0

  # Clone each approved template row, overriding client + csreq. Column list
  # is read live from the schema so a macOS schema change adds columns without
  # breaking the copy. INSERT OR IGNORE: existing rows (user decisions) win.
  local cols select_exprs c expr
  cols="$(sqlite3 "$db" "SELECT group_concat(name) FROM pragma_table_info('access');")"
  [[ -n "$cols" ]] || { echo "rbf-tcc-preseed: could not read access schema; skipping" >&2; return 0; }
  select_exprs=""
  # No case-in-$() — macOS bash 3.2 cannot parse case patterns inside a
  # command substitution, so build the list with plain ifs in the main shell.
  for c in $(printf '%s' "$cols" | tr ',' ' '); do
    if [[ "$c" == "client" ]]; then expr="'$bundle_id'"
    elif [[ "$c" == "csreq" ]]; then expr="X'$csreq_hex'"
    elif [[ "$c" == "last_modified" ]]; then expr="strftime('%s','now')"
    else expr="$c"
    fi
    select_exprs="${select_exprs:+$select_exprs,}$expr"
  done

  # Local Network (multicast) is deliberately NOT handled here. It lives in a
  # root-owned NSKeyedArchiver store (/Library/Preferences/
  # com.apple.networkextension.plist) whose owning daemons rewrite it from
  # memory, erasing out-of-band edits — a seeding attempt on 2026-08-05 lost
  # every record within a minute. The durable fix is app-side: dev builds
  # default the Bonjour listener off (MobileHostService.isListeningEnabled),
  # so no dev build multicasts at launch and the prompt never fires.
  if sqlite3 "$db" "INSERT OR IGNORE INTO access ($cols) SELECT $select_exprs FROM access WHERE client = '$template' AND auth_value = 2 AND service <> 'kTCCServiceSystemPolicyAppData';" 2>/dev/null; then
    local n
    n="$(sqlite3 "$db" "SELECT count(*) FROM access WHERE client = '$bundle_id' AND auth_value = 2 AND service <> 'kTCCServiceSystemPolicyAppData';")"
    echo "rbf-tcc-preseed: $bundle_id pre-granted ($n persistent services, cloned from $template; App Data excluded)" >&2
    # tccd caches; nudge it so the new rows are live before first launch.
    killall tccd 2>/dev/null || true
  else
    echo "rbf-tcc-preseed: insert failed (TCC schema drift?); skipping" >&2
  fi
  return 0
}
