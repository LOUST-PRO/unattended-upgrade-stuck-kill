# Selective mode in depth

This document explains the three selective guards, how they compose,
and what each guard protects against. Read this if you need to
customize behavior beyond the defaults.

## The three guards

| Guard                      | Granularity      | Protects against                                         |
|----------------------------|------------------|----------------------------------------------------------|
| `UA_STUCK_ALLOWLIST`       | per-PID          | PIDs whose cmdline matches a known wrapper / orchestrator |
| `UA_STUCK_DENY_LOG_REGEX`  | per-run (global) | All kills, when log shows in-progress risky upgrade      |
| `UA_STUCK_PRESERVE_KERNEL` | per-run (global) | Kernel upgrades (linux-image, linux-headers, etc.)       |

They are AND-composed: if ANY guard fires, the kill is skipped
(allowlist per-PID, deny-log + preserve-kernel per-run).

## Guard 1: PID cmdline allowlist

### What it does

For each PID matching the `unattended-upgrade` pattern (via
`pgrep -af`), the script reads `/proc/PID/cmdline` (NUL-separated),
joins with spaces, and tests against `UA_STUCK_ALLOWLIST`.

If the regex matches, that PID is marked "allowlisted" in the log
and skipped.

### When to use it

You run unattended-upgrade via a wrapper (Ansible, custom script,
containerized entrypoint). The wrapper's PID has a recognizable
cmdline but might not have "unattended-upgrade" in its name.

Example: a nightly upgrade triggered by `cron.weekly/upgrade.sh`:

```text
bash /etc/cron.weekly/upgrade.sh --apt-mode unattended
```

This shows up as `bash` with `--apt-mode unattended` in the
cmdline. If unattended-upgrade is launched as a child, the parent
`bash` won't match the unattended-upgrade filter — only the child
will. But if your wrapper *is* the upgrade (using `apt-get` directly),
the wrapper PID itself shows up.

### Caveats

- The cmdline is NUL-separated. The script uses `tr '\0' ' '` to
  read it. Pathological binaries with embedded NULs in argv can
  confuse the match.
- `setproctitle` can rewrite argv. If a process uses it, the
  cmdline seen via `/proc/PID/cmdline` may differ from what you
  expected.

### Example

```bash
UA_STUCK_ALLOWLIST="cron-weekly-upgrade|nightly-patches" \
    sudo ./bin/unattended-upgrade-stuck-kill.sh --dry-run
```

## Guard 2: Log-based deny

### What it does

Reads the last 200 lines of `UA_STUCK_LOG_FILE` (default
`/var/log/unattended-upgrade/unattended-upgrades.log`). If any
line matches `UA_STUCK_DENY_LOG_REGEX`, the entire run is skipped.

### When to use it

This is the canonical way to protect kernel upgrades. unattended-upgrade
logs the package list before installing:

```
2026-08-06 12:00:00,123 INFO Packages that will be upgraded:
  linux-image-7.0.10+deb14-amd64 linux-headers-7.0.10+deb14-amd64
```

A regex like `linux-image|linux-headers` matches this. The script
will refuse to kill any PID this run.

### Why log-based, not state-based

You might think: "Why not parse `/var/lib/dpkg/status` for the
package currently being upgraded?" Two reasons:

1. **No reliable signal mid-upgrade.** dpkg locks `/var/lib/dpkg/status-` while writing, and the upgrade-in-progress state is opaque to userspace.
2. **Race condition.** Reading dpkg status from the watchdog is itself an I/O operation that can be blocked by the same lock the upgrade holds.

The log file is the canonical "what was the script doing" record.
It's append-only, rarely locked, and reliable.

### Caveats

- 200 lines is a small window. If your log is very chatty (debug
  logging enabled), you might miss a kernel package mention that
  scrolled off. Set `UA_STUCK_DENY_LOG_LINES=500` for more buffer.
- The log rotation can happen mid-run. If `/var/log/unattended-upgrade/`
  is rotated (via logrotate) during the upgrade, the watchdog might
  miss the kernel mention. Mitigation: systemd's `ProtectSystem=strict`
  + `ReadWritePaths=` covers the common case.

### Example

```bash
UA_STUCK_DENY_LOG_REGEX="linux-image|linux-headers|linux-kbuild|linux-compiler" \
    sudo ./bin/unattended-upgrade-stuck-kill.sh --dry-run
```

## Guard 3: PRESERVE_KERNEL (convenience)

### What it does

Sets `UA_STUCK_DENY_LOG_REGEX` to a sensible default for kernel
upgrades. Equivalent to:

```text
linux-image|linux-headers|linux-kbuild|linux-compiler|linux-modules|linux-firmware
```

### When to use it

Most operators want this. If your Debian/Ubuntu system upgrades
its kernel unattended, you almost certainly want to let it finish.

```bash
UA_STUCK_PRESERVE_KERNEL=1 \
    sudo ./bin/unattended-upgrade-stuck-kill.sh --dry-run
```

## How they compose

```
                     +-- (cmdline matches ALLOWLIST) --+
                     |                                   |
process candidate ->-+                                   +--> skip kill
                     |                                   |
                     +-- (log matches DENY_LOG_REGEX) ---+
                     |                                   |
                     +-- (PRESERVE_KERNEL=1 AND         +
                          log mentions kernel pkgs) ----+

If none match → check 3-criteria "stuck" → kill or skip.
```

## Practical defaults

For a typical Debian 12+ server:

```bash
UA_STUCK_PRESERVE_KERNEL=1
UA_STUCK_PSI_IO_PCT_MAX=10
UA_STUCK_RATE_LIMIT_SECS=14400
```

For a tight loop in CI:

```bash
UA_STUCK_STUCK_MIN=60
UA_STUCK_CPU_MAX_PCT=2
UA_STUCK_PSI_IO_PCT_MAX=2
UA_STUCK_RATE_LIMIT_SECS=300
```

For a workstation with multiple custom upgrade wrappers:

```bash
UA_STUCK_ALLOWLIST="my-ansible-upgrade|user-apt-helper"
UA_STUCK_PRESERVE_KERNEL=1
```
