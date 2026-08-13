#!/usr/bin/env bash
# activate phase (declared unit): gate + preconditions, then hand the actual
# activation to apply.sh. In "switch" mode apply.sh runs in a TRANSIENT unit so
# that switch-to-configuration cannot stop the unit performing the switch (see
# DESIGN.md "Why activation runs in a transient unit"). In "boot" mode nothing
# is restarted, so apply.sh runs inline.
set -euo pipefail

PHASE=activate

# shellcheck source=/dev/null
. /etc/nixos-autoupdate/config.env
export PATH="$RUNTIME_PATH:$PATH"
# shellcheck source=/dev/null
. /etc/nixos-autoupdate/lib.sh

status_init

FETCHED="$(status_get fetched_path)"
APPLIED="$(status_get applied_path)"
DESIRED_COMMIT="$(status_get desired_commit)"
REBOOT_REQUIRED="$(status_get reboot_required)"

# A release may override the module's activate.mode (e.g. stage a risky update
# for the next boot without touching the host's configuration).
MODE="$ACTIVATE_MODE"
RELEASE_OPERATION="$(status_get desired_operation)"
if [ -n "$RELEASE_OPERATION" ]; then
  MODE="$RELEASE_OPERATION"
fi

if [ -z "$FETCHED" ]; then
  log "Nothing fetched yet"
  exit 0
fi

if ! gate_ok activate "$ACTIVATE_GATE"; then
  log "Activation deferred by gate/hold"
  status_settle
  emit "$ON_APPLY_STATUS" ACTIVATE_DEFERRED DEFERRED "Activation deferred by gate" \
    "$DESIRED_COMMIT" "$REBOOT_REQUIRED" "$FETCHED"
  exit 0
fi

if [ "${FORCED:-0}" != "1" ] && [ "$FETCHED" = "$APPLIED" ]; then
  log "Already activated $FETCHED"
  status_settle
  exit 0
fi

if [ ! -e "$PENDING_SYSTEM" ]; then
  error "No fetched system present at $PENDING_SYSTEM"
  status_error activate "pending-system missing"
  exit 1
fi

if [ "$MODE" = "boot" ]; then
  log "Activating (boot) $FETCHED..."
  MODE=boot exec "$BASH" /etc/nixos-autoupdate/apply.sh
fi

# switch mode: run the activation in a fixed-name transient unit.
if systemctl is-active --quiet nixos-autoupdate-switch.service; then
  log "A switch is already in progress; skipping"
  exit 0
fi

log "Activating (switch) $FETCHED in transient unit..."
systemctl reset-failed nixos-autoupdate-switch.service 2>/dev/null || true
exec systemd-run \
  --unit=nixos-autoupdate-switch \
  --setenv=MODE=switch \
  --setenv=PATH="$RUNTIME_PATH" \
  --setenv=HOME=/root \
  "$BASH" /etc/nixos-autoupdate/apply.sh
