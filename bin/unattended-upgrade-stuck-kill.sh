#!/usr/bin/env bash
# unattended-upgrade-stuck-kill.sh — Kill-switch for stuck unattended-upgrade
#
# Detects unattended-upgrade processes that are stuck (long elapsed, low CPU,
# no I/O progress) and kills them with grace. Triggered by the companion
# systemd timer (daily 05:10, 10 min after apt-daily-upgrade).
#
# Detection (3 criteria, score ≥ 2/3 → ACT):
#   S1 elapsed:    ps -o etimes= → elapsed_min ≥ threshold (default 30)
#   S2 low CPU:    CPU% < 5% in last sample (idle/waiting, NOT working)
#   S3 no I/O:     read_bytes delta in 5s sample < 1 MiB (no progress)
#
# Score interpretation:
#   0/3 → fresh, no decision
#   1/3 → log + skip (probably fine)
#   2/3 → candidate, log
#   3/3 → ACT (stuck)
#
# Action:
#   - ionice idle + renice 19 (de-prioritize first)
#   - SIGTERM (grace $UA_STUCK_GRACE_SEC) → if still alive → SIGKILL
#   - dpkg --configure -a + apt-get check post-kill
#   - Notify via DBus if available
#
# Selective mode: by default kills ALL stuck unattended-upgrade processes. To
# NOT kill certain upgrades (e.g. kernel upgrades that may take longer), use
# the UA_STUCK_DENY_LOG_REGEX or UA_STUCK_PRESERVE_KERNEL flag. To preserve
# specific processes entirely, use the UA_STUCK_ALLOWLIST.
#
# Config (env vars; all optional):
#   UA_STUCK_STUCK_MIN       default 30  — S1 threshold (minutes)
#   UA_STUCK_KILL_MIN        default 60  — escalate to SIGKILL (minutes)
#   UA_STUCK_GRACE_SEC       default 60  — between SIGTERM and SIGKILL
#   UA_STUCK_IO_SKIP         default 1   — skip if PSI io.full > threshold
#   UA_STUCK_IO_SKIP_PCT     default 5   — PSI io.full % threshold
#   UA_STUCK_RATELIMIT_HR    default 24  — hours between consecutive kills
#   UA_STUCK_ALLOWLIST       default ""  — regex: skip PIDs whose cmdline matches
#   UA_STUCK_DENY_LOG_REGEX  default ""  — regex: skip if recent log matches
#   UA_STUCK_PRESERVE_KERNEL default 0   — convenience: deny log containing linux-image
#   UA_STUCK_LOG_FILE        default /var/log/unattended-upgrade/unattended-upgrades.log
#                                          — where recent UA activity is logged
#   UA_STUCK_CONFIG_FILE     default ""  — optional config file to source
#
# Usage:
#   unattended-upgrade-stuck-kill.sh                       # normal run
#   unattended-upgrade-stuck-kill.sh --dry-run             # don't act
#   unattended-upgrade-stuck-kill.sh --test-sentinel       # validate filter
#   unattended-upgrade-stuck-kill.sh --help
#
# Exit codes:
#   0 = no stuck process (or successfully handled)
#   1 = error in detection (filter failure, etc.)
#   2 = stuck process detected but action failed

set -uo pipefail

# ---- Defaults / env overrides ----
STUCK_MIN="${UA_STUCK_STUCK_MIN:-30}"
KILL_MIN="${UA_STUCK_KILL_MIN:-60}"
GRACE_SEC="${UA_STUCK_GRACE_SEC:-60}"
IO_SKIP="${UA_STUCK_IO_SKIP:-1}"
IO_SKIP_PCT="${UA_STUCK_IO_SKIP_PCT:-5}"
RATELIMIT_HR="${UA_STUCK_RATELIMIT_HR:-24}"
ALLOWLIST="${UA_STUCK_ALLOWLIST:-}"
DENY_LOG_REGEX="${UA_STUCK_DENY_LOG_REGEX:-}"
PRESERVE_KERNEL="${UA_STUCK_PRESERVE_KERNEL:-0}"
UA_LOG_FILE="${UA_STUCK_LOG_FILE:-/var/log/unattended-upgrade/unattended-upgrades.log}"
CONFIG_FILE="${UA_STUCK_CONFIG_FILE:-}"

