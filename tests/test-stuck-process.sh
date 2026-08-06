#!/usr/bin/env bash
# test-stuck-process.sh — verify the script detects a fake stuck process
#
# Strategy:
#   1. Create a fake process that LOOKS like unattended-upgrade (via
#      bash exec -a + sleep) with a marker we control.
#   2. Run the script with very low thresholds (UA_STUCK_STUCK_MIN=0)
#      so it detects the fake.
#   3. Verify the fake appears in the "found unattended-upgrade PIDs"
#      log line.
#   4. With --dry-run: verify it WOULD kill (no actual kill).
#   5. Cleanup: kill the fake sentinel.
#
# Exit codes:
#   0 = detection worked
#   1 = detection failed

set -uo pipefail

SCRIPT="${1:?usage: $0 SCRIPT_PATH}"

USER_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/unattended-upgrade-stuck-kill"
mkdir -p "$USER_LOG_DIR"
LOG_FILE="$USER_LOG_DIR/stuck-kill.log"
export UA_STUCK_LOG_FILE="$LOG_FILE"

MARKER="STUCKTEST-$$-$(date +%s)-$RANDOM"

# Spawn fake
bash -c "exec -a 'unattended-upgrade-shutdown --marker=$MARKER' sleep 600" &
FAKE_PID=$!
disown "$FAKE_PID" 2>/dev/null || true
sleep 0.5

if [ ! -d "/proc/$FAKE_PID" ]; then
    echo "FAIL: fake sentinel did not spawn"
    exit 1
fi

# Run with low threshold + dry-run
log_before=0
[ -f "$LOG_FILE" ] && log_before=$(wc -l < "$LOG_FILE")

if ! UA_STUCK_STUCK_MIN=0 timeout 60 "$SCRIPT" --dry-run; then
    echo "FAIL: script exited non-zero"
    kill -9 "$FAKE_PID" 2>/dev/null
    exit 1
fi

# Verify log mentions the PID or the marker
log_after=0
[ -f "$LOG_FILE" ] && log_after=$(wc -l < "$LOG_FILE")

if [ "$log_after" -le "$log_before" ]; then
    echo "FAIL: no new log output"
    kill -9 "$FAKE_PID" 2>/dev/null
    exit 1
fi

if tail -50 "$LOG_FILE" | grep -q "$MARKER\|$FAKE_PID"; then
    echo "PASS: detected fake stuck process (PID=$FAKE_PID marker=$MARKER)"
else
    echo "FAIL: fake process not detected in log"
    tail -30 "$LOG_FILE"
    kill -9 "$FAKE_PID" 2>/dev/null
    exit 1
fi

# Cleanup
kill -9 "$FAKE_PID" 2>/dev/null
pkill -9 -f "$MARKER" 2>/dev/null
sleep 0.3
exit 0
