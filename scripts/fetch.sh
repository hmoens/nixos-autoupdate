#!/usr/bin/env bash
# fetch phase: realise the desired system store path from the binary cache and
# pin it with a GC root. Gated (bandwidth/timing).
#
# This phase can only ever DOWNLOAD. The host holds a store path but no
# derivation and no flake, so there is nothing here that nix could build even
# if it wanted to: if the cache does not have the closure, the fetch fails and
# we defer to the next tick. That is the whole point of v2 — see DESIGN-v2.md.
set -euo pipefail

PHASE=fetch

# shellcheck source=/dev/null
. /etc/nixos-autoupdate/config.env
export PATH="$RUNTIME_PATH:$PATH"
# shellcheck source=/dev/null
. /etc/nixos-autoupdate/lib.sh

status_init

DESIRED="$(status_get desired_path)"
DESIRED_COMMIT="$(status_get desired_commit)"
APPLIED="$(status_get applied_path)"
FETCHED="$(status_get fetched_path)"

if [ -z "$DESIRED" ]; then
  log "No release pointer seen yet; run check first"
  exit 0
fi

if ! gate_ok fetch "$FETCH_GATE"; then
  log "Fetch deferred by gate/hold"
  status_settle
  emit "$ON_APPLY_STATUS" FETCH_DEFERRED DEFERRED "Fetch deferred by gate" \
    "$DESIRED_COMMIT" false "$DESIRED"
  exit 0
fi

# Without a force flag, only fetch when the desired release is not already
# applied or already sitting in the GC-rooted staging slot.
if [ "${FORCED:-0}" != "1" ]; then
  if [ "$DESIRED" = "$APPLIED" ]; then
    log "No update pending (desired == applied)"
    status_settle
    exit 0
  fi
  if [ "$DESIRED" = "$FETCHED" ] && [ -e "$PENDING_SYSTEM" ]; then
    log "Already fetched $DESIRED"
    status_settle
    exit 0
  fi
fi

status_set phase fetching

log "Fetching $DESIRED ..."
set +e
if [ -n "$CACHE_URL" ]; then
  # Signatures are checked against trusted-public-keys; --no-check-sigs is
  # deliberately NOT passed.
  nix --extra-experimental-features nix-command \
    copy --from "$CACHE_URL" "$DESIRED"
else
  # No explicit cache configured: fall back to the system's substituters.
  nix-store --realise "$DESIRED" >/dev/null
fi
FETCH_EXIT=$?
set -e

if [ "$FETCH_EXIT" -ne 0 ]; then
  error "fetch failed (exit $FETCH_EXIT) — is $DESIRED in the cache yet?"
  status_error fetch "fetch failed (exit $FETCH_EXIT)"
  status_settle
  emit "$ON_APPLY_STATUS" FETCH_FAILED NIX_ERROR "Fetch failed (exit $FETCH_EXIT)" \
    "$DESIRED_COMMIT" false "$DESIRED"
  exit "$FETCH_EXIT"
fi

# Pin it so GC cannot collect the staged system before it is activated.
if ! nix-store --add-root "$PENDING_SYSTEM" --indirect --realise "$DESIRED" >/dev/null; then
  error "failed to create GC root for $DESIRED"
  status_error fetch "failed to create GC root"
  status_settle
  emit "$ON_APPLY_STATUS" FETCH_FAILED NIX_ERROR "Could not GC-root the fetched system" \
    "$DESIRED_COMMIT" false "$DESIRED"
  exit 1
fi

REBOOT_REQUIRED=false
if reboot_needed_between /run/booted-system "$DESIRED"; then
  REBOOT_REQUIRED=true
fi

status_set fetched_path "$DESIRED"
status_set_json reboot_required "$REBOOT_REQUIRED"
status_clear_error
status_settle

log "Fetch succeeded ($DESIRED, reboot_required=$REBOOT_REQUIRED)"
emit "$ON_APPLY_STATUS" FETCH_OK OK "System closure fetched" \
  "$DESIRED_COMMIT" "$REBOOT_REQUIRED" "$DESIRED"
