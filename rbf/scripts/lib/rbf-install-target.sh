#!/usr/bin/env bash
# rbf-install-target.sh — resolve and validate where the RBF channel installs.
#
# Sourced, never executed. Defines functions and has no side effects at source
# time, so a test can load it and call one function in isolation.
#
#   # shellcheck source=rbf/scripts/lib/rbf-install-target.sh
#   source "$SCRIPT_DIR/lib/rbf-install-target.sh"
#
# THE INSTALL TARGET IS NOT A PARAMETER. It comes from rbf-channel.env and
# nothing else — no flag, no environment override, no argument reaches it. The
# installer has no way to be aimed, which is why the refusal paths below are
# unreachable from the real entry point and this file is the only honest place
# to prove they work. See the brief's Decisions log (2026-08-01).
#
# What these guards actually defend against is therefore NOT a hostile caller
# — there isn't one. It is rbf-channel.env being edited, mis-merged, or
# hand-copied into pointing at upstream's install, which would make the
# installer destroy the fallback the whole side-by-side design exists to keep.

# Resolve a path lexically: collapse duplicate slashes, drop "." components,
# pop ".." components, and strip any trailing slash. Touches no filesystem, so
# it works for a path that does not exist yet — which the install target does
# not, on a first run. Absolute input keeps its leading slash.
rbf_lexical_normalize() {
  local input="$1"
  local absolute=0
  case "$input" in
    /*) absolute=1 ;;
  esac

  local -a out=()
  local field
  local oldifs="$IFS"
  IFS='/'
  # shellcheck disable=SC2086
  for field in $input; do
    case "$field" in
      ''|'.') continue ;;
      '..')
        if [[ ${#out[@]} -gt 0 && "${out[${#out[@]}-1]}" != ".." ]]; then
          unset 'out[${#out[@]}-1]'
          # re-index so the next append lands contiguously
          out=("${out[@]+"${out[@]}"}")
        elif [[ $absolute -eq 0 ]]; then
          out+=("..")
        fi
        ;;
      *) out+=("$field") ;;
    esac
  done
  IFS="$oldifs"

  local joined=""
  local part
  for part in ${out[@]+"${out[@]}"}; do
    joined="${joined}/${part}"
  done

  if [[ $absolute -eq 1 ]]; then
    printf '%s' "${joined:-/}"
  else
    printf '%s' "${joined#/}"
  fi
}

# Resolve a path physically where the filesystem can answer, lexically where it
# cannot. BSD realpath (the one macOS ships — no GNU long flags) exits non-zero
# on a path that does not exist, so a first install cannot rely on it for the
# target. Resolving the deepest existing ancestor and re-appending the rest
# catches the case that matters here: a SYMLINKED PARENT pointing into
# upstream's bundle, which lexical normalization alone would miss.
rbf_physical_path() {
  local path
  path="$(rbf_lexical_normalize "$1")"

  if [[ -e "$path" ]]; then
    realpath "$path" 2>/dev/null || printf '%s' "$path"
    return 0
  fi

  local head="$path" tail=""
  while [[ "$head" != "/" && "$head" != "." && -n "$head" ]]; do
    local base="${head##*/}"
    local parent="${head%/*}"
    [[ -z "$parent" ]] && parent="/"
    tail="${base}${tail:+/}${tail}"
    head="$parent"
    if [[ -e "$head" ]]; then
      local resolved
      resolved="$(realpath "$head" 2>/dev/null || printf '%s' "$head")"
      printf '%s' "${resolved%/}/${tail}"
      return 0
    fi
  done

  printf '%s' "$path"
}

# Load the channel record. Values come from the file; nothing is defaulted here,
# because a silently-defaulted bundle id is exactly the failure this guards.
rbf_channel_load() {
  local lib_dir="${1:-}"
  if [[ -z "$lib_dir" ]]; then
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  local record="${lib_dir}/rbf-channel.env"

  if [[ ! -r "$record" ]]; then
    printf 'error: channel record not readable: %s\n' "$record" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$record"

  local key
  for key in RBF_APP_NAME RBF_BUNDLE_ID RBF_PLUGIN_BUNDLE_ID RBF_INSTALL_PATH \
             RBF_ICON_SET RBF_VERSION_PLIST_KEY UPSTREAM_BUNDLE_ID UPSTREAM_INSTALL_PATH; do
    if [[ -z "${!key:-}" ]]; then
      printf 'error: channel record is missing %s: %s\n' "$key" "$record" >&2
      return 1
    fi
  done
}

