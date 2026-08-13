# nixos-autoupdate shared shell library.
# Sourced by every phase script AFTER /etc/nixos-autoupdate/config.env.
# Provides state (status.json) management, gate evaluation and hook dispatch.
#
# Expects from config.env: AU_HOSTNAME, and (optionally) AGE_KEY_PATH,
# GIT_SSH_KEY, ON_GIT_STATUS, ON_APPLY_STATUS, ON_REBOOT_STATUS.
# Expects the sourcing script to set PHASE (check|build|activate|reboot).

STATE_DIR="/var/lib/nixos-mgmt"
RUN_DIR="/run/nixos-autoupdate"
STATUS_FILE="$STATE_DIR/status.json"
STATUS_LOCK="$STATE_DIR/.status.lock"
PENDING_SYSTEM="$STATE_DIR/pending-system"
SENTINEL="$RUN_DIR/reboot-required"
HOLD_FILE="$STATE_DIR/hold"
LEGACY_APPLIED="$STATE_DIR/last-applied-commit"

log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }

now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

host_ip() {
  ip -4 -o addr show scope global 2>/dev/null \
    | head -1 | awk '{print $4}' | cut -d/ -f1 || echo 'unknown'
}

ensure_dirs() { mkdir -p "$STATE_DIR" "$RUN_DIR"; }

# Run a command while holding an exclusive lock on status.json, serialising the
# read-modify-write cycle across concurrently running phases (each individual
# write is already atomic via tmp+mv; the lock prevents lost updates). Falls
# back to running unlocked if flock is unavailable.
_with_status_lock() {
  ensure_dirs
  (
    flock 9 2>/dev/null || true
    "$@"
  ) 9>>"$STATUS_LOCK"
}

# Create status.json on first run, seeding applied_commit from the legacy
# last-applied-commit file so upgrading from the old module does not trigger a
# spurious rebuild.
status_init() {
  ensure_dirs
  [ -f "$STATUS_FILE" ] && return 0
  _with_status_lock _status_init_write
}

_status_init_write() {
  # Re-check under the lock in case another phase created it in the meantime.
  [ -f "$STATUS_FILE" ] && return 0

  local applied=""
  if [ -f "$LEGACY_APPLIED" ]; then
    applied="$(cat "$LEGACY_APPLIED" 2>/dev/null || echo "")"
  fi

  local tmp
  tmp="$(mktemp "$STATE_DIR/.status.XXXXXX")"
  if [ -n "$applied" ]; then
    jq -n --arg a "$applied" '{
      phase:"idle", hold:false, last_check:null,
      fetched_commit:null, built_commit:null, applied_commit:$a,
      reboot_required:false, last_error:null
    }' > "$tmp"
  else
    jq -n '{
      phase:"idle", hold:false, last_check:null,
      fetched_commit:null, built_commit:null, applied_commit:null,
      reboot_required:false, last_error:null
    }' > "$tmp"
  fi
  mv "$tmp" "$STATUS_FILE"
}

# Read a top-level key; null becomes "", booleans become "true"/"false".
status_get() {
  jq -r --arg k "$1" 'if .[$k]==null then "" else (.[$k]|tostring) end' \
    "$STATUS_FILE" 2>/dev/null || echo ""
}

_status_apply() {
  # _status_apply <jq-filter> [jq-args...]
  _with_status_lock _status_write "$@"
}

_status_write() {
  local filter="$1"; shift
  local tmp
  tmp="$(mktemp "$STATE_DIR/.status.XXXXXX")"
  if jq "$@" "$filter" "$STATUS_FILE" > "$tmp"; then
    mv "$tmp" "$STATUS_FILE"
  else
    rm -f "$tmp"
    error "failed to update status.json"
    return 1
  fi
}

status_set()      { _status_apply '.[$k]=$v'          --arg k "$1" --arg v "$2"; }
status_set_json() { _status_apply '.[$k]=($v|fromjson)' --arg k "$1" --arg v "$2"; }

status_error() {
  # status_error <phase> <message>
  _status_apply '.last_error={phase:$p, message:$m, at:$t}' \
    --arg p "$1" --arg m "$2" --arg t "$(now_iso)"
}
status_clear_error() { _status_apply '.last_error=null'; }

