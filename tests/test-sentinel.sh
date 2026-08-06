#!/usr/bin/env bash
# test-sentinel.sh — validate the unattended-upgrade-stuck-kill filter
#
# Runs the script's --test-sentinel mode N times in sequence. Verifies:
#   - exits 0 each time
#   - no orphaned sleep children remain after cleanup
#   - the filter correctly excludes the fake sentinel
#
# Exit codes:
#   0 = all passes
#   1 = at least one failure

set -uo pipefail

SCRIPT="${1:?usage: $0 SCRIPT_PATH}"
N="${TEST_SENTINEL_RUNS:-3}"

pass=0
fail=0

for i in $(seq 1 "$N"); do
    echo "--- run $i/$N ---"
    if timeout 10 "$SCRIPT" --test-sentinel; then
        pass=$((pass+1))
        echo "  run $i: PASS"
    else
        fail=$((fail+1))
        echo "  run $i: FAIL"
    fi
done

# Verify no orphans
sleep 0.5
orphans=$(pgrep -af 'uastest-' | grep -v 'grep' | wc -l)
if [ "$orphans" -gt 0 ]; then
    echo "FAIL: $orphans orphaned sentinels remain"
    pgrep -af 'uastest-' | grep -v 'grep'
    fail=$((fail+1))
else
    echo "PASS: no orphan sentinels"
fi

echo ""
echo "Result: $pass pass, $fail fail (of $N runs)"
[ "$fail" -eq 0 ]
