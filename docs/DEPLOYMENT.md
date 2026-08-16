# QManager Deployment Guide

This document covers building, installing, and deploying QManager to the Quectel RM520N-GL modem.

---

## Quick Install (Recommended)

ADB or SSH into the modem and run the one-liner installer:

```bash
curl -fsSL -o /tmp/qmanager-installer.sh \
  https://github.com/tuanlongsav/QManager-VN/raw/refs/heads/main/qmanager-installer.sh && \
  bash /tmp/qmanager-installer.sh
```

The interactive installer fetches the latest release tarball, verifies the SHA-256 checksum, bootstraps Entware (if needed), installs lighttpd and required modules, deploys the frontend and backend, configures systemd services, and optionally sets up SSH (dropbear). A reboot is triggered after installation.

See `install_rm520n.sh --help` for all flags (`--skip-packages`, `--force`, etc.)

### Manual / Offline Install

If internet access is unavailable on the modem, build and transfer the tarball from your dev machine:

```bash
# 1. Build the package (frontend + backend + dependencies)
bun run package

# 2. Transfer to device (use -O for RM520N-GL dropbear, which lacks sftp-server)
scp -O qmanager-*.tar.gz root@192.168.225.1:/tmp/

# 3. Extract and install on device
ssh root@192.168.225.1
cd /tmp && tar xzf qmanager-*.tar.gz
cd qmanager_install && bash install_rm520n.sh
```

The installer will:
- Bootstrap Entware from `bin.entware.net` if not present
- Install lighttpd + modules, sudo, jq, and coreutils-timeout from Entware
- Deploy frontend, backend scripts, CGI endpoints, and systemd service units
- Strip CRLF from all deployed shell scripts, systemd units, and sudoers rules
- Configure sudoers rules for `www-data` privilege escalation
- Enable and start all QManager systemd services

See `bash install_rm520n.sh --help` for all options (`--skip-packages`, `--force`, etc.)

---

## Prerequisites

### Development Machine

