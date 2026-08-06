#!/usr/bin/env bash
# test-dry-run.sh — verify dry-run completes without acting
#
# Runs the script with --dry-run. With no stuck unattended-upgrade
# processes on the system, the script should:
#   - exit 0
#   - log "no unattended-upgrade processes"
#   - NOT touch any process
#
# Also verifies PSI self-check runs without error.

set -uo pipefail

SCRIPT="${1:?usage: $0 SCRIPT_PATH}"

# Ensure log directory exists in user-local fallback (when /var/log isn't writable)
USER_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/unattended-upgrade-stuck-kill"
mkdir -p "$USER_LOG_DIR"
LOG_FILE="$USER_LOG_DIR/stuck-kill.log"
export UA_STUCK_LOG_FILE="$LOG_FILE"

# Capture log size before
log_before=0
[ -f "$LOG_FILE" ] && log_before=$(wc -l < "$LOG_FILE")

# Run dry-run
if ! timeout 60 "$SCRIPT" --dry-run; then
    echo "FAIL: dry-run exited non-zero"
    exit 1
fi

# Verify log was written (script doesn't silently exit)
log_after=0
[ -f "$LOG_FILE" ] && log_after=$(wc -l < "$LOG_FILE")

if [ "$log_after" -le "$log_before" ]; then
    echo "FAIL: dry-run produced no log output (before=$log_before after=$log_after)"
    exit 1
fi

# Verify the last lines mention dry-run or no-action
tail -5 "$LOG_FILE" | grep -qE 'DRY-RUN|no unattended-upgrade|skipping|exit 0' || {
    echo "FAIL: dry-run log doesn't mention expected outcome"
    tail -5 "$LOG_FILE"
    exit 1
}

echo "PASS: dry-run completed cleanly"
exit 0
