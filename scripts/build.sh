#!/usr/bin/env bash
# build phase: check out the pending commit and build the system toplevel into a
# GC-rooted store path. Gated (performance); resource-limited by the unit.
set -euo pipefail

PHASE=build

# shellcheck source=/dev/null
. /etc/nixos-autoupdate/config.env
export PATH="$RUNTIME_PATH:$PATH"
# shellcheck source=/dev/null
. /etc/nixos-autoupdate/lib.sh

status_init

FETCHED="$(status_get fetched_commit)"
APPLIED="$(status_get applied_commit)"
BUILT="$(status_get built_commit)"

if [ -z "$FETCHED" ]; then
  log "Nothing fetched yet; run check first"
  exit 0
fi

if ! gate_ok build "$BUILD_GATE"; then
  log "Build deferred by gate/hold"
  status_settle
  emit "$ON_APPLY_STATUS" BUILD_DEFERRED DEFERRED "Build deferred by gate" "$FETCHED" false
  exit 0
fi

# Without a force flag, only build when there is a pending update that has not
# already been built.
if [ "${FORCED:-0}" != "1" ]; then
  if [ "$FETCHED" = "$APPLIED" ]; then
    log "No update pending (fetched == applied)"
    status_settle
    exit 0
  fi
  if [ "$FETCHED" = "$BUILT" ] && [ -e "$PENDING_SYSTEM" ]; then
    log "Already built $FETCHED"
    status_settle
    exit 0
  fi
fi

status_set phase building

cd "$REPO_PATH"
log "Checking out $FETCHED..."
git reset --hard "$FETCHED"
git clean -fd

TARGET="$(echo "$FLAKE_OUTPUT" | grep -oE '[^.]+$' || echo "$FLAKE_OUTPUT")"
if [ -n "$FLAKE_SUBDIR" ]; then
  FLAKE_PATH="$REPO_PATH/$FLAKE_SUBDIR"
else
  FLAKE_PATH="$REPO_PATH"
fi
ATTR="$FLAKE_PATH#nixosConfigurations.$TARGET.config.system.build.toplevel"

log "Building $ATTR ..."
set +e
# shellcheck disable=SC2086
NIX_REMOTE=local nix build $NIX_BUILD_FLAGS --out-link "$PENDING_SYSTEM" "$ATTR"
BUILD_EXIT=$?
set -e

if [ "$BUILD_EXIT" -ne 0 ]; then
  error "nix build failed (exit $BUILD_EXIT)"
  status_error build "nix build failed (exit $BUILD_EXIT)"
  status_settle
  emit "$ON_APPLY_STATUS" BUILD_FAILED NIX_ERROR "Build failed (exit $BUILD_EXIT)" "$FETCHED" false
  exit "$BUILD_EXIT"
fi

TOPLEVEL="$(readlink -f "$PENDING_SYSTEM")"

REBOOT_REQUIRED=false
if reboot_needed_between /run/booted-system "$TOPLEVEL"; then
  REBOOT_REQUIRED=true
fi

status_set built_commit "$FETCHED"
status_set_json reboot_required "$REBOOT_REQUIRED"
status_clear_error
status_settle

log "Build succeeded ($FETCHED, reboot_required=$REBOOT_REQUIRED)"
emit "$ON_APPLY_STATUS" BUILD_OK OK "Build succeeded" "$FETCHED" "$REBOOT_REQUIRED"