- [Bun](https://bun.sh/) — Package manager and runtime
- Git
- A text editor that preserves LF line endings (VS Code, Vim, etc.)

### Target Device

- Quectel RM520N-GL modem with RGMII Ethernet connectivity
- ADB or SSH access to the modem's internal Linux OS (SDXLEMUR, ARMv7l)
- Internet access on the modem (for Entware bootstrap and package install — non-fatal if offline, packages are skipped with warnings)
- Writable `/usrdata/` partition (persistent storage)

---

## Building the Frontend

### Development Build

```bash
cd QManager
bun install
bun run dev
```

Opens at `http://localhost:3000`. API requests are proxied to `http://192.168.224.1` (the modem's IP).

To change the proxy target, edit `next.config.ts`:

```typescript
destination: "http://192.168.224.1/cgi-bin/:path*",
// or for Tailscale:
// destination: "http://your-device.ts.net/cgi-bin/:path*",
```

### Production Build

```bash
bun run build
```

This produces a static export in the `out/` directory. The output is a complete, self-contained frontend that requires no server-side rendering.

**Important:** The `rewrites()` block in `next.config.ts` is only used in development. In production, the browser makes direct requests to the device's CGI endpoints.

### Build Output

```
out/
├── index.html          # Redirects to /dashboard/
├── dashboard/
│   └── index.html
├── login/
│   └── index.html
├── cellular/
│   ├── index.html
│   ├── settings/
│   ├── cell-locking/
│   ├── cell-scanner/
│   ├── custom-profiles/
│   └── sms/
├── local-network/
│   └── ...
├── monitoring/
│   └── ...
├── _next/
│   ├── static/         # JS bundles, CSS, fonts
│   └── ...
└── ...
```

### Release Packaging & CI

`bun run package` is the packaging entry point. It is three steps, in this order:

```
bash scripts/test/run-all.sh   →   bun --bun next build   →   bash build.sh
```

The gate comes **first** by design. `run-all.sh` is six checks (`bash -n` syntax, CRLF, iCloud conflict copies, i18n parity, exclusion drift, sudoers hygiene); the fatal ones abort before anything is built, so a broken script — or an unparseable sudoers file, or one that has regained a wildcard grant — cannot reach a tarball. See [BACKEND.md §13 — Testing Locally](BACKEND.md#testing-locally) for the full check table.

`.github/workflows/release.yml` builds the same artifacts on a `v*` tag push (or `workflow_dispatch`). It calls `next build` and `build.sh` directly rather than going through `bun run package`, so it runs the gate as an explicit step:

| Step | Command |
|------|---------|
| Stamp version from tag | `sed` into `package.json` |
| Install dependencies | `bun install --frozen-lockfile` |
| **Pre-build gate** | `bash scripts/test/run-all.sh` |
| Build static export | `bun --bun next build` |
| Package tarball | `bash build.sh` |
| Verify artifacts | `qmanager.tar.gz` + `sha256sum.txt` exist |
| Create GitHub Release | `softprops/action-gh-release@v2` |

> ⚠️ WARNING: Keep the gate step in the workflow. Without it, cutting a release by pushing a tag skips every check that `bun run package` runs locally — and a tag push is precisely the path where nobody ran `bun run package` by hand first. If you add a step to `run-all.sh`, both entry points pick it up automatically; if you add a *new* build path, wire the gate into it explicitly.

---

## Deploying to the RM520N-GL

The installer (`install_rm520n.sh`) handles all deployment steps. Manual file-by-file deployment is not recommended. Use `bun run package` to produce the tarball, then run the installer on the device as described in [Quick Install](#quick-install-recommended).

### Verifying Installation

```bash
# Check all QManager services are running
systemctl list-units 'qmanager-*'

# Check the poller is producing data
jq .timestamp /tmp/qmanager_status.json

# Check CGI endpoints are accessible
curl -k https://localhost/cgi-bin/quecmanager/at_cmd/fetch_data.sh

# Check installer log (if install just ran)
tail -50 /tmp/qmanager_install.log

# Check installed version
cat /etc/qmanager/VERSION
```

---

## Directory Structure on Device

```
/usrdata/qmanager/www/
├── index.html              # Frontend entry point
├── _next/                  # Frontend assets (JS, CSS, fonts)
├── dashboard/              # Frontend pages
├── cellular/
├── monitoring/
├── local-network/
├── login/
├── about-device/
├── support/
└── cgi-bin/
    └── quecmanager/        # CGI API endpoints
        ├── auth/
        ├── at_cmd/
        ├── bands/
        ├── cellular/
        ├── device/
        ├── frequency/
        ├── monitoring/
        ├── network/
        ├── profiles/
        ├── scenarios/
        ├── system/
        ├── tower/
        └── vpn/

/usr/bin/
├── qcmd                    # AT command wrapper
├── qmanager_update         # OTA update worker (runs as root via sudoers)
├── qmanager_auto_update    # Automatic update checker daemon
├── qmanager_poller         # Main data collector
├── qmanager_ping           # Ping daemon
├── qmanager_watchcat       # Connection watchdog
├── qmanager_profile_apply  # Profile apply daemon
├── qmanager_cell_scanner   # Cell scanner
├── qmanager_neighbour_scanner
├── qmanager_band_failover
├── qmanager_tower_failover
├── qmanager_tower_schedule
├── qmanager_mtu_apply
├── qmanager_imei_check
├── qmanager_setup          # Boot one-shot (permissions, pre-create /tmp files)
└── qmanager_logread

/usr/lib/qmanager/
├── cgi_base.sh             # CGI boilerplate (sources platform.sh)
├── cgi_auth.sh             # Session management
├── cgi_at.sh               # AT command helpers
├── platform.sh             # systemd/sudo abstraction (svc_*, pid_alive, etc.)
├── qlog.sh                 # Logging library
├── parse_at.sh             # AT response parsers
├── semver.sh               # Shared semver_compare() — sourced by update CGI and auto_update
├── events.sh               # Event detection
├── profile_mgr.sh          # Profile CRUD
├── tower_lock_mgr.sh       # Tower lock management
├── email_alerts.sh         # Email alert logic
└── sms_alerts.sh           # SMS alert logic

/lib/systemd/system/
├── qmanager-firewall.service
├── qmanager-setup.service
├── qmanager-poller.service
├── qmanager-ping.service
├── qmanager-console.service
├── qmanager-watchcat.service
├── qmanager-ttl.service
├── qmanager-mtu.service
├── qmanager-imei-check.service
└── qmanager-tower-failover.service

/etc/qmanager/             # Persistent configuration
├── VERSION                # Installed version (written atomically at install end)
├── VERSION.pending        # Present during install; mv'd to VERSION on success
├── shadow                 # Password hash
├── profiles/              # Custom SIM profiles
├── tower_lock.json
├── band_lock.json
├── imei_backup.json
├── last_iccid
└── msmtprc                # Email SMTP config (no logfile directive)

/etc/sudoers.d/qmanager    # www-data privilege escalation rules (includes qmanager_update)

/tmp/                      # Runtime state (lost on reboot)
├── qmanager_status.json
├── qmanager_signal_history.json
├── qmanager_ping_history.json
├── qmanager_events.json
├── qmanager_ping.json
├── qmanager_watchcat.json
├── qmanager_watchcat.lock # Touched during install/low-power to pause watchdog
├── qmanager_update.log    # OTA update worker log (root-owned)
├── qmanager_install.log   # Installer log (step progress for UI streaming)
├── qmanager_sessions/
└── qmanager.log
```

---

## Line Ending Enforcement

**Critical:** All shell scripts must have LF line endings. CRLF breaks scripts silently on OpenWRT.

### Prevention

The `.gitattributes` file enforces LF:
```
scripts/**/*.sh text eol=lf
scripts/etc/init.d/* text eol=lf
scripts/usr/bin/* text eol=lf
```

### Checking

```bash
# Check for CRLF in scripts
file scripts/usr/bin/* | grep CRLF
file scripts/etc/init.d/* | grep CRLF
find scripts -name "*.sh" -exec file {} \; | grep CRLF
```

### Fixing

```bash
# Convert CRLF to LF
sed -i 's/\r$//' scripts/usr/bin/*
sed -i 's/\r$//' scripts/etc/init.d/*
find scripts -name "*.sh" -exec sed -i 's/\r$//' {} \;
```

---

## iCloud Conflict Copies

**Critical:** the maintainer's checkout lives under `~/Desktop`, which iCloud Drive
syncs. That placement is a settled decision — do not propose moving the repo.

When iCloud cannot decide between two versions of a file it keeps both, naming
the loser `<name> 2.<ext>`. The copy is a stale snapshot, but nothing about it
looks stale to a tool that globs the tree, so it gets read as if it were source.
This has cost real work three times: ESLint re-reported all 16 already-fixed
`react-hooks/set-state-in-effect` errors out of pre-refactor copies under
`components/` and `hooks/`; a `.next/types/routes.d 2.ts` failed
`bunx tsc --noEmit` with `TS2300: Duplicate identifier 'LayoutProps'`; and a
duplicated ref turned up inside `.git/refs/heads/`.

**Rule of thumb:** when a tool result contradicts the committed file, suspect a
conflict copy before suspecting the tool.

### Prevention

- `bash scripts/dev/icloud-exclude.sh --apply` relocates the regenerable
  artefacts (`node_modules`, `.next`, `.codegraph`, `qmanager-build`) to
  `.artifacts.nosync/` and symlinks them back. iCloud skips any path component
  ending in `.nosync`, which drops the bulk of the sync churn — `node_modules`
  alone was 71,029 of the 75,412 paths iCloud was tracking here — and a
  backlogged sync engine is what produces conflict copies in the first place.
  It **deletes and lets each artefact be rebuilt** at the new path rather than
  `mv`-ing it there, which is why the deletion needs `--yes-delete` and why the
  allowlist admits only names with a known rebuild command. Moving already-
  indexed content is the operation that cost 212 MB here: iCloud had those
  paths in its index, the move looked like a mass delete, and it propagated the
  delete. Regenerated content is born invisible instead. `--status` reports
  without touching anything, `--revert` undoes it.
- `tsconfig.json` excludes `**/* ?*.*`. This guard matters most for
  `.next/types/**`, which `include` pulls in even though git ignores it: a copy
  landing there is invisible to `git status` and surfaces only as a
  duplicate-identifier error that reads like a genuine type bug. It cannot reuse
  the ESLint spelling because tsc's glob grammar is only `*`, `?` and `**` —
  brackets are literal there, so a `[0-9]` class matches nothing.
- `eslint.config.mjs` ignores `**/* [0-9].[A-Za-z]*` and its two- and
  three-digit siblings — a mirror of the detector's regex, not a superset. The
  two must agree in both directions: a shape ESLint hides *and* the detector
  does not match is seen by nothing, while a shape ESLint lets through is read
  as source. Finder's worded duplicates (`use-i18n copy.ts`) and
  `use-i18n 2 copy.ts` match neither side, so they lint — deliberately, since
  noisy beats unseen.

### Checking

```bash
bash scripts/dev/conflict-copies.sh   # graded report with a per-file verdict
bash scripts/test/run-all.sh          # same scan, folded into the pre-build gate
```

The report is graded by where the copy landed, because the damage differs:
CRITICAL inside `.git/` (a duplicated ref or index can corrupt the repository),
HIGH in build output (regenerable, but tools re-read build output as input),
WARN in the source tree, and a bare count for `node_modules`.

### Fixing

```bash
bash scripts/dev/conflict-copies.sh --clean         # dry run — deletes nothing
bash scripts/dev/conflict-copies.sh --clean --yes   # delete identical/stale copies
```

The tool never deletes anything under `.git/` — it reports and stops there, since
that is the case where a wrong guess costs commits. Copies that differ from the
original *and* are newer are held back too unless `--include-newer` is passed:
one of those can be the only copy of a change.

`node_modules` is only ever counted, never listed, because the answer there is
never "which of these two is the good one" — it is a reinstall. **Which
reinstall depends on whether the exclusion is applied**, so check first:

```bash
bash scripts/dev/icloud-exclude.sh --status         # is node_modules "excluded" or "SYNCED"?
```

If it reports `SYNCED` (no exclusion yet — a fresh clone, or after `--revert`),
`node_modules` is a real directory and the obvious command is right:

```bash
rm -rf node_modules && bun install
```

If it reports `excluded`, `node_modules` is a **symlink** into
`.artifacts.nosync/`, and that same command is actively harmful: `rm -rf` on a
symlink removes the link and not its target, orphaning ~705 MB, and `bun install`
then materialises a real `node_modules` back in the synced tree — re-exposing the
94% of the problem the exclusion existed to remove, and leaving a later `--apply`
refusing to choose between the real directory and the orphaned target. Delete the
target instead and let the script restore the layout:

```bash
rm -rf node_modules .artifacts.nosync/node_modules   # the link AND its target
bash scripts/dev/icloud-exclude.sh --apply           # relinks, target pre-created empty
bun install                                          # bun 1.3.14 installs through the symlink
```

Both, not just the target. `--apply` treats a link whose target has vanished as
a failure and stops — deliberately, because that is the state iCloud leaves
behind when it eats a target, and reporting `OK` there is how the damage stays
invisible. Removing the link too puts the artefact in the `absent` state, which
is the one `--apply` is allowed to fix on its own.

The same shape applies to any managed artefact.

Conflict copies in the source tree are deliberately **not** git-ignored, so
`git status` keeps surfacing those until they are dealt with. It is a partial
net, not a second opinion: `git status` can only see copies on paths git tracks.
Anything landing under ignored build output — `.next/types/`, `.codegraph/`,
`.artifacts.nosync/`, `node_modules/` — is invisible to it, which is exactly
where the two worst incidents happened (`routes.d 2.ts` breaking `tsc`, and two
`codegraph 2.db-*` sidecars sitting unreported). `.env 2` is swallowed the same
way by the existing `.env*` rule. The detector is what covers all of them, which
is why it scans rather than defers to `git status`.

---

## Troubleshooting

### CGI Returns Empty Response

1. **Check line endings** — CRLF is the #1 cause of silent CGI failures
2. **Check permissions** — CGI scripts need `chmod +x`
3. **Check syntax** — Run `sh -n /www/cgi-bin/quecmanager/<script>.sh`
4. **Check logs** — `cat /tmp/qmanager.log | tail -50`

### Poller Not Producing Data

```bash
# Check if poller is running
ps | grep qmanager_poller

# Check if modem serial port is accessible
ls -la /dev/smd7  # or /dev/ttyUSB2

# Test AT command
qcmd 'AT+QENG="servingcell"'

# Check poller logs
grep "poller" /tmp/qmanager.log
```

### Authentication Issues

```bash
# Reset password (run on device)
/usr/bin/qmanager_reset_password

# Check session directory
ls /tmp/qmanager_sessions/

# Check shadow file
ls -la /etc/qmanager/shadow
```

### Service Won't Start

```bash
# Check init.d script
/etc/init.d/qmanager start
cat /tmp/qmanager.log

# Verify dependencies
which jq        # Required
which qcmd      # Required
which msmtp     # Optional (email only)
which ethtool   # Optional (ethernet only)
```

---

## Updating

### OTA Update (v0.1.5+)

From v0.1.5 onward, updates are fully self-contained via the web UI: **System Settings → Software Update**. The UI checks for new releases, downloads and verifies the tarball, runs the installer, and reboots — no SSH required.

**Update worker flow:**

1. The `update.sh` CGI invokes `/usr/bin/qmanager_update` via `sudo -n` (sudoers rule: `www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_update`)
2. The worker downloads, verifies (`tar tzf` + grep for `install_rm520n.sh`), and runs the installer
3. The CGI's spawn-line redirects to `/dev/null 2>&1` — the worker creates `/tmp/qmanager_update.log` as root, avoiding `fs.protected_regular=1` blocking root from truncating a www-data-owned log file
4. The installer writes `=== Step N/M: <label> ===` lines to `/tmp/qmanager_install.log`; the worker tails this file and mirrors progress into the status JSON for UI step-streaming
5. On completion, `finalize_version()` moves `/etc/qmanager/VERSION.pending` → `/etc/qmanager/VERSION`

**OTA status values:** `idle` → `checking` → `update_available` → `downloading` → `verifying` → `ready` → `installing` → `rebooting` / `error`

**Rollback:** If `/etc/qmanager/VERSION.pending` exists after reboot, the previous install did not finalize. The update CGI GET response includes `previous_install_failed: true` and `pending_version: "<version>"` when this file is present, allowing the UI to offer rollback.

> **Bootstrap caveat:** The v0.1.4 → v0.1.5 upgrade requires ADB or SSH because v0.1.4's CGI has no sudo and v0.1.4's sudoers has no `qmanager_update` rule. From v0.1.5 onward, OTA works via the UI.

### Manual Update (SSH)

```bash
# Transfer updated tarball
scp -O qmanager-*.tar.gz root@192.168.225.1:/tmp/

# Extract and run installer (handles stop/deploy/start/cleanup)
ssh root@192.168.225.1
cd /tmp && tar xzf qmanager-*.tar.gz
cd qmanager_install && bash install_rm520n.sh
```

The installer is idempotent — re-running updates rather than duplicates. It handles:
- Stopping existing services (filesystem-driven scan of `/lib/systemd/system/qmanager-*.service`, batched into a single `systemctl stop` call so systemd shuts them down in parallel; long-running daemons set `TimeoutStopSec=10` so a wedged service caps the wait at 10s instead of systemd's 90s default)
- Removing orphaned daemons/units/libs not present in the current source tree (`cleanup_legacy_scripts`)
- Removing conflicting packages (`socat`, `socat-at-bridge`) even with `--skip-packages`
- Re-enabling services (UCI-gated services only re-enabled if their `multi-user.target.wants/` symlink existed pre-upgrade)
- AT stack health check (3× `qcmd 'ATI'` retries, warn-only) and poller health check after completion

---

## Uninstalling

```bash
# Interactive (prompts for confirmation)
bash /tmp/qmanager_install/uninstall_rm520n.sh

# Skip confirmation prompt (non-interactive / scripted)
bash /tmp/qmanager_install/uninstall_rm520n.sh --force

# Skip automatic reboot after uninstall
bash /tmp/qmanager_install/uninstall_rm520n.sh --no-reboot

# Also remove config/profiles/passwords and Tailscale
bash /tmp/qmanager_install/uninstall_rm520n.sh --purge
```

The uninstaller:
- Scans `/lib/systemd/system/qmanager-*.service` and `/usr/bin/qmanager_*` at runtime — no hardcoded service list
- Stops and disables all discovered QManager services
- Removes frontend, CGI scripts, daemons, shared libraries, systemd units, sudoers rules, and udev rules
- Removes the web console (`/usrdata/qmanager/console/`) by default
- With `--purge`: also tears down Tailscale (stops `tailscaled`, removes unit, removes `/usrdata/tailscale/` and symlinks)
- Cleans up `/etc/qmanager/VERSION.pending` and `/etc/qmanager/updates/previous_version`
- **Entware (`/opt/`) is always preserved** even with `--purge` — remove it manually if needed

---

## Troubleshooting

### Installer / Update Failures

**`VERSION.pending` exists after reboot:**
The installer writes `/etc/qmanager/VERSION.pending` early and only moves it to `/etc/qmanager/VERSION` at the very end. If the modem rebooted mid-install, `VERSION.pending` survives. The update CGI GET response will include `"previous_install_failed": true` and `"pending_version": "<version>"`. Use the UI rollback option or re-run the installer manually.

**`fs.protected_regular=1` — log truncation failures:**
The kernel's sticky directory protection (`fs.protected_regular=1`) blocks a process from truncating a file in `/tmp` that was created by a different user. The OTA worker (`qmanager_update`) works around this by doing `rm -f $LOG_FILE` before creating a fresh log — never truncating an existing file. CGI scripts that need to write `/tmp` files should pre-create them with the correct ownership in `qmanager_setup` (boot one-shot).

**Socat conflict blocks AT transport:**
If `socat` or `socat-at-bridge` services are running, `atcli_smd11` cannot open `/dev/smd11`. The installer actively removes these packages (`opkg remove socat socat-at-bridge`) with retry through `--force-removal-of-dependent-packages`. This runs even with `--skip-packages`.

### CGI Returns Empty Response

1. Check line endings — CRLF causes silent CGI failures (installer strips `\r` automatically; check manually with `file /usr/lib/qmanager/*.sh`)
2. Check permissions — CGI scripts need `chmod +x`
3. Check PATH — lighttpd CGI has a minimal PATH; `cgi_base.sh` exports the full PATH including `/opt/bin`
4. Check logs — `tail -50 /tmp/qmanager.log`

### Poller Not Producing Data

```bash
# Check if poller is running
systemctl status qmanager-poller

# Test AT command directly
qcmd 'ATI'

# Check /dev/smd11 permissions (should be crw-rw---- root:dialout)
ls -la /dev/smd11

# Check poller logs
grep "poller" /tmp/qmanager.log
```

### Service Won't Start

```bash
# Check systemd status and journal
systemctl status qmanager-poller
journalctl -u qmanager-poller --no-pager -n 50

# Verify dependencies
command -v qcmd
command -v jq
ls /usr/lib/qmanager/cgi_base.sh
```

### Authentication Issues

```bash
# Reset password (run on device as root)
/usr/bin/qmanager_reset_password

# Check session directory
ls /tmp/qmanager_sessions/
```

---

## Sudoers Rules

QManager's sudoers file (`/etc/sudoers.d/qmanager`) grants `www-data` the following:

```
# OTA update worker
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_update

# Service control — exact unit + verb, never `systemctl start *`
www-data ALL=(root) NOPASSWD: /bin/systemctl restart qmanager-watchcat
www-data ALL=(root) NOPASSWD: /bin/systemctl stop qmanager-watchcat
www-data ALL=(root) NOPASSWD: /bin/systemctl start qmanager-tower-failover
www-data ALL=(root) NOPASSWD: /bin/systemctl stop qmanager-tower-failover

# Boot persistence (symlink-based — systemctl enable doesn't work).
# Both units named in full, source and destination: a '*' here would have
# matched across argument boundaries and made this `rm -f <anything>`.
www-data ALL=(root) NOPASSWD: /bin/ln -sf /lib/systemd/system/qmanager-watchcat.service /lib/systemd/system/multi-user.target.wants/qmanager-watchcat.service
www-data ALL=(root) NOPASSWD: /bin/ln -sf /lib/systemd/system/qmanager-tower-failover.service /lib/systemd/system/multi-user.target.wants/qmanager-tower-failover.service
www-data ALL=(root) NOPASSWD: /bin/rm -f /lib/systemd/system/multi-user.target.wants/qmanager-watchcat.service
www-data ALL=(root) NOPASSWD: /bin/rm -f /lib/systemd/system/multi-user.target.wants/qmanager-tower-failover.service

# Firewall, reboot, SSH password
www-data ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/iptables-restore, /usr/sbin/ip6tables, /usr/sbin/ip6tables-restore
www-data ALL=(root) NOPASSWD: /sbin/reboot
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_set_ssh_password

# Scheduled-task timer arming (replaced a wildcard-equivalent /usr/bin/crontab grant)
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_scheduled_reboot_arm
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_tower_schedule_arm
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_auto_update_arm

# Timezone (repoints /etc/localtime — /etc is root:root 0755)
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_set_timezone

# System Health Check runner, Ethernet link speed limit
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_health_check
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_ethernet_apply

# Custom DNS (dnsmasq config atomic swap + reload)
www-data ALL=(root) NOPASSWD: /bin/mv /etc/data/qmanager/dnsmasq.conf.new /etc/data/dnsmasq.conf
www-data ALL=(root) NOPASSWD: /bin/chown radio\:radio /etc/data/dnsmasq.conf
www-data ALL=(root) NOPASSWD: /usr/bin/killall -HUP dnsmasq
```

> **Note:** The above is abridged. `scripts/etc/sudoers.d/qmanager` is the source of truth — see [BACKEND.md §7](BACKEND.md#7-sudoers-rules) for the full file with per-rule annotations.

> **Note:** All sudoers commands use full absolute paths — Entware's sudo has a restricted `secure_path` that excludes `/sbin/` and `/usr/bin/`. Bare command names will fail silently from CGI context.

> ⚠️ WARNING: Argument specs are exact. **The file contains no `*` at all**, and that is enforced. sudo matches a command's arguments as one space-joined string, so a `*` does not stay inside the argument it was written in — it matches across word boundaries. `/bin/systemctl start *` was a grant over *every unit on the device*; worse, `/bin/rm -f …/qmanager*.service` was a grant to delete *any list of files* as root, because the `*` could absorb extra operands and the joined string still ended in `.service`. Service control and boot persistence are therefore enumerated one command at a time — eight grants, both units named in full. If you add a rule, enumerate it too, and mind the spacing (single spaces; a double space passes `visudo` and then never matches). `scripts/test/run-all.sh` §6 fails the build on any `*` in any grant and asserts all eight by exact string. See [BACKEND.md §7.1](BACKEND.md#71-wildcards-in-argument-specs).

### Install-time validation

The installer validates the sudoers file **before** it is allowed to replace the one already on the device. `install_backend()` copies the source to `/tmp/qmanager-sudoers-candidate.$$` with CRLF stripped — byte-for-byte what `install_file` would go on to write — and runs `visudo -cf` on that staged copy:

| Outcome | Installer behaviour |
|---------|--------------------|
| `visudo` present, file parses | Installs, then `sync` |
| `visudo` present, file fails to parse | Prints visudo's output, `die`s — **the existing sudoers file is left untouched** |
| `visudo` not found | Warns, installs unvalidated, then `sync` |

The reason this gate exists at all: sudo refuses **every** request when any file it reads fails to parse, and `sudoers.d` is read in full. Because `www-data` is the only sudo user on this device, one stray character disables every privileged action the web UI has — service control, iptables, reboot, DNS, and `qmanager_update` with them, so the device cannot even pull down the fix. Recovery is a manual root SSH session, which is precisely what OTA exists to avoid.

The missing-`visudo` case warns rather than dies deliberately. A device can carry sudo without visudo, and refusing to install there would leave the CGI with no privileges at all — a certain failure in place of a risk. The backstop is upstream: the same `visudo -cf` check runs in `scripts/test/run-all.sh` and in the release workflow, so a published tarball should never arrive carrying a grammar error. A hand-built tarball can still bypass both.

The `sync` after install matters for the same reason it does for systemd units: the OTA path reboots without a sync of its own, and a sudoers file that exists in page cache but not on flash is a sudoers file that is missing after the reboot.

See [BACKEND.md §7.2](BACKEND.md#72-one-bad-drop-in-disables-every-rule) for the incident this gate was built from.

---

## RM520N-GL Platform Summary

QManager runs directly on the modem's internal Linux OS — no external OpenWRT router required. Key platform facts:

| Concern | Value |
|---------|-------|
| Platform | Quectel RM520N-GL (SDXLEMUR, ARMv7l, kernel 5.4.180) |
| Init system | systemd (units in `/lib/systemd/system/`) |
| Root filesystem | Read-only by default (`mount -o remount,rw /` when needed) |
| Persistent storage | `/usrdata/` partition |
| Web server | lighttpd (Entware) |
| AT transport | `atcli_smd11` on `/dev/smd11` directly (no socat bridge) |
| Config store | Files in `/etc/qmanager/` (rootfs, remounted rw) |
| Firewall | iptables direct |
| `systemctl enable` | Does NOT work — use direct symlinks into `multi-user.target.wants/` |

> **See also:** [RM520N-GL Architecture Report](rm520n-gl-architecture.md) for the complete platform analysis.
