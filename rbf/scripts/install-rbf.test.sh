#!/usr/bin/env bash
# install-rbf.test.sh — drive install-rbf.sh end to end against a fixture copy of
# itself (#cm-142.2).
#
#   bash rbf/scripts/install-rbf.test.sh
#
# The installer is the one script that builds, stages, signs and then replaces
# the everyday app, and none of that can run in a test. So the test copies the
# script and its lib/ into a fixture repo, rewrites the two channel records to
# point at fixture paths (the records are the only place an install path and a
# bundle id are written), and puts stubs where the machine would be: a fake
# `xcodebuild` and `codesign` on PATH, stub signing/zig/metal/git-env libs, a fake
# `defaults`, and a probe on the swap helper that records that it was reached.
# The real swap helper, keep branch and id rule run unchanged, against the fixture
# apps, inline. Nothing here touches /Applications, a real app or real state.
#
# What it proves:
#   - RBF_KEEP_PREVIOUS=1 reaches `--keep-previous-root` (the folder appears)
#   - `--build-only` stops after the signature check, before the swap helper is
#     reached (stop one), and exports RBF_BUILD_ONLY=1 so the helper would refuse
#     (stop two, proved in rbf-swap.test.sh)
#   - without either, the install is what it was

set -uo pipefail

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPTS_DIR/lib"
# shellcheck source=rbf/scripts/lib/rbf-testkit.sh
source "$LIB_DIR/rbf-testkit.sh"
rbf_test_begin rbf-install-test

ID="com.example.installtest"
NAME="cmux RBF (fx)"

