#!/usr/bin/env bash
# reboot phase: fire onRebootStatus each tick; when a reboot is genuinely needed
# and enabled (or forced), reboot subject to the gate. Clears stale sentinels.
set -euo pipefail

PHASE=reboot

# shellcheck source=/dev/null
. /etc/nixos-autoupdate/config.env
export PATH="$RUNTIME_PATH:$PATH"
# shellcheck source=/dev/null
. /etc/nixos-autoupdate/lib.sh

status_init

APPLIED="$(status_get applied_path)"
APPLIED_COMMIT="$(status_get applied_commit)"

# Clear a stale sentinel (e.g. a manual reboot already happened).
if [ -f "$SENTINEL" ] && ! reboot_needed_between /run/booted-system /run/current-system; then
  log "Reboot no longer needed; clearing stale sentinel"
  rm -f "$SENTINEL"
  status_set_json reboot_required false
fi

if [ ! -f "$SENTINEL" ]; then
  status_settle
  emit "$ON_REBOOT_STATUS" NO_REBOOT_NEEDED OK "No reboot needed" "$APPLIED_COMMIT" false "$APPLIED"
  exit 0
fi

status_settle
emit "$ON_REBOOT_STATUS" REBOOT_NEEDED REBOOT_NEEDED "Reboot is pending" "$APPLIED_COMMIT" true "$APPLIED"

# Never reboot while an update is mid-flight.
for u in check fetch activate switch; do
  if systemctl is-active --quiet "nixos-autoupdate-$u.service" 2>/dev/null; then
    log "Pipeline busy ($u active); not rebooting"
    exit 0
  fi
done

if ! gate_ok reboot "$REBOOT_GATE"; then
  log "Reboot deferred by gate/hold"
  emit "$ON_REBOOT_STATUS" REBOOT_DEFERRED DEFERRED "Reboot deferred by gate" "$APPLIED_COMMIT" true "$APPLIED"
  exit 0
fi

# Auto-reboot only when enabled; a force flag (FORCED=1) overrides.
if [ "${FORCED:-0}" = "1" ] || [ "$REBOOT_ENABLE" = "true" ]; then
  log "Rebooting now..."
  systemctl reboot
else
  log "Reboot needed but auto-reboot disabled; leaving sentinel in place"
fi
