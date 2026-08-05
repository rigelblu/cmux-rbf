#!/bin/bash
# One-time root install for the Local Network pre-grant helper.
#
# Copies rbf-localnet-preseed.py to a ROOT-OWNED path and adds a sudoers rule
# allowing the invoking user to run exactly that copy without a password.
# The repo copy stays user-writable and is never in the sudoers rule — that
# split is the security boundary: editing the repo cannot escalate; changing
# the privileged copy requires running this installer (with sudo) again.
#
# Run:  sudo rbf/scripts/install-localnet-preseed.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "run with sudo: sudo $0" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$REPO_ROOT/rbf/scripts/lib/rbf-localnet-preseed.py"
DEST_DIR="/usr/local/lib/cmux-rbf"
DEST="$DEST_DIR/rbf-localnet-preseed.py"
# The user who ran sudo — the one the NOPASSWD rule is for.
RULE_USER="${SUDO_USER:?must be run via sudo, not a root shell}"
SUDOERS="/etc/sudoers.d/cmux-rbf-localnet"

[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

mkdir -p "$DEST_DIR"
chown root:wheel "$DEST_DIR"
chmod 755 "$DEST_DIR"
cp "$SRC" "$DEST"
chown root:wheel "$DEST"
chmod 755 "$DEST"

printf '%s ALL=(root) NOPASSWD: /usr/bin/python3 %s *\n' "$RULE_USER" "$DEST" > "$SUDOERS.tmp"
chmod 440 "$SUDOERS.tmp"
# visudo -c validates before the rule goes live; a bad file here locks sudo out.
if visudo -c -f "$SUDOERS.tmp" >/dev/null; then
  mv "$SUDOERS.tmp" "$SUDOERS"
  echo "installed: $DEST"
  echo "sudoers rule for $RULE_USER: $SUDOERS"
else
  rm -f "$SUDOERS.tmp"
  echo "sudoers validation failed; rule NOT installed" >&2
  exit 1
fi
