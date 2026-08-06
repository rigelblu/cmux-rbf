#!/usr/bin/env bash
# install-rbf.sh — build this checkout and install it as `cmux RBF.app`,
# alongside upstream's cmux rather than replacing it.
#
#   rbf/scripts/install-rbf.sh [--dry-run]
#
# THERE IS NO TARGET FLAG, DELIBERATELY. The install path and both bundle ids
# come from rbf/scripts/lib/rbf-channel.env via the resolver, and nothing an
# argument can reach. Aiming an installer that writes to /Applications is the
# dangerous capability; the design choice was that it must not exist rather
# than exist and be blocked. The refusal paths are proved in
# rbf/scripts/lib/rbf-install-target.test.sh, the only place they are reachable.
#
# FOUR MECHANISMS HERE ARE NON-OBVIOUS, AND EACH WAS WRONG IN AN EARLIER DESIGN:
#
#   1. Info.plist values CANNOT be set by xcodebuild build settings. The app
#      target sets GENERATE_INFOPLIST_FILE = NO with a literal
#      INFOPLIST_FILE = Resources/Info.plist, so the whole INFOPLIST_KEY_*
#      family is inert and PRODUCT_BUNDLE_IDENTIFIER= on the command line is
#      build-wide -- it would collapse the app and its nested dock tile plugin
#      onto one identifier. Everything plist-shaped goes through the single
#      PlistBuddy pass below, then signing runs inside-out.
#      (scripts/reloads.sh does the same: its :157-158 build settings do
#      nothing; its :214-217 PlistBuddy calls are what actually work.)
#
#   2. The Release config carries entitlements (Resources/cmux.entitlements,
#      project.pbxproj:9457) that demand a development certificate, while the
#      target has DEVELOPMENT_TEAM = "". Upstream only builds Release in CI with
#      Apple credentials, so a local Release build fails outright. Debug sets
#      CODE_SIGN_ENTITLEMENTS = "" (:9407), which is why reload.sh works. This
#      channel does the same. The only entitlement is keychain-access-groups
#      naming the app's OWN default group, and no code references
#      kSecAttrAccessGroup -- so dropping it costs nothing anyone uses, and RBF
#      simply gets its own keychain items, which is what side-by-side wants.
#      Rejected: signing with an Apple Development cert, which expires annually
#      and resets every TCC grant on renewal -- the exact failure the stable
#      cmux Dev Signing identity exists to prevent.
#
#   3. The Metal toolchain trap, and where its fix ACTUALLY lives — not here.
#      Script phases inherit TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault,
#      which pins xcrun to a toolchain containing no `metal`, so ghostty's shader
#      build dies with "cannot execute tool 'metal' due to missing Metal
#      Toolchain" even when the Metal toolchain (com.apple.dt.toolchain.Metal.
#      32023) is installed and `xcrun -sdk macosx metal` works fine in a normal
#      shell. The ONLY thing that fixes it is `unset TOOLCHAINS` inside
#      scripts/build-ghostty-cli-helper.sh:16 — its header records that neither
#      the calling shell's unset NOR a `TOOLCHAINS=` build-setting override
#      survives into the script phase, both verified 2026-08-01. The
#      TOOLCHAINS="" on the xcodebuild line below is therefore belt-and-braces
#      for THIS process's own toolchain selection (it neutralizes a TOOLCHAINS
#      exported in the invoking shell), not the mechanism. Do not delete the
#      unset in the helper and expect this to cover it. Same trap class as item
#      1: a build setting that looks like it controls something controlled
#      somewhere else entirely.
#
#   4. The swap must be a same-volume rename(2). Build artifacts live on the
#      external drive by repo policy, and /Applications is on the boot volume;
#      rename across volumes fails EXDEV and degrades to copy-over-live-bundle,
#      which is the non-atomic write this is trying to avoid. So the finished
#      bundle is copied to a boot-volume staging dir first, and only the
#      same-volume rename is the swap.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=rbf/scripts/lib/rbf-install-target.sh
source "$SCRIPT_DIR/lib/rbf-install-target.sh"

DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: rbf/scripts/install-rbf.sh [--dry-run]

Build this checkout and install it as `cmux RBF.app` in /Applications, beside
upstream's cmux. Upstream's install is never read, written, or replaced.

Options:
  --dry-run   Print the plan -- target path, both bundle ids, signing identity,
              and the state-migration decision -- then exit without building.
  -h, --help  Show this help.

There is intentionally no option to change the install path or bundle id.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
step() { printf '⋯ %s\n' "$1"; }

# Load and validate the channel record before anything reads RBF_* — this is
# the resolver's own guard (rbf-install-target.sh), not Guard 1 below.
rbf_channel_load "$SCRIPT_DIR/lib" || exit 1
rbf_assert_safe_target || exit 1

# ---------------------------------------------------------------------------
# Guard 1 — route the swap around the app hosting this very terminal (#cm-27).
#
# cmux is a terminal, and RBF is by design the terminal you work in, so this
# command will routinely be typed inside the app it is about to replace. This
# used to be a refusal, and the refusal was right about the ~2-second swap and
# wrong about the ~10-minute build it also blocked: quitting the app kills this
# script's own parent, but only the tail past `codesign --verify` needs the app
# to die. So the guard became routing — hosted by the target, the tail runs in
# a daemonized helper (double-fork + setsid(2); macOS ships no setsid(1)) that
# outlives the PTY; anywhere else it runs inline with live output, exactly as
# before the split. reload.sh and reloadp.sh both kill first and face none of
# this, because a tagged build is never where you work.
# ---------------------------------------------------------------------------
# shellcheck source=rbf/scripts/lib/rbf-swap.sh
source "$SCRIPT_DIR/lib/rbf-swap.sh"
SWAP_MODE="$(rbf_swap_mode "$RBF_BUNDLE_ID")"
SWAP_LOG="${HOME}/Library/Logs/cmux-rbf/install.log"
# Generous on purpose: a healthy helper claims in milliseconds, so waiting costs
# nothing, while a false timeout costs the user the session they are sitting in.
SWAP_CLAIM_TIMEOUT_S=30

# ---------------------------------------------------------------------------
# Guard 2 — a stable signing identity, or nothing.
#
# Deliberately the OPPOSITE of reload.sh:1071, which warns and falls back to
# ad-hoc. macOS keys TCC grants (Accessibility, Screen Recording, Full Disk
# Access) to the code-signing designated requirement; an ad-hoc install changes
# it every build and silently drops every permission. For a throwaway tagged
# build that is a shrug. For the app you live in it is not.
# ---------------------------------------------------------------------------
CODESIGN_IDENTITY="${CMUX_DEV_CODESIGN_IDENTITY:-cmux Dev Signing}"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$CODESIGN_IDENTITY"; then
  printf 'error: signing identity not found: %s\n' "$CODESIGN_IDENTITY" >&2
  printf '       Not falling back to ad-hoc signing: that changes the designated\n' >&2
  printf '       requirement on every install, so macOS drops every permission\n' >&2
  printf '       you have granted (Accessibility, Screen Recording, Full Disk).\n' >&2
  printf '       Create it once in Keychain Access (Certificate Assistant →\n' >&2
  printf '       Create a Certificate → Code Signing, self-signed), or set\n' >&2
  printf '       CMUX_DEV_CODESIGN_IDENTITY to one you already have.\n' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Guard 3 — a Zig ghostty will accept, or nothing.
