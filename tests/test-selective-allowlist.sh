#!/usr/bin/env bash
# test-selective-allowlist.sh — verify allowlist skips matching PIDs
#
# Strategy:
#   1. Spawn fake stuck process matching UA_STUCK_ALLOWLIST pattern.
#   2. Run script with allowlist set + low threshold.
#   3. Verify log mentions "allowlisted" for the marker.
#   4. Verify the fake PID was NOT killed (still alive after).
#
# Exit codes:
#   0 = allowlist honored
#   1 = allowlist failed (PID was killed or not detected)

set -uo pipefail

SCRIPT="${1:?usage: $0 SCRIPT_PATH}"

USER_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/unattended-upgrade-stuck-kill"
mkdir -p "$USER_LOG_DIR"
LOG_FILE="$USER_LOG_DIR/stuck-kill.log"
export UA_STUCK_LOG_FILE="$LOG_FILE"

MARKER="ALLOWLISTTEST-$$-$(date +%s)-$RANDOM"

# Spawn fake with a recognizable cmdline
bash -c "exec -a 'unattended-upgrade-shutdown --marker=$MARKER' sleep 600" &
FAKE_PID=$!
disown "$FAKE_PID" 2>/dev/null || true
sleep 0.5

if [ ! -d "/proc/$FAKE_PID" ]; then
    echo "FAIL: fake sentinel did not spawn"
    exit 1
fi

# Run with allowlist active + low threshold + dry-run
log_before=0
[ -f "$LOG_FILE" ] && log_before=$(wc -l < "$LOG_FILE")

UA_STUCK_STUCK_MIN=0 \
UA_STUCK_ALLOWLIST="$MARKER" \
    timeout 60 "$SCRIPT" --dry-run || true

# Verify log mentions "allowlisted" for the marker
log_after=0
[ -f "$LOG_FILE" ] && log_after=$(wc -l < "$LOG_FILE")

if [ "$log_after" -le "$log_before" ]; then
    echo "FAIL: no new log output"
    kill -9 "$FAKE_PID" 2>/dev/null
    exit 1
fi

if tail -50 "$LOG_FILE" | grep -q "allowlisted.*$MARKER\|allowlisted.*$FAKE_PID"; then
    echo "PASS: allowlist honored (fake PID not killed)"
    allowlist_ok=1
else
    echo "FAIL: allowlist not honored — log doesn't show skip"
    tail -30 "$LOG_FILE"
    allowlist_ok=0
fi

# Verify the fake is still alive (was NOT killed)
if [ -d "/proc/$FAKE_PID" ]; then
    echo "PASS: fake PID $FAKE_PID still alive (allowlist preserved)"
else
    echo "FAIL: fake PID was killed despite allowlist"
    allowlist_ok=0
fi

# Cleanup
kill -9 "$FAKE_PID" 2>/dev/null
pkill -9 -f "$MARKER" 2>/dev/null
sleep 0.3

[ "$allowlist_ok" -eq 1 ]
