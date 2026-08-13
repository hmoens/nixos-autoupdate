#!/usr/bin/env bash
# check phase: fetch the release pointer repo and record the desired system
# store path. Never checks out a working tree and never evaluates anything —
# the pointer file is read straight out of the git object store.
set -euo pipefail

PHASE=check

# shellcheck source=/dev/null
. /etc/nixos-autoupdate/config.env
export PATH="$RUNTIME_PATH:$PATH"
# shellcheck source=/dev/null
. /etc/nixos-autoupdate/lib.sh

status_init
status_set phase checking

fail() {
  # fail <message>
  status_error check "$1"
  status_settle
  emit "$ON_GIT_STATUS" UPDATE_FAILED GIT_ERROR "$1" \
    "$(status_get desired_commit)" false "$(status_get desired_path)"
  exit 1
}

trap cleanup_git_ssh EXIT
if ! setup_git_ssh; then
  fail "SSH key setup failed"
fi

# Clone on first run / if the checkout is invalid. --no-checkout: the host only
# ever reads one small file via `git show`, so materialising a work tree of the
# config repo would be pure waste.
if ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -e "$REPO_PATH" ]; then
    log "Existing repo checkout invalid, removing $REPO_PATH"
    rm -rf "$REPO_PATH"
  fi
  log "Cloning release repository..."
  mkdir -p "$(dirname "$REPO_PATH")"
  if ! git clone --no-checkout --branch "$BRANCH" "$REPO_URL" "$REPO_PATH"; then
    fail "Git clone failed"
  fi
fi

cd "$REPO_PATH"

log "Fetching release pointers..."
if ! git fetch --prune origin; then
  fail "Git fetch failed"
fi

REMOTE="$(git rev-parse "origin/$BRANCH")"

# Optionally require a valid signature on the pointer commit: a validly-signed
# closure is not enough on its own, since an unsigned pointer could still aim
# this host at a different (also signed) system.
if [ "$VERIFY_COMMITS" = "true" ]; then
  if ! git verify-commit "$REMOTE" >/dev/null 2>&1; then
    fail "Commit $REMOTE has no valid signature"
  fi
fi

if ! RELEASE_JSON="$(git show "$REMOTE:$RELEASE_FILE" 2>/dev/null)"; then
  fail "No release pointer at $RELEASE_FILE in $REMOTE"
fi

if ! DESIRED_PATH="$(printf '%s' "$RELEASE_JSON" | jq -er '.storePath')"; then
  fail "Release pointer $RELEASE_FILE has no .storePath"
fi

case "$DESIRED_PATH" in
  /nix/store/*) ;;
  *) fail "Release storePath is not a /nix/store path: $DESIRED_PATH" ;;
esac

DESIRED_COMMIT="$(printf '%s' "$RELEASE_JSON" | jq -r '.builtFrom.commit // ""')"
# Per-release override of activate.mode; "" means "use the module default".
DESIRED_OPERATION="$(printf '%s' "$RELEASE_JSON" | jq -r '.operation // ""')"
case "$DESIRED_OPERATION" in
  ""|switch|boot) ;;
  *) fail "Release operation must be switch or boot, got: $DESIRED_OPERATION" ;;
esac

APPLIED_PATH="$(status_get applied_path)"

status_set desired_path "$DESIRED_PATH"
status_set desired_commit "$DESIRED_COMMIT"
status_set desired_operation "$DESIRED_OPERATION"
status_set last_check "$(now_iso)"
status_clear_error
status_settle

if [ "$DESIRED_PATH" = "$APPLIED_PATH" ]; then
  log "No update available (already running $DESIRED_PATH)"
  emit "$ON_GIT_STATUS" NOOP OK "No updates available (already applied)" \
    "$DESIRED_COMMIT" false "$DESIRED_PATH"
else
  log "Update found: $DESIRED_PATH (running ${APPLIED_PATH:-unknown})"
  emit "$ON_GIT_STATUS" UPDATE_FOUND OK "Update found: new release available" \
    "$DESIRED_COMMIT" false "$DESIRED_PATH"
fi