# Optional config file (sourced as bash)
if [ -n "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

# PRESERVE_KERNEL convenience: deny log if it contains kernel upgrade indicators
if [ "$PRESERVE_KERNEL" = "1" ]; then
    DENY_LOG_REGEX="${DENY_LOG_REGEX:+${DENY_LOG_REGEX}|}(linux-image|linux-headers|linux-kbuild|linux-compiler)"
fi

# Log paths: prefer /var/log if writable, fallback to user-local
LOG_DIR_SYSTEM="/var/log/unattended-upgrade-stuck-kill"
LOG_DIR_USER="${XDG_STATE_HOME:-$HOME/.local/state}/unattended-upgrade-stuck-kill"
if [ -w "$LOG_DIR_SYSTEM" ] || { mkdir -p "$LOG_DIR_SYSTEM" 2>/dev/null && [ -w "$LOG_DIR_SYSTEM" ]; }; then
    LOG_DIR="$LOG_DIR_SYSTEM"
else
    LOG_DIR="$LOG_DIR_USER"
fi
LOG_FILE="$LOG_DIR/stuck-kill.log"
RATELIMIT_FILE="$LOG_DIR/.last-action"
mkdir -p "$LOG_DIR" 2>/dev/null || true

# Self PID (excluded from filter)
SELF_PID=$$

# ---- Helpers ----
log() {
    local msg="$*"
    local ts
    ts="$(date -Iseconds)"
    echo "${ts} ${msg}" >> "$LOG_FILE"
    # Structured JSON line for tooling (separate, optional)
    echo "${ts} $(printf '%s\n' "$msg" | tr -d '"')" >> "$LOG_FILE.jsonl" 2>/dev/null || true
}

die() { log "FATAL: $*"; exit 1; }

# Read /proc/PID/io read_bytes safely (returns 0 on error)
io_read_bytes() {
    local pid="$1"
    awk '/^read_bytes:/ {print $2; exit}' "/proc/$pid/io" 2>/dev/null || echo 0
}

# Read PSI io.full percentage (returns 0 if not available)
psi_io_full_pct() {
    awk '/^full/ {
        for (i=2; i<=NF; i++) if ($i ~ /^avg10=/) {
            gsub("avg10=", "", $i); gsub("%", "", $i); print $i; exit
        }
    }' /proc/pressure/io 2>/dev/null || echo 0
}

# Read PSI memory.full percentage
psi_mem_full_pct() {
    awk '/^full/ {
        for (i=2; i<=NF; i++) if ($i ~ /^avg10=/) {
            gsub("avg10=", "", $i); gsub("%", "", $i); print $i; exit
        }
    }' /proc/pressure/memory 2>/dev/null || echo 0
}

# Self-test: create fake --wait-for-signal process and verify filter excludes it
#
# Mechanism: bash -c 'exec -a "name ...flags..." sleep 600' replaces the
# bash process with `sleep` while preserving our crafted string as argv[0].
# /proc/PID/comm = "sleep" (real binary), /proc/PID/cmdline shows the
# crafted argv[0 + "600". Sleep sees only "600" as its argument and runs
# for 600 seconds, indifferent to the fake argv[0].
#
# Cleanup: marker is unique per run. Killing the captured PID cleans the
# sleep child. pkill -f $marker catches any other spawned child.
self_test_sentinel() {
    log "=== self_test_sentinel: validating filter ==="

    local marker="uastest-$$-$(date +%s)-$RANDOM"

    # Spawn in current shell (NOT inside $(...) — command substitution
    # waits for ALL child processes). Capture $! directly, disown to
    # detach from job table.
    bash -c "exec -a 'unattended-upgrade-shutdown --wait-for-signal --marker=$marker' sleep 600" &
    local fake_pid=$!
    disown "$fake_pid" 2>/dev/null || true

    # bash exec is instant; 0.3s sufficient for /proc update
    sleep 0.3

    # Sanity: marker must be visible in /proc/PID/cmdline
    if ! pgrep -af "$marker" >/dev/null 2>&1; then
        log "  WARN: marker '$marker' not found — exec -a may have failed"
        pkill -9 -f "$marker" 2>/dev/null || true
        [ -n "$fake_pid" ] && [ -d "/proc/$fake_pid" ] && kill -9 "$fake_pid" 2>/dev/null || true
        return 1
    fi
    log "  marker visible (fake PID=$fake_pid, marker='$marker')"

    # Run the production filter
    local filtered
    filtered="$(pgrep -af 'unattended-upgrade' 2>/dev/null \
                | grep -v "^${SELF_PID} " \
                | grep -v 'wait-for-signal' \
                | grep -v "self_test_sentinel" \
                | grep -v "$marker" \
                | awk '{print $1}' \
                | sort -n -u | tr '\n' ',' | sed 's/,$//')"

    # Cleanup: kill by full marker (specific, won't nuke other shells)
    pkill -9 -f "$marker" 2>/dev/null || true
    [ -n "$fake_pid" ] && [ -d "/proc/$fake_pid" ] && kill -9 "$fake_pid" 2>/dev/null || true

    # Verify: filtered must NOT contain fake_pid or marker
    if [[ ",$filtered," == *",$fake_pid,"* ]]; then
        log "  FAIL: filter INCLUDED sentinel PID $fake_pid (filtered='$filtered')"
        return 1
    fi
    if [[ ",$filtered," == *"$marker,"* ]]; then
        log "  FAIL: filter INCLUDED marker '$marker' (filtered='$filtered')"
        return 1
    fi
    log "  PASS: filter correctly excluded sentinel (raw_filtered='$filtered')"
    return 0
}

