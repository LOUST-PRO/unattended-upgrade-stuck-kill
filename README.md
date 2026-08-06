# unattended-upgrade-stuck-kill

**Selective kill-guard for stuck `unattended-upgrade` runs on Debian / Ubuntu.**

When the unattended-upgrade daemon hangs (often on apt locks, dpkg lock,
network timeouts, or kernel-package replacement during a long sleep),
this watchdog detects it, applies your selection rules, and only kills
what you've explicitly allowed.

```text
NOT a "kill anything that runs unattended-upgrade for > N minutes".
SELECTIVE: you decide which upgrades are safe to interrupt
           and which must complete (e.g. kernel packages).
```

## Why

`unattended-upgrade` is designed to be safe-but-conservative. It uses
flock locks and waits. But on real systems it gets stuck more often
than its maintainers admit:

- dpkg lock held by an interactive `apt-get` left open overnight
- network unreachable + ipv6 retries for 30+ minutes
- kernel-package replacement (linux-image, linux-headers) with
  initramfs regen that sleeps inside dpkg
- apt lock held by snap or flatpak background updaters

Most "kill it" scripts are blunt — they look at elapsed time and
terminate. That breaks the one moment you actually want the upgrade
to finish: a kernel upgrade. Killing mid-kernel-upgrade can leave
initramfs half-built, leading to unbootable systems on next reboot.

This script lets you:

| Decision                          | How                          |
|-----------------------------------|------------------------------|
| Kill stuck unattended-upgrade PIDs | Default behavior (configurable elapsed + CPU + I/O inactivity) |
| Protect kernel upgrades           | `UA_STUCK_PRESERVE_KERNEL=1` or `UA_STUCK_DENY_LOG_REGEX` |
| Protect specific PIDs             | `UA_STUCK_ALLOWLIST="regex1\|regex2"` (cmdline regex) |
| Skip everything if system is busy  | PSI self-check (configurable threshold, default 5%) |
| Throttle per-host                 | Rate-limit (default 4h cooldown) |

## Quick start

```bash
# Run once interactively (dry-run, no kills)
sudo ./bin/unattended-upgrade-stuck-kill.sh --dry-run

# Validate the filter (spawns + cleans a sentinel process)
./bin/unattended-upgrade-stuck-kill.sh --test-sentinel

# Run it now (with default thresholds)
sudo ./bin/unattended-upgrade-stuck-kill.sh

# Install as a daily systemd timer (runs at 05:10 every day)
sudo ./install.sh
```

## Selective mode

Three independent guards. They compose (AND logic: all must pass to skip).

### 1. PID cmdline allowlist

Skip PIDs whose `/proc/PID/cmdline` matches a regex. Useful for
protecting upgrade processes spawned by wrappers that have known,
identifiable names.

```bash
UA_STUCK_ALLOWLIST="my-orchestrator-upgrade|nightly-patches" \
    sudo ./bin/unattended-upgrade-stuck-kill.sh --dry-run
```

### 2. Log-based deny

Read the last 200 lines of `unattended-upgrades.log`. If any line
matches `UA_STUCK_DENY_LOG_REGEX`, skip **all** kills this run. This
is the recommended way to protect kernel upgrades:

```bash
UA_STUCK_DENY_LOG_REGEX="linux-image|linux-headers|linux-kbuild|linux-compiler" \
    sudo ./bin/unattended-upgrade-stuck-kill.sh --dry-run
```

The script also exposes `UA_STUCK_PRESERVE_KERNEL=1` as a convenience
flag that sets the same regex.

### 3. Self rate-limit

If a kill was issued in the last `UA_STUCK_RATE_LIMIT_SECS` seconds
(default 14400 = 4h), skip. Prevents thrash if the upgrade tries to
restart and re-hang.

```bash
# Tighter throttle for testing
UA_STUCK_RATE_LIMIT_SECS=300 \
    sudo ./bin/unattended-upgrade-stuck-kill.sh
```

## Configuration

