#!/usr/bin/env bash
# rbf-tui-client.sh — give a dev build here the cmux-tui client upstream published for the upstream commit this fork
# last merged.
#
#   source rbf/scripts/lib/rbf-tui-client.sh
#   rbf_tui_client_apply "$REPO_ROOT"
#   [[ -n "$RBF_TUI_CLIENT_NOTE" ]] && echo "==> $RBF_TUI_CLIENT_NOTE"
#
# SYMPTOM. Since the cm-142 sync, `make build` and `make run` stop in upstream's scripts/reload.sh with
# "error: no published cmux-tui client for this checkout, so the app bundle cannot get one."
#
# CAUSE. reload.sh bundles a prebuilt cmux-tui client, found by scripts/ci/resolve-cmux-tui-client-commit.sh: the
# newest commit whose client inputs equal HEAD's must have a published manifest at
# https://files.cmux.com/cmux-tui/<commit>/manifest.json. The inputs are `cmux-tui`, `ghostty` and two workflow files
# (the script's PATHS). This fork records its own ghostty and disarms upstream's workflows, so no fork commit ever
# has upstream's inputs, and upstream publishes clients only for its own commits.
#
# THE FIX. When the caller set neither CMUX_TUI_CLIENT_LOCAL nor CMUX_TUI_CLIENT_MANIFEST_URL (reload.sh's own two
# ways in), resolve the client from the upstream side: the merge-base of HEAD with refs/remotes/upstream/main is the
# upstream commit this fork last merged, and the resolver finds that commit's published client. Export its manifest
# URL, which reload.sh reads. The fork's cmux-tui sources are upstream's, so this is the client upstream ships for the
# same code. If anything is missing (no upstream ref, no network, no published client), nothing is exported and
# reload.sh fails with its own message, as before. Applied below `make build`/`make run`, never by editing upstream's
# reload.sh, so a later sync takes upstream's reload.sh as it is.
#
# Test: bash rbf/scripts/lib/rbf-tui-client.test.sh (also /bin/bash).

RBF_TUI_CLIENT_BASE_URL="https://files.cmux.com/cmux-tui"

rbf_tui_client_apply() {
  local root="$1" up commit
  RBF_TUI_CLIENT_NOTE=""
  [[ -n "${CMUX_TUI_CLIENT_LOCAL:-}" || -n "${CMUX_TUI_CLIENT_MANIFEST_URL:-}" ]] && return 0
  up="$(git -C "$root" merge-base HEAD refs/remotes/upstream/main 2>/dev/null || true)"
  [[ "$up" =~ ^[0-9a-f]{40}$ ]] || return 0
  commit="$(cd "$root" && "$root/scripts/ci/resolve-cmux-tui-client-commit.sh" --head "$up" 2>/dev/null | tail -1 || true)"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || return 0
  export CMUX_TUI_CLIENT_MANIFEST_URL="$RBF_TUI_CLIENT_BASE_URL/$commit/manifest.json"
  RBF_TUI_CLIENT_NOTE="cmux-tui client: upstream's published client for ${commit:0:12} (upstream ${up:0:12}; see rbf-tui-client.sh)"
  return 0
}
