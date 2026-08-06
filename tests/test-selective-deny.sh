#!/usr/bin/env bash
# test-selective-deny.sh — verify log-based deny skips killing
#
# Strategy:
#   1. Create a fake unattended-upgrade log file with kernel-upgrade
#      content.
#   2. Set UA_STUCK_LOG_FILE to that file + UA_STUCK_DENY_LOG_REGEX to
#      "linux-image".
#   3. Run script with low threshold + dry-run.
#   4. Verify log mentions "deny-log" or "skipping all kills".
#   5. Verify the fake PID was NOT in the kill list.
#
# Exit codes:
#   0 = deny honored
#   1 = deny failed

set -uo pipefail

SCRIPT="${1:?usage: $0 SCRIPT_PATH}"

USER_LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/unattended-upgrade-stuck-kill"
mkdir -p "$USER_LOG_DIR"
LOG_FILE="$USER_LOG_DIR/stuck-kill.log"
export UA_STUCK_LOG_FILE="$LOG_FILE"
FAKE_UA_LOG="$(mktemp /tmp/ua-stuck-kill-test-XXXXXX.log)"

# Spawn fake stuck process
MARKER="DENYTEST-$$-$(date +%s)-$RANDOM"
bash -c "exec -a 'unattended-upgrade-shutdown --marker=$MARKER' sleep 600" &
FAKE_PID=$!
disown "$FAKE_PID" 2>/dev/null || true
sleep 0.5

# Create fake UA log with kernel upgrade indicator
cat > "$FAKE_UA_LOG" <<EOF
2026-08-06 12:00:00,123 INFO Starting unattended upgrades script
2026-08-06 12:00:01,456 INFO Allowed origins are: ['origin=Debian,codename=Debian unstable,label=Debian']
2026-08-06 12:00:02,789 INFO upgrade is already running (PID: $FAKE_PID)
2026-08-06 12:01:00,001 INFO Packages that will be upgraded: linux-image-7.0.10+deb14-amd64
2026-08-06 12:01:00,002 INFO Packages that will be upgraded: linux-headers-7.0.10+deb14-amd64
EOF

log_before=0
[ -f "$LOG_FILE" ] && log_before=$(wc -l < "$LOG_FILE")

# Run with deny log regex active
UA_STUCK_STUCK_MIN=0 \
UA_STUCK_LOG_FILE="$FAKE_UA_LOG" \
UA_STUCK_DENY_LOG_REGEX="linux-image|linux-headers" \
    timeout 60 "$SCRIPT" --dry-run || true

log_after=0
[ -f "$LOG_FILE" ] && log_after=$(wc -l < "$LOG_FILE")

if [ "$log_after" -le "$log_before" ]; then
    echo "FAIL: no new log output"
    kill -9 "$FAKE_PID" 2>/dev/null
    rm -f "$FAKE_UA_LOG"
    exit 1
fi

if tail -50 "$LOG_FILE" | grep -qE "deny-log|skipping all kills"; then
    echo "PASS: deny-log honored"
    deny_ok=1
else
    echo "FAIL: deny-log not honored"
    tail -30 "$LOG_FILE"
    deny_ok=0
fi

# Verify the fake is still alive
if [ -d "/proc/$FAKE_PID" ]; then
    echo "PASS: fake PID $FAKE_PID still alive (deny preserved)"
else
    echo "FAIL: fake PID was killed despite deny"
    deny_ok=0
fi

# Cleanup
kill -9 "$FAKE_PID" 2>/dev/null
pkill -9 -f "$MARKER" 2>/dev/null
rm -f "$FAKE_UA_LOG"
sleep 0.3

[ "$deny_ok" -eq 1 ]