# Refuse any channel record that resolves onto upstream's install. Every branch
# names the offending value — an operator who trips this needs to know which
# field is wrong, not that "validation failed".
rbf_assert_safe_target() {
  local install_path="${1:-${RBF_INSTALL_PATH:-}}"
  local bundle_id="${2:-${RBF_BUNDLE_ID:-}}"
  local plugin_id="${3:-${RBF_PLUGIN_BUNDLE_ID:-}}"
  local upstream_path="${UPSTREAM_INSTALL_PATH:-/Applications/cmux.app}"
  local upstream_id="${UPSTREAM_BUNDLE_ID:-com.cmuxterm.app}"

  if [[ -z "$install_path" || -z "$bundle_id" || -z "$plugin_id" ]]; then
    printf 'error: refusing to install with an incomplete channel record\n' >&2
    return 1
  fi

  if [[ "$bundle_id" == "$upstream_id" ]]; then
    printf 'error: refusing — RBF_BUNDLE_ID is upstream'\''s bundle id (%s).\n' "$bundle_id" >&2
    printf '       Installing under it would replace the app you fall back to.\n' >&2
    return 1
  fi

  if [[ "$plugin_id" == "$upstream_id" || "$plugin_id" == "$bundle_id" ]]; then
    printf 'error: refusing — RBF_PLUGIN_BUNDLE_ID (%s) must differ from both\n' "$plugin_id" >&2
    printf '       the app id (%s) and upstream'\''s (%s).\n' "$bundle_id" "$upstream_id" >&2
    return 1
  fi

  local resolved upstream_resolved
  resolved="$(rbf_physical_path "$install_path")"
  upstream_resolved="$(rbf_physical_path "$upstream_path")"

  if [[ "$resolved" == "$upstream_resolved" ]]; then
    printf 'error: refusing — RBF_INSTALL_PATH resolves to upstream'\''s app.\n' >&2
    printf '       given:    %s\n' "$install_path" >&2
    printf '       resolves: %s\n' "$resolved" >&2
    return 1
  fi

  # A target *inside* upstream's bundle is equally destructive and would slip
  # past an equality check.
  case "$resolved/" in
    "$upstream_resolved"/*)
      printf 'error: refusing — RBF_INSTALL_PATH is inside upstream'\''s app bundle.\n' >&2
      printf '       given:    %s\n' "$install_path" >&2
      printf '       resolves: %s\n' "$resolved" >&2
      return 1
      ;;
  esac

  case "$resolved" in
    *.app) ;;
    *)
      printf 'error: refusing — RBF_INSTALL_PATH is not an .app bundle: %s\n' "$resolved" >&2
      return 1
      ;;
  esac

  return 0
}

# The one public entry point. Loads, validates, and prints the resolved target
# as KEY=value lines on stdout. Same call the installer makes, --dry-run makes,
# and the test makes — so a preview cannot disagree with a real run.
rbf_resolve_install_target() {
  rbf_channel_load "${1:-}" || return 1
  rbf_assert_safe_target || return 1

  printf 'RBF_APP_NAME=%s\n'           "$RBF_APP_NAME"
  printf 'RBF_BUNDLE_ID=%s\n'          "$RBF_BUNDLE_ID"
  printf 'RBF_PLUGIN_BUNDLE_ID=%s\n'   "$RBF_PLUGIN_BUNDLE_ID"
  printf 'RBF_INSTALL_PATH=%s\n'       "$(rbf_physical_path "$RBF_INSTALL_PATH")"
  printf 'RBF_ICON_SET=%s\n'           "$RBF_ICON_SET"
  printf 'RBF_VERSION_PLIST_KEY=%s\n'  "$RBF_VERSION_PLIST_KEY"
}
