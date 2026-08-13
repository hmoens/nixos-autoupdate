#!/usr/bin/env bash
# Activation body. Run either inline (boot mode) or inside the transient
# nixos-autoupdate-switch.service (switch mode). Sets the system profile,
# activates, updates state, drops the GC root and raises the reboot sentinel.
# Expects MODE=switch|boot in the environment.
set -euo pipefail

PHASE=activate
MODE="${MODE:-switch}"

# shellcheck source=/dev/null
. /etc/nixos-autoupdate/config.env
export PATH="$RUNTIME_PATH:$PATH"
# shellcheck source=/dev/null
. /etc/nixos-autoupdate/lib.sh

status_init
status_set phase activating

BUILT="$(status_get built_commit)"
REBOOT_REQUIRED="$(status_get reboot_required)"

if [ ! -e "$PENDING_SYSTEM" ]; then
  error "No pending-system build present at $PENDING_SYSTEM"
  status_error activate "pending-system missing"
  emit "$ON_APPLY_STATUS" APPLY_FAILED NIX_ERROR "pending-system missing" "$BUILT" "$REBOOT_REQUIRED"
  exit 1
fi

TOPLEVEL="$(readlink -f "$PENDING_SYSTEM")"

log "Setting system profile to $TOPLEVEL"
set +e
nix-env -p /nix/var/nix/profiles/system --set "$TOPLEVEL"
NE_EXIT=$?
set -e

if [ "$NE_EXIT" -ne 0 ]; then
  error "nix-env --set failed (exit $NE_EXIT)"
  status_error activate "nix-env --set failed (exit $NE_EXIT)"
  status_settle
  emit "$ON_APPLY_STATUS" APPLY_FAILED NIX_ERROR "Setting system profile failed (exit $NE_EXIT)" \
    "$BUILT" "$REBOOT_REQUIRED"
  exit "$NE_EXIT"
fi

set +e
"$TOPLEVEL/bin/switch-to-configuration" "$MODE"
SW_EXIT=$?
set -e

if [ "$SW_EXIT" -ne 0 ]; then
  error "switch-to-configuration $MODE failed (exit $SW_EXIT)"
  status_error activate "switch-to-configuration $MODE failed (exit $SW_EXIT)"
  status_settle
  emit "$ON_APPLY_STATUS" APPLY_FAILED NIX_ERROR "Activation failed (exit $SW_EXIT)" \
    "$BUILT" "$REBOOT_REQUIRED"
  exit "$SW_EXIT"
fi

status_set applied_commit "$BUILT"
echo "$BUILT" > "$LEGACY_APPLIED"

# Drop the GC root now that the generation is the system profile.
rm -f "$PENDING_SYSTEM"

if [ "$REBOOT_REQUIRED" = "true" ]; then
  mkdir -p "$RUN_DIR"
  touch "$SENTINEL"
  log "Reboot required: sentinel created"
fi

status_clear_error
status_settle

log "Update applied successfully ($BUILT)"
emit "$ON_APPLY_STATUS" SUCCESS OK "Update applied successfully" "$BUILT" "$REBOOT_REQUIRED"