# Get unattended-upgrade PIDs, excluding self + sentinel
get_pids() {
    pgrep -af 'unattended-upgrade' 2>/dev/null \
        | grep -v "^${SELF_PID} " \
        | grep -v 'wait-for-signal' \
        | grep -v 'self_test_sentinel' \
        | awk '{print $1}' \
        | sort -n -u
}

# Read cmdline of a PID (NUL-separated, replace with space)
get_cmdline() {
    local pid="$1"
    tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null
}

# Check if PID's cmdline matches the allowlist (regex)
# Returns 0 if allowlisted (skip this PID), 1 if not
is_allowlisted() {
    local pid="$1" cmdline
    [ -z "$ALLOWLIST" ] && return 1
    cmdline="$(get_cmdline "$pid")"
    [ -z "$cmdline" ] && return 1
    [[ "$cmdline" =~ $ALLOWLIST ]] && return 0
    return 1
}

# Check if recent unattended-upgrade log matches the deny pattern
# Returns 0 if denied (skip killing), 1 if not denied
is_denied_by_log() {
    [ -z "$DENY_LOG_REGEX" ] && return 1
    [ -f "$UA_LOG_FILE" ] || return 1
    # Read last 200 lines (most recent activity)
    tail -n 200 "$UA_LOG_FILE" 2>/dev/null | grep -qE "$DENY_LOG_REGEX" && return 0
    return 1
}

# Evaluate single PID: returns "score|details"
# Uses ps -o etimes= for elapsed seconds (robust, not /proc/PID/stat field 22)
evaluate_pid() {
    local pid="$1"
    [ -d "/proc/$pid" ] || { echo "0|exited"; return; }

    # S1: elapsed minutes
    local etimes
    etimes="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')"
    [ -z "$etimes" ] && { echo "0|exited"; return; }
    local elapsed_min=$((etimes / 60))

    if [ "$elapsed_min" -lt "$STUCK_MIN" ]; then
        echo "0|fresh:${elapsed_min}m"; return
    fi

    # S2: CPU% over last sample window
    local cpu_pct
    cpu_pct="$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')"
    [ -z "$cpu_pct" ] && { echo "0|exited"; return; }

    # S3: I/O progress — sample read_bytes twice, 5s apart
    local rb1 rb2 rb_delta
    rb1="$(io_read_bytes "$pid")"
    sleep 5
    rb2="$(io_read_bytes "$pid")"
    rb_delta=$(( rb2 - rb1 ))

    # Scoring
    local s1=0 s2=0 s3=0
    [ "$elapsed_min" -ge "$STUCK_MIN" ] && s1=1
    # CPU < 5% = idle
    awk -v cpu="$cpu_pct" 'BEGIN { exit !(cpu+0 < 5) }' && s2=1
    # I/O delta < 1 MiB in 5s = no progress
    [ "$rb_delta" -lt 1048576 ] && s3=1

    local score=$((s1 + s2 + s3))
    echo "${score}|e=${elapsed_min}m,cpu=${cpu_pct}%,io_delta=${rb_delta}|s1=$s1,s2=$s2,s3=$s3"
}

# Kill stuck PID with grace
kill_stuck() {
    local pid="$1" elapsed_min="$2"

    log "  ---- PID $pid action start (elapsed ${elapsed_min}m) ----"

    # Step 1: ionice + renice (de-prioritize first, may self-recover)
    ionice -c idle -p "$pid" 2>/dev/null || true
    renice -n 19 -p "$pid" 2>/dev/null || true
    log "    step 1: ionice idle + renice 19 done"

    log "    grace period ${GRACE_SEC}s..."
    sleep "$GRACE_SEC"

    if [ -d "/proc/$pid" ]; then
        log "    step 2a: still alive, SIGTERM"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 5
    fi

    if [ -d "/proc/$pid" ]; then
        log "    step 2b: SIGTERM didn't work, SIGKILL"
        kill -KILL "$pid" 2>/dev/null || true
        sleep 2
    fi

    if [ -d "/proc/$pid" ]; then
        log "    ERROR: PID $pid survived SIGKILL — kernel may be hung"
        return 1
    fi

    log "    step 3: PID $pid dead, dpkg recovery..."
    dpkg --configure -a 2>&1 | tail -5 >> "$LOG_FILE" || true
    apt-get check 2>&1 | tail -3 >> "$LOG_FILE" || true
    log "    recovery done"

    # Update rate limit
    date +%s > "$RATELIMIT_FILE"
    return 0
}