# fixture_repo: copies the installer into a fixture repo and stubs the machine.
# Sets FX (root), and the paths below.
fixture_repo() {
  FX="$(rbf_test_world install)"
  REPO="$FX/repo"
  mkdir -p "$FX/tmp" "$REPO/rbf/scripts" "$REPO/scripts" "$REPO/cmux.xcodeproj" "$FX/bin" "$FX/upstream/cmux.app" "$FX/probe"
  command cp -f "$SCRIPTS_DIR/install-rbf.sh" "$REPO/rbf/scripts/install-rbf.sh"
  command cp -Rf "$LIB_DIR" "$REPO/rbf/scripts/lib"
  command rm -f "$REPO/rbf/scripts/lib/"*.test.sh
  printf '0.0.1-fx\n' > "$REPO/rbf/VERSION"
  printf '#!/bin/sh\nexit 0\n' > "$REPO/scripts/ensure-ghosttykit.sh"; chmod +x "$REPO/scripts/ensure-ghosttykit.sh"
  L="$REPO/rbf/scripts/lib"
  # channel records: fixture identities and paths, same keys
  cat > "$L/rbf-channel.env" <<EOF
RBF_APP_NAME="cmux RBF fx-regular"
RBF_BUNDLE_ID="com.example.regular"
RBF_PLUGIN_BUNDLE_ID="com.example.regular.plugin"
RBF_INSTALL_PATH="$FX/apps/cmux RBF fx-regular.app"
RBF_ICON_SET="AppIcon-RBF"
RBF_VERSION_PLIST_KEY="RBFVersion"
UPSTREAM_BUNDLE_ID="com.example.upstreamapp"
UPSTREAM_INSTALL_PATH="$FX/upstream/cmux.app"
EOF
  cat > "$L/rbf-dogfood-channel.env" <<EOF
RBF_APP_NAME="$NAME"
RBF_BUNDLE_ID="$ID"
RBF_PLUGIN_BUNDLE_ID="$ID.plugin"
RBF_INSTALL_PATH="$FX/apps/$NAME.app"
RBF_ICON_SET="AppIcon-RBF"
RBF_VERSION_PLIST_KEY="RBFVersion"
UPSTREAM_BUNDLE_ID="com.example.upstreamapp"
UPSTREAM_INSTALL_PATH="$FX/upstream/cmux.app"
EOF
  # stubs where the machine would be
  cat > "$L/rbf-signing.sh" <<'EOF'
rbf_configure_dev_signing() { CMUX_DEV_CODESIGN_IDENTITY="fixture identity"; return 0; }
rbf_verify_dev_signing() { [[ "${FX_VERIFY_FAIL:-0}" != 1 ]]; }
EOF
  cat > "$L/rbf-zig.sh" <<'EOF'
RBF_ZIG_REQUIRED="0.0.0"
rbf_ensure_zig() { CMUX_ZIG="/fixture/zig"; return 0; }
EOF
  cat > "$L/rbf-metal.sh" <<'EOF'
rbf_ensure_metal_toolchain() { CMUX_METAL_TOOLCHAIN="fixture"; return 0; }
EOF
  cat > "$L/rbf-git-env.sh" <<'EOF'
RBF_GIT_ENV_NOTE=""
rbf_git_env_apply() { :; }
EOF
  # the swap helper, with a probe that records that it was reached
  perl -pi -e 's/^  rbf_swap_main "\$@"$/  : > "\$RBF_TEST_SWAP_PROBE"; rbf_swap_main "\$@"/' "$L/rbf-swap.sh"
  # fake xcodebuild: records its call and the RBF_BUILD_ONLY it saw, then makes a built app
  cat > "$FX/bin/xcodebuild" <<EOF
#!/bin/bash
echo "called RBF_BUILD_ONLY=\${RBF_BUILD_ONLY:-unset}" >> "$FX/xcodebuild.calls"
dd=""; while [[ \$# -gt 0 ]]; do [[ "\$1" == -derivedDataPath ]] && dd="\$2"; shift; done
app="\$dd/Build/Products/Release/cmux.app"
mkdir -p "\$app/Contents/PlugIns/Dock.plugin/Contents" "\$app/Contents/Resources"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.built" "\$app/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.example.built.plugin" "\$app/Contents/PlugIns/Dock.plugin/Contents/Info.plist" >/dev/null
printf built > "\$app/Contents/Resources/marker"
EOF
  printf '#!/bin/sh\nexit 0\n' > "$FX/bin/codesign"
  chmod +x "$FX/bin/xcodebuild" "$FX/bin/codesign"
  rbf_test_fake_defaults "$FX/bin" "$FX/defaults-store"
  # the installed app and state the install replaces
  rbf_test_make_app "$FX/apps/$NAME.app" "$ID" 0.0.0-old oldcommit old
  rbf_test_make_state "$FX/home" "$ID" one
  printf 'defaults-one' > "$FX/defaults-store/$ID.plist"
  mkdir -p "$FX/apps"
}

# run_installer <args...>: the fixture installer, inline, with a clean environment.
# Sets RC. stdout/stderr go to $FX/out and $FX/err.
run_installer() {
  (
    cd "$FX" || exit 1
    env -i HOME="$FX/home" PATH="$FX/bin:/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$FX/tmp/" \
      RBF_DEFAULTS_BIN="$FX/bin/defaults" CMUX_DOGFOOD_DERIVED_DATA="$FX/derived" \
      RBF_TEST_SWAP_PROBE="$FX/probe/swap-reached" EXTERNAL_DRIVE="$FX" \
      ${EXTRA_ENV:-} \
      bash "$REPO/rbf/scripts/install-rbf.sh" --dogfood "$@" > "$FX/out" 2> "$FX/err"
  ); RC=$?
}
backups() { printf '%s/home/Library/Application Support/cmux/migration-backups/%s' "$FX" "$ID"; }
installed_marker() { cat "$FX/apps/$NAME.app/Contents/Resources/marker" 2>&1; }
staging_left() { ls -d "$FX"/apps/.cmux-rbf-staging.* "$FX"/apps/.cmux-rbf-rollback.* 2>/dev/null | wc -l | tr -d ' '; }

# =============================================================================
printf 'the install as it was (control)\n'
fixture_repo; EXTRA_ENV=""
run_installer
if [[ $RC -eq 0 && "$(installed_marker)" == built && -e "$FX/probe/swap-reached" && ! -e "$(backups)" \
      && "$(staging_left)" == 0 ]] && ! grep -q 'kept ' "$FX/out" && ! grep -q 'keeping' "$FX/out"; then
  ok "no flag, no variable: builds, swaps the new app in, keeps nothing, leaves no staging, prints no keep lines"
else
  bad "plain install" "rc=$RC installed=$(installed_marker) probe=$([[ -e "$FX/probe/swap-reached" ]] && echo yes || echo no) backups=$(ls "$(backups)" 2>&1) out=$(tail -12 "$FX/out") err=$(cat "$FX/err")"
fi

printf '\nRBF_KEEP_PREVIOUS=1 reaches --keep-previous-root\n'
fixture_repo; EXTRA_ENV="RBF_KEEP_PREVIOUS=1"
run_installer
KEPT_DIR="$(ls -d "$(backups)"/pre-install-* 2>/dev/null | tail -1)"
if [[ $RC -eq 0 && "$(installed_marker)" == built && -n "$KEPT_DIR" && "$(cat "$KEPT_DIR/$NAME.app/Contents/Resources/marker" 2>&1)" == old \
      && "$(cat "$KEPT_DIR/Library/WebKit/$ID/marker" 2>&1)" == one && -f "$KEPT_DIR/kept.env" ]] \
   && grep -qF "$KEPT_DIR" "$FX/out"; then
  ok "RBF_KEEP_PREVIOUS=1: the old app and its state are in a pre-install-<ts> folder under migration-backups/<id>/, and the log names it"
else
  bad "keep wiring" "rc=$RC installed=$(installed_marker) kept=$KEPT_DIR backups=$(ls "$(backups)" 2>&1) out=$(tail -8 "$FX/out") err=$(cat "$FX/err")"
fi

fixture_repo; EXTRA_ENV="RBF_KEEP_PREVIOUS=0"
run_installer
if [[ $RC -eq 0 && "$(installed_marker)" == built && ! -e "$(backups)" ]]; then
  ok "RBF_KEEP_PREVIOUS=0 keeps nothing"
else
  bad "keep 0" "rc=$RC backups=$(ls "$(backups)" 2>&1)"
fi

fixture_repo; EXTRA_ENV="RBF_KEEP_PREVIOUS=yes"
run_installer
if [[ $RC -ne 0 && ! -e "$FX/xcodebuild.calls" && "$(installed_marker)" == old && ! -e "$FX/probe/swap-reached" ]] \
   && grep -q "RBF_KEEP_PREVIOUS" "$FX/err"; then
  ok "any other RBF_KEEP_PREVIOUS value is refused before the build starts; the app is untouched"
else
  bad "keep junk value" "rc=$RC xcodebuild=$([[ -e "$FX/xcodebuild.calls" ]] && echo called || echo no) err=$(cat "$FX/err")"
fi

printf '\n--build-only stops before the swap (stop one)\n'
fixture_repo; EXTRA_ENV=""
run_installer --build-only
if [[ $RC -eq 0 && "$(installed_marker)" == old && ! -e "$FX/probe/swap-reached" && "$(staging_left)" == 0 \
      && -e "$FX/xcodebuild.calls" && ! -e "$(backups)" ]] \
   && grep -q "stopped after the signature check" "$FX/out" && grep -q "rbf_verify_dev_signing" "$FX/out"; then
  ok "--build-only: builds, stages, signs, exits 0 saying it stopped after the signature check; the swap helper is never reached, the app is untouched, staging is removed"
else
  bad "build only" "rc=$RC installed=$(installed_marker) probe=$([[ -e "$FX/probe/swap-reached" ]] && echo REACHED || echo no) staging=$(staging_left) out=$(tail -6 "$FX/out") err=$(cat "$FX/err")"
fi
if grep -q "called RBF_BUILD_ONLY=1" "$FX/xcodebuild.calls" 2>/dev/null; then
  ok "--build-only exports RBF_BUILD_ONLY=1 (the environment of stop two) before the build"
else
  bad "RBF_BUILD_ONLY export" "$(cat "$FX/xcodebuild.calls" 2>&1)"
fi

fixture_repo; EXTRA_ENV=""
run_installer
if grep -q "called RBF_BUILD_ONLY=unset" "$FX/xcodebuild.calls" 2>/dev/null; then
  ok "without --build-only, RBF_BUILD_ONLY is not set"
else
  bad "RBF_BUILD_ONLY unset" "$(cat "$FX/xcodebuild.calls" 2>&1)"
fi

fixture_repo; EXTRA_ENV="RBF_KEEP_PREVIOUS=1"
run_installer --build-only
if [[ $RC -eq 0 && "$(installed_marker)" == old && ! -e "$(backups)" && ! -e "$FX/probe/swap-reached" && "$(staging_left)" == 0 ]]; then
  ok "RBF_KEEP_PREVIOUS=1 with --build-only (the first real run's line): no keep folder, app untouched"
else
  bad "build only with keep" "rc=$RC backups=$(ls "$(backups)" 2>&1) installed=$(installed_marker)"
fi

fixture_repo; EXTRA_ENV="FX_VERIFY_FAIL=1"
run_installer --build-only
if [[ $RC -ne 0 && "$(installed_marker)" == old && ! -e "$FX/probe/swap-reached" ]] && ! grep -q "stopped after" "$FX/out" \
   && grep -q "signature verification failed" "$FX/err"; then
  ok "--build-only with a failing signature check fails and does not say it stopped cleanly"
else
  bad "build only, signature fails" "rc=$RC out=$(cat "$FX/out") err=$(cat "$FX/err")"
fi

# a stop-one cut leaves stop two: the helper itself refuses (the helper's own test
# holds that case); here, the installer's own exit is what is under test.

printf '\na stale RBF_BUILD_ONLY does not refuse a real install\n'
fixture_repo; EXTRA_ENV="RBF_BUILD_ONLY=1"
run_installer
if [[ $RC -eq 0 && "$(installed_marker)" == built && -e "$FX/probe/swap-reached" ]] && grep -q "called RBF_BUILD_ONLY=unset" "$FX/xcodebuild.calls"; then
  ok "an exported RBF_BUILD_ONLY=1 left in the environment is unset when --build-only is not given: the install goes ahead"
else
  bad "stale RBF_BUILD_ONLY" "rc=$RC installed=$(installed_marker) calls=$(cat "$FX/xcodebuild.calls" 2>&1) err=$(cat "$FX/err")"
fi

printf '\ndetached hand-off with nothing installed yet\n'
fixture_repo; EXTRA_ENV="RBF_KEEP_PREVIOUS=1 CMUX_BUNDLE_ID=$ID RBF_SWAP_OPEN=$FX/bin/open"
command rm -rf "${FX:?}/apps/$NAME.app"
printf '#!/bin/sh\nexit 0\n' > "$FX/bin/osascript"; printf '#!/bin/sh\nexit 0\n' > "$FX/bin/open"; chmod +x "$FX/bin/osascript" "$FX/bin/open"
run_installer
w=0; while [[ ! -s "$FX/home/Library/Logs/cmux-rbf/install-dogfood.log" || -z "$(grep -l 'installed' "$FX/home/Library/Logs/cmux-rbf/install-dogfood.log" 2>/dev/null)" ]] && [[ $w -lt 100 ]]; do sleep 0.1; w=$((w + 1)); done
if [[ $RC -eq 0 ]] && grep -q "handing off" "$FX/out" && ! grep -q "keeping the replaced app" "$FX/out" && [[ "$(installed_marker)" == built ]]; then
  ok "detached, keep asked, no app installed: the hand-off does not announce a kept folder that will never exist"
else
  bad "detached first install" "rc=$RC installed=$(installed_marker) out=$(cat "$FX/out") err=$(cat "$FX/err")"
fi

printf '\nplan and usage\n'
fixture_repo; EXTRA_ENV="RBF_KEEP_PREVIOUS=1"
run_installer --dry-run
if [[ $RC -eq 0 ]] && grep -q "^  keep previous" "$FX/out" && ! grep -q "build only" "$FX/out" && [[ ! -e "$FX/xcodebuild.calls" ]]; then
  ok "--dry-run with RBF_KEEP_PREVIOUS=1 prints a keep row and builds nothing"
else
  bad "plan keep row" "rc=$RC out=$(cat "$FX/out") err=$(cat "$FX/err")"
fi
fixture_repo; EXTRA_ENV=""
run_installer --dry-run
before_plan="$(cat "$FX/out")"
if [[ $RC -eq 0 ]] && ! grep -q "keep previous" "$FX/out" && ! grep -q "build only" "$FX/out"; then
  ok "--dry-run without either prints no keep or build-only row (the plan is as it was)"
else
  bad "plan unchanged" "rc=$RC out=$(cat "$FX/out")"
fi
fixture_repo; EXTRA_ENV=""
run_installer --dry-run --build-only
if [[ $RC -eq 0 ]] && grep -q "^  mode           build only" "$FX/out"; then
  ok "--dry-run --build-only prints the build-only row"
else
  bad "plan build only row" "rc=$RC out=$(cat "$FX/out")"
fi
fixture_repo; EXTRA_ENV=""
run_installer --help
if [[ $RC -eq 0 ]] && grep -q -- "--build-only" "$FX/out" && grep -q "RBF_KEEP_PREVIOUS" "$FX/out"; then
  ok "--help documents --build-only and RBF_KEEP_PREVIOUS"
else
  bad "help text" "rc=$RC out=$(cat "$FX/out")"
fi

rbf_test_finish
