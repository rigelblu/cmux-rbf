# Shared signing contract for RBF development and installed builds.
# Shell startup files are not part of the build: resolve the existing stable
# certificate here, before Xcode runs, and never silently replace it with ad-hoc.
rbf_configure_dev_signing() {
  local identity="${CMUX_DEV_CODESIGN_IDENTITY:-cmux Dev Signing}"
  local cert_hash
  if [[ "$identity" == "-" ]]; then
    echo "error: ad-hoc signing cannot preserve cmux permission grants." >&2
    echo "       Select a stable CMUX_DEV_CODESIGN_IDENTITY." >&2
    return 1
  fi
  cert_hash="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -v id="$identity" 'index($0, "\"" id "\"") || tolower($2) == tolower(id) { print $2; exit }')"
  if [[ ! "$cert_hash" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    printf 'error: stable cmux signing identity not found: %s\n' "$identity" >&2
    echo "       Create a Code Signing certificate in Keychain Access or set" >&2
    echo "       CMUX_DEV_CODESIGN_IDENTITY to an existing signing identity." >&2
    return 1
  fi
  export CMUX_DEV_CODESIGN_IDENTITY="$identity"
  export RBF_DEV_CODESIGN_CERT_HASH="$cert_hash"
}

# Verify the artifact, not just whether codesign exited successfully. A stable
# designated requirement matches this bundle identifier and selected leaf cert.
rbf_verify_dev_signing() {
  local app_path="$1" bundle_id requirement
  bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")" || return 1
  requirement="identifier \"$bundle_id\" and certificate leaf = H\"$RBF_DEV_CODESIGN_CERT_HASH\""
  /usr/bin/codesign --verify --deep --strict -R="$requirement" "$app_path"
}
