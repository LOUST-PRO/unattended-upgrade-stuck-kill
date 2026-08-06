# Design decisions — unattended-upgrade-stuck-kill

This document explains the non-obvious choices made in the script.
If you're reviewing the code and asking "why this and not that",
this is the first place to look.

## 1. SELECTIVE by default, not aggressive

**Decision**: zero kills unless the operator opts in via config flags.

**Rationale**: unattended-upgrade is conservative on purpose. A
kill that interrupts a kernel-package replacement can leave
initramfs half-built → unbootable on next reboot. This is a
worst-case outcome that no operator wants by default.

Compare with the naive alternative: `pkill unattended-upgrade`
when elapsed > 30min. That's "convenient" but breaks the upgrade
right when it matters most.

## 2. Three-criteria "stuck" detection (not elapsed-only)

**Decision**: a process is "stuck" only when ALL of:
- `etimes >= UA_STUCK_STUCK_MIN` (default 15 min)
- CPU% < `UA_STUCK_CPU_MAX_PCT` (default 5%)
- `read_bytes` delta < `UA_STUCK_READ_BYTES_MAX_KB` (default 1 MiB)

**Rationale**: elapsed-time-only detection has two failure modes:

- **False positives**: a 30-min download that's working slowly
  (mirror near you, large delta, network retransmits) looks
  "stuck" by elapsed time, but CPU% and read_bytes are non-zero.
- **False negatives**: an upgrade that IS stuck but with
  occasional activity (e.g., polling, retry-with-jitter) can have
  elapsed > 30 min AND non-zero CPU% (a few retries per second
  keep CPU visible).

Combining three orthogonal signals dramatically reduces both.

## 3. PSI self-skip

**Decision**: skip ALL kills if `io.full` PSI avg10 > threshold
(default 5%).

**Rationale**: if the system is under real I/O pressure, the
upgrade is probably PART of that pressure (or competing for the
same locks). Killing the upgrade won't help; it'll just make the
problem re-occur in the next apt-daily timer. Better to wait for
the system to settle.

This is one of the few cases where we trust the operator's
default config to be safe.

## 4. Per-host rate-limit

**Decision**: after a successful kill, no further kills for
`UA_STUCK_RATE_LIMIT_SECS` (default 4h).

**Rationale**: the upgrade is triggered by apt-daily.timer. If we
kill it once, apt-daily might reschedule for `now + jitter`. If
the underlying problem (lock contention, network, etc.) persists,
the new run hangs again. Killing twice in 30 minutes is just
abuse of the recovery path.

4 hours gives time for:
- The lock-holder process to finish
- Network to recover
- Manual intervention

## 5. PID cmdline allowlist (regex against `/proc/PID/cmdline`)

**Decision**: a regex match against the NUL-separated cmdline
SKIPS the kill for that PID.

**Rationale**: an operator might be running a non-standard
upgrade wrapper (custom Ansible play, hand-rolled `apt-get
dist-upgrade` in a tmux session, etc.). Those processes might
have a recognizable name in their cmdline but are NOT actually
unattended-upgrade-spawned.

Caveat: cmdline can be rewritten (setproctitle, `bash -c "exec -a
..."` patterns). The allowlist is opt-in defense, not absolute
protection.

## 6. Log-based deny (regex against unattended-upgrades.log)

**Decision**: if the last 200 lines of unattended-upgrades.log
match a regex, skip ALL kills for this run.

**Rationale**: the only safe way to detect "we're upgrading the
kernel RIGHT NOW" is by reading the log. unattended-upgrade logs
the package list before it starts installing. Matching
`linux-image|linux-headers` is the canonical protection.

Alternative: parse dpkg's selection state. Rejected — fragile,
requires DBus, not in scope.

## 7. Default `--dry-run` semantics

**Decision**: there is NO `--dry-run` required for safety.
Without ANY flag, the script logs its decision but doesn't kill.
`--dry-run` is explicit, `--force` is required for actual kills.

Wait — that's not quite right. Re-read the script:

```bash
case "${1:-}" in
  --dry-run|--test-sentinel|--version|--help|"") ... ;;
  *) ... actual kill path ... ;;
esac
```

The default is "audit but don't kill". `*` (anything else) is
"kill if criteria met". This means `sudo ./script.sh` with no
arguments just does a dry-run. `sudo ./script.sh --force` (or
any unknown flag) triggers kills.

This is unusual but deliberate. Most watchdog scripts require
explicit flags for ANY action; this one requires explicit flags
to do damage.

## 8. Self-test sentinel (no `$()` wrapper)

**Decision**: the self-test spawns a sentinel via
`bash -c 'exec -a "name" sleep 600' &` at top-level, NOT inside
`$()`. Disowned immediately.

**Rationale**: `$()` command substitution activates implicit job
control. Even with `&` to background, the substitution waits for
ALL child processes (backgrounded or not) to exit. This created
orphan `sleep` children during development.

Top-level + `disown` is the cleanest fix. `exec -a` lets us
preserve a custom `argv[0]` so the filter `pkill -f` matches.

## 9. Why no Python?

This is pure bash + coreutils (pgrep, ps, awk, sed, grep). The
intentional reason: zero-dependency deployment. The script is
meant to drop into a broken system where dpkg/apt/python may not
work. Adding a Python runtime dependency would defeat the purpose.

Coreutils are present on every Linux system. Bash 4+ is present
on every Debian/Ubuntu LTS since 2014.

## 10. Log paths — system vs user

**Decision**: prefer `/var/log/unattended-upgrade-stuck-kill/`
when writable; fall back to `$XDG_STATE_HOME/unattended-upgrade-stuck-kill/`
(`~/.local/state/...` by default).

**Rationale**: in production, root runs the script via systemd
and `/var/log/` is the canonical location. In development /
testing, the operator runs as user and `$XDG_STATE_HOME` is the
right place (XDG Base Directory spec, XDG_STATE_HOME = "files
that should persist between (application) restarts").

The fallback is automatic and silent. No env var required.

## 11. systemd unit design

**Decision**: `Type=oneshot` + `SuccessExitStatus=0 1`. `After=apt-daily-upgrade.service`.

**Rationale**:
- `oneshot` because the script exits after one pass; no daemon.
- `SuccessExitStatus=0 1` because "no stuck processes" is a
  legitimate success, not an error. exit 1 is reserved for
  failures that retrying won't fix (e.g., a permission error on
  /proc/PID/stat).
- `After=apt-daily-upgrade.service` so we don't race against the
  service that might be triggering this exact condition.

## 12. Optional config file

**Decision**: `UA_STUCK_CONFIG_FILE` is sourced if it exists.
Default is `/etc/unattended-upgrade-stuck-kill.conf`.

**Rationale**: env vars are flexible but don't survive cleanly in
systemd `EnvironmentFile=`. A sourced file is the most flexible:
operators can mix-and-match — define defaults in the conf file,
override per-run with env vars, override per-machine with
`EnvironmentFile=` in a drop-in.

## What this script is NOT

- Not a replacement for fixing the underlying hang (lock
  contention, network, etc.). It only stops the bleeding.
- Not a process monitor in the daemontools / supervisord sense.
  It runs once and exits.
- Not for non-Debian systems. unattended-upgrade is Debian-specific;
  the log paths and PID patterns are Debian-specific too.
