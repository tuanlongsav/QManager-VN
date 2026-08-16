# QManager Independence (RM520N-GL)

> QManager installs standalone with no SimpleAdmin/RGMII-toolkit dependency — it owns its directory, bootstraps Entware, configures lighttpd, and manages all services itself.

---

## Directory layout & bootstrapping

- **Own directory**: `/usrdata/qmanager/` — contains web root, lighttpd config, and TLS certs.
- **Bootstraps Entware** from `bin.entware.net` if not present. The bootstrap process creates the `opt.mount`, `start-opt-mount.service`, and `rc.unslung.service` systemd units.
- **Installs lighttpd + modules** from Entware: `lighttpd-mod-cgi`, `lighttpd-mod-openssl`, `lighttpd-mod-redirect`, and (optionally) `lighttpd-mod-deflate`.
- **lighttpd module version sync**: The installer runs `opkg upgrade` on lighttpd and all its modules together when they are already installed — this prevents `plugin-version doesn't match` errors that occur if modules are at different versions during upgrades.
- **Gzip compression (`mod_deflate`) — auto-enabling & brick-safe**: `lighttpd.conf` never names `mod_deflate` directly — it ends with `include_shell "cat /usrdata/qmanager/lighttpd-deflate.conf 2>/dev/null || true"`, so the gzip snippet is loaded only if that file exists. The deflate block in **`install_backend()` runs on EVERY install, OTA included** (it's gated on `DO_BACKEND=1`, which OTA keeps set — only `DO_PACKAGES` is cleared by `--skip-packages`). The block:
  1. If `lighttpd-mod-deflate` isn't installed, runs `opkg install --nodeps lighttpd-mod-deflate`. **`--nodeps` is load-bearing**: it installs *only* the module and never lets opkg upgrade `lighttpd` as a dependency — which would version-mismatch the other modules (cgi/openssl/redirect) and brick on reboot. A version-matched install for `lighttpd` itself happens only on full installs via the `opkg upgrade lighttpd lighttpd-mod-* …` sync.
  2. Writes the deflate snippet (`server.modules += ("mod_deflate")` + `deflate.*`).
  3. Validates with **`lighttpd -tt -f $LIGHTTPD_CONF`** (preflight that actually loads modules). On success → keep, gzip on. On failure (module missing, plugin-version mismatch, anything) → `rm -f` the snippet → server starts on the matched base config. The revert is clean because `--nodeps` guarantees `lighttpd` and the other modules were never touched.

  Net effect: once a device is online, gzip turns on by itself and **stays on across future OTA updates** (the Entware module persists in `/opt`, the snippet in `/usrdata`). Offline / feed-down / rollback paths simply leave it off — never a config that fails to load. Compresses `text/html`, `text/css`, `application/javascript`, `application/json`, `image/svg+xml`, `text/plain` above `min-compress-size` 256 B.
- **Creates `www-data:dialout`** user and group if missing. The `dialout` group membership grants `www-data` access to `/dev/smd11`.
- **Installer stops socat-smd11** services if they are running — `atcli_smd11` requires exclusive access to `/dev/smd11` and cannot co-exist with a socat bridge holding it open.
- **Windows line ending safety**: The installer strips `\r` from all deployed shell scripts, systemd units, and sudoers rules using `sed -i 's/\r$//'`. This prevents BusyBox and sudoers parse failures that occur when tarballs are built on Windows.

---

## Device permissions (/dev/smd11 & udev)

`/dev/smd11` defaults to `crw------- root:root` — completely inaccessible to `www-data`. QManager uses two complementary paths to fix this, both of which are idempotent:

### Primary: udev rule

- Rule file: `/etc/udev/rules.d/99-qmanager-smd11.rules`
- Fires on every kernel `add` event for the `smd11` device.
- Executes `/usr/lib/qmanager/qmanager_smd11_udev.sh`, which runs `chmod 660` and `chown root:dialout` on `/dev/smd11`.
- The rule intentionally **omits `SUBSYSTEM==`** — the subsystem on RM520N-GL is `glinkpkt` (sysfs at `/sys/class/glinkpkt/smd11`), but omitting the subsystem filter makes the rule work across both this platform and others (e.g. RG502Q/RM502Q). `KERNEL=="smd11"` is already specific enough.
- Source path for the udev helper script is `scripts/etc/udev/scripts/qmanager_smd11_udev.sh` — deliberately placed **outside** `usr/lib/qmanager/` to prevent `install_backend`'s glob copy from resetting its file mode to 644.

### Fallback: boot-time setup

- `qmanager_setup` runs the same `chown`/`chmod` at boot, in case udev has not loaded the rule yet (e.g. on fresh install before a udev reload).
- This covers PRAIRE-derived platforms (RG502Q/RM502Q) where the modem re-creates `/dev/smd11` **after** `qmanager-setup.service` completes, leaving the one-shot's `[ -e ]` guard false when udev fires later.

---

## CGI environment & auth

- **CGI PATH problem**: lighttpd starts CGI scripts with a stripped-down `PATH` that excludes `/opt/bin` — so Entware tools like `jq` are invisible to CGI scripts by default.
  - Fix 1: `cgi_base.sh` exports the full PATH including `/opt/bin`.
  - Fix 2: The installer symlinks `jq` to `/usr/bin/` so it is always found regardless of PATH.
- **Cookie-based session auth** is used at the CGI layer. There is no HTTP Basic Auth and no `.htpasswd` file.
- **AT transport in CGI**: `atcli_smd11` accesses `/dev/smd11` directly — no socat-at-bridge is needed.

---

## Service persistence (systemd symlinks)

- **`systemctl enable` does not work** on this platform — it fails silently or errors depending on systemd version.
- All boot persistence is implemented via **direct symlinks** into `/lib/systemd/system/multi-user.target.wants/`. Note that `/etc/systemd/system/multi-user.target.wants/` also exists on the device (18 stock-firmware entries on the RM520N-GLAA probed) and is a genuinely different directory — `/lib` is a real directory, not a symlink to it. A boot symlink placed under `/etc` does not survive a reboot. Timers are separate again: `schedule_timer.sh` uses `/lib/systemd/system/timers.target.wants/`.
- This is managed through `svc_enable` and `svc_disable` helpers in `platform.sh` — use those functions everywhere, never call `systemctl enable/disable` directly.
- Both helpers **verify the post-condition** rather than trusting the write: after the `ln`/`rm` they test the boot symlink with `[ -h … ]` and return that. Previously they returned the status of a sudo call whose stderr was discarded, so a read-only rootfs or a device with an older sudoers file failed silently and the user found out at the next boot. The result is direction-aware — `svc_enable` succeeds when the link is present, `svc_disable` when it is gone — so "true" always means *the boot state matches what was asked*, and callers can compare it against a constant rather than against the requested direction. Every call site now reads it (see the boot-persistence bullet under Sudoers grants below).
- From `www-data`, both helpers work on **`qmanager-watchcat` and `qmanager-tower-failover` only**. Adding a UI-toggleable unit means adding a matching `ln -sf` and `rm -f` grant (source *and* destination path in full) plus the two entries in the `run-all.sh` §6 assertion list.

---

## Sudoers grants & validation

- **Grants are exact-argument, never wildcard — the file now contains no `*` at all.** The reason is stronger than tidiness: sudo joins the command's arguments into **one space-separated string** and matches the pattern against that whole string (`sudoers(5)`, *"Wildcards in command arguments"*), so a `*` matches across word boundaries instead of staying inside the argument it was written in.

- **Service control** is four literal grants. The old `/bin/systemctl start *` (and its `stop`/`restart`/`is-active` siblings) let `www-data` drive *any* unit on the device as root:

  | Unit | Verbs granted | Consumed by |
  |------|---------------|-------------|
  | `qmanager-watchcat` | `restart`, `stop` | `monitoring/watchdog.sh` |
  | `qmanager-tower-failover` | `start`, `stop` | `tower_lock_mgr.sh`, sourced by the `tower/` and `frequency/` CGI handlers |

  The verbs are asymmetric on purpose — watchcat is never started on its own, tower-failover is never restarted — because nothing calls those combinations. Every unit QManager drives from a `www-data` context is a literal string in the source, so an explicit list loses nothing.

- **Boot persistence** is four more literal grants, and these were the worse hole of the two. The `systemctl` wildcards reached running state only; `/bin/rm -f /lib/systemd/system/multi-user.target.wants/qmanager*.service` reached **the filesystem**. Because the match is against the joined argument string, `sudo /bin/rm -f …/qmanagerX /tmp/victim /x.service` was permitted — the `*` absorbs `X /tmp/victim /x`, the string still ends in `.service`, and `rm` deletes every operand. Arbitrary file removal as root, needing no path traversal, no pre-existing directory and no injection bug elsewhere, because any code running as `www-data` can call `sudo` with those arguments directly.

  Verified on the live RM520N-GLAA before and after the patch: a root-owned mode-0600 file in `/tmp` that `www-data` could not remove directly was deleted through the granted `rm`; afterwards the identical command returns `sudo: a password is required`, the file survives, disabling `qmanager-firewall`'s boot symlink is refused, and the legitimate enable/disable of `qmanager-watchcat` still works.

  | Command | Unit |
  |---------|------|
  | `/bin/ln -sf` (source + destination in full) | `qmanager-watchcat`, `qmanager-tower-failover` |
  | `/bin/rm -f` (destination in full) | `qmanager-watchcat`, `qmanager-tower-failover` |

- **Spacing is part of the grant.** sudo compares the joined argument string, so a double space in a rule parses fine under `visudo` and then silently never matches. The four boot-persistence grants were checked against what `platform.sh` actually emits — source it, substitute `$_SUDO` with `echo`, call `svc_enable`/`svc_disable` — rather than by reading the code, because `_svc_unit()` rewrites the argument (`qmanager_watchcat` → `qmanager-watchcat.service`) and the call site does not show you the final string.

- **`svc_is_running` has no grant and needs none.** `systemctl is-active` is a read-only query. The old wildcard covered it, but the function had no caller anywhere in the tree, so the grant was dropped rather than narrowed and `platform.sh` now calls it without `$_SUDO`. Leaving the sudo prefix behind would have been worse than useless: sudo refuses the unmatched command, the function's `2>&1` swallows the reason, and a running service reads as stopped.

- **A missing grant fails silently — except for boot persistence, which now reports.** `platform.sh` discards sudo's stderr and `monitoring/watchdog.sh` backgrounds its restart without checking the exit status, so for service *control* a daemon that quietly never restarts is still the only symptom. Boot persistence is the exception: the helpers return a verified result and **every** call site now reads it. `watchdog.sh:360,366` surfaces `boot_enabled: false` for `qmanager-watchcat`; the tower handlers surface `failover_boot_enabled: false` plus a `failover_boot_error` sentence for `qmanager-tower-failover`, from `tower/lock.sh:144,199,277,328` (enable) and `:206,335` (disable), and `tower/settings.sh:132`/`:151`. The unattended `qmanager_tower_schedule:136` has no response to attach it to and logs a `qlog_warn` instead. **This gap was open and is now closed** — see [BACKEND.md §7.3](../BACKEND.md#73-closed-a-denied-boot-persistence-grant-now-surfaces-at-every-call-site) for what closed it.

  Two details are worth carrying over, because both were failure modes on the way to the fix. The result is read from **globals** (`TOWER_FAILOVER_BOOT_ENABLED`, `TOWER_FAILOVER_WATCHER_ALIVE`), so the library function must be called directly and never as `x=$(tower_spawn_failover_watcher)` — command substitution runs it in a subshell and the answer dies there. And the shell half was not the blocker: `watchdog.sh` had been emitting `boot_enabled` correctly for a long time into a hook that returned a bare boolean and discarded the body, which from the user's chair is indistinguishable from a backend that lies. `scripts/test/failover-boot-contract.sh` now asserts the whole chain, greps *and* executes.

- **`scripts/test/run-all.sh` §6 is what stands in for the silence.** It rejects any `*` anywhere in the file — a blanket rule, not a match on known-bad shapes — and asserts all **eight** service-control and boot-persistence grants with `grep -F` on exact single-spaced strings, which pins the spacing too. `visudo` cannot catch either failure: a wildcard grant and a double-spaced grant are both perfectly valid sudoers. An upstream merge reintroducing a wildcard, or dropping a grant, is otherwise invisible.

- **One malformed drop-in disables every rule.** sudo refuses *every* request when any file it reads fails to parse, and `sudoers.d` is read in full. `www-data` being the only sudo user here means that is a total outage of the web UI's privileged surface — service control, iptables, reboot, DNS, and `qmanager_update` — leaving the device unable to fetch its own fix. An unescaped `:` in the Custom DNS `chown` rule caused exactly this once; see [custom-dns.md](custom-dns.md).

- **Three `visudo -cf` gates now stand in front of that:** `scripts/test/run-all.sh` §6 on the dev machine (also the first step of `bun run package`), the "Pre-build gate" step in `.github/workflows/release.yml`, and `install_backend()` on-device. All three check a CRLF-stripped copy, because that is what actually gets written.

- **The installer validates a staged candidate, not the live file.** It writes `/tmp/qmanager-sudoers-candidate.$$` (deliberately outside `SUDOERS_DIR`, so a leftover can never be read as a rule), validates that, and `die`s without touching the installed file if it fails. If `visudo` is absent it warns and installs anyway — a device can have sudo without visudo, and refusing would leave the CGI with no privileges at all, trading a risk for a certainty. It `sync`s after install, since the OTA path reboots without one.

---

## SSH password management

- Helper: `qmanager_set_ssh_password`
- Reads the new password from stdin and updates `/etc/shadow` using `openssl passwd -1`.
- Whitelisted in sudoers for `www-data` so the CGI layer can invoke it without a password.
- Called automatically during onboarding to sync the web UI password to the root account.
- Also callable independently from **System Settings > SSH Password** card.

---

## Networking & firewall

- **Port firewall**: `qmanager-firewall.service` restricts the web UI (ports 80 and 443) to trusted interfaces: `lo`, `bridge0`, `eth0`, and `tailscale0` (if installed). Cellular-side access is blocked.
- This service replaces SimpleAdmin's `simplefirewall` — it is QManager-owned and installed by default.
- SSH (port 22) is intentionally left open on all interfaces for emergency access.

---

## Tailscale VPN

Tailscale is installed on-demand via the `qmanager_tailscale_mgr` helper. The install flow is aligned with the rgmii-toolkit convention (validated 2026-04-10). There are many non-obvious gotchas — read this section fully before touching any Tailscale code.

### Version & download

- Hardcoded version: `1.92.5`, arch: `arm`. No CDN directory scraping, no version detection, no timeout gymnastics.
- Download lands in `/usrdata/` (persistent partition) via bare `curl -O`.
- **Do NOT add `-fSL` or timeouts to the curl command** — both flags contributed to the original installation hang.
- Binaries live at `/usrdata/tailscale/`.

### Two-layer execution pattern

The helper uses a deliberate two-layer design to survive CGI disconnects:

1. An **outer wrapper** stages an inner install script and a temporary systemd oneshot unit (`qmanager_tailscale_install.service`), fires the unit, and returns immediately.
2. The **inner script** runs detached under systemd, independent of the CGI caller's lifetime.

The helper calls `sleep 2` after `daemon-reload` and before `start` to give systemd time to register the new unit.

### Symlinks (both are required)

CLI accessibility requires **two symlinks**:
- `/usrdata/root/bin/tailscale` — rgmii-toolkit convention
- `/usr/bin/tailscale` — QManager's default root shell uses `HOME=/home/root` and does not have `/usrdata/root/bin` in its PATH

### Systemd units

Units come from `/usr/lib/qmanager/tailscaled.service` and `tailscaled.defaults` (bundled by the installer). The helper includes an inline fallback for these files if they are missing.

### tailscale up flag restriction

`tailscale up` must **NOT** use the `--json` flag. Its output is fully buffered on RM520N-GL (there is no `stdbuf` available) and never flushes to a file. Use interactive mode and grep for the auth URL instead.

### tailscaled state directory reset

`tailscaled` resets its state directory permissions to `700` on every start, making the binary inside inaccessible. To work around this:
- CGI `is_installed()` checks for the **systemd unit file** (world-readable) plus directory existence — not binary executability.
- `ExecStartPost=/bin/chmod 755` in the service unit restores access after each start.
- `qmanager_setup` also restores access at boot as belt-and-suspenders.

### Rootfs flush before remounting read-only

**All rootfs writes must be flushed before remounting read-only.** `qmanager_tailscale_mgr` calls `sync` before every `mount -o remount,ro /` to prevent unit file or symlink loss on reboot.

### Firewall restart

The helper restarts `qmanager-firewall.service` after install so `tailscale0` is recognized as a trusted interface.

### PID tracking across install phases

PID tracking spans the full install lifetime to keep the CGI's `pid_alive` concurrency check working:
1. The outer wrapper writes its own PID initially.
2. It overwrites with the systemd oneshot's `MainPID` after unit start.
3. The inner script overwrites with its own PID via an `EXIT` trap that also handles cleanup on completion.

### Progress & log files

- Progress file (CGI poll target): `/tmp/qmanager_tailscale_install.json`
- Log file: `/tmp/qmanager_tailscale_install.log`
- No dependency on SimpleAdmin.

---

## Web console

- Service: `qmanager-console.service`
- Runs **ttyd v1.7.7** (armhf) on `localhost:8080`.
- Reverse-proxied by lighttpd at `/console` with WebSocket upgrade support.
- Binary location: `/usrdata/qmanager/console/ttyd`
- Downloaded during install — non-fatal if the device is offline at install time.
- Theme matches QManager dark mode. Shell startup script sets PATH to include Entware tools.

---

## Email & SMS alerts

### Email alerts

- MTA: `msmtp`, installed from Entware at `/opt/bin/msmtp`.
- Config file: `/etc/qmanager/msmtprc`
- **Do NOT include a `logfile` directive** in msmtprc. If msmtp cannot write its log file, it returns `rc=1` even when the email was sent successfully. This causes false failures.
- The `email_alerts.sh` library detects msmtp at `/opt/bin/msmtp` explicitly — the poller's `PATH` does not include `/opt/bin`.
- Recovery emails wait **30 seconds** after connectivity returns before the first send attempt, to allow DNS and SMTP to stabilize.

### SMS alerts

- Transport: bundled `sms_tool` binary on `/dev/smd11` — no package install needed.
- `sms_alerts.sh` is sourced by the poller and reads poller globals directly: `conn_internet_available`, `modem_reachable`, `lte_state`, `nr_state`.
- **Registration guard is mandatory before every send.** The modem must be reachable AND (`lte_state="connected"` OR `nr_state="connected"`). Waiting for registration is unbounded at the state machine level, but `_sa_do_send` caps real send attempts at 3. Unregistered skips do not consume the retry budget — they are bounded separately by `_SA_MAX_SKIPS`.
- **Recovery path has two branches**:
  - If `downtime-start` status is `"sent"`: send a separate recovery SMS.
  - Otherwise: send a combined dedup message ("was down for X, now restored").
- **Recovery is silenced** when `status="none" && duration < threshold_secs` — sub-threshold blips never generate notifications.
- Phone numbers are stored with a leading `+` but stripped via `${_sa_recipient#+}` before passing to `sms_tool send` (matches the convention in `scripts/www/cgi-bin/quecmanager/cellular/sms.sh:265`).
- The shared lock `/tmp/qmanager_at.lock` serializes `sms_tool` calls with `qcmd` and the SMS Center CGI.
- **Test sends from the CGI** override `_sa_is_registered() { return 0; }` because CGI context lacks poller globals. The override must be placed **after** sourcing the library — the library has a `_SMS_ALERTS_LOADED` guard that prevents re-sourcing from clobbering the override.
- Config file: `/etc/qmanager/sms_alerts.json`
- NDJSON log: `/tmp/qmanager_sms_log.json` (capped at 100 entries)
- Reload flag: `/tmp/qmanager_sms_reload`
- Config writes are atomic: write to `.tmp`, then `mv` into place.

---

## OTA update pipeline

- **sudoers rule**: `www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_update` — allows the `update.sh` CGI to invoke the update worker as root via `sudo -n`. This rule is also why a sudoers parse error is self-trapping: lose sudo and you lose the one mechanism that could deliver the fix.
- **Release builds run the pre-build gate**: `.github/workflows/release.yml` runs `bash scripts/test/run-all.sh` before `next build` and `build.sh`. The workflow calls those two directly instead of `bun run package`, so the gate is an explicit step — a tag push is the one release path where nobody ran `bun run package` by hand first.
- **Log file ownership trick**: The CGI spawn-line redirects to `/dev/null 2>&1` (not `>>log`) so the worker (`qmanager_update`) creates `/tmp/qmanager_update.log` as root. This sidesteps `fs.protected_regular=1`, which would block root from truncating a log file previously created by `www-data`.
- **Atomic status writes**: The worker uses `write_status` (`.tmp` + `mv`) for all status updates.
- **Progress validation**: Progress is tracked by tailing `=== Step N/M: <label> ===` lines from the installer log.
- **Two-phase VERSION write**:
  - Installer writes `/etc/qmanager/VERSION.pending` early via `mark_version_pending()`.
  - `finalize_version()` moves it to `/etc/qmanager/VERSION` at the end.
  - A surviving `.pending` file after reboot indicates a failed install.
- **Filesystem-driven cleanup**: `cleanup_legacy_scripts()` and service enable/disable scan `/lib/systemd/system/qmanager-*.service` and `/usr/bin/qmanager_*` at runtime — not a hardcoded list.
- **`UCI_GATED_SERVICES`**: Controls which services are only re-enabled if their `multi-user.target.wants/` symlink existed before the upgrade.
- **Watchdog suppression**: The watchcat lock `/tmp/qmanager_watchcat.lock` is touched before stopping services and released via an `EXIT` trap, suppressing the watchdog during the install window.
- **Shared semver library**: `/usr/lib/qmanager/semver.sh` — sourced by both `update.sh` CGI and `qmanager_auto_update`.
- **Shared downloader library**: `/usr/lib/qmanager/downloader.sh` — sourced by `update.sh` CGI, `qmanager_update` (OTA worker), and `qmanager_auto_update` (cron). The two worker/cron scripts source it *guarded*, with an inline fallback so they still run if the lib is missing. See "HTTP transport & installer resilience" below — note the 3-copy maintenance hazard.
- **v0.1.4 → v0.1.5 requires ADB/SSH**: v0.1.4's CGI has no sudo and v0.1.4's sudoers has no `qmanager_update` rule, so OTA cannot self-update from v0.1.4. From v0.1.5 onward, OTA works via the UI.

---

## HTTP transport & installer resilience

- **`curl` is NOT a hard requirement.** The install and OTA pipeline auto-detect whichever HTTP downloader the device has — `curl` or `wget` — and use it. `curl` is preferred when both are present, but it is **never force-installed**.
- **Shared downloader library**: `/usr/lib/qmanager/downloader.sh` (POSIX sh) is the canonical implementation. Functions:
  - `qm_downloader()` — echoes `curl`, `wget`, or `""` (empty if neither). Non-network presence detection only; curl preferred.
  - `qm_https_ok()` — **advisory** HTTPS probe. Warn-only — it never gates a download.
  - `qm_download <url> <dest> [timeout]` — downloads; removes `<dest>` on failure.
  - `qm_download_headers <url> <body> <hdr> [timeout]` — downloads and captures response headers (used for GitHub rate-limit detection).
  - Sourcing the lib also exports an Entware-inclusive `PATH`.
- **Detection is non-network**: it checks tool presence and curl-preference only. The HTTPS probe (`qm_https_ok`) is advisory — the installer preflight *warns* if it cannot confirm `wget` does HTTPS, but **never aborts**. The real download is the authoritative test.
- **opkg bootstrap uses plain HTTP** (`bin.entware.net`), so even a TLS-less BusyBox `wget` can fetch it.
- **`qm_download_headers` portability**: GNU `wget` uses `-S` for full headers; BusyBox `wget` has no header-dump option, so the function falls back to harvesting the HTTP status line from stderr. Coarse rate-limit detection still works — only the precise reset time is lost.
- **ELF sanity check**: `install_rm520n.sh` verifies the downloaded opkg binary's ELF magic bytes, because `wget` (unlike `curl -f`) writes HTTP error pages to disk on a 4xx/5xx.
- **Maintenance hazard — three copies of the detection logic.** The canonical `downloader.sh` lib, plus inline copies in `qmanager-installer.sh` (bash) and `install_rm520n.sh` (sh). The inline copies exist because the install scripts run *before* the lib is on disk. **Bug fixes must be applied to all three.** The inline copies carry a comment pointing at the canonical lib.
- **`opkg update` failure is handled gracefully**: all Entware package installs are skipped with clear warnings, but the rest of the install (scripts, frontend, systemd units) continues normally.
- **The installer's shebang is not what runs it.** `install_rm520n.sh` carries `#!/bin/bash`, but `qmanager_update` launches it as `sh install_rm520n.sh` (`qmanager_update:128`), so on-device it is interpreted by BusyBox `ash`. Treat it as POSIX sh under `set -e` when editing.
  - This bites hardest on optional-tool fallbacks. Under `set -e`, POSIX exempts commands in an AND-OR list from triggering an exit *except the last one*, so `[ -n "$x" ] || x=$(command -v tool)` aborts the script when `tool` is absent — the exact opposite of the intended "shrug and continue". Put the `|| true` **inside** the command substitution. The `visudo` lookup in `install_backend()` shipped the wrong shape briefly and turned its warn-and-continue path into a hard install failure on every device without visudo.
  - Neither `bash -n` nor the portability validator catches this — it is a semantics bug, not a grammar one. Verify by running the construct under `dash` and `bash` and comparing `$?`. Full write-up in [BACKEND.md §14](../BACKEND.md#14-common-pitfalls).

---

## Supplemental assets

- **Speedtest CLI**: Downloaded from `install.speedtest.net` (package: `ookla-speedtest-1.2.0-linux-armhf.tgz`) during install. Placed at `/usrdata/root/bin/speedtest` with a `/bin/speedtest` symlink. CGI scripts discover it via `command -v speedtest`. Non-fatal if the download fails.
- **Cell scanner operator lookup**: `qmanager_cell_scanner` uses `operator-list.json` from `/usrdata/qmanager/www/cgi-bin/quecmanager/` for MCC/MNC → provider name resolution. The `jq` expression handles both `--slurpfile` (wrapped array) and `--argjson` (direct) operator input formats.