#
# ghostty pins 0.15.2 exactly and a stock PATH here is 0.16.0. Without this the
# Release build ran for minutes and then died inside an xcodebuild Run Script
# phase with "zig 0.15.2 is required to build the Ghostty CLI helper", buried in
# a wall of `export FOO=bar` that reads like an Xcode fault.
#
# Resolved here so the plan can PRINT it, enforced again after the --dry-run
# exit so a dry run still prints. A plan is information; refusing to show one
# because the build would fail is withholding the very fact worth reading.
#
# The plan line comes from the STRICT check's exit code, never from "is CMUX_ZIG
# set". A WRONG CMUX_ZIG is set, so set-ness read as validity: this printed
# `zig  /usr/bin/false` as though it were fine, and the enforcement below --
# guarded by the same set-ness test -- then skipped itself, handing a guaranteed
# failure to a script phase ten minutes into a Release build.
# ---------------------------------------------------------------------------
RBF_REPO_ROOT="$REPO_ROOT"
# shellcheck source=rbf/scripts/lib/rbf-zig.sh
source "$SCRIPT_DIR/lib/rbf-zig.sh"
if rbf_ensure_zig --required >/dev/null 2>&1; then
  ZIG_STATUS="$CMUX_ZIG"
elif [[ -n "${CMUX_ZIG:-}" ]]; then
  ZIG_STATUS="UNUSABLE — CMUX_ZIG=$CMUX_ZIG is not $RBF_ZIG_REQUIRED; build will fail"
else
  ZIG_STATUS="NOT FOUND — build will fail (need $RBF_ZIG_REQUIRED)"
fi

RBF_VERSION="$(tr -d '[:space:]' < "$REPO_ROOT/rbf/VERSION" 2>/dev/null || true)"
[[ -n "$RBF_VERSION" ]] || die "rbf/VERSION is empty or unreadable"
GIT_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"

INSTALL_PATH="$(rbf_physical_path "$RBF_INSTALL_PATH")"
STAGING_ROOT="$(dirname "$INSTALL_PATH")/.cmux-rbf-staging.$$"
# Deliberately a SIBLING of the staging dir, not a child. The previous install is
# parked here during the swap, and for those two renames it is the only copy of a
# working app on the machine. The EXIT trap unlinks $STAGING_ROOT on any exit --
# including a signal -- so parking the old bundle inside it would let an
# interrupt between "move the old aside" and "move the new in" leave
# /Applications with no app at all and nothing to roll back to. One directory
# must not hold both "delete this on any exit" and "the only copy of your app".
ROLLBACK_ROOT="$(dirname "$INSTALL_PATH")/.cmux-rbf-rollback.$$"
# A Release DerivedData is multi-GB, and repo policy keeps large build
# artifacts off the near-full internal SSD. Prefer the external drive when it
# is mounted; fall back to TMPDIR when it is not, rather than failing.
#
# The mount check and the fallback used to be spelled out here, and dev.sh grew
# a second copy of the same decision. Both now call rbf_tmp_dir, so there is one
# answer to "where do big throwaway artifacts go" instead of two that drift.
# The on-drive path is byte-identical to the old one, so an existing build is
# reused rather than recompiled. Only the drive-offline fallback moves, from
# $TMPDIR/cmux-rbf-derived to $TMPDIR/cmux-rbf-cm-17-install/derived — both
# internal, both throwaway, and reached only when the drive is unplugged.
# shellcheck source=rbf/scripts/lib/rbf-tmp.sh
. "$REPO_ROOT/rbf/scripts/lib/rbf-tmp.sh"
DERIVED_DATA="${CMUX_RBF_DERIVED_DATA:-}"
if [[ -z "$DERIVED_DATA" ]]; then
  DERIVED_DATA="$(rbf_tmp_dir "cmux-rbf-cm-17-install")/derived"
fi

# Is this a first install? Decides whether state migration runs. Destination
# existence, not a flag — a flag can be passed twice, existence cannot lie.
FIRST_INSTALL=0
[[ -d "$INSTALL_PATH" ]] || FIRST_INSTALL=1

