#!/usr/bin/env bash
# check phase: fetch the remote and record the pending commit. No checkout.
set -euo pipefail

PHASE=check

# shellcheck source=/dev/null
. /etc/nixos-autoupdate/config.env
export PATH="$RUNTIME_PATH:$PATH"
# shellcheck source=/dev/null
. /etc/nixos-autoupdate/lib.sh

status_init
status_set phase checking

trap cleanup_git_ssh EXIT
if ! setup_git_ssh; then
  status_error check "git ssh key setup failed"
  status_settle
  emit "$ON_GIT_STATUS" UPDATE_FAILED GIT_ERROR "SSH key setup failed" \
    "$(status_get fetched_commit)" false
  exit 1
fi

# Clone on first run / if the checkout is invalid.
if ! git -C "$REPO_PATH" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -e "$REPO_PATH" ]; then
    log "Existing repo checkout invalid, removing $REPO_PATH"
    rm -rf "$REPO_PATH"
  fi
  log "Cloning repository..."
  mkdir -p "$(dirname "$REPO_PATH")"
  if ! git clone --branch "$BRANCH" "$REPO_URL" "$REPO_PATH"; then
    status_error check "git clone failed"
    status_settle
    emit "$ON_GIT_STATUS" UPDATE_FAILED GIT_ERROR "Git clone failed" \
      "$(status_get fetched_commit)" false
    exit 1
  fi
fi

cd "$REPO_PATH"

log "Fetching latest changes..."
if ! git fetch --prune origin; then
  status_error check "git fetch failed"
  status_settle
  emit "$ON_GIT_STATUS" UPDATE_FAILED GIT_ERROR "Git fetch failed" \
    "$(status_get fetched_commit)" false
  exit 1
fi

REMOTE="$(git rev-parse "origin/$BRANCH")"
APPLIED="$(status_get applied_commit)"

status_set fetched_commit "$REMOTE"
status_set last_check "$(now_iso)"
status_clear_error
status_settle

if [ "$REMOTE" = "$APPLIED" ]; then
  log "No updates available (already applied $REMOTE)"
  emit "$ON_GIT_STATUS" NOOP OK "No updates available (already applied)" "$REMOTE" false
else
  log "Update found: remote $REMOTE (applied ${APPLIED:-none})"
  emit "$ON_GIT_STATUS" UPDATE_FOUND OK "Update found: new commits available" "$REMOTE" false
fi