# Notify via DBus (best effort)
notify() {
    local summary="$1" body="$2"
    command -v notify-send >/dev/null 2>&1 || return 0
    DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}" \
        notify-send -u critical -a "ua-stuck-kill" "$summary" "$body" 2>/dev/null || true
}

# ---- Argument parsing ----
DRY_RUN=0
case "${1:-}" in
    --help|-h)
        sed -n '2,75p' "$0" | sed 's/^# \?//'
        exit 0
        ;;
    --dry-run)
        DRY_RUN=1
        log "=== DRY-RUN mode ==="
        ;;
    --test-sentinel)
        self_test_sentinel
        exit $?
        ;;
esac

# ---- Pre-checks ----
command -v ps >/dev/null 2>&1 || die "ps not found"
command -v pgrep >/dev/null 2>&1 || die "pgrep not found"

# Self-test always (cheap, prevents filter regressions)
if ! self_test_sentinel; then
    log "SELF-TEST FAILED — refusing to run. Fix the filter manually."
    exit 1
fi

# ---- Rate limit check ----
if [ -f "$RATELIMIT_FILE" ]; then
    last=$(cat "$RATELIMIT_FILE" 2>/dev/null || echo 0)
    now=$(date +%s)
    age_hr=$(( (now - last) / 3600 ))
    if [ "$age_hr" -lt "$RATELIMIT_HR" ]; then
        log "rate limit: acted ${age_hr}h ago (< ${RATELIMIT_HR}h), skip kill + notify only"
        notify "ua-stuck-kill: rate limited" "Already acted ${age_hr}h ago (< ${RATELIMIT_HR}h). Manual check."
        exit 0
    fi
fi

# ---- PSI awareness ----
if [ "$IO_SKIP" = "1" ]; then
    io_full="$(psi_io_full_pct)"
    io_full_int="${io_full%.*}"
    [ -z "$io_full_int" ] && io_full_int=0
    if [ "$io_full_int" -gt "$IO_SKIP_PCT" ]; then
        log "PSI io.full=${io_full}% > ${IO_SKIP_PCT}% threshold — system under real I/O load, skipping kill"
        exit 0
    fi
    log "PSI io.full=${io_full}% OK (< ${IO_SKIP_PCT}%)"
fi

mem_full="$(psi_mem_full_pct)"
mem_full_int="${mem_full%.*}"
[ -z "$mem_full_int" ] && mem_full_int=0
if [ "$mem_full_int" -gt 1 ]; then
    log "PSI memory.full=${mem_full}% > 1% — memory pressure high, skipping kill (might be legit)"
    exit 0
fi

# ---- Global log deny check (selective mode) ----
if is_denied_by_log; then
    log "deny-log: recent log matches UA_STUCK_DENY_LOG_REGEX — skipping all kills this run"
    notify "ua-stuck-kill: skipped (deny log)" "Recent log matches deny pattern. Manual check if persistent."
    exit 0
fi

# ---- Main loop ----
log "=== run start (stuck_min=${STUCK_MIN} kill_min=${KILL_MIN} grace=${GRACE_SEC}s) ==="

PIDS="$(get_pids)"
if [ -z "$PIDS" ]; then
    log "no unattended-upgrade processes; exit 0"
    exit 0
fi

log "found unattended-upgrade PIDs: $(echo "$PIDS" | tr '\n' ',' | sed 's/,$//')"

acted=0
for pid in $PIDS; do
    [ -d "/proc/$pid" ] || { log "  PID $pid: already exited"; continue; }

    # Selective mode: allowlist check
    if is_allowlisted "$pid"; then
        local_cmdline="$(get_cmdline "$pid")"
        log "  PID $pid: allowlisted (cmdline matches UA_STUCK_ALLOWLIST): ${local_cmdline:0:80}…"
        continue
    fi

    result="$(evaluate_pid "$pid")"
    score="${result%%|*}"
    rest="${result#*|}"

    log "  evaluating PID $pid: $rest"

    if [ "$score" -ge 2 ] && [ "${score%%|*}" != "0" ]; then
        elapsed_min="$(echo "$rest" | grep -oE 'e=[0-9]+' | cut -d= -f2)"

        if [ "$DRY_RUN" = "1" ]; then
            log "  DRY-RUN: would kill PID $pid (score=$score, elapsed=${elapsed_min}m)"
            acted=1
            continue
        fi

        log "  ACTING on PID $pid (score=$score, elapsed=${elapsed_min}m)"
        if kill_stuck "$pid" "$elapsed_min"; then
            acted=1
            notify "ua-stuck-kill: killed stuck PID $pid" "Elapsed ${elapsed_min}m, score=$score. dpkg recovery run."
        else
            log "  ERROR: kill_stuck failed for PID $pid"
        fi
    fi
done

if [ "$acted" -eq 0 ]; then
    log "no stuck processes to act on; exit 0"
fi
exit 0