printf 'cmux RBF install plan\n'
printf '  app name       %s\n'  "$RBF_APP_NAME"
printf '  bundle id      %s\n'  "$RBF_BUNDLE_ID"
printf '  plugin id      %s\n'  "$RBF_PLUGIN_BUNDLE_ID"
printf '  install path   %s\n'  "$INSTALL_PATH"
printf '  icon set       %s\n'  "$RBF_ICON_SET"
printf '  rbf version    %s (%s)\n' "$RBF_VERSION" "$GIT_COMMIT"
printf '  signing        %s\n'  "$CODESIGN_IDENTITY"
printf '  zig            %s\n'  "$ZIG_STATUS"
printf '  derived data   %s\n'  "$DERIVED_DATA"
if [[ "$SWAP_MODE" == "detached" ]]; then
  printf '  swap           detached — this terminal is hosted by the app being replaced;\n'
  printf '                 outcome via notification + %s\n' "$SWAP_LOG"
else
  printf '  swap           inline — live output in this terminal\n'
fi
printf '  upstream       %s (never touched)\n' "$UPSTREAM_INSTALL_PATH"
if [[ $FIRST_INSTALL -eq 1 ]]; then
  printf '  state          first install — will migrate from %s\n' "$UPSTREAM_BUNDLE_ID"
else
  printf '  state          existing install — RBF state preserved, not re-cloned\n'
fi
printf '\n'

if [[ $DRY_RUN -eq 1 ]]; then
  printf 'dry run — nothing built, nothing written.\n'
  if [[ $FIRST_INSTALL -eq 1 ]]; then
    printf '\nstate migration would run:\n'
    bash "$SCRIPT_DIR/migrate-rbf-state.sh" --dry-run 2>&1 | sed 's/^/  /'
  fi
  exit 0
fi

# Now enforce Guard 3. Strict here and only a warning in dev.sh, because that
# path may be rescued by a cached GhosttyKit while this one builds into its own
# Release DerivedData with no such cache — so a miss is a guaranteed failure
# that otherwise costs a full compile to discover.
#
# Unconditional, and cheap when it passes: the call above suppressed the
# diagnostics so the plan stayed readable, so this is also what PRINTS the
# reason before exiting. Do not put a condition in front of it — the previous
# `[[ -z "${CMUX_ZIG:-}" ]]` made a wrong CMUX_ZIG the one input that skipped it.
rbf_ensure_zig --required || exit 1

