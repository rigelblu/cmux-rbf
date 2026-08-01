#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "Running release pre-tag checks..."
"$ROOT_DIR/tests/test_ci_sparkle_build_monotonic.sh"

# The submodule pointer must match what is actually checked out. A mismatch is
# invisible at build time — the build succeeds against whatever is on disk — and
# it means the source you debug is not the source you shipped. cmux ran 65
# commits with a linked GhosttyKit that did not match its recorded pointer.
echo "Checking submodule pointers match their checkouts..."
if ! git -C "$ROOT_DIR" submodule status --recursive | grep -qv '^ '; then
  echo "  submodules match recorded pointers."
else
  echo "ERROR: a submodule differs from its recorded pointer." >&2
  git -C "$ROOT_DIR" submodule status --recursive | grep -v '^ ' >&2
  echo "  '-' = not checked out, '+' = different commit than recorded." >&2
  echo "  Run: git submodule update --init --recursive" >&2
  exit 1
fi

# cmuxTests must COMPILE before a release. It is not run here — the suite needs a
# quiet machine and no tagged app holding the test host — but a test target that
# does not build is indistinguishable from a passing one in every report, and
# shipped twice unnoticed because CI is workflow_dispatch-only.
echo "Compiling the unit test target (scheme cmux-unit)..."
if ! xcodebuild build-for-testing \
      -project "$ROOT_DIR/cmux.xcodeproj" \
      -scheme cmux-unit \
      -configuration Debug \
      -destination 'platform=macOS' \
      -derivedDataPath "${CMUX_PRETAG_DERIVED_DATA:-$ROOT_DIR/.pretag-dd}" \
      > /tmp/cmux-pretag-testbuild.log 2>&1; then
  echo "ERROR: cmuxTests does not compile — refusing to tag a release." >&2
  grep -E 'error:' /tmp/cmux-pretag-testbuild.log | head -20 >&2
  echo "  full log: /tmp/cmux-pretag-testbuild.log" >&2
  exit 1
fi
echo "  unit test target compiles."

echo "Release pre-tag checks passed."
