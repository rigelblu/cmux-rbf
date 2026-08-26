#!/usr/bin/env bash
# Fails fast when the checked-in ghostty submodule SHA lacks a pinned
# GhosttyKit archive checksum. This prevents new ghostty bumps from merging
# without the checksum entry that nightly/release workflows require.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECKSUMS_FILE="$ROOT_DIR/scripts/ghosttykit-checksums.txt"

# shellcheck source=scripts/lib/recorded-gitlink.sh
source "$ROOT_DIR/scripts/lib/recorded-gitlink.sh"

if [ ! -f "$CHECKSUMS_FILE" ]; then
  echo "FAIL: missing checksum file $CHECKSUMS_FILE"
  exit 1
fi

GHOSTTY_SHA="$(cmux_recorded_gitlink_sha "$ROOT_DIR" ghostty || true)"
if [[ -z "$GHOSTTY_SHA" ]]; then
  echo "FAIL: could not read the recorded ghostty gitlink from $ROOT_DIR"
  exit 1
fi

MATCH_COUNT="$(
  awk -v sha="$GHOSTTY_SHA" '
    $1 == sha {
      count += 1
    }
    END {
      print count + 0
    }
  ' "$CHECKSUMS_FILE"
)"

if [ "$MATCH_COUNT" -eq 0 ]; then
  echo "FAIL: scripts/ghosttykit-checksums.txt is missing an entry for ghostty $GHOSTTY_SHA"
  exit 1
fi

if [ "$MATCH_COUNT" -ne 1 ]; then
  echo "FAIL: scripts/ghosttykit-checksums.txt has $MATCH_COUNT entries for ghostty $GHOSTTY_SHA"
  exit 1
fi

echo "PASS: scripts/ghosttykit-checksums.txt pins ghostty $GHOSTTY_SHA"
