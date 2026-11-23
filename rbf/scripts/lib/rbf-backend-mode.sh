#!/usr/bin/env bash
# rbf-backend-mode.sh — let a tagged dev build here start without cmuxterm-hq.
#
#   source rbf/scripts/lib/rbf-backend-mode.sh
#   rbf_backend_mode_apply
#   [[ -n "$RBF_BACKEND_MODE_NOTE" ]] && echo "==> $RBF_BACKEND_MODE_NOTE"
#
# SYMPTOM. Since the cm-142 sync, `make build` and `make run` stop in upstream's
# scripts/reload.sh before Xcode starts, because a tagged Debug build resolves its
# dev backend through scripts/lib/dev-backend-origin.sh
# (`cmux_resolve_tagged_backend`), which looks for a cmuxterm-hq checkout.
#
# CAUSE. Upstream e23247014e (#12973, 2026-09-19): "reload: CMUX_DEV_BACKEND_MODE=local
# for checkouts without the shared dev backend". Upstream's tagged builds use a
# shared dev backend that only a cmuxterm-hq checkout knows how to reach. This
# fork has no cmuxterm-hq checkout, ever.
#
# THE FIX. Default CMUX_DEV_BACKEND_MODE to `local`, upstream's own switch for
# exactly this case: the app then points at http://localhost:<port>, as every
# build of this fork did before the sync. A value the caller exported wins.
# `--prod-auth` skips the backend resolution in reload.sh altogether, so it is
# unaffected. Applied below every `make` entrypoint that reaches reload.sh
# (dev.sh build|run|test), never by editing upstream's reload.sh, so a later sync
# takes upstream's reload.sh as it is.
#
# Test: bash rbf/scripts/lib/rbf-backend-mode.test.sh (also /bin/bash).

rbf_backend_mode_apply() {
  RBF_BACKEND_MODE_NOTE=""
  if [[ -z "${CMUX_DEV_BACKEND_MODE:-}" ]]; then
    export CMUX_DEV_BACKEND_MODE=local
    RBF_BACKEND_MODE_NOTE="CMUX_DEV_BACKEND_MODE=local (no cmuxterm-hq in this fork; see rbf-backend-mode.sh)"
  fi
}
