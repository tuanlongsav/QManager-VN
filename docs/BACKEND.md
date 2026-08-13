# QManager Backend Reference

**Target platforms:** QManager targets the broader Quectel ARMv7-on-modem ecosystem, not a single SKU. Two SoC families are in scope:

- **SDXLEMUR (5G Modem-RF System)** — X62 silicon (RM520N-GL, the dev device for this branch) and X65 silicon (RM521F). The SoC codename `SDXLEMUR` reported by `/proc/cpuinfo` covers both; firmware is built from the SDX65 SDK regardless (`LE.UM.6.3.6.r1-02600-SDX65.0` on the dev device), which is why the OEM build string mentions `SDX65` even on the X62 part.
- **SDXPRAIRIE** — X55 silicon (RG502Q-EA, RM502Q-AE). Quirks unique to this family are called out where they differ (notably `/dev/smd11` re-creation timing, see [§8 udev Rules](#8-udev-rules)).

Probe data in this document was collected on an RM520N-GL (X62, SDXLEMUR, ARMv7l Cortex-A7 single-core, kernel `5.4.210-perf`, glibc 2.31, distro `qti-distro-nogplv3-perf` `LE.UM.6.3.6.r1-02600-SDX65.0`, 178 MB RAM, ~91 MB zram swap, `/tmp` 89 MB tmpfs). PRAIRIE devices report different OEM strings but share the same Quectel userspace conventions (BusyBox-1.31 toolchain, bash 3.2, systemd 244, Entware armv7sf-k3.2). Where this doc says "the platform", read it as "this Quectel-on-modem userspace stack" unless a SDK-specific note is called out.
This document is a developer reference for the shell-script backend. It covers every library, daemon, unit file, sudoers rule, udev rule, CGI endpoint, and file path that exists in this codebase. It does not cover frontend React code, installer operational flow, or platform internals.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Critical Constraints](#2-critical-constraints)
3. [Source Tree Layout](#3-source-tree-layout)
4. [Shared Libraries](#4-shared-libraries)
5. [Daemons & Utilities](#5-daemons--utilities)
6. [Systemd Services](#6-systemd-services)
7. [Sudoers Rules](#7-sudoers-rules)
8. [udev Rules](#8-udev-rules)
9. [CGI Endpoint Reference](#9-cgi-endpoint-reference)
10. [File Locations on Device](#10-file-locations-on-device)
11. [Locking & Concurrency Conventions](#11-locking--concurrency-conventions)
12. [Update Pipeline](#12-update-pipeline)
13. [Development Guidelines](#13-development-guidelines)
14. [Common Pitfalls](#14-common-pitfalls)
15. [See Also](#15-see-also)

---

## 1. Overview

QManager runs as a self-contained web management stack inside the RM520N-GL modem itself. The modem runs vanilla Debian-adjacent Linux (not OpenWRT). QManager installs independently under `/usrdata/qmanager/` with no dependency on the OEM SimpleAdmin panel.

**Platform stack:**

| Layer | Technology |
|-------|-----------|
| Init system | systemd 244 (`-PAM -SECCOMP -APPARMOR`, hybrid cgroup v1+v2) |
| Web server | lighttpd 1.4.82 (Entware, `/opt/sbin/lighttpd`) |
| Package manager | Entware opkg at `/opt/` (Entware libc 2.27 alongside system glibc 2.31) |
| Config store | JSON files under `/etc/qmanager/` (no UCI) |
| AT transport | `atcli_smd11` via `/dev/smd11` (direct, no socat) |
| Firewall | iptables 1.8.4 legacy (direct, no nftables/fw4) |
| Shell | `/bin/sh` is **BusyBox `ash`** (`/bin/sh -> busybox.nosuid`); `/bin/bash` exists but is **bash 3.2.57(1)-release** — see [§14 Common Pitfalls](#14-common-pitfalls) for missing modern bashisms |

**Backend layers (source to device):**

```
CGI scripts (lighttpd) -- scripts/www/cgi-bin/quecmanager/
     |
Shared libraries       -- scripts/usr/lib/qmanager/
     |
Shell daemons          -- scripts/usr/bin/qmanager_*
     |
AT command gatekeeper  -- scripts/usr/bin/qcmd -> atcli_smd11 -> /dev/smd11
     |
systemd services       -- scripts/etc/systemd/system/
     |
sudoers rules          -- scripts/etc/sudoers.d/qmanager
udev rules             -- scripts/etc/udev/rules.d/
```

`scripts/` in the repository mirrors the device filesystem. `install_rm520n.sh` copies these files to their target paths on the device.

---

## 2. Critical Constraints

These constraints cause silent failures or security issues if violated.

**LF line endings mandatory.** `.gitattributes` enforces LF for all `.sh`, `.service`, and `sudoers` files. CRLF in shell scripts causes BusyBox/bash parse failures. CRLF in sudoers rules causes silent sudo rejection. The installer runs `sed -i 's/\r$//'` on deployed files as a second safety net, but the source must be LF.

**Atomic writes are universal.** Every file that is polled by another process (status JSON, config, state files) must be written via a temporary file plus `mv`. Never truncate-in-place. This prevents readers from seeing partial JSON during writes.

**`fs.protected_regular=1` is active.** The kernel prevents a root process from truncating a file owned by a different user in a sticky `/tmp` directory. This means: if a CGI script (www-data) creates `/tmp/foo.json`, the poller (root) cannot later open it for truncation. Workaround patterns:
- `qmanager_setup` pre-creates shared `/tmp` files as `www-data:www-data` mode 666 at boot.
- For files written exclusively by root, pre-create them as `root:root` mode 666.
- For worker scripts that need to reset their own log, use `rm -f` then create fresh (as seen in `qmanager_update`).

**`/bin/bash` is bash 3.2.57 — many "modern" bashisms are missing.** Probe-confirmed unsupported in this version:
- `${var,,}` / `${var^^}` (lowercase/uppercase substitution) — **broken**, use `tr` instead
- `mapfile` / `readarray` — **not built-in**, use `while read` loops
- `wait -n` (wait for any child) — **not supported**
- `declare -A` (associative arrays) — **not supported**, use parallel indexed arrays or temp files

Probe-confirmed supported: `<<<` herestring, `[[ =~ ]]` regex with `$BASH_REMATCH`, indexed arrays, `local`, `[[ ]]`, process substitution `<(...)`. **`/bin/sh` is BusyBox `ash`** — POSIX-only by definition; do **not** assume any bashism in `#!/bin/sh` scripts. Libraries sourced by both contexts must stay POSIX-clean.

**AT commands via `qcmd` only.** Never write directly to `/dev/smd11`. `qcmd` provides flock serialization. Concurrent writes to `/dev/smd11` corrupt modem responses.

**`jq //` (alternative operator) treats `false` as absent.** `false // "default"` returns `"default"`. When reading boolean config fields (like `enabled`), use the explicit null check pattern:

```sh
val=$(jq -r '(.field) | if . == null then "false" else tostring end' file.json)
```

**CGI privilege model.** lighttpd runs CGI as `www-data`. All privileged operations (service control, iptables, reboot) require `sudo -n` with full absolute paths. The `platform.sh` library provides sudo-wrapped helpers (`svc_*`, `run_iptables`, `run_reboot`). The sudoers file whitelists exactly these paths.

**`systemctl enable` does not work on RM520N-GL.** Unit files live on a read-only rootfs partition where `systemctl enable` cannot write symlinks. Boot persistence uses direct symlinks in `/lib/systemd/system/multi-user.target.wants/`. Use `svc_enable`/`svc_disable` from `platform.sh` which write the symlinks directly via `sudo /bin/ln -sf` / `sudo /bin/rm -f`.

---

## 3. Source Tree Layout

All paths are relative to the repository root. The source tree mirrors the device filesystem exactly.

| Source path | Device path | Contents |
|-------------|-------------|----------|
| `scripts/usr/bin/` | `/usr/bin/` | Daemon and utility scripts (qcmd, qmanager_*) |
| `scripts/usr/lib/qmanager/` | `/usr/lib/qmanager/` | Shared shell libraries |
| `scripts/etc/systemd/system/` | `/lib/systemd/system/` | Systemd unit files |
| `scripts/etc/sudoers.d/qmanager` | `/etc/sudoers.d/qmanager` (also `/opt/etc/sudoers.d/qmanager`) | Sudoers rules for www-data |
| `scripts/etc/udev/rules.d/99-qmanager-smd11.rules` | `/etc/udev/rules.d/99-qmanager-smd11.rules` | udev rule for /dev/smd11 |
| `scripts/etc/udev/scripts/qmanager_smd11_udev.sh` | `/usr/lib/qmanager/qmanager_smd11_udev.sh` | udev helper script |
| `scripts/etc/qmanager/` | `/etc/qmanager/` | Persistent config and state (template files) |
| `scripts/www/cgi-bin/quecmanager/` | `/usrdata/qmanager/www/cgi-bin/quecmanager/` | CGI scripts |
| `scripts/usrdata/qmanager/lighttpd.conf` | `/usrdata/qmanager/lighttpd.conf` | lighttpd configuration (ends with an `include_shell` that optionally pulls in gzip config) |
| _(generated at install time)_ | `/usrdata/qmanager/lighttpd-deflate.conf` | gzip/`mod_deflate` snippet — `install_backend()` auto-installs the module (`opkg install --nodeps`, runs on OTA too), writes this file, then validates with `lighttpd -tt` and reverts (rm) if it can't load. Absent ⇒ no compression, never a brick. Not shipped in the tarball. |
| `scripts/usrdata/qmanager/console/` | `/usrdata/qmanager/console/` | Web console (ttyd) |
| `dependencies/atcli_smd11` | `/usr/bin/atcli_smd11` | AT CLI binary (Rust, ARMv7 static) |
| `dependencies/sms_tool` | `/usr/bin/sms_tool` | SMS send/receive binary (ARMv7) |
| `dependencies/ttyd` | `/usrdata/qmanager/console/ttyd` | Web terminal binary (ARMv7) |

**Note on `qmanager_smd11_udev.sh`:** The source path (`scripts/etc/udev/scripts/`) is deliberately outside `scripts/usr/lib/qmanager/` to prevent the installer's glob copy from resetting its execute bit to 644. The installer copies it to `/usr/lib/qmanager/` with explicit `chmod +x`.

---

## 4. Shared Libraries

All libraries live at `/usr/lib/qmanager/` on the device. Each uses a guard variable to prevent double-sourcing (e.g., `[ -n "$_CGI_BASE_LOADED" ] && return 0`). Source order matters: `qlog.sh` should be sourced before any library that calls `qlog_*`.

### 4.1 `cgi_at.sh`

AT command helpers for CGI scripts and daemons. Source after `qlog.sh` or `cgi_base.sh`.

| Function | Description |
|----------|-------------|
| `strip_at_response <raw>` | Remove command echo, `OK`, and `ERROR` lines from a raw qcmd response |
| `run_at <at_command>` | Execute an AT command via qcmd; returns stripped response or rc=1 on error |
| `detect_active_cid` | Determine active WAN CID via `AT+CGPADDR;+QMAP="WWAN"`; sets global `active_cid` |
| `parse_cgdcont <raw>` | Parse `AT+CGDCONT?` response into a JSON array `[{cid, pdp_type, apn}]` |
| `validate_imei <imei>` | Validate that imei is exactly 15 decimal digits; returns 0/1 |
| `wait_modem_ready <seconds>` | Block for N seconds to allow AT interface to stabilise after boot |

### 4.2 `cgi_auth.sh`

Cookie-based authentication library. Sourced automatically by `cgi_base.sh`. Storage:
- `/etc/qmanager/auth.json` — password hash + salt (SHA-256, persistent)
- `/tmp/qmanager_sessions/<token>` — one file per session (RAM, cleared on reboot)
- `/tmp/qmanager_auth_attempts.json` — rate limiting state (5 attempts / 5-minute window)

Session tokens are 64-char hex strings (256 bits). Session TTL is 3600 seconds.

| Function | Description |
|----------|-------------|
| `is_setup_required` | Returns 0 if `auth.json` is missing or empty (first-run state) |
| `qm_generate_salt` | Generate a 32-char hex salt from `/dev/urandom` |
| `qm_hash_password <pw> <salt>` | SHA-256 hash of `salt+password` |
| `qm_timing_safe_compare <a> <b>` | Constant-time string comparison via awk |
| `qm_verify_password <pw>` | Verify password against stored hash+salt in `auth.json` |
| `qm_save_password <pw>` | Hash and persist a new password to `auth.json` (chmod 600) |
| `qm_get_cookie <name>` | Extract named cookie value from `$HTTP_COOKIE` |
| `qm_set_session_cookies <token>` | Emit `Set-Cookie` headers for session + indicator cookies |
| `qm_clear_session_cookies` | Emit `Set-Cookie` headers that expire both cookies |
| `qm_generate_token` | Generate a 64-char hex session token |
| `qm_create_session` | Create session file in `SESSIONS_DIR`, return token |
| `qm_validate_session <token>` | Check token exists, is valid hex, and is not expired |
| `qm_destroy_session <token>` | Remove session file |
| `qm_cleanup_sessions` | Remove expired session files (called on login) |
| `qm_check_rate_limit` | Check if caller is rate-limited; sets `RATE_LIMIT_RETRY_AFTER` |
| `qm_record_failed_attempt` | Increment failed attempt counter |
| `qm_clear_attempts` | Clear rate limit state |
| `qm_set_ssh_password <pw>` | Pipe password to `qmanager_set_ssh_password` via sudo |
| `require_auth` | Main auth gate; exits 401 if session invalid or setup required |

### 4.3 `cgi_base.sh`

HTTP headers, POST parsing, and JSON response helpers. Source this at the top of every CGI script. Automatically sources `qlog.sh`, `platform.sh`, and `cgi_auth.sh`. Automatically calls `require_auth` unless `_SKIP_AUTH=1` is set before sourcing.

```sh
# Standard CGI header
_SKIP_AUTH=1   # set only for auth/* endpoints
. /usr/lib/qmanager/cgi_base.sh
```

PATH is exported at source time to include `/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin`.

| Function | Description |
|----------|-------------|
| `cgi_headers` | Emit `Content-Type: application/json` + CORS + blank line |
| `cgi_handle_options` | Exit 0 immediately for OPTIONS (CORS preflight) |
| `cgi_read_post` | Read stdin into `$POST_DATA` using `$CONTENT_LENGTH`; exits on empty body |
| `cgi_method_not_allowed` | Emit 405 JSON and exit |
| `cgi_success` | Emit `{"success":true}` |
| `cgi_error <code> <detail>` | Emit `{"success":false,"error":$code,"detail":$detail}` |
| `cgi_reboot_response` | Emit success, then async-wait for `/tmp/qmanager_reboot_ack` (up to `$QM_REBOOT_ACK_TIMEOUT`s, default 20) before issuing reboot via `run_reboot`. See [§4.3.1 Reboot Ack Handshake](#431-reboot-ack-handshake). |
| `serve_ndjson_as_array <file>` | Serve an NDJSON file as a JSON array; emits `[]` if missing |

#### 4.3.1 Reboot Ack Handshake

Any CGI endpoint that triggers a reboot must call `cgi_reboot_response` — never inline `( sleep N && reboot )`. The helper coordinates with the static `/reboot/` page so the device only reboots **after** the countdown UI is in browser memory; otherwise lighttpd dies mid-serve and the user gets a connection-reset error instead of a countdown.

The contract:

1. CGI emits `{"success":true}` and forks a background block that polls `/tmp/qmanager_reboot_ack` once a second.
2. Frontend redirects to `/reboot/` on save success (see the [Reboot Navigation Pattern](FRONTEND.md#reboot-navigation-pattern) in FRONTEND.md).
3. The `/reboot/` page (`components/reboot/reboot-countdown.tsx`) fires `GET /cgi-bin/quecmanager/system/update.sh?action=reboot_ack` on mount, which creates `/tmp/qmanager_reboot_ack`.
4. The CGI background block sees the ack file, removes it, sleeps `$QM_REBOOT_POST_ACK_DELAY` seconds, then calls `run_reboot`.
5. If the user closed the tab or a non-UI caller invoked the endpoint, the wait is bounded — the reboot fires after `$QM_REBOOT_ACK_TIMEOUT` seconds regardless. The contract cannot hang.

Tunables (export before sourcing or before the call):

| Variable | Default | Purpose |
|----------|---------|---------|
| `QM_REBOOT_ACK_TIMEOUT` | `20` | Max seconds to wait for the ack file before forcing reboot. Matches the OTA worker's `REBOOT_ACK_TIMEOUT` in `qmanager_update` so every reboot path shares one budget. |
| `QM_REBOOT_POST_ACK_DELAY` | `1` | Grace seconds after ack is received, before `run_reboot` runs. Lets the browser finish painting the countdown's initial frame. |

The OTA worker (`qmanager_update`) is **not** a CGI and reaches reboot via its own ack-wait loop using the same file. Both paths use the same 20s budget so user expectations match wherever the reboot was triggered.

### 4.4 `config.sh`

File-backed key-value config store. Replaces UCI for RM520N-GL. Config file: `/etc/qmanager/qmanager.conf` (JSON). Sections: `watchcat`, `bridge_monitor`, `eth_link`, `settings`, `update`.

| Function | Description |
|----------|-------------|
| `qm_config_init` | Create default config file if missing or empty |
| `qm_config_get <section> <key> [default]` | Read a value; returns default if missing |
| `qm_config_set <section> <key> <value>` | Write a value atomically (numeric values stored as numbers) |
| `qm_config_section <section>` | Return entire section as a JSON object |

**Note on `qm_config_get` and `false`:** Uses `// empty` which treats `false` as absent. All values in this config are strings or integers, never boolean `false`, so this is safe. If a future field needs boolean `false`, use the explicit null-check pattern instead.

### 4.5 — removed

`email_alerts.sh` documented an Email Alerts library that this fork cut in
Phase B. The file no longer exists; SMS Alerts (§4.12) is the remaining
notification channel. The number is left as a gap so older references to
§4.6-§4.16 keep pointing at the same sections.

`qmanager_health_check` still collects `/etc/qmanager/msmtprc` and
`email_alerts.json` into its diagnostic bundle, and still redacts them — that is
deliberate, for devices upgraded from a build that had the feature. Both reads
are guarded, so on a clean install they simply find nothing.

### 4.6 `events.sh`

Network event detection library. Sourced by `qmanager_poller` and `qmanager_watchcat`. Detects state changes and appends NDJSON events to `/tmp/qmanager_events.json` (max 50 entries). Reads global state variables populated by the poller's AT parsers.

| Function | Description |
|----------|-------------|
| `append_event <type> <message> [severity]` | Append one event record to `$EVENTS_FILE`; trims to `$MAX_EVENTS` |
| `snapshot_event_state` | Snapshot current state into `prev_ev_*` variables |
| `detect_events` | Compare current vs previous state; emit events for all changes |
| `detect_data_connection_events` | Detect internet up/down and high latency/loss events (debounced) |
| `detect_scc_pci_changes` | Detect SCC cell handoffs via `$PCI_STATE_FILE`; called on Tier 2 refresh |
| `_ev_bands <tech> <cc_json>` | Extract compact band list from carrier_components JSON |
| `_ev_band_summary <tech> <cc_json>` | Build band + total bandwidth summary string |
| `_ev_ca_diff <tech> <prev_cc> <curr_cc>` | Compute added/removed bands; sets `_diff_added` / `_diff_removed` |
| `_ev_net_context` | Build short network context string from current globals |

**First-cycle behaviour:** `detect_events` populates `prev_ev_*` on the first call without emitting events. Set `events_initialized=false` at startup.


**Recovery suppression:** Internet events are suppressed while `$conn_during_recovery = "true"` to prevent spurious events during watchcat recovery actions.

### 4.7 `parse_at.sh`

AT command response parsers. Sourced by `qmanager_poller`. All functions take raw AT response strings and populate global state variables.

| Function | Populates | AT command |
|----------|-----------|------------|
| `parse_serving_cell <raw>` | `lte_state`, `nr_state`, `lte_band`, `lte_pci`, `lte_rsrp`, `lte_rsrq`, `lte_sinr`, `lte_rssi`, `lte_cell_id`, `lte_enodeb_id`, `lte_sector_id`, `lte_tac`, `lte_earfcn`, `lte_bandwidth`, `nr_band`, `nr_pci`, `nr_arfcn`, `nr_rsrp`, `nr_rsrq`, `nr_sinr`, `nr_scs`, `nr_cell_id`, `nr_enodeb_id`, `nr_sector_id`, `nr_tac`, `network_type`, `service_status` | `AT+QENG="servingcell"` |
| `parse_temperature <raw>` | `t2_temperature` | `AT+QTEMP` |
| `parse_carrier <raw>` | `t2_carrier` | `AT+COPS?` |
| `parse_sim_status <raw>` | `t2_sim_status` | `AT+CPIN?` |
| `parse_sim_slot <raw>` | `t2_sim_slot` | `AT+QUIMSLOT?` |
| `parse_version <raw>` | `boot_firmware`, `boot_build_date`, `boot_manufacturer` | `AT+CVERSION` |
| `parse_capability <raw>` | `boot_lte_category` | `AT+QGETCAPABILITY` |
| `parse_mimo <lte_raw> [nr_raw]` | `t2_mimo` | `AT+QNWCFG="lte_mimo_layers"`, `"nr5g_mimo_layers"` |
| `parse_ca_info <raw>` | `t2_ca_active`, `t2_ca_count`, `t2_nr_ca_active`, `t2_nr_ca_count`, `t2_total_bandwidth_mhz`, `t2_bandwidth_details`, `t2_carrier_components` | `AT+QCAINFO` |
| `parse_time_advance <raw>` | `lte_ta`, `nr_ta` | `AT+QNWCFG="lte_time_advance"`, `"nr5g_time_advance"` |
| `parse_qrsrp <raw>` | `sig_lte_rsrp`, `sig_nr_rsrp` | `AT+QRSRP` |
| `parse_qrsrq <raw>` | `sig_lte_rsrq`, `sig_nr_rsrq` | `AT+QRSRQ` |
| `parse_qsinr <raw>` | `sig_lte_sinr`, `sig_nr_sinr` | `AT+QSINR` |
| `parse_cgcontrdp <raw>` | `t2_apn`, `t2_primary_dns`, `t2_secondary_dns` | `AT+CGCONTRDP` |
| `parse_wan_ip <raw>` | `t2_wan_ipv4`, `t2_wan_ipv6` | `AT+QMAP="WWAN"` |
| `parse_policy_band <raw>` | `boot_supported_lte_bands`, `boot_supported_nsa_nr5g_bands`, `boot_supported_sa_nr5g_bands` | `AT+QNWPREFCFG="policy_band"` |
| `parse_ippt_mpdn_rule <raw>` | `boot_ippt_mode`, `boot_ippt_mac` | `AT+QMAP="MPDN_RULE"` |
| `parse_ippt_nat <raw>` | `boot_ippt_nat` | `AT+QMAP="IPPT_NAT"` |
| `parse_ippt_usbnet <raw>` | `boot_ippt_usbnet` | `AT+QCFG="usbnet"` |
| `parse_ippt_dhcpv4dns <raw>` | `boot_ippt_dhcpv4dns` | `AT+QMAP="DHCPV4DNS"` |

Helper functions:

| Function | Description |
|----------|-------------|
| `_sig_val <val>` | Map sentinel value -32768 or empty to `null`; pass through otherwise |
| `_antenna_to_json_array v0 v1 v2 v3` | Build 4-element JSON array with sentinel mapping |
| `_antenna_line_to_json <line> <prefix>` | Parse one `+QRSRP`/`+QRSRQ`/`+QSINR` line into a JSON array |
| `_compute_cell_parts <hex_id> [nr]` | Decode hex cell ID; sets `_cid_dec`, `_cid_enb`, `_cid_sec` |
| `_hex_to_dec <hex>` | Convert hex string to decimal |
| `map_scs_to_khz <scs_enum>` | Map SCS enum (0-4) to subcarrier spacing in kHz |
| `_lte_rb_to_mhz <rb>` | Map LTE resource block count to bandwidth in MHz |
| `_nr_bw_to_mhz <bw_enum>` | Map NR bandwidth enum to MHz |

### 4.8 `platform.sh`

Service control abstraction and sudo wrappers for CGI context. Detects whether caller is root (skips `sudo`) or www-data (uses Entware sudo at `/opt/bin/sudo` if available, else `/usr/bin/sudo`).

| Function | Description |
|----------|-------------|
| `svc_start <name>` | `systemctl start <unit>` |
| `svc_stop <name>` | `systemctl stop <unit>` |
| `svc_restart <name>` | `systemctl restart <unit>` |
| `svc_enable <name>` | Create symlink in `multi-user.target.wants/` |
| `svc_disable <name>` | Remove symlink from `multi-user.target.wants/` |
| `svc_is_enabled <name>` | Test whether boot symlink exists |
| `svc_is_running <name>` | Test whether unit is currently active |
| `run_iptables [args...]` | `iptables` with sudo prefix |
| `run_ip6tables [args...]` | `ip6tables` with sudo prefix |
| `run_reboot [args...]` | `reboot` with sudo prefix |
| `pid_alive <pid>` | Test `/proc/<pid>` existence (works cross-user, unlike `kill -0`) |

**Unit name translation:** `svc_*` functions translate underscores to dashes (`qmanager_watchcat` -> `qmanager-watchcat.service`) via `_svc_unit()`.

### 4.9 `profile_mgr.sh`

SIM profile CRUD library. No persistent process. Sourced by CGI scripts and `qmanager_profile_apply`. Profiles stored as individual JSON files under `/etc/qmanager/profiles/p_<timestamp>_<hex>.json`. Maximum 10 profiles.

| Function | Description |
|----------|-------------|
| `profile_count` | Return count of `p_*.json` files in `PROFILE_DIR` |
| `profile_list` | Return `{profiles:[...], active_profile_id}` JSON |
| `profile_get <id>` | Cat the named profile JSON file; rc=1 if not found |
| `profile_save` | Read profile JSON from stdin; create or update; enforce limit |
| `profile_delete <id>` | Remove profile file; clear active marker if it matches |
| `get_active_profile` | Print active profile ID (verifies file still exists) |
| `set_active_profile <id>` | Write ID to `ACTIVE_PROFILE_FILE` |
| `clear_active_profile` | Remove `ACTIVE_PROFILE_FILE` |
| `find_profile_by_iccid <iccid>` | Search profiles for ICCID match; print matching ID |
| `auto_apply_profile <iccid> [caller]` | Find profile, set active, spawn `qmanager_profile_apply` |
| `profile_check_lock` | Check if apply process is running; clean stale PID; sets `_profile_lock_pid` |
| `profile_acquire_lock` | Check + write PID to `PROFILE_APPLY_PID_FILE`; rc=1 if locked |

Profile JSON schema: `{id, name, mno, sim_iccid, created_at, updated_at, settings: {apn: {cid, name, pdp_type}, imei, ttl, hl, scenario_id}}`.

`settings.scenario_id` is optional (`""` = no binding). Valid values: `""`, `balanced`, `gaming`, `streaming`, or a `custom-<timestamp>` ID that exists at `/etc/qmanager/scenarios/<id>.json`. `profile_save` validates the field against this enum and rejects unknown values. See [`reference/sim-profiles.md`](reference/sim-profiles.md) for the binding semantics, gate matrix, and apply pipeline.

### 4.9a `scenario_mgr.sh`

Connection Scenario apply library. Sourced by `scenarios/activate.sh` and `qmanager_profile_apply`. Custom scenarios are stored at `/etc/qmanager/scenarios/<id>.json`; the active scenario ID is written to `/etc/qmanager/active_scenario`.

| Function | Description |
|----------|-------------|
| `scenario_get_active` | Print the currently active scenario ID, or empty if none |
| `scenario_set_active <id>` | Write active scenario ID atomically via `tmp` + `mv` |
| `scenario_clear_active` | Remove the active scenario marker |
| `scenario_lookup_custom <id>` | For a `custom-*` ID, print the stored JSON; rc=1 if missing |
| `scenario_apply <id> [mode] [lte_bands] [nsa_nr_bands] [sa_nr_bands]` | Apply mode pref + optional band locks via `AT+QNWPREFCFG`. Built-ins (`balanced`/`gaming`/`streaming`) ignore the extra args and use hardcoded modes. Custom scenarios require `mode`. Returns 0 if `mode_pref` succeeded; sets `_scenario_apply_failed` to a comma-separated list of failed band sub-steps for partial-success detection. |

### 4.10 `qlog.sh`

Centralized logging library. Writes structured log lines to `/tmp/qmanager.log` with rotation and optional syslog forwarding.

Log format: `[YYYY-MM-DD HH:MM:SS] LEVEL [component:PID] message`

| Function | Description |
|----------|-------------|
| `qlog_init <component>` | Set component name; create log directory |
| `qlog_debug <msg>` | Log at DEBUG level |
| `qlog_info <msg>` | Log at INFO level |
| `qlog_warn <msg>` | Log at WARN level |
| `qlog_error <msg>` | Log at ERROR level |
| `qlog_at_cmd <cmd> <response> [rc]` | Log AT command + response at DEBUG; truncates long responses to 200 chars |
| `qlog_lock <event> [detail]` | Log flock acquire/release/timeout/stale_recovery events |
| `qlog_state_change <field> <old> <new>` | Log state transitions at INFO level (only when old != new) |

Environment overrides: `QLOG_LEVEL` (DEBUG/INFO/WARN/ERROR, default INFO), `QLOG_FILE`, `QLOG_MAX_SIZE_KB` (default 256), `QLOG_MAX_FILES` (default 2), `QLOG_TO_SYSLOG` (default 1), `QLOG_TO_STDOUT` (default 0).

### 4.11 `semver.sh`

Semantic version comparison. Used by `qmanager_update` and `qmanager_auto_update`.

| Function | Exit codes | Description |
|----------|-----------|-------------|
| `semver_compare <a> <b>` | 0=a newer, 1=equal, 2=a older | Compare two semver strings; strips leading `v`; handles pre-release labels |

### 4.12 `sms_alerts.sh`

SMS alert library. Sourced by `qmanager_poller`. Tracks internet downtime and sends a recovery SMS via `sms_tool` once downtime exceeds the configured threshold. Since Email Alerts was cut in Phase B (§4.5), this is the only notification channel left. Shares `/tmp/qmanager_at.lock` with `qcmd` and the SMS Center CGI to serialize `/dev/smd11` access.

Config: `/etc/qmanager/sms_alerts.json`. Log: `/tmp/qmanager_sms_log.json` (NDJSON, max 100 entries). Reload flag: `/tmp/qmanager_sms_reload`.

**Registration guard:** Before every send attempt, `_sa_is_registered()` verifies that `modem_reachable="true"` AND (`lte_state="connected"` OR `nr_state="connected"`). Unregistered checks do not consume the retry budget (`_SA_MAX_ATTEMPTS=3`); they are bounded separately by `_SA_MAX_SKIPS=3` consecutive skips before deferring to the next poll cycle.

**Phone number format:** Stored with leading `+` in config; `+` is stripped via `${_sa_recipient#+}` before calling `sms_tool send` (sms_tool does not accept `+` prefix).

**Recovery deduplication:** If the downtime-start SMS was never sent (`_sa_downtime_sms_status != "sent"`), recovery emits a single combined message ("was down for X, now restored"). If the downtime-start SMS was sent, recovery emits a separate "recovered" message.

**CGI test send override:** CGI sets `_sa_is_registered() { return 0; }` after sourcing the library (the `_SMS_ALERTS_LOADED` guard prevents re-source clobber) because CGI context lacks poller globals.

| Function | Description |
|----------|-------------|
| `sms_alerts_init` | Read config; log state (called once at poller startup) |
| `check_sms_alert` | Main poll hook; track downtime, attempt sends, handle recovery |
| `_sa_read_config` | Read `sms_alerts.json` into `_sa_*` state variables |
| `_sa_is_registered` | Check modem reachable + LTE or NR connected; return 0/1 |
| `_sa_flock_wait <fd> <timeout>` | BusyBox-compatible flock polling loop |
| `_sa_sms_locked [sms_tool_args...]` | Run sms_tool under the shared AT lock |
| `_sa_do_send <body>` | Send SMS with retry; returns 0=success, 1=failed, 2=not attempted |
| `_sa_send_test_sms` | Send test SMS (called by CGI) |
| `_sa_log_event <trigger> <status> <recipient>` | Append NDJSON entry to SMS log |
| `_sa_format_duration <secs>` | Convert seconds to human-readable string |

### 4.13 `system_config.sh`

System settings abstraction. Replaces `uci system.@system[0].*` for hostname and timezone. Sources `config.sh` and `platform.sh` (for `$_SUDO`).

Neither hostname nor timezone can be applied in-process: the CGI runs as `www-data`, `/etc` is `root:root 0755`, `/proc/sys/kernel/hostname` is root-only, and no sudoers rule grants `mount` for the read-only-rootfs case. Both therefore hand the privileged half to a root helper (§5) and return a real exit code.

| Function | Description |
|----------|-------------|
| `sys_get_hostname` | Read hostname from `qmanager.conf` -> `/etc/hostname` -> default `"RM520N-GL"` |
| `sys_hostname_label <name>` | Reduce a free-form display name to an RFC 1123 label (non-`[A-Za-z0-9-]` -> `-`, squeeze, trim, 63-char cap, fallback `"RM520N-GL"`) |
| `sys_set_hostname <name>` | Persist the display name to `qmanager.conf`, then apply `sys_hostname_label` of it via `qmanager_set_hostname`. Returns 0 on apply, 1 when only the preference was stored |
| `sys_get_timezone` | Read POSIX TZ string from `qmanager.conf` (default `"UTC0"`) |
| `sys_get_zonename` | Read IANA zone name from `qmanager.conf` (default `"UTC"`) |
| `sys_set_timezone <tz> [zonename]` | Persist TZ, apply the zone via `qmanager_set_timezone`, export `$TZ`. Returns 0 on apply, 1 on failure |

**Why `settings.hostname` is sanitized rather than validated.** The key doubles as the user's display name — onboarding asks for it as "Your name" and the sidebar renders it verbatim — so values with spaces, apostrophes or diacritics are normal. Rejecting them to satisfy RFC 1123 would break the rename dialog, so the stored value stays free-form and only the derived label reaches the kernel. `scripts/test/hostname-helper.sh` asserts that every label the sanitizer can emit is accepted by the helper's validator; if those two drift apart, renaming silently stops applying again.

### 4.14 `tower_lock_mgr.sh`

Tower lock config CRUD, AT command builders, signal quality calculation, and failover watcher management. Sourced by CGI scripts and failover/schedule daemons. Config: `/etc/qmanager/tower_lock.json`.

| Function | Description |
|----------|-------------|
| `tower_config_init` | Create default config if missing or invalid |
| `tower_config_read` | Cat config to stdout; falls back to embedded default on missing/invalid |
| `tower_config_get <jq_filter>` | Extract value via jq; uses explicit null check (not `//`) |
| `tower_config_update <jq_filter>` | Apply jq filter to config; atomic write via tmp+mv |
| `tower_config_update_lte <enabled> c1_e c1_p [c2_e c2_p [c3_e c3_p]]` | Update LTE lock cells in config |
| `tower_config_update_nr <enabled> pci arfcn scs band` | Update NR-SA lock params in config |
| `tower_config_update_settings <persist> <fo_enabled> <fo_threshold>` | Update persist + failover settings |
| `tower_config_update_schedule <enabled> <start> <end> <days_json>` | Update schedule config |
| `tower_lock_lte <num_cells> earfcn1 pci1 [...]` | Send `AT+QNWLOCK="common/4g"` |
| `tower_unlock_lte` | Send `AT+QNWLOCK="common/4g",0` |
| `tower_read_lte_lock` | Query and parse LTE lock state; prints `locked N earfcn pci...` or `unlocked` |
| `tower_lock_nr <pci> <arfcn> <scs> <band>` | Send `AT+QNWLOCK="common/5g"` |
| `tower_unlock_nr` | Send `AT+QNWLOCK="common/5g",0` |
| `tower_read_nr_lock` | Query and parse NR-SA lock state; prints `locked pci arfcn scs band` or `unlocked` |
| `tower_set_persist <0\|1>` | Send `AT+QNWLOCK="save_ctrl",val,val` |
| `tower_read_persist` | Query persistence state; prints `<lte_ctrl> <nr_ctrl>` |
| `calc_signal_quality <rsrp>` | Map RSRP to 0-100 integer: `clamp(0,100,((rsrp+140)*100)/60)` |
| `tower_kill_failover_watcher` | Stop `qmanager-tower-failover` service |
| `tower_spawn_failover_watcher` | Check config, restart failover service, verify PID; prints `true`/`false` |
| `mtu_reapply_after_bounce` | Spawn background MTU re-apply watcher (polls up to 30s after interface bounce) |

### 4.15 `ttl_state.sh`

TTL/HL iptables rule management. Reads/writes `/etc/qmanager/ttl_state` (plain `TTL=N\nHL=N` format). Requires `platform.sh` to be sourced by the caller first (uses `run_iptables` / `run_ip6tables`).

TTL rules target `rmnet+` interface in `mangle POSTROUTING`. Replaces the legacy `/etc/firewall.user.ttl`.

| Function | Description |
|----------|-------------|
| `ttl_state_read_persisted` | Print `"<ttl> <hl>"` from state file; missing keys default to 0 |
| `ttl_state_read_live` | Print `"<ttl> <hl>"` from live iptables rules |
| `ttl_state_write_persisted <ttl> <hl>` | Atomic write to state file; removes file if both are 0 |
| `ttl_state_apply <ttl> <hl>` | Delete old rules, insert new rules; skips insert if value is 0 |
| `ttl_state_clear` | Apply 0 0 and remove state file |

### 4.16 `ethtool_helper.sh`

Ethernet PHY helpers for `network/ethernet.sh`. Wraps `ethtool` output parsing into reusable functions. Guards against double-sourcing via `_ETHTOOL_HELPER_LOADED`.

| Function | Description |
|----------|-------------|
| `get_supported_advertise_hex` | Parse `ethtool $ETH_INTERFACE` supported link modes into a bitmask hex string (for `ethtool --change advertise`) |
| `supports_2500` | Returns `true` if `eth0` advertises `2500baseT/Full`; `false` otherwise |

Caller must set `ETH_INTERFACE` before sourcing (default `eth0` in `ethernet.sh`).

---

## 5. Daemons & Utilities

### 5.1 Long-Running Daemons

These run continuously under systemd supervision.

#### `qmanager_poller`

**Location:** `/usr/bin/qmanager_poller`
**State files:** `/tmp/qmanager_status.json` (main cache), `/tmp/qmanager_signal_history.json`, `/tmp/qmanager_ping_history.json`, `/tmp/qmanager_events.json`
**Logs:** `/tmp/qmanager.log`

Main data collection daemon. Sources `qlog.sh`, `parse_at.sh`, `events.sh`, `email_alerts.sh`, `sms_alerts.sh` at startup.

**Polling tiers:**

| Tier | Interval | AT commands |
|------|----------|-------------|
| Tier 1 (hot) | Every cycle (~2s) | `AT+QENG="servingcell"`, `/proc` traffic stats |
| Tier 1.5 (signal) | Every 5 cycles (~10s) | `AT+QRSRP`, `AT+QRSRQ`, `AT+QSINR` |
| Tier 2 (warm) | Every 15 cycles (~30s) | `AT+QTEMP`, `AT+COPS?`, `AT+CPIN?`, `AT+QUIMSLOT?`, `AT+QCAINFO`, `AT+QNWCFG="lte_time_advance"`, `AT+QNWCFG="nr5g_time_advance"`, `AT+QNWCFG="lte_mimo_layers"`, `AT+QNWCFG="nr5g_mimo_layers"`, `AT+CGCONTRDP`, `AT+QMAP="WWAN"` |
| Boot-only | Once at startup | `AT+CVERSION`, `AT+CGSN`, `AT+CIMI`, `AT+QCCID`, `AT+CNUM`, `AT+QGETCAPABILITY`, `AT+QNWPREFCFG="policy_band"`, IPPT parsers |

Network interface for traffic stats is auto-detected: `rmnet_ipa0` on RM520N-GL (presence of `/etc/quectel-project-version`), `wwan0` on other platforms.

**System Health collection (`update_system_health()`):** Runs every Tier 1 cycle. Cheap reads only — no AT commands, no extra forks beyond `awk`/`grep`/`df`. Emits a top-level `system_health` block in the cache so the `system/modem-subsys.sh` CGI can serve it as a thin reader. Sources:

| Field | Source |
|-------|--------|
| `state`, `state_raw`, `crash_count` | `/sys/devices/platform/4080000.qcom,mss/subsys0/{state,crash_count}` |
| `coredump_present` | Non-empty file under `/sys/devices/platform/4080000.qcom,mss/ramdump/ramdump_modem/` (sysfs metadata pseudo-files excluded) |
| `last_crash_at`, `total_logged_crashes` | `/etc/qmanager/modem_crashes.json` (NDJSON-style array; last entry's `ts` and `length`) |
| `cpu.load_1m` | `/proc/loadavg` (first column) |
| `cpu.core_count` | `nproc` (cached after first read — value never changes at runtime) |
| `cpu.usage_pct` | `/proc/stat` delta computed in `update_proc_metrics()` (the same value the rest of the cache uses) |
| `cpu.freq_khz`, `cpu.max_freq_khz` | `/sys/devices/system/cpu/cpu0/cpufreq/{scaling_cur_freq,scaling_max_freq}` |
| `memory.{total_kb, used_kb, available_kb}` | Derived from `device.memory_total_mb` / `device.memory_used_mb` (× 1024) |
| `storage.{mount, total_kb, used_kb, available_kb}` | `df -P /usrdata` |

The CGI reader (`/cgi-bin/quecmanager/system/modem-subsys.sh`) is now a thin `jq` extractor: it reshapes `system_health` into the historical response schema, falls back to an all-null shape if the cache is missing or older than 30s, and never re-implements live computation. Per-request cost dropped from ~80–120ms to ~15–25ms.

#### `qmanager_ping`

**Location:** `/usr/bin/qmanager_ping`
**State files:** `/tmp/qmanager_ping.json` (current state), `/tmp/qmanager_ping_history` (flat ring buffer)

The single source of internet reachability data. Probes two configurable HTTP/HTTPS targets on a 5-second interval using a primary-then-fallback strategy. Writes atomic JSON with `available`, `latency_ms`, `streak_ok`, and `streak_fail` fields. Does not touch the modem or AT device. Stats (avg/min/max/jitter/loss) are computed by the poller from the history file.

**Config:** `/etc/qmanager/ping_profile.json` — `profile` (sensitivity preset), `target_1` (primary), `target_2` (secondary).

Consumers: poller (reads `ping.json` and history), watchcat (reads `streak_fail` to drive recovery), frontend (reads via `status.json` merged by poller).

### Probe Targets

The ping daemon checks two targets in a primary-then-fallback strategy. Primary is probed every interval; secondary is only probed when primary returns `Disconnected`.

Both targets accept:
- Full URL: `https://example.com/path` or `http://example.com/path`
- Bare hostname: `youtube.com` (auto-prefixed to `https://youtube.com/`)
- Hostname with path: `example.com/health` → `https://example.com/health`

**Response interpretation:**
- For canonical captive-portal endpoints (`/generate_204`, `/hotspot-detect.html`): 204 = Connected, anything else = Limited (probable captive portal intercept).
- For custom URLs: any HTTP response (2xx–5xx) = Connected — the network path worked end-to-end. Limited state only triggers from canonical endpoints.

**Defaults:** `http://cp.cloudflare.com/` (primary), `http://www.gstatic.com/generate_204` (secondary).

**Why these defaults:** Cloudflare's captive portal endpoint is reachable from most regions including networks that filter Google services (e.g. mainland China). Google's `gstatic` is the established fallback for everywhere else.

#### `qmanager_watchcat`

**Location:** `/usr/bin/qmanager_watchcat`
**State files:** `/tmp/qmanager_watchcat.json`, `/tmp/qmanager_watchcat.pid`, `/tmp/qmanager_watchcat.lock`, `/tmp/qmanager_recovery_active`, `/tmp/qmanager_sim_failover`, `/etc/qmanager/crash.log`
**Config:** `qmanager.conf` section `watchcat`

Pure state machine. Reads `qmanager_ping.json`; never pings independently.

**State machine:**

```
MONITOR -> SUSPECT -> RECOVERY -> COOLDOWN -> MONITOR
          (LOCKED: maintenance mode, sleeps until lock removed)
```

**Escalation tiers:**

| Tier | UI Label | Action | Guard |
|------|----------|--------|-------|
| 1 | Re-register to Network | Network deregister/reregister (`AT+COPS=2/0`) | Enabled by default |
| 2 | CFUN Toggle | Radio toggle (`AT+CFUN=0/1`) | Skipped if tower lock active |
| 3 | SIM Failover | SIM failover (`AT+QUIMSLOT`) | Disabled by default; Golden Rule sequence |
| 4 | Reboot | System reboot | Token bucket: max N/hour; auto-disables if limit hit |

LOCKED state: set by touching `/tmp/qmanager_watchcat.lock`. Watchcat sleeps until the file is removed. The update worker and installer touch this file during OTA operations.

### 5.2 On-Demand Daemons

These are started on-demand by CGI actions and stop when their task completes.

#### `qmanager_cell_scanner`

**Location:** `/usr/bin/qmanager_cell_scanner`
**State files:** `/tmp/qmanager_cell_scan.json`, `/tmp/qmanager_cell_scan.pid`

Runs `AT+QSCAN` (may take >60 seconds). Writes scan results with MCC/MNC lookups from `/usrdata/qmanager/www/cgi-bin/quecmanager/operator-list.json`. Spawned by `at_cmd/cell_scan_start.sh`; polled by `at_cmd/cell_scan_status.sh`.

#### `qmanager_neighbour_scanner`

**Location:** `/usr/bin/qmanager_neighbour_scanner`
**State files:** `/tmp/qmanager_neighbour_scan.json`, `/tmp/qmanager_neighbour_scan.pid`

Runs `AT+QENG="neighbourcell"`. Spawned by `at_cmd/neighbour_scan_start.sh`; polled by `at_cmd/neighbour_scan_status.sh`.

#### `qmanager_band_failover`

**Location:** `/usr/bin/qmanager_band_failover`
**State files:** `/tmp/qmanager_band_failover.json`, `/tmp/qmanager_band_failover.pid`

Monitors signal quality and falls back to a configured backup band configuration when the primary drops below threshold. Spawned and stopped by `bands/failover_toggle.sh`.

#### `qmanager_tower_failover`

**Location:** `/usr/bin/qmanager_tower_failover`
**State files:** `/tmp/qmanager_tower_failover.json`, `/tmp/qmanager_tower_failover.pid`, `/tmp/qmanager_tower_failover`

Monitors signal quality against the tower lock failover threshold. When quality drops below threshold, clears the tower lock. Spawned by `tower_lock_mgr.sh`'s `tower_spawn_failover_watcher()` when failover is enabled. Configured via `tower_lock.json` section `failover`.

#### `qmanager_tower_schedule`

**Location:** `/usr/bin/qmanager_tower_schedule`
**State files:** `/tmp/qmanager_tower_schedule.pid`

Applies and removes tower lock on a time schedule. Reads `tower_lock.json` section `schedule`. Spawned by `tower/schedule.sh` when schedule is enabled.

#### `qmanager_profile_apply`

**Location:** `/usr/bin/qmanager_profile_apply`
**State files:** `/tmp/qmanager_profile_state.json`, `/tmp/qmanager_profile_apply.pid`

Detached process spawned by `profiles/apply.sh`. Applies a saved profile to the modem in four steps (`STEP_NAMES="apn ttl_hl scenario imei"`):
1. APN -- `AT+CGDCONT` + full attach cycle (see [`reference/wan-profile-management.md`](reference/wan-profile-management.md))
2. TTL/HL -- iptables rules via `ttl_state_apply`
3. Scenario -- `scenario_apply` from `scenario_mgr.sh`; skipped if `settings.scenario_id` is empty; marks `skipped` with detail `"Scenario <id> no longer exists"` for a dangling custom reference
4. IMEI -- `AT+EGMR` + `AT+CFUN=1,1` soft reboot (most disruptive, applied last)

Scenario MUST precede IMEI: `AT+CFUN=1,1` reboots the radio, so any `AT+QNWPREFCFG` writes after it would be lost.

State JSON tracks current step, total steps (4), and per-step status (`pending`/`running`/`done`/`skipped`/`failed`). Polled by `profiles/apply_status.sh`. Singleton via PID file; `profile_check_lock()` guards against concurrent runs.

### 5.3 Boot Oneshots

These run once at boot via systemd oneshot units.

#### `qmanager_setup`

**Location:** `/usr/bin/qmanager_setup`

Pre-create shared `/tmp` files with correct ownership for `fs.protected_regular=1`. Set `/dev/smd11` permissions. Ensure required directories exist. Initialize `qmanager.conf` defaults. Make all CGI scripts and binaries executable.

Key pre-creates (see §10 and §11 for the full list and rationale):
- `/tmp/qmanager_at.lock` -- `www-data:www-data` mode 666
- `/tmp/qmanager.log` -- `root:root` mode 666
- `/tmp/qmanager_sessions/` -- `www-data:www-data` mode 700

#### `qmanager_firewall`

**Location:** `/usr/bin/qmanager_firewall`

Manages iptables rules restricting web UI access (ports 80/443) to trusted interfaces (`lo`, `bridge0`, `eth0`, `tailscale0` if installed). Invoked as `qmanager_firewall start` / `stop` by the systemd unit. SSH (port 22) is intentionally left open for emergency access.

#### `qmanager_imei_check`

**Location:** `/usr/bin/qmanager_imei_check`

One-shot check that runs after boot if `/etc/qmanager/imei_check_pending` exists. Reads `/etc/qmanager/imei_backup.json` and verifies/restores IMEI settings. The systemd unit's `ExecCondition` guard skips the service if the pending marker or backup file is absent, or if the backup has `enabled != true` -- skipping is not a failure, so the (majority) devices that never enabled IMEI persistence do not boot with a failed unit. See the start-gating note in §6 for why this is `ExecCondition` and not `ExecStartPre`.

#### `qmanager_mtu_apply`

**Location:** `/usr/bin/qmanager_mtu_apply`

Apply custom MTU from `/etc/firewall.user.mtu` to `rmnet_data*` interface at boot. The systemd unit has `ConditionPathExists=/etc/firewall.user.mtu` so it is a no-op if no custom MTU is configured.

### 5.4 Cron-Driven

These are invoked by root's crontab entries written by CGI scripts.

#### `qmanager_scheduled_reboot`

**Location:** `/usr/bin/qmanager_scheduled_reboot`

Performs a scheduled reboot at the configured time. Crontab entry written by `system/settings.sh` when `sched_reboot_enabled=1`. Config: `qmanager.conf` section `settings`.

#### `qmanager_auto_update`

**Location:** `/usr/bin/qmanager_auto_update`

Checks GitHub for a newer release and spawns `qmanager_update install` if a newer version is available. Crontab entry written by `system/settings.sh` when `auto_update_enabled=1`. Config: `qmanager.conf` section `update`. Uses `semver_compare` from `semver.sh`.


### 5.5 Helper Utilities

These are invoked on-demand by CGI scripts via sudo, or interactively.

#### `qcmd`

**Location:** `/usr/bin/qcmd`
**Lock file:** `/tmp/qmanager_at.lock`
**Depends on:** `atcli_smd11` (Rust, ARMv7 static binary), flock

The single entry point for all modem AT communication. Serializes access to `/dev/smd11` via `flock`. Uses `atcli_smd11` which accesses the device directly (no PTY bridge, no socat).

```sh
qcmd "AT+COMMAND"      # Returns raw response
qcmd -j "AT+COMMAND"   # Returns JSON-wrapped response
```

`atcli_smd11` always exits 0. `qcmd` detects errors by scanning the response for `ERROR`. Long commands (`QSCAN`, `QSCANFREQ`, `QFOTADL`) get a longer lock wait (10s vs 5s).

**Lock pattern:** `( flock_wait 9 $TIMEOUT; atcli_smd11 "$CMD" ) 9<"$LOCK_FILE"`

See §11 for the `flock_wait` polling pattern.

#### `qmanager_set_ssh_password`

**Location:** `/usr/bin/qmanager_set_ssh_password`

Reads a new root password from stdin, hashes it with `openssl passwd -1`, and updates `/etc/shadow`. Called via `sudo -n` from `cgi_auth.sh`'s `qm_set_ssh_password()`. Invoked automatically during onboarding (syncs web UI password to root) and from System Settings.

#### `qmanager_set_timezone`

**Location:** `/usr/bin/qmanager_set_timezone`

Repoints `/etc/localtime` at a zoneinfo file. Called via `sudo -n` from `system_config.sh`'s `sys_set_timezone()` (invoked by `system/settings.sh`). `www-data` cannot do this itself: `/etc` is `root:root` 0755, so replacing a symlink there needs write permission on the directory, and the rootfs is read-only on a stock boot.

Behavior worth knowing:
- **Zone name validation** rejects `..`, absolute paths, and shell metacharacters by shape (`Area/Location`), since the argument arrives from an HTTP request and is used to build a path as root.
- **Zoneinfo lookup** tries `/usr/share/zoneinfo` first, then `/opt/usr/share/zoneinfo` (Entware) for devices where the installer's symlink is missing.
- **Read-only rootfs** is remounted rw only if a write probe fails; a genuine failure returns `etc_readonly` rather than succeeding silently.
- **Atomic swap** — the symlink is built as `/etc/.localtime.qm` and `mv`'d over `/etc/localtime`, because `ln -sf` is unlink-then-symlink and a crash between the two leaves no `/etc/localtime` at all (glibc then falls back to UTC).
- `/etc/TZ` is written to keep BusyBox applets in step. lighttpd is deliberately **not** restarted (it is serving the request that asked for the change); only its own log timestamps stay stale until its next restart.

Returns JSON on stdout; exit 0 = success, 1 = failure.

#### `qmanager_set_hostname`

**Location:** `/usr/bin/qmanager_set_hostname`

Applies a system hostname. Validates the argument as an RFC 1123 label (letters, digits and hyphens; no leading or trailing hyphen; 63 bytes max) before touching anything — the value originates in an HTTP request and is used by a root process, so it is checked by shape rather than escaped. Probes `/etc` for writability, remounts the rootfs rw if needed, writes `/etc/hostname` atomically (temp file + `mv -f`), then writes `/proc/sys/kernel/hostname`. Emits JSON; exits 0 on success, 1 with an `error` code otherwise.

Called via `sudo -n` from `system_config.sh`'s `sys_set_hostname()`. Restarts nothing: no daemon on this device caches the hostname, and restarting lighttpd would kill the CGI request that asked for the change.

#### `qmanager_reset_password`

**Location:** `/usr/bin/qmanager_reset_password`

Resets the QManager web UI password. Interactive utility; typically invoked via SSH.

#### `qmanager_logread`

**Location:** `/usr/bin/qmanager_logread`

Read and format log entries. Called via `sudo -n` from `system/logs.sh` CGI.

#### `qmanager_update`

**Location:** `/usr/bin/qmanager_update`

OTA update worker. See §12 for full pipeline description. Called via `sudo -n` from `system/update.sh` CGI. Runs as root; manages its own log at `/tmp/qmanager_update.log`.

#### `qmanager_health_check`

**Location:** `/usr/bin/qmanager_health_check`
**Status file:** `/tmp/qmanager_health_check.json`
**Lock file:** `/tmp/qmanager_health_check.lock`
**Log:** `/tmp/qmanager_health_check.log`

Privileged System Health Check runner. Probes binaries, AT transport, services, and sudoers rules — checks that need root, which is why the CGI cannot do them itself. Called via `sudo -n` from the `system/health-check/` CGI scripts (`run.sh`, `status.sh`, `clear.sh`, `download.sh`).

```sh
qmanager_health_check <job_id>   # Run a diagnostic job
qmanager_health_check --clear    # Delete previous run artifacts
```

Writes incremental status to the status file so the UI can poll progress mid-run. Per-test raw output goes to `/tmp/qmanager_health_check_<job_id>/tests/<test_id>.txt`, and on completion the run is bundled into `/tmp/qmanager_health_check_<job_id>.tar.gz` for download. `--clear` refuses to run while a job is still live (checked via the recorded PID).

#### `qmanager_ethernet_apply`

**Location:** `/usr/bin/qmanager_ethernet_apply`
**State file:** `/etc/qmanager/ethernet_speed`
**Depends on:** `/usr/sbin/ethtool`, `ethtool_helper.sh`

Applies the Ethernet link-speed limit on `eth0`. Called via `sudo -n` from `network/ethernet.sh` CGI.

```sh
qmanager_ethernet_apply auto|10|100|1000|2500
```

The limit is applied as an **advertise mask** with autoneg left on, not as a forced speed — the PHY negotiates the best mode within the mask, so a capped link still comes up cleanly against any partner. `auto` advertises everything the PHY reports as supported. After setting the mask the helper forces renegotiation (`ethtool -r`), then persists the value atomically (write `.tmp` + `mv`) so `qmanager-ethernet.service` can reapply it at boot. Returns JSON; exit 0 = success, 1 = invalid input or `ethtool` failure.

---

## 6. Systemd Services

**Boot persistence model:** Boot persistence uses direct symlinks in `/lib/systemd/system/multi-user.target.wants/`. `systemctl enable` does not work on RM520N-GL because unit files live on a partition where the `systemctl enable` mechanism cannot write. Use `svc_enable`/`svc_disable` from `platform.sh`.

**`UCI_GATED_SERVICES` pattern:** During upgrades, `install_rm520n.sh` only re-enables `qmanager-watchcat` and `qmanager-tower-failover` if their `multi-user.target.wants/` symlink existed before the upgrade. The variable is named `UCI_GATED_SERVICES` for historical reasons (RM551E had UCI-gated enables); on RM520N-GL the mechanism is purely symlink-presence detection with no UCI involvement.

| Service | Type | Binary | Description |
|---------|------|--------|-------------|
| `lighttpd.service` | simple | `/opt/sbin/lighttpd` | Entware lighttpd; uses `/usrdata/qmanager/lighttpd.conf`; after `opt.mount` |
| `qmanager-cfun-fix.service` | oneshot (RemainAfterExit) | `/usr/bin/qmanager_cfun_fix` | Boot-time radio recovery; `ExecStartPre` waits up to 30 s for `/dev/smd11`; after setup, before poller |
| `qmanager-ethernet.service` | oneshot (RemainAfterExit) | `/usr/bin/qmanager_ethernet_apply` | Reapplies the saved `eth0` speed limit at boot; `ConditionPathExists=/etc/qmanager/ethernet_speed` |
| `qmanager-firewall.service` | oneshot | `/usr/bin/qmanager_firewall` | Port firewall; runs before setup and lighttpd |
| `qmanager-imei-check.service` | oneshot | `/usr/bin/qmanager_imei_check` | Post-boot IMEI restore; skipped via `ExecCondition` unless the pending marker and backup both exist and the backup is `enabled` |
| `qmanager-mtu.service` | simple | `/usr/bin/qmanager_mtu_apply` | MTU persistence; `ConditionPathExists=/etc/firewall.user.mtu` |
| `qmanager-ping.service` | simple | `/usr/bin/qmanager_ping` | Ping daemon; required by poller |
| `qmanager-poller.service` | simple | `/usr/bin/qmanager_poller` | Main data poller; guards `/dev/smd11` in `ExecStartPre`; sources Data Used (schema v4, with per-boot orientation detection) from `/proc/net/dev` at the 2 s Tier 1 cadence |
| `qmanager-setup.service` | oneshot (RemainAfterExit) | `/usr/bin/qmanager_setup` | Permission setup; before ping and poller |
| `qmanager-tower-failover.service` | simple | `/usr/bin/qmanager_tower_failover` | Tower lock failover; skipped via `ExecCondition` unless `tower_lock.json` has failover plus an LTE or NR-SA lock enabled |
| `qmanager-ttl.service` | oneshot (RemainAfterExit) | inline sh | TTL/HL rule persistence; `ConditionPathExists=/etc/qmanager/ttl_state` |
| `qmanager-watchcat.service` | simple | `/usr/bin/qmanager_watchcat` | Connection watchdog; skipped via `ExecCondition` unless `qm_config_get watchcat enabled` is `1` |

**Service ordering:** `qmanager-firewall` -> `qmanager-setup` -> `qmanager-ping` -> `qmanager-poller` -> `qmanager-watchcat`.

**Start gating -- `Condition*` vs `ExecCondition` vs `ExecStartPre`:** Most QManager units are for optional features, so on a given device they should frequently do *nothing*. Doing nothing must mean **skip**, not **fail**: a failing `ExecStartPre` marks the unit `failed`, so an entirely healthy boot ends with red entries in `systemctl --failed`, and on a unit that also sets `Restart=on-failure` (watchcat) systemd retries the guaranteed-to-fail start until `StartLimitBurst` is exhausted. Pick the gate in this order:

- **`Condition*` in `[Unit]`** -- a plain file or executable test (`qmanager-ethernet`, `qmanager-mtu`, `qmanager-ttl`). These directives are only honoured in the `[Unit]` section; put them under `[Service]` and systemd silently ignores them, so the unit runs unconditionally and `ExecStart` fails on every device where the feature is off.
- **`ExecCondition`** -- when the test needs real logic: several checks that must *all* hold, or a `jq`/config lookup (`qmanager-imei-check`, `qmanager-tower-failover`, `qmanager-watchcat`). systemd reads an `ExecCondition` exit of 1-254 as "skip this unit quietly" and only 255-or-signal as an error. Repeated `Condition*` lines of the same type are ORed together, which is exactly why the multi-check units cannot express their guard with `Condition*` and need a script. Needs systemd >= 243; this platform ships 244.
- **`ExecStartPre`** -- only for work that genuinely has to run before `ExecStart` and where failing *is* the correct outcome: the `/dev/smd11` wait loops in `qmanager-cfun-fix` and `qmanager-poller` (no AT device means the daemon truly cannot run) and the `sleep 5` settle delay in `qmanager-ttl`.

---

## 7. Sudoers Rules

File deployed to `/etc/sudoers.d/qmanager` (and `/opt/etc/sudoers.d/qmanager` for Entware sudo).

```
# QManager -- sudoers rules for CGI scripts (lighttpd runs as www-data)
# Install location: /opt/etc/sudoers.d/qmanager (Entware) or /etc/sudoers.d/qmanager

# Service control (used by platform.sh svc_* functions)
www-data ALL=(root) NOPASSWD: /bin/systemctl start *, /bin/systemctl stop *, /bin/systemctl restart *, /bin/systemctl is-active *

# Boot persistence (symlink-based -- systemctl enable doesn't work on RM520N-GL)
www-data ALL=(root) NOPASSWD: /bin/ln -sf /lib/systemd/system/qmanager*.service /lib/systemd/system/multi-user.target.wants/qmanager*.service
www-data ALL=(root) NOPASSWD: /bin/rm -f /lib/systemd/system/multi-user.target.wants/qmanager*.service

# Firewall rules (used by TTL, VPN firewall)
www-data ALL=(root) NOPASSWD: /usr/sbin/iptables, /usr/sbin/iptables-restore, /usr/sbin/ip6tables, /usr/sbin/ip6tables-restore

# System reboot (used by system/reboot.sh, update installer)
www-data ALL=(root) NOPASSWD: /sbin/reboot

# Crontab management (used by scheduled reboot, low power, auto-update)
www-data ALL=(root) NOPASSWD: /usr/bin/crontab

# SSH password management (reads password from stdin, updates /etc/shadow)
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_set_ssh_password

# Timezone (repoints /etc/localtime -- /etc is root:root 0755, so www-data
# cannot replace a symlink there itself). The helper validates the zone name
# before using it in a path.
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_set_timezone

# Hostname (writes /proc/sys/kernel/hostname and /etc/hostname -- both root-only,
# and remounting a read-only rootfs has no grant of its own). The helper
# validates the name against RFC 1123 before writing it anywhere.
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_set_hostname

# OTA updater (download/stage/install/rollback -- needs full root for install.sh)
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_update

# System Health Check (privileged runner that probes binaries, AT, services, sudoers)
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_health_check

# Ethernet link speed limit management
www-data ALL=(root) NOPASSWD: /usr/bin/qmanager_ethernet_apply

# Custom DNS management (dnsmasq config atomic swap + reload)
# Note: chown's "radio:radio" argument has the colon backslash-escaped because
# sudoers treats ':' as the user:group separator in any token unless escaped.
www-data ALL=(root) NOPASSWD: /bin/mv /etc/data/qmanager/dnsmasq.conf.new /etc/data/dnsmasq.conf
www-data ALL=(root) NOPASSWD: /bin/chown radio\:radio /etc/data/dnsmasq.conf
www-data ALL=(root) NOPASSWD: /usr/bin/killall -HUP dnsmasq
```

**Rule annotations:**

| Rule | Used by |
|------|---------|
| `systemctl start/stop/restart/is-active *` | `platform.sh` `svc_start`, `svc_stop`, `svc_restart`, `svc_is_running`; all CGI scripts that control services |
| `ln -sf qmanager*.service` / `rm -f qmanager*.service` | `platform.sh` `svc_enable`/`svc_disable`; `tower/settings.sh`, `monitoring/watchdog.sh` |
| `iptables*`, `ip6tables*`, `*-restore` | `platform.sh` `run_iptables`/`run_ip6tables`; `network/ttl.sh`, `qmanager_firewall` |
| `/sbin/reboot` | `cgi_base.sh` `cgi_reboot_response`; `system/reboot.sh`; `qmanager_update` |
| `/usr/bin/crontab` | Crontab management for scheduled reboot and auto-update entries |
| `qmanager_set_ssh_password` | `cgi_auth.sh` `qm_set_ssh_password`; `auth/ssh_password.sh` |
| `qmanager_set_timezone` | `system_config.sh` `sys_set_timezone`; `system/settings.sh` (timezone picker) |
| `qmanager_set_hostname` | `system_config.sh` `sys_set_hostname`; reached from `system/settings.sh` (`save_settings`) |
| `qmanager_update` | `system/update.sh` (OTA update; added in v0.1.5 -- previously required ADB/SSH) |
| `qmanager_health_check` | `system/health-check/run.sh`, `status.sh`, `clear.sh`, `download.sh` |
| `qmanager_ethernet_apply` | `network/ethernet.sh` (link speed limit) |
| `mv .../dnsmasq.conf.new`, `chown radio:radio`, `killall -HUP dnsmasq` | `network/custom_dns.sh` (atomic config swap + dnsmasq reload) |

**Security note:** All rules use full absolute paths. sudo's `secure_path` is overridden by Entware's sudo configuration, but absolute paths in rules are immune to PATH injection regardless.

---

## 8. udev Rules

### Rule file: `/etc/udev/rules.d/99-qmanager-smd11.rules`

```
KERNEL=="smd11", ACTION=="add", RUN+="/usr/lib/qmanager/qmanager_smd11_udev.sh"
```

**Purpose:** `/dev/smd11` defaults to `crw------- root:root` on boot. `www-data` (member of the `dialout` group) needs read/write access to run AT commands via `atcli_smd11`. This rule fires on every kernel `add` event for `smd11` and runs the helper which sets `chmod 660` + `chown root:dialout`.

**Why no `SUBSYSTEM==` filter:** The subsystem name for `smd11` is `glinkpkt` on RM520N-GL (sysfs path: `/sys/class/glinkpkt/smd11`) but differs on PRAIRE-derived platforms (RG502Q/RM502Q). `KERNEL=="smd11"` is already highly specific to Qualcomm SMD naming convention. Omitting `SUBSYSTEM==` makes the rule portable across platforms without verification.

**Why `99-` prefix:** Ensures this rule runs after OEM/vendor `data_udev_rules.rules`, overriding any permissions they set.

**Why `ACTION=="add"` only:** Prevents redundant firing on `change` and `remove` events.

### Helper script: `/usr/lib/qmanager/qmanager_smd11_udev.sh`

Runs in udev's minimal environment (no PATH, no controlling tty). Sets `PATH` explicitly. Checks `[ -c "$DEVICE" ]` before attempting chown/chmod. Always exits 0 to prevent udev log spam on race conditions. Source path: `scripts/etc/udev/scripts/qmanager_smd11_udev.sh`.

### Fallback: `qmanager_setup`

`qmanager_setup` runs the same `chown root:dialout /dev/smd11` + `chmod 660 /dev/smd11` at boot as a belt-and-suspenders fallback. This covers the case where:
- The udev rule has not yet been loaded (fresh install before `udevadm control --reload-rules`)
- The device was created before udev started
- PRAIRE-derived platforms where the modem recreates `/dev/smd11` after `qmanager-setup.service` completes

Both the udev helper and `qmanager_setup` are idempotent.

---

## 9. CGI Endpoint Reference

### Standard CGI Pattern

Every CGI script (except auth endpoints) follows this boilerplate:

```sh
#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh   # enforces auth automatically
qlog_init "cgi_<name>"
cgi_headers
cgi_handle_options

case "$REQUEST_METHOD" in
    GET)
        # ... read data, emit JSON
        ;;
    POST)
        cgi_read_post
        # ... process $POST_DATA
        ;;
    *)
        cgi_method_not_allowed
        ;;
esac
```

For auth endpoints that must skip authentication:

```sh
#!/bin/sh
_SKIP_AUTH=1              # MUST be set before sourcing cgi_base.sh
. /usr/lib/qmanager/cgi_base.sh
```

Authentication is automatically enforced by `cgi_base.sh` unless `_SKIP_AUTH=1` is set. CGI scripts never check auth manually.

For request/response schemas, see `API-REFERENCE.md`.

### Category Tables

#### `auth/` (5 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `auth/check.sh` | GET | Check current session validity; `_SKIP_AUTH=1` |
| `auth/login.sh` | POST | Validate password, create session; `_SKIP_AUTH=1` |
| `auth/logout.sh` | POST | Destroy session; `_SKIP_AUTH=1` |
| `auth/password.sh` | POST | Change web UI password (and SSH password via `qm_set_ssh_password`) |
| `auth/ssh_password.sh` | POST | Change root SSH password only |

#### `at_cmd/` (14 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `at_cmd/cell_scan_start.sh` | POST | Spawn `qmanager_cell_scanner`; return PID |
| `at_cmd/cell_scan_status.sh` | GET | Poll cell scan progress and results |
| `at_cmd/fetch_data.sh` | GET | Return current poller status cache (`qmanager_status.json`) |
| `at_cmd/fetch_events.sh` | GET | Return recent events as JSON array |
| `at_cmd/fetch_ping_history.sh` | GET | Return ping history data for latency chart |
| `at_cmd/fetch_signal_history.sh` | GET | Return signal history data for RSRP/SINR chart |
| `at_cmd/neighbour_scan_start.sh` | POST | Spawn `qmanager_neighbour_scanner`; return PID |
| `at_cmd/neighbour_scan_status.sh` | GET | Poll neighbour scan progress and results |
| `at_cmd/send_command.sh` | POST | Send arbitrary AT command via `qcmd`; returns raw response |
| `at_cmd/speedtest_check.sh` | GET | Check if Ookla speedtest CLI is installed |
| `at_cmd/speedtest_servers.sh` | GET | List nearest speedtest servers |
| `at_cmd/speedtest_start.sh` | POST | Start a speedtest; return PID |
| `at_cmd/speedtest_status.sh` | GET | Poll speedtest progress and results |

#### `bands/` (4 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `bands/current.sh` | GET | Read current locked bands from modem |
| `bands/failover_status.sh` | GET | Check band failover daemon status |
| `bands/failover_toggle.sh` | POST | Start or stop `qmanager_band_failover` |
| `bands/lock.sh` | POST | Apply LTE/NR band lock via `AT+QNWPREFCFG` |

#### `cellular/` (7 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `cellular/apn.sh` | GET/POST | WAN Profile Management — list/save/toggle 6 PDP contexts (AT-only). See `docs/reference/wan-profile-management.md` |
| `cellular/fplmn.sh` | GET/POST | Read or manage FPLMN (forbidden PLMN) list |
| `cellular/imei.sh` | GET/POST | Read or change IMEI (`AT+EGMR`) |
| `cellular/mbn.sh` | GET/POST | Read or select MBN profile |
| `cellular/network_priority.sh` | GET/POST | Read or set network mode priority (`AT+QNWPREFCFG`) |
| `cellular/settings.sh` | GET/POST | Combined cellular settings (network search mode, etc.) |
| `cellular/sms.sh` | GET/POST/DELETE | SMS center: list, read, send, delete messages via `sms_tool` |

`cellular/sms.sh` uses the same `/tmp/qmanager_at.lock` lock as `qcmd` and `sms_alerts.sh` to prevent concurrent `/dev/smd11` access.

#### `device/` (1 script)

| Script | Method | Description |
|--------|--------|-------------|
| `device/about.sh` | GET | Device info: model, firmware, IMEI, ICCID, uptime, QManager version |

#### `frequency/` (2 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `frequency/lock.sh` | POST | Apply EARFCN/ARFCN frequency lock |
| `frequency/status.sh` | GET | Read current frequency lock state |

#### `monitoring/` (5 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `monitoring/email_alert_log.sh` | GET | Return email alert history (NDJSON -> JSON array) |
| `monitoring/email_alerts.sh` | GET/POST | Read or write email alert config; POST test send |
| `monitoring/sms_alert_log.sh` | GET | Return SMS alert history (NDJSON -> JSON array) |
| `monitoring/sms_alerts.sh` | GET/POST | Read or write SMS alert config; POST test send |
| `monitoring/watchdog.sh` | GET/POST | Read or write watchcat config; start/stop watchcat service |

#### `network/` (7 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `network/custom_dns.sh` | GET/POST | Read or write dnsmasq upstream DNS override via sentinel block in `/etc/data/dnsmasq.conf`. See `docs/reference/custom-dns.md` |
| `network/data_used.sh` | GET | Return `.data_used` block from poller status cache with stale flag; polled at 2 Hz by `useDataUsed` |
| `network/data_used_reset.sh` | POST | Write reset flag consumed by poller on next tick; counter drops to ~0 within 4–5 s |
| `network/ethernet.sh` | GET/POST | Read RTL8125B link state (sysfs + `ethtool`) and apply speed limit via `qmanager_ethernet_apply` root helper; uses `ethtool_helper.sh` |
| `network/ip_passthrough.sh` | GET/POST | Read or configure IP passthrough (`AT+QMAP`, `AT+QCFG="usbnet"`) |
| `network/mtu.sh` | GET/POST | Read or write custom MTU setting |
| `network/ttl.sh` | GET/POST | Read or write TTL/HL override rules via `ttl_state.sh` |

#### `profiles/` (8 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `profiles/apply.sh` | POST | Spawn `qmanager_profile_apply` for a profile ID |
| `profiles/apply_status.sh` | GET | Poll apply progress from `qmanager_profile_state.json` |
| `profiles/current_settings.sh` | GET | Read current modem settings (APN, IMEI, TTL) for comparison |
| `profiles/deactivate.sh` | POST | Clear active profile marker |
| `profiles/delete.sh` | POST | Delete a profile by ID |
| `profiles/get.sh` | GET | Return full profile JSON for a profile ID |
| `profiles/list.sh` | GET | Return profile list with active profile marker |
| `profiles/save.sh` | POST | Create or update a profile |

#### `scenarios/` (5 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `scenarios/activate.sh` | POST | Apply a connection scenario (band lock + network mode). Returns `profile_managed` error without touching the modem if the active SIM profile binds a non-Balanced scenario via `settings.scenario_id` (defense-in-depth for stale frontends). A `"balanced"` binding is allowed through — Balanced is treated as "no opinion" both on the UI gates and at this guard. |
| `scenarios/active.sh` | GET | Return currently active scenario ID |
| `scenarios/delete.sh` | POST | Delete a scenario |
| `scenarios/list.sh` | GET | Return all saved scenarios |
| `scenarios/save.sh` | POST | Create or update a scenario |

#### `system/` (5 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `system/logs.sh` | GET | Return QManager log file contents |
| `system/modem-subsys.sh` | GET | Return modem subsystem health (state, crash count, coredump flag) by reshaping the `system_health` block from the poller status cache; thin `jq` extractor — never re-computes live data |
| `system/reboot.sh` | POST | Initiate system reboot via `cgi_reboot_response` |
| `system/settings.sh` | GET/POST | Read or write system settings (hostname, timezone, temperature/distance units, scheduled reboot) |
| `system/update.sh` | GET/POST | OTA update: check version, download, install, rollback; spawns `qmanager_update` via sudo |

#### `tower/` (5 scripts)

| Script | Method | Description |
|--------|--------|-------------|
| `tower/failover_status.sh` | GET | Return tower failover daemon status and current signal quality |
| `tower/lock.sh` | POST | Apply or clear LTE/NR-SA tower lock via `tower_lock_mgr.sh` |
| `tower/schedule.sh` | POST | Enable, disable, or update tower lock schedule |
| `tower/settings.sh` | GET/POST | Read or write tower lock config (all sections) |
| `tower/status.sh` | GET | Return current lock state from modem + config |

#### `vpn/` (1 script)

| Script | Method | Description |
|--------|--------|-------------|
| `vpn/tailscale.sh` | GET/POST | Tailscale VPN: install, uninstall, status, `tailscale up` |

**Total: 69 CGI scripts.**

---

## 10. File Locations on Device

### Temporary State (`/tmp/`)

Cleared on every reboot (tmpfs). Files pre-created by `qmanager_setup` are marked with (S).

| Path | Owner | Created by | Description |
|------|-------|------------|-------------|
| `/tmp/qmanager_at.lock` (S) | www-data | qmanager_setup | Shared flock file for `/dev/smd11` serialization |
| `/tmp/qmanager_at.pid` (S) | www-data | qmanager_setup | AT command PID tracking |
| `/tmp/qmanager.log` (S) | root | qmanager_setup | Main QManager log (all components) |
| `/tmp/qmanager_status.json` | root | qmanager_poller | Main modem status cache; polled by frontend |
| `/tmp/qmanager_ping.json` | root | qmanager_ping | Current ping state (available, latency, streaks) |
| `/tmp/qmanager_ping_history` | root | qmanager_ping | Raw latency history (flat ring buffer) |
| `/tmp/qmanager_signal_history.json` | root | qmanager_poller | Signal history NDJSON for chart |
| `/tmp/qmanager_events.json` | root | qmanager_poller / qmanager_watchcat | Recent activity events NDJSON |
| `/tmp/qmanager_pci_state.json` | root | qmanager_poller | SCC PCI state for handoff detection |
| `/tmp/qmanager_watchcat.json` | root | qmanager_watchcat | Watchcat state (mode, tier, recoveries) |
| `/tmp/qmanager_watchcat.pid` | root | qmanager_watchcat | Watchcat process PID |
| `/tmp/qmanager_watchcat.lock` | root | qmanager_watchcat / update worker | Maintenance lock; forces watchcat into LOCKED state |
| `/tmp/qmanager_watchcat_reload` | root | CGI | Flag: watchcat should reload config |
| `/tmp/qmanager_recovery_active` | root | qmanager_watchcat | Flag: recovery action in progress |
| `/tmp/qmanager_sim_failover` | root | qmanager_watchcat | Flag: SIM failover occurred (Tier 3) |
| `/tmp/qmanager_profile_state.json` (S) | www-data | qmanager_setup | Profile apply progress state |
| `/tmp/qmanager_profile_apply.pid` (S) | www-data | qmanager_setup | Profile apply PID |
| `/tmp/qmanager_sessions/` | www-data | qmanager_setup | Session token directory (mode 700) |
| `/tmp/qmanager_auth_attempts.json` | www-data | cgi_auth.sh | Login rate limiting state |
| `/tmp/qmanager_cell_scan.json` | root | qmanager_cell_scanner | Cell scan results |
| `/tmp/qmanager_cell_scan.pid` | root | qmanager_cell_scanner | Cell scanner PID |
| `/tmp/qmanager_neighbour_scan.json` | root | qmanager_neighbour_scanner | Neighbour scan results |
| `/tmp/qmanager_neighbour_scan.pid` | root | qmanager_neighbour_scanner | Neighbour scanner PID |
| `/tmp/qmanager_tower_failover.json` | root | qmanager_tower_failover | Failover daemon state |
| `/tmp/qmanager_tower_failover.pid` | root | qmanager_tower_failover | Failover daemon PID |
| `/tmp/qmanager_tower_failover` | root | qmanager_tower_failover | Failover active flag |
| `/tmp/qmanager_email_log.json` | root | email_alerts.sh | Email alert history NDJSON (max 100) |
| `/tmp/qmanager_email_reload` | www-data | monitoring/email_alerts.sh | Reload flag for email config |
| `/tmp/qmanager_sms_log.json` | root | sms_alerts.sh | SMS alert history NDJSON (max 100) |
| `/tmp/qmanager_sms_reload` | www-data | monitoring/sms_alerts.sh | Reload flag for SMS config |
| `/tmp/qmanager_update.json` | root | qmanager_update | OTA update status (idle/downloading/verifying/ready/installing/rebooting/error) |
| `/tmp/qmanager_update.pid` | root | qmanager_update | Update worker PID |
| `/tmp/qmanager_update.log` | root | qmanager_update | Update worker log |
| `/tmp/qmanager_install.log` | root | qmanager_update | Step-streaming install log (polled by worker) |
| `/tmp/qmanager_staged.tar.gz` | root | qmanager_update (download mode) | Staged update tarball |
| `/tmp/qmanager_staged_version` | root | qmanager_update (download mode) | Staged version string |
| `/tmp/qmanager_long_running` | root | qmanager_poller | Flag: long AT command in progress |
| `/tmp/qmanager_cc_data.tmp` | root | parse_at.sh | Carrier component parse scratch file |
| `/tmp/qmanager_ca_parse.tmp` | root | parse_at.sh | CA parse scratch file |
| `/tmp/qmanager_mtu_reapply.pid` | root | tower_lock_mgr.sh | MTU re-apply watcher PID |
| `/tmp/msmtp_last_err.log` | root | email_alerts.sh | Last msmtp error output |

### Persistent Configuration (`/etc/qmanager/`)

Lives on the rootfs (read-only by default). `qmanager_setup` calls `mount -o remount,rw /` before writing. `/etc/qmanager/` is owned by `www-data` for CGI write access.

| Path | Description |
|------|-------------|
| `/etc/qmanager/auth.json` | Password hash + salt (mode 600) |
| `/etc/qmanager/qmanager.conf` | Main JSON config (watchcat, settings, update sections) |
| `/etc/qmanager/VERSION` | Current installed version string (e.g., `v0.1.5`) |
| `/etc/qmanager/VERSION.pending` | Written at install preflight; `mv`'d to VERSION on success; stale file indicates a crash |
| `/etc/qmanager/updates/previous_version` | Previous version string for rollback support |
| `/etc/qmanager/active_profile` | Active profile ID (plain text) |
| `/etc/qmanager/profiles/` | Profile JSON files (`p_<ts>_<hex>.json`) |
| `/etc/qmanager/active_scenario` | Active scenario ID (plain text) — written by `scenario_set_active` |
| `/etc/qmanager/scenarios/` | Custom scenario JSON files (`custom-<ts>.json`) |
| `/etc/qmanager/tower_lock.json` | Tower lock config (lte, nr_sa, persist, failover, schedule) |
| `/etc/qmanager/email_alerts.json` | Email alert config (enabled, sender, recipient, threshold) |
| `/etc/qmanager/msmtprc` | msmtp config (generated on save; no `logfile` directive) |
| `/etc/qmanager/sms_alerts.json` | SMS alert config (enabled, recipient_phone, threshold) |
| `/etc/qmanager/imei_backup.json` | IMEI backup for rejection check restore |
| `/etc/qmanager/imei_check_pending` | Marker: IMEI restore pending after next boot |
| `/etc/qmanager/ttl_state` | TTL/HL values (`TTL=N\nHL=N`); absent = no rules |
| `/etc/firewall.user.mtu` | MTU setting script (sourced by `qmanager_mtu.service`) |
| `/etc/qmanager/long_commands.list` | List of AT commands treated as long (one per line) |
| `/etc/qmanager/crash.log` | Watchcat Tier-4 reboot log |
| `/etc/qmanager/environment` | Optional environment overrides for systemd units (e.g., `QLOG_LEVEL=DEBUG`) |

### Other Paths

| Path | Description |
|------|-------------|
| `/usr/bin/qcmd` | AT command gatekeeper |
| `/usr/bin/atcli_smd11` | AT CLI binary (Rust, ARMv7 static, ~647KB, do NOT UPX-compress) |
| `/usr/bin/sms_tool` | SMS send/receive binary (ARMv7) |
| `/usr/bin/qmanager_*` | All daemon and utility scripts |
| `/usr/lib/qmanager/` | All shared library scripts |
| `/lib/systemd/system/qmanager-*.service` | Systemd unit files |
| `/lib/systemd/system/multi-user.target.wants/` | Boot-persistence symlinks |
| `/etc/udev/rules.d/99-qmanager-smd11.rules` | udev rule for `/dev/smd11` |
| `/usr/lib/qmanager/qmanager_smd11_udev.sh` | udev helper script |
| `/etc/sudoers.d/qmanager` | Sudoers rules (also `/opt/etc/sudoers.d/qmanager`) |
| `/usrdata/qmanager/` | Web root, lighttpd config, TLS certs, console binary |
| `/usrdata/qmanager/lighttpd.conf` | lighttpd configuration |
| `/usrdata/qmanager/www/` | Web root (frontend assets + CGI scripts) |
| `/usrdata/qmanager/certs/` | TLS certificate and key |
| `/usrdata/qmanager/console/ttyd` | Web terminal binary |
| `/usrdata/qmanager/console/console.sh` | Shell startup script (sets PATH for Entware tools) |
| `/usrdata/tailscale/` | Tailscale binaries and state (on-demand install) |
| `/usrdata/root/bin/tailscale` | Tailscale CLI symlink (rgmii-toolkit convention) |
| `/usr/bin/tailscale` | Tailscale CLI symlink (QManager root shell convention) |
| `/usr/bin/jq` | Symlink to `/opt/bin/jq` (installed by installer for CGI PATH) |

---

## 11. Locking & Concurrency Conventions

### `/tmp/qmanager_at.lock` -- AT Device Serialization

All processes that access `/dev/smd11` share this lock. Holders:
- `qcmd` (for all AT commands from the poller, CGI scripts, and daemons)
- `sms_tool` invocations in `sms_alerts.sh` (via `_sa_sms_locked()`)
- `sms_tool` invocations in `cellular/sms.sh` (via `sms_locked()`)

**Lock pattern (BusyBox `flock` lacks `-w`):**

```sh
# BusyBox flock lacks -w (timeout flag). Poll with -x -n in a loop.
flock_wait() {
    _fd="$1"; _wait="$2"; _elapsed=0
    while [ "$_elapsed" -lt "$_wait" ]; do
        flock -x -n "$_fd" 2>/dev/null && return 0
        sleep 1
        _elapsed=$((_elapsed + 1))
    done
    flock -x -n "$_fd" 2>/dev/null   # one final try
}

# Usage with FD 9 (read-only to satisfy fs.protected_regular=1):
( flock_wait 9 5 || exit 2; atcli_smd11 "$CMD" ) 9<"$LOCK_FILE"
```

**Why `9<` (read-only FD):** `fs.protected_regular=1` blocks `open()` for write on files owned by other users in sticky `/tmp`. Using `<` (read-only) instead of `<>` (read-write) avoids this restriction while still providing a valid file descriptor for flock.

### `/tmp/qmanager_watchcat.lock` -- Maintenance Lock

A plain file (not a flock file). When this file exists, watchcat enters LOCKED state and suspends all recovery actions. Created by:
- `qmanager_update` (during OTA install)
- `install_rm520n.sh` (during installer run)

Cleaned up by watchcat's `ExecStopPost` and by `rm -f` in the update worker's EXIT trap.

### PID File Singleton Pattern

Long-running on-demand daemons use a PID file to prevent concurrent instances:

```sh
# Write PID at startup
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT INT TERM

# Check before spawning (from CGI or library)
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE" 2>/dev/null)
    if pid_alive "$pid"; then
        # Already running
        exit 0
    fi
    rm -f "$PID_FILE"   # stale PID
fi
```

`pid_alive` checks `/proc/$pid` rather than `kill -0` because CGI (www-data) cannot send signals to root-owned daemon processes.

### Atomic JSON Write

All status/config files written with:

```sh
jq -n '...' > "${FILE}.tmp" && mv "${FILE}.tmp" "$FILE"
```

Never truncate-in-place. The `tmp + mv` ensures readers always see either the old complete file or the new complete file, never a partial write.

---

## 12. Update Pipeline

See `DEPLOYMENT.md` for the operational flow (what a user does). This section documents the worker's internal behaviour.

### Worker: `qmanager_update`

Spawned by `system/update.sh` CGI via `sudo -n /usr/bin/qmanager_update <mode> [args]`. The CGI's spawn line redirects to `/dev/null`; the worker manages its own log as root.

#### Modes

| Mode | Arguments | Description |
|------|-----------|-------------|
| `install` | `<url> <version> [size]` | Download, verify, install, reboot in one step |
| `download` | `<url> <checksum_url> <version>` | Download and verify only; stage at `/tmp/qmanager_staged.tar.gz` |
| `install_staged` | (none) | Install a previously downloaded staged tarball |
| `rollback` | `<url> <version>` | Download and install a prior release; strict URL validation |

#### Status State Machine

```
idle -> downloading -> verifying -> ready        (download mode -- stops here)
idle -> downloading -> verifying -> installing -> rebooting
idle ->                             installing -> rebooting   (install_staged mode)
any  -> error                                                 (on failure)
```

Status written atomically to `/tmp/qmanager_update.json` via `write_status()`:

```json
{"status": "installing", "message": "Copying files", "version": "v0.1.5", "size": ""}
```

#### URL Validation

`validate_url()` enforces a GitHub origin whitelist:
- `https://github.com/tuanlongsav/QManager-VN/releases/download/*/qmanager.tar.gz` -- allowed in all modes
- `https://github.com/tuanlongsav/QManager-VN/raw/*/qmanager-build/qmanager.tar.gz` -- allowed in `install` mode only (not strict mode)

Rollback and download modes use `validate_url "$URL" "strict"` to permit only the releases path.

#### SHA-256 Verification

`download` mode downloads a checksum file and compares with `sha256sum`. Non-fatal if the checksum URL returns 404 or if `sha256sum` is unavailable.

#### Two-Phase VERSION Write

Prevents silent version mismatches when the installer crashes mid-flight:

1. `install_rm520n.sh` writes `/etc/qmanager/VERSION.pending` at the start of its preflight step.
2. On successful completion, it `mv`s `VERSION.pending` -> `VERSION`.
3. `post_install_check()` in `qmanager_update` verifies `VERSION.pending` does not exist and that `VERSION` matches the expected value. A stale `VERSION.pending` is treated as a crash indicator.

#### Step-Streaming Progress

Contract between the installer and the worker:

- **Installer:** `step()` function writes `=== Step N/M: <label> ===` lines to `/tmp/qmanager_install.log` via stdout redirect.
- **Worker:** `run_install_with_progress()` polls `/tmp/qmanager_install.log` every 2 seconds with `grep '=== Step '| tail -1`, parses the label via `sed`, and calls `write_status "installing" "<label>"`.
- **UI:** polls `/tmp/qmanager_update.json` for status changes.

#### Watchcat Lock During Install

`qmanager_update` stops `qmanager-watchcat` via `svc_stop` before downloading. Additionally, the installer touches `/tmp/qmanager_watchcat.lock` as belt-and-suspenders to prevent watchcat from performing a Tier-4 reboot mid-install if watchcat was restarted by systemd during the operation.

#### Rollback Support

Before every install, `qmanager_update` writes the current version to `/etc/qmanager/updates/previous_version`. The CGI's rollback action reads this file to determine the URL for the previous release.

For more detail on the CGI request/response schemas, see `API-REFERENCE.md`.

---

## 13. Development Guidelines

### Adding a New CGI Endpoint

1. Create `scripts/www/cgi-bin/quecmanager/<category>/<name>.sh`.
2. Boilerplate:
   ```sh
   #!/bin/sh
   . /usr/lib/qmanager/cgi_base.sh
   qlog_init "cgi_<name>"
   cgi_headers
   cgi_handle_options
   case "$REQUEST_METHOD" in
       GET)  ... ;;
       POST) cgi_read_post; ... ;;
       *)    cgi_method_not_allowed ;;
   esac
   ```
3. Use `qcmd` for all AT commands. Never access `/dev/smd11` directly.
4. Use `jq` for all JSON construction. Never hand-build JSON strings.
5. Use `cgi_error` / `cgi_success` for response consistency.
6. Ensure LF line endings. Run `bash -n <script>` to syntax-check.
7. If the endpoint needs privileged operations, add a sudoers rule (see §7) and call the privileged binary via `$_SUDO /usr/bin/<helper>`.

### Adding a New Daemon

1. Create `scripts/usr/bin/qmanager_<name>`.
2. Source `qlog.sh` and call `qlog_init "<name>"` at startup.
3. Create `scripts/etc/systemd/system/qmanager-<name>.service`.
4. The installer's `enable_services()` function scans for service files and enables them automatically -- no installer edits needed.
5. If the daemon needs a PID file, use the PID file singleton pattern from §11.
6. If the daemon writes to `/tmp`, pre-create shared files in `qmanager_setup` with the correct owner and mode.

### Adding a New Sudoers Rule

When a CGI script needs to call a privileged binary:
1. Add `www-data ALL=(root) NOPASSWD: /full/absolute/path/to/binary [fixed_args]` to `scripts/etc/sudoers.d/qmanager`.
2. If the command takes variable arguments that cannot be narrowed, use the wildcard form (e.g., `/bin/systemctl start *`).
3. Prefer narrowing with fixed arguments where possible to limit the attack surface.
4. Do not use `sudo -i` or `sudo -s`; use `sudo -n /full/path` with explicit args.

### JSON Response Conventions

- Success: `{"success": true, ...additional fields}`
- Error: `{"success": false, "error": "<code>", "detail": "<human message>"}`
- Error codes are short snake_case identifiers (e.g., `validation_failed`, `not_found`, `modem_busy`).
- Never return HTTP error status codes; always return 200 with a JSON body.

### Logging Levels

| Level | Use for |
|-------|---------|
| DEBUG | AT commands, lock events, detailed flow tracing |
| INFO | Normal operations, state transitions, config changes |
| WARN | Unexpected state that is handled (stale PID, missing optional file) |
| ERROR | Failures that affect functionality (AT command failed, write failed) |

### Testing Locally

```sh
# POSIX syntax check
sh -n scripts/usr/lib/qmanager/config.sh

# Bash syntax check
bash -n scripts/usr/bin/qmanager_poller

# Check for CRLF
file scripts/usr/bin/qmanager_setup
# should say: "... shell script, ASCII text executable"
# NOT: "... CRLF line terminators"
```

---

## 14. Common Pitfalls

**jq `//` treats `false` as absent.** `jq -r '.enabled // "false"'` returns `"false"` even when `.enabled` is explicitly `false` in JSON. Use `if . == null then "false" else tostring end` for boolean fields. This pattern appears throughout the codebase and is documented in `config.sh` and `tower_lock_mgr.sh`.

**`fs.protected_regular=1` log-truncation failures.** If a CGI script (www-data) creates a `/tmp` file and a root daemon later tries to truncate it (e.g., `: > "$LOG_FILE"`), the kernel blocks the open. Fix: use `rm -f` before creating the file (as in `qmanager_update`), or pre-create the file with the right owner in `qmanager_setup`.

**CRLF in Windows-edited files.** `.gitattributes` sets `eol=lf` for `.sh`, `.service`, and sudoers files. If you edit with a Windows tool that bypasses git's filter, CRLF will silently break script parsing and sudoers. Check with `file <script>` before committing. The installer's `sed -i 's/\r$//'` pass catches this on deploy but the source should always be clean.

**Forgetting `sudo -n` in CGI invocations.** CGI runs as www-data. Any call to a root-required binary (iptables, systemctl, reboot, chown) without `sudo -n` will silently fail or produce a permission error that is hard to diagnose. Always use the `platform.sh` wrappers (`run_iptables`, `svc_*`, `run_reboot`) from CGI context.

**Inlining `( sleep N && reboot )` in a CGI script.** Two failure modes, both silent: (1) bare `reboot` runs as www-data and fails with "Failed to talk to init daemon" because systemd's private bus rejects unprivileged callers; (2) even if you wrap it in `run_reboot`, the fixed sleep races the `/reboot/` page — lighttpd is killed mid-serve and the user sees a connection-reset instead of the countdown. Always use `cgi_reboot_response` (see [§4.3.1](#431-reboot-ack-handshake)); it uses the sudo-aware `run_reboot` and waits for the page's ack file before pulling the plug.

**Trying to `systemctl enable` on RM520N-GL.** `systemctl enable` is a no-op on this platform because unit files are on the read-only rootfs where the command cannot write symlinks. Always use `svc_enable` / `svc_disable` from `platform.sh`, which writes the symlinks directly via `sudo /bin/ln -sf` and `sudo /bin/rm -f`.

**Writing to `/tmp/qmanager_*.json` from CGI without pre-creation.** If a CGI script creates a `/tmp` file that a root daemon will later overwrite, root will be blocked by `fs.protected_regular=1`. Pre-create the file in `qmanager_setup` with `www-data` ownership and mode 666 (or `root:root` mode 666 if root writes it primarily). See `qmanager_setup` for the full list of pre-created files.

**Hardcoding service lists in install/uninstall.** Use filesystem scans instead. `install_rm520n.sh` discovers services by globbing `scripts/etc/systemd/system/qmanager-*.service`. Adding a new service file is sufficient -- no installer edits needed.

**UPX-compressing `atcli_smd11`.** UPX self-modifying code causes segmentation faults on exit for this ARMv7 Rust build. Ship the uncompressed binary (~647KB). The installer must not UPX-compress it.

**Using `kill -0` for cross-user PID checks.** `kill -0 <pid>` fails with EPERM when www-data checks a root daemon's PID. Use `pid_alive()` from `platform.sh` which checks `/proc/$pid` existence instead.

### Platform Tooling Quirks (probe-confirmed 2026-05-09)

These quirks are easy to miss when porting code from a typical GNU/Linux box. Every item below was verified by direct SSH probing of the target firmware (`LE.UM.6.3.6.r1-02600-SDX65.0`).

**`bash` is 3.2.57.** Predates `mapfile`, `readarray`, `${var,,}`, `${var^^}`, `wait -n`, `declare -A`. See [§2 Critical Constraints](#2-critical-constraints) for the full list and workarounds.

**`/bin/sh` is BusyBox `ash`, not bash.** Do not put bashisms in `#!/bin/sh` scripts even if they "work locally" — they will fail on-device. Use `#!/bin/bash` if a script genuinely needs bash features.

**`sed` is BusyBox sed (1.31.1), not GNU sed.** Probe shows: `sed -i`, `sed -i.bak`, `sed -E`, `sed -r` all work. **Avoid:** GNU-specific `\<`/`\>` word boundaries, `sed -i ''` (empty SFX requires a non-empty arg or no arg at all), `sed --expression` long form. Stick to short flags.

**`awk` is BusyBox awk.** Probe shows `length()`, indexed arrays, `gensub()`, `systime()`, `strftime()` all available. Does **not** accept `--version` (silent stderr). For one-off scripts this is rich enough — but do not assume full gawk: `--posix`, `--re-interval`, GNU `printf %a`, `getline` over pipes with `|&` may behave differently.

**`tar` is BusyBox tar (1.31.1).** Only short flags: `c|x|t -ZzJjahmvokO -f -C -T -X --exclude`. **Missing:** `--owner=`, `--group=`, `--transform=`, `--newer-mtime=`, `--exclude-from`, `--mode=`. Backup/restore code that relies on these will silently misbehave or refuse the option.

**`xmlstarlet` is NOT installed.** Earlier docs imply `xmlstarlet` is the tool for `/etc/data/mobileap_cfg.xml`; **it is not present** on stock RM520N-GL. Use **`xmllint`** (`/usr/bin/xmllint`, system-bundled) for queries, or `sed`/`awk` for simple in-place edits. If a feature requires xmlstarlet, the installer must `opkg install xmlstarlet` from Entware first.

**`date` cannot do nanoseconds or relative-time parsing.**
- `date +%N` returns the **literal string `%N`** (no expansion). For sub-second timestamps, use `date +%s` (seconds only).
- `date -d 'now - 1 hour'` returns `invalid date` — BusyBox date has no GNU date-string parser. Compute offsets in shell: `$(( $(date +%s) - 3600 ))` and feed back via `date -d @<epoch>` (this **does** work).

**`mktemp --tmpdir=` is unsupported.** Use the template form: `mktemp /tmp/qmanager_foo.XXXXXX`.

**`ps -o etimes` is unsupported.** Only `etime` (HH:MM:SS string format) is allowed. To get elapsed seconds, parse `etime` in shell or read `/proc/<pid>/stat` field 22 (`starttime` jiffies) and subtract from `/proc/uptime`.

**`ss` is not installed.** Use `/opt/bin/netstat` (Entware net-tools) or BusyBox `netstat`. There is no `ss --version` to detect.

**No script interpreters beyond shell.** No `python`, `python3`, `perl`, `lua`, `node` — none. Anything that needs structured logic must be written as POSIX shell + `jq`. Adding an interpreter would mean an Entware package install (`opkg install python3`) plus its ~15 MB footprint on the persistent partition.

**No `getconf` for `ARG_MAX`/`PIPE_BUF`/`PATH_MAX`.** These names return empty on this device. Use Linux defaults: `ARG_MAX = 131072`, `PIPE_BUF = 4096`, `PATH_MAX = 4096`. If you need a real check, read `/proc/sys/kernel/...` directly.

**No NTP, RTC drifts to 1970.** `timedatectl` reports `System clock synchronized: no` and `NTP service: n/a`. Wall-clock time is set by the cellular network when it attaches; if the modem is offline at boot the clock can be years off. Never rely on absolute timestamps for security-sensitive ordering — use monotonic deltas (`/proc/uptime`) where possible.

**`/etc`, `/opt`, `/usrdata`, `/data`, `/cache`, `/persist`, `/systemrw` all bind-mount the same `/dev/ubi2_0` ubifs volume (~124 MB total).** Writes anywhere in this set consume from the same pool. `/tmp` is a separate 89 MB tmpfs (volatile). The rootfs `/` is `/dev/ubi0:rootfs` (~100 MB) — boots `ro`, must `mount -o remount,rw /` before persistent writes, then `sync` and `mount -o remount,ro /` before reboot.

**Single-core CPU, 178 MB RAM, ~91 MB zram swap.** ARMv7-A Cortex-A7 @ ~1.2 GHz (`BogoMIPS 38.40`) with VFPv4 + NEON + IDIVA/IDIVT. CPU-bound shell loops compete with the modem stack — keep daemon polling intervals reasonable and avoid per-second `jq` invocations on large JSON.

**`kernel.dmesg_restrict=1` and `kernel.kptr_restrict=2`.** Non-root cannot read kernel ring buffer; pointer values are zeroed in `/proc`. Diagnostic scripts that scrape `dmesg` will return empty under www-data.

**`conntrack_max = 12288`.** NAT table is small. Don't run conntrack-heavy probes (e.g., concurrent port scans) from the modem.

**Hardware-enforced binary ABI.** Native binaries shipped in `dependencies/` must be **armhf VFPv4** (Cortex-A7 features: `half thumb fastmult vfp edsp neon vfpv3 tls vfpv4 idiva idivt vfpd32 lpae evtstrm`). `armel` (soft-float) binaries will run but slowly; `aarch64` will not run at all.

**`iptables` rules live in a dedicated `QMANAGER_FW` user chain.** All web-UI port-firewall rules (ports 80/443 ACCEPT on trusted interfaces, DROP on others) live in the user chain `QMANAGER_FW` hooked from `INPUT`. `qmanager_firewall start` creates the chain (`-N`), flushes it (`-F`), populates the rules (`-A`), and hooks `INPUT` exactly once (`-I INPUT 1 -j QMANAGER_FW`). `qmanager_firewall stop` unhooks, flushes, and deletes the chain. This replaces an earlier direct-`INPUT` layout that left orphan rules across version drift (e.g. `DROP -i rmnet_data0 -p tcp --dport 80` rules from a prior trusted-interface set). Both `start` and `stop` also call `cleanup_legacy_input_rules()` to drain such orphans on devices upgrading from the old layout. Inspect with `iptables -L QMANAGER_FW -n -v` — single source of truth.

---

## 15. See Also

- `API-REFERENCE.md` -- CGI request/response schemas for all 69 endpoints
- `DEPLOYMENT.md` -- Install and update operational flow; installer behaviour; upgrade/rollback procedures
- `docs/rm520n-gl-architecture.md` -- Platform internals: Entware bootstrap, lighttpd configuration, boot sequences, `/usrdata/` partition layout, troubleshooting
- `ARCHITECTURE.md` -- System overview: component diagram, data flow, frontend/backend boundary
- `RELEASE_NOTES.md` -- Current release notes and version history
