#!/usr/bin/env python3
"""Pre-grant the macOS Local Network (multicast) permission for a dev bundle id.

Why: the Local Network prompt is not TCC — it lives in the root-owned
NSKeyedArchiver plist /Library/Preferences/com.apple.networkextension.plist,
one record per signing identifier with two flags: MulticastPreferenceSet
(has the user answered?) and DenyMulticast (the answer). A new branch mints a
new bundle id, so its first launch prompts. This edits the archive in place:
existing record -> flip the flags to granted; missing record -> clone a
granted record, append the identifier string, and wire it into the owning
NSArray. Structure verified live on macOS 26 (2026-08-05): every app record
sits in one NS.objects array; SigningIdentifier is a UID to the id string.

Runs as root (the file is root-owned). Intended to be installed root-owned
outside the repo and allowed via a NOPASSWD sudoers rule, so a user-writable
repo copy can never be a privilege escalation: sudo points only at the
root-owned copy.

Fail-soft: any surprise (schema drift, missing template) exits 0 with a
message on stderr — the caller's fallback is one Allow click, never a broken
build. Exit 1 only for usage errors.

Usage: rbf-localnet-preseed.py <bundle-id> [<bundle-id>...]
"""
import copy
import os
import plistlib
import subprocess
import sys

# RBF_NE_PLIST overrides the target for tests against a copy — never set in
# production wiring.
PLIST = os.environ.get(
    "RBF_NE_PLIST", "/Library/Preferences/com.apple.networkextension.plist"
)


def warn(msg):
    print(f"rbf-localnet-preseed: {msg}", file=sys.stderr)


def main(bundle_ids):
    try:
        with open(PLIST, "rb") as f:
            data = plistlib.load(f)
    except Exception as e:  # unreadable / not root / format change
        warn(f"cannot read {PLIST}: {e}; skipping")
        return 0

    objs = data.get("$objects")
    if not isinstance(objs, list):
        warn("unexpected archive shape (no $objects); skipping")
        return 0

    def record_for(uid_of_string):
        for i, o in enumerate(objs):
            if isinstance(o, dict) and "SigningIdentifier" in o:
                sid = o["SigningIdentifier"]
                if isinstance(sid, plistlib.UID) and sid.data == uid_of_string:
                    return i
        return None

    # A granted record to clone from, and the NSArray that owns app records.
    template_idx = None
    owner_array = None
    for i, o in enumerate(objs):
        if (
            isinstance(o, dict)
            and o.get("MulticastPreferenceSet") is True
            and o.get("DenyMulticast") is False
            and "SigningIdentifier" in o
        ):
            template_idx = i
            break
    if template_idx is not None:
        for o in objs:
            if isinstance(o, dict) and isinstance(o.get("NS.objects"), list):
                if any(
                    isinstance(u, plistlib.UID) and u.data == template_idx
                    for u in o["NS.objects"]
                ):
                    owner_array = o
                    break

    changed = False
    for bundle_id in bundle_ids:
        string_uid = next(
            (i for i, o in enumerate(objs) if o == bundle_id), None
        )
        if string_uid is not None:
            rec = record_for(string_uid)
            if rec is not None:
                r = objs[rec]
                if r.get("DenyMulticast") is not False or r.get("MulticastPreferenceSet") is not True:
                    r["DenyMulticast"] = False
                    r["MulticastPreferenceSet"] = True
                    changed = True
                    warn(f"{bundle_id}: existing record flipped to granted")
                else:
                    warn(f"{bundle_id}: already granted")
                continue
        # No record: clone the template.
        if template_idx is None or owner_array is None:
            warn(f"{bundle_id}: no granted template record to clone; skipping")
            continue
        new_rec = copy.deepcopy(objs[template_idx])
        objs.append(bundle_id)
        new_string_uid = len(objs) - 1
        new_rec["SigningIdentifier"] = plistlib.UID(new_string_uid)
        new_rec["DenyMulticast"] = False
        new_rec["MulticastPreferenceSet"] = True
        objs.append(new_rec)
        owner_array["NS.objects"].append(plistlib.UID(len(objs) - 1))
        changed = True
        warn(f"{bundle_id}: record created (granted)")

    if not changed:
        return 0

    tmp = PLIST + ".rbf-tmp"
    # The NE daemons keep this store in memory and write it back on their own
    # schedule, erasing out-of-band edits (proven live 2026-08-05: a seeded
    # record vanished within a minute, generation bumped). SIGTERM makes it
    # WORSE — they flush stale state while dying. SIGKILL first, then write:
    # no flush, and launchd respawns them against the fresh file. Skipped in
    # tests (RBF_NE_PLIST set) — never kill daemons over a copy.
    if "RBF_NE_PLIST" not in os.environ:
        subprocess.run(
            ["/usr/bin/killall", "-9", "nehelper", "nesessionmanager"],
            capture_output=True,
        )
    try:
        # Keep the pre-edit bytes beside the file; restoring is one copy back.
        with open(PLIST, "rb") as f, open(PLIST + ".rbf-backup", "wb") as b:
            b.write(f.read())
        with open(tmp, "wb") as f:
            plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)
        os.chmod(tmp, 0o644)
        os.replace(tmp, PLIST)
    except Exception as e:
        warn(f"write failed: {e}; original untouched")
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return 0
    # No post-write kill: the daemons were SIGKILLed pre-write and respawn
    # reading this fresh file; a SIGTERM here would flush stale state over it.
    warn("written")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: rbf-localnet-preseed.py <bundle-id> [...]", file=sys.stderr)
        sys.exit(1)
    sys.exit(main(sys.argv[1:]))