All knobs are env vars. No config file is required, but
`UA_STUCK_CONFIG_FILE=/etc/unattended-upgrade-stuck-kill.conf` is
sourced if it exists (see [`docs/decisions.md`](docs/decisions.md)).

| Variable                     | Default                  | Notes |
|------------------------------|--------------------------|-------|
| `UA_STUCK_STUCK_MIN`         | 900                      | Min elapsed seconds before considered stuck |
| `UA_STUCK_CPU_MAX_PCT`       | 5                        | Skip if CPU% > this (still doing work) |
| `UA_STUCK_READ_BYTES_MAX_KB` | 1024                     | Skip if read_bytes delta > this (1 MiB) |
| `UA_STUCK_PSI_IO_PCT_MAX`    | 5                        | Skip if `io.full` PSI > this (system busy) |
| `UA_STUCK_RATE_LIMIT_SECS`   | 14400                    | Per-host cooldown between kill actions |
| `UA_STUCK_LOG_FILE`          | `/var/log/unattended-upgrade/unattended-upgrades.log` | Source log for deny-log matching |
| `UA_STUCK_ALLOWLIST`         | (empty)                  | Regex against `/proc/PID/cmdline` (skip kill on match) |
| `UA_STUCK_DENY_LOG_REGEX`    | (empty)                  | Regex against log file (skip all kills on match) |
| `UA_STUCK_PRESERVE_KERNEL`   | 0                        | Convenience: sets `linux-image\|linux-headers\|...` deny regex |
| `UA_STUCK_CONFIG_FILE`       | `/etc/unattended-upgrade-stuck-kill.conf` | Optional config source |
| `UA_STUCK_LOG_DIR`           | `/var/log/unattended-upgrade-stuck-kill` | Falls back to `$XDG_STATE_HOME/unattended-upgrade-stuck-kill` |

## Detection logic

A process is "stuck" when **all three** hold:

1. `etimes >= UA_STUCK_STUCK_MIN` (default 15 min)
2. `pcpu < UA_STUCK_CPU_MAX_PCT` (default 5%)
3. `read_bytes` delta over a sample window is `< UA_STUCK_READ_BYTES_MAX_KB`

PLUS none of these system-level skips fire:

- PSI `io.full` avg10 > `UA_STUCK_PSI_IO_PCT_MAX`
- Rate-limit active (last kill < `UA_STUCK_RATE_LIMIT_SECS` ago)
- Log deny regex matched recent unattended-upgrade activity
- Cmdline matches `UA_STUCK_ALLOWLIST`

## Installation (systemd timer)

```bash
sudo ./install.sh
# creates:
#   /usr/local/sbin/unattended-upgrade-stuck-kill.sh
#   /etc/systemd/system/unattended-upgrade-stuck-kill.{service,timer}
#   /var/log/unattended-upgrade-stuck-kill/
# enables + starts the timer (daily at 05:10)
```

To uninstall:

```bash
sudo systemctl disable --now unattended-upgrade-stuck-kill.timer
sudo rm /etc/systemd/system/unattended-upgrade-stuck-kill.{service,timer}
sudo rm /usr/local/sbin/unattended-upgrade-stuck-kill.sh
```

## Testing

Five smoke tests are provided. They spawn fake "stuck" processes via
`bash exec -a + sleep` (preserving custom argv[0]) and verify the
script detects, skips, or kills correctly. All use isolated temp
log paths and clean up after themselves.

```bash
cd tests/
./test-sentinel.sh            ../bin/unattended-upgrade-stuck-kill.sh
./test-dry-run.sh             ../bin/unattended-upgrade-stuck-kill.sh
./test-stuck-process.sh       ../bin/unattended-upgrade-stuck-kill.sh
./test-selective-allowlist.sh  ../bin/unattended-upgrade-stuck-kill.sh
./test-selective-deny.sh      ../bin/unattended-upgrade-stuck-kill.sh
```

See [`docs/`](docs/) for design rationale, decision tree, and
mermaid state diagrams.

## License

MIT. See [`LICENSE`](LICENSE).

## Author

David Mireles (DavidMireles) — `research@loust.pro`