# Resting phase, derived from commits + sentinel, for human-readable status.
status_settle() {
  local applied built p
  applied="$(status_get applied_commit)"
  built="$(status_get built_commit)"
  if [ -f "$SENTINEL" ]; then
    p="reboot-pending"
  elif [ -n "$built" ] && [ "$built" != "$applied" ] && [ -e "$PENDING_SYSTEM" ]; then
    p="built"
  else
    p="idle"
  fi
  status_set phase "$p"
}

is_held() { [ -f "$HOLD_FILE" ]; }

# Decide whether a gated phase may proceed. Sets FORCED=1 when a force flag was
# present (and consumes it), else FORCED=0. Returns 0 to proceed, 1 to defer.
# A force flag bypasses both hold and the gate script.
gate_ok() {
  # gate_ok <phase> <gate-script-or-empty>
  local phase="$1" gate="$2"
  if [ -f "$RUN_DIR/force-$phase" ]; then
    rm -f "$RUN_DIR/force-$phase"
    FORCED=1
    return 0
  fi
  FORCED=0
  is_held && return 1
  if [ -n "$gate" ]; then
    "$gate" && return 0 || return 1
  fi
  return 0
}

# Run a status hook with the AUTOUPDATE_* environment. Never fails the caller.
emit() {
  # emit <hook-or-empty> <event> <status> <message> <commit> <reboot_required>
  local hook="$1"
  [ -z "$hook" ] && return 0
  AUTOUPDATE_EVENT="$2" \
  AUTOUPDATE_STATUS="$3" \
  AUTOUPDATE_MESSAGE="$4" \
  AUTOUPDATE_CHECKED_OUT_COMMIT="$5" \
  AUTOUPDATE_REBOOT_REQUIRED="$6" \
  AUTOUPDATE_HOSTNAME="$AU_HOSTNAME" \
  AUTOUPDATE_HOST_IP="$(host_ip)" \
  AUTOUPDATE_PHASE="$PHASE" \
    "$hook" || true
}

# Decrypt the git SSH key (if configured) and export GIT_SSH_COMMAND.
setup_git_ssh() {
  if [ -n "${AGE_KEY_PATH:-}" ]; then
    if [ ! -f "$AGE_KEY_PATH" ]; then
      error "Age key not found at $AGE_KEY_PATH"; return 1
    fi
    export SOPS_AGE_KEY_FILE="$AGE_KEY_PATH"
  fi
  if [ -n "${GIT_SSH_KEY:-}" ]; then
    if [ ! -f "$GIT_SSH_KEY" ]; then
      error "Encrypted SSH key not found at $GIT_SSH_KEY"; return 1
    fi
    _AU_SSH_KEY_FILE="$(mktemp)"
    if ! age -d -i "$AGE_KEY_PATH" -o "$_AU_SSH_KEY_FILE" "$GIT_SSH_KEY" 2>/dev/null; then
      error "Failed to decrypt SSH key"
      rm -f "$_AU_SSH_KEY_FILE"
      return 1
    fi
    chmod 600 "$_AU_SSH_KEY_FILE"
    export _AU_SSH_KEY_FILE
    export GIT_SSH_COMMAND="ssh -i $_AU_SSH_KEY_FILE -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
  fi
}
cleanup_git_ssh() {
  [ -n "${_AU_SSH_KEY_FILE:-}" ] && rm -f "$_AU_SSH_KEY_FILE"
  return 0
}

# Return 0 if booting into system $b from booted system $a needs a reboot to
# fully take effect (kernel / initrd / modules / kernel params changed).
reboot_needed_between() {
  local a="$1" b="$2" f
  [ -e "$a" ] || return 0
  [ -e "$b" ] || return 1
  for f in kernel initrd kernel-modules; do
    if [ "$(readlink -f "$a/$f" 2>/dev/null || echo __a)" \
       != "$(readlink -f "$b/$f" 2>/dev/null || echo __b)" ]; then
      return 0
    fi
  done
  cmp -s "$a/kernel-params" "$b/kernel-params" 2>/dev/null || return 0
  return 1
}