# Claim-aware: once the swap helper has claimed staging (atomic mkdir of the
# sentinel — rbf_swap_claim_path in lib/rbf-swap.sh), this trap owns nothing
# and must delete nothing, even if it fires before the explicit `trap - EXIT`
# below — bash runs EXIT traps on an untrapped SIGHUP, so a PTY teardown in
# that gap would otherwise delete the app mid-swap (cold review, 2026-08-04).
cleanup() {
  [[ -n "${STAGING_ROOT:-}" && -d "$STAGING_ROOT" ]] || return 0
  [[ -e "$(rbf_swap_claim_path "$STAGING_ROOT")" ]] && return 0
  rm -rf "$STAGING_ROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
step "building Release (this takes a while)"
# Only ASSETCATALOG_COMPILER_APPICON_NAME rides the xcodebuild line: it is a real
# build setting consumed at asset-compile time. Nothing plist-shaped is passed
# here — see the header.
#
# TOOLCHAINS="" is belt-and-braces, NOT the Metal fix. It only neutralizes a
# TOOLCHAINS exported in the invoking shell; it does not reach the script phase
# where the Metal failure happens. That fix is the `unset TOOLCHAINS` in
# scripts/build-ghostty-cli-helper.sh:16 — see header item 3 before touching
# either one.
# ---------------------------------------------------------------------------
xcodebuild \
  -project "$REPO_ROOT/cmux.xcodeproj" \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ASSETCATALOG_COMPILER_APPICON_NAME="$RBF_ICON_SET" \
  CODE_SIGN_ENTITLEMENTS="" \
  TOOLCHAINS="" \
  build || die "xcodebuild failed — nothing was written to /Applications"

BUILT_APP="$DERIVED_DATA/Build/Products/Release/cmux.app"
[[ -d "$BUILT_APP" ]] || die "build succeeded but no app at $BUILT_APP"

# ---------------------------------------------------------------------------
step "staging and rewriting bundle identity"
# ---------------------------------------------------------------------------
mkdir -p "$STAGING_ROOT" || die "cannot create staging dir on the install volume: $STAGING_ROOT"
STAGED_APP="$STAGING_ROOT/$(basename "$INSTALL_PATH")"
ditto "$BUILT_APP" "$STAGED_APP" || die "failed to stage the built app"

APP_PLIST="$STAGED_APP/Contents/Info.plist"
plist_set() {
  local plist="$1" key="$2" type="$3" value="$4"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$plist" \
    || die "PlistBuddy failed to set $key in $plist"
}

plist_set "$APP_PLIST" CFBundleName          string "$RBF_APP_NAME"
plist_set "$APP_PLIST" CFBundleDisplayName   string "$RBF_APP_NAME"
plist_set "$APP_PLIST" CFBundleIdentifier    string "$RBF_BUNDLE_ID"
plist_set "$APP_PLIST" "$RBF_VERSION_PLIST_KEY" string "$RBF_VERSION"
# Sparkle: upstream's feed is baked into the literal plist and would offer
# upstream's 0.64.x as an "update" to this build. Both carry CFBundleVersion
# 100, so the comparison is not something to rely on — turn the check off.
plist_set "$APP_PLIST" SUEnableAutomaticChecks bool false
plist_set "$APP_PLIST" SUAutomaticallyUpdate   bool false
# The app reads its own identity from here; this is what makes Guard 1 above
# work at all, and mirrors scripts/reloads.sh:233-236.
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$APP_PLIST" 2>/dev/null || true
plist_set "$APP_PLIST" "LSEnvironment:CMUX_BUNDLE_ID" string "$RBF_BUNDLE_ID"

# A nested bundle's plist lives at <name>.plugin/Contents/Info.plist -- depth 3
# from PlugIns, not 2. An earlier -maxdepth 2 here silently found nothing and
# shipped an install whose dock tile plugin still carried UPSTREAM's id,
# colliding with upstream's own installed plugin. The "note: no nested plugin
# found" it printed read like an absence, not a miss.
PLUGIN_COUNT=0
while IFS= read -r plugin_plist; do
  [[ -n "$plugin_plist" ]] || continue
  plist_set "$plugin_plist" CFBundleIdentifier string "$RBF_PLUGIN_BUNDLE_ID"
  printf '  plugin id set: %s (%s)\n' "$RBF_PLUGIN_BUNDLE_ID" "$(basename "$(dirname "$(dirname "$plugin_plist")")")"
  PLUGIN_COUNT=$((PLUGIN_COUNT + 1))
done < <(find "$STAGED_APP/Contents/PlugIns" -maxdepth 3 -name Info.plist 2>/dev/null)

# The app HAS a nested plugin (project.pbxproj declares CmuxDockTilePlugin with
# its own per-config ids). Finding none means the search is wrong, not that the
# plugin is absent -- fail rather than ship a colliding id again.
if [[ $PLUGIN_COUNT -eq 0 ]]; then
  die "no nested plugin plist found under $STAGED_APP/Contents/PlugIns — refusing to install an app whose plugin would keep upstream's bundle id"
fi

# ---------------------------------------------------------------------------
step "signing inside-out"
# Nested code must be signed before the outer bundle, or re-signing the app
# invalidates the seal over the plists just edited.
# ---------------------------------------------------------------------------
while IFS= read -r nested; do
  codesign --force --timestamp=none --sign "$CODESIGN_IDENTITY" "$nested" \
    || die "failed to sign nested bundle: $nested"
done < <(find "$STAGED_APP/Contents/PlugIns" "$STAGED_APP/Contents/Frameworks" \
           -maxdepth 1 \( -name '*.plugin' -o -name '*.framework' -o -name '*.appex' \) 2>/dev/null)

codesign --force --deep --timestamp=none \
  --sign "$CODESIGN_IDENTITY" "$STAGED_APP" || die "failed to sign $STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP" || die "signature verification failed"

# ---------------------------------------------------------------------------
# The tail — quit, swap, migrate, report — lives in lib/rbf-swap.sh since
# #cm-27, because it is the only part that cannot survive this script's own
# parent dying. Everything below the codesign --verify above only ever touched
# DerivedData and the staging dir; everything from the quit onward mutates
# /Applications and must not be interrupted by the app hosting this terminal
# going away. The helper receives every value through its argument contract and
# re-derives nothing.
# ---------------------------------------------------------------------------
SWAP_ARGS=(
  --staged-app "$STAGED_APP"
  --staging-root "$STAGING_ROOT"
  --rollback-root "$ROLLBACK_ROOT"
  --install-path "$INSTALL_PATH"
  --bundle-id "$RBF_BUNDLE_ID"
  --upstream-bundle-id "$UPSTREAM_BUNDLE_ID"
  --upstream-path "$UPSTREAM_INSTALL_PATH"
  --first-install "$FIRST_INSTALL"
  --rbf-version "$RBF_VERSION"
  --git-commit "$GIT_COMMIT"
  --log-file "$SWAP_LOG"
)

if [[ "$SWAP_MODE" == "inline" ]]; then
  # A child process, deliberately not `exec`: bash skips EXIT traps on exec,
  # which would orphan the staging cleanup this script still owns. Once the
  # helper claims staging, our claim-aware trap goes inert and the helper's
  # own trap cleans up; if the helper dies before claiming, our trap still
  # holds. One owner at every instant, zero windows.
  bash "$SCRIPT_DIR/lib/rbf-swap.sh" --mode inline "${SWAP_ARGS[@]}"
  exit $?
fi

# Detached: daemonize the helper (double-fork + setsid(2) — macOS ships no
# setsid(1) binary), then wait for it to CLAIM staging (atomic mkdir) before
# standing down. Ownership is an election, not a baton: if the wait times out,
# we reclaim by the same atomic mkdir — whoever wins is the only process that
# may delete staging or act against the app, so a slow helper either claims
# in time or finds the claim taken and exits touching nothing. The wait length
# costs nothing when the helper is healthy (it claims in milliseconds) and a
# false timeout would cost the user's whole session, so it is deliberately
# generous.
step "handing the swap to a detached helper — this terminal is hosted by the app being replaced"
mkdir -p "$(dirname "$SWAP_LOG")" || die "cannot create log dir for $SWAP_LOG"

if ! rbf_swap_launch_detached "$STAGING_ROOT" "$SWAP_LOG" "$SWAP_CLAIM_TIMEOUT_S" \
     /bin/bash "$SCRIPT_DIR/lib/rbf-swap.sh" --mode detached "${SWAP_ARGS[@]}"; then
  # We hold the claim: the helper can never act now. Delete staging ourselves
  # (the claim-aware trap would refuse — the claim dir exists) and report on a
  # terminal that is still alive; the app was never quit.
  rm -rf "$STAGING_ROOT"
  trap - EXIT
  die "swap helper never claimed ownership within ${SWAP_CLAIM_TIMEOUT_S}s — ownership reclaimed, staging cleaned up; the helper cannot act and nothing was installed. See $SWAP_LOG"
fi

# The helper holds the claim: staging is its to guard and ours to leave alone.
# The claim-aware trap above is already inert; this disarm is hygiene.
trap - EXIT

printf '\n⋯ handing off — cmux RBF will quit, ending ALL its shells and agents, then swap and relaunch.\n'
printf '  log: %s\n' "$SWAP_LOG"
printf '  a notification will confirm success or failure.\n'
exit 0
