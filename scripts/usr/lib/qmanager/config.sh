#!/bin/sh
# config.sh — QManager Configuration Helper (RM520N-GL)
# Drop-in replacement for UCI get/set/commit operations.
# Uses a single JSON config file with jq for reads and writes.

[ -n "$_CONFIG_LOADED" ] && return 0
_CONFIG_LOADED=1

QM_CONFIG="/etc/qmanager/qmanager.conf"
QM_CONFIG_TMP="/etc/qmanager/qmanager.conf.tmp"

# How many quarantined copies of a corrupt config to keep (see
# _qm_config_quarantine for why this is capped at all).
QM_CONFIG_CORRUPT_MAX=3

# Move a corrupt config aside and say so out loud.
#
# From the user's seat, losing this file is indistinguishable from a factory
# reset — band locks, watchdog tuning, timezone, hostname and the scheduled
# reboot all revert at once — so the repair leaves a syslog line naming the
# preserved copy instead of happening in silence.
#
# The logging has to stay dependency-free: config.sh is sourced by everything,
# including CGI handlers where stdout IS the HTTP response body and qlog.sh is
# not necessarily loaded. Hence a guarded `logger` straight to syslog and not a
# single byte on stdout. (Sourcing qlog.sh would not create a cycle — it pulls
# in nothing — but it would drag log-file creation and rotation into every
# script that only wanted to read one config key.)
#
# Copies are timestamped so a second corruption cannot clobber the evidence
# from the first, and capped so a boot loop cannot fill the rootfs volume with
# them. Past the cap it is the NEW copy that is dropped, not the oldest: the
# first capture is the one taken closest to whatever broke the file, and the
# later ones are the same damage observed again.
_qm_config_quarantine() {
    local ts saved msg count=0

    ts=$(date +%s 2>/dev/null)
    [ -n "$ts" ] || ts=$$
    saved="${QM_CONFIG}.corrupt.${ts}"

    # Unmatched globs stay literal in POSIX sh, hence the -e probe before
    # trusting $#. Positional parameters are function-local, so `set --` here
    # cannot disturb the caller.
    set -- "${QM_CONFIG}".corrupt.*
    [ -e "$1" ] && count=$#

    if [ "$count" -ge "$QM_CONFIG_CORRUPT_MAX" ]; then
        rm -f "$QM_CONFIG"
        msg="config unparseable, restoring defaults; already holding ${count} saved copies, this one discarded"
    elif mv "$QM_CONFIG" "$saved" 2>/dev/null; then
        msg="config unparseable, restoring defaults; previous file saved as ${saved}"
    else
        # Rename failed (read-only /etc, most likely). The defaults still have
        # to be written over it, so the bad file goes regardless.
        rm -f "$QM_CONFIG"
        msg="config unparseable, restoring defaults; could not save a copy, previous file discarded"
    fi

    command -v logger >/dev/null 2>&1 && \
        logger -t qmanager_config -p daemon.err "$msg" 2>/dev/null
    return 0
}

# Create default config if missing, empty, or unparseable.
#
# Non-empty is not a strong enough test: a truncated or malformed file (power
# loss mid-write, a half-finished manual edit) still passes -s, and from then
# on every jq call against it fails. Validate the JSON and move a bad file
# aside rather than deleting it, so the original is still there to inspect.
#
# That validation costs a jq fork, so it runs at most once per process.
# qm_config_set calls this before its own jq, and a single settings save issues
# up to ~10 consecutive sets — without the guard that is 20 jq forks instead of
# 10, which is measurable on this ARMv7 CPU. Per-process is the right
# granularity, deliberately chosen rather than inherited:
#   - CGI handlers get a fresh process per request, so a config that goes bad
#     between requests is still caught on the very next one.
#   - qmanager_watchcat, the one long-lived daemon that sources this, does
#     cache for its whole lifetime. That is acceptable: every writer goes
#     through qm_config_set, which replaces the file atomically with jq output,
#     so a config that validated once cannot turn invalid under a running
#     process except through power loss or storage failure — either of which
#     takes the daemon down with it, and the check re-runs on the next start.
qm_config_init() {
    [ -n "$_CONFIG_VALIDATED" ] && return 0
    if [ -s "$QM_CONFIG" ]; then
        if jq -e . "$QM_CONFIG" >/dev/null 2>&1; then
            _CONFIG_VALIDATED=1
            return 0
        fi
        _qm_config_quarantine
    fi
    cat > "$QM_CONFIG" << 'DEFAULTS'
{
  "watchcat": {
    "enabled": 0,
    "check_interval": 10,
    "max_failures": 5,
    "cooldown": 60,
    "tier1_enabled": 1,
    "tier2_enabled": 1,
    "tier3_enabled": 0,
    "tier4_enabled": 1,
    "backup_sim_slot": "",
    "max_reboots_per_hour": 3
  },
  "bridge_monitor": {
    "enabled": 0,
    "ws_port": 8838,
    "refresh_rate_ms": 1000,
    "interfaces": "br-lan,eth0,rmnet_data0,rmnet_data1,rmnet_ipa0",
    "channel": "network-monitor",
    "json_mode": "yes"
  },
  "eth_link": {
    "speed_limit": "auto"
  },
  "settings": {
    "temp_unit": "celsius",
    "distance_unit": "km",
    "hostname": "",
    "timezone": "UTC0",
    "zonename": "UTC",
    "sms_tool_device": "",
    "sched_reboot_enabled": 0,
    "sched_reboot_time": "04:00",
    "sched_reboot_days": "0,1,2,3,4,5,6"
  },
  "update": {
    "include_prerelease": 1,
    "auto_update_enabled": 0,
    "auto_update_time": "03:00"
  }
}
DEFAULTS
    # Only mark the config good once the defaults actually landed. If /etc is
    # still mounted read-only the redirect above failed, and the next call in
    # this process must retry rather than assume a config it never wrote.
    [ -s "$QM_CONFIG" ] || return 1
    _CONFIG_VALIDATED=1
}

# Read: qm_config_get <section> <key> [default]
# Example: qm_config_get watchcat enabled 0
#   Equivalent to: uci -q get quecmanager.watchcat.enabled
# NOTE: Uses // empty which treats both false and null as absent.
# All config values here are strings or integers (never boolean false),
# so this is safe. If boolean false is ever needed, use the safe pattern:
#   jq '(.[$s][$k]) | if . == null then empty else tostring end'
qm_config_get() {
    local section="$1" key="$2" default="${3:-}"
    [ -f "$QM_CONFIG" ] || { echo "$default"; return; }
    local val
    val=$(jq -r --arg s "$section" --arg k "$key" \
        '.[$s][$k] // empty' "$QM_CONFIG" 2>/dev/null)
    if [ -z "$val" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# Write: qm_config_set <section> <key> <value>
# Example: qm_config_set watchcat enabled 0
#   Equivalent to: uci set quecmanager.watchcat.enabled=0 && uci commit
# Atomic write via temp file + mv.
qm_config_set() {
    local section="$1" key="$2" value="$3"
    local rc
    qm_config_init
    # Detect numeric values to store as numbers, not strings
    case "$value" in
        ''|*[!0-9]*) # non-numeric or empty — store as string
            jq --arg s "$section" --arg k "$key" --arg v "$value" \
                '.[$s][$k] = $v' "$QM_CONFIG" > "$QM_CONFIG_TMP" ;;
        *) # numeric — store as number
            jq --arg s "$section" --arg k "$key" --argjson v "$value" \
                '.[$s][$k] = $v' "$QM_CONFIG" > "$QM_CONFIG_TMP" ;;
    esac
    rc=$?
    # Commit only when jq both succeeded and produced output. The shell
    # truncates $QM_CONFIG_TMP to zero bytes before jq even starts, so an
    # unconditional mv turns any jq failure into an empty live config — every
    # setting on the device gone at once (band locks, watchdog tuning,
    # timezone, hostname, scheduled reboot), with no error surfaced and
    # qm_config_init quietly recreating defaults on the next call.
    if [ "$rc" -ne 0 ] || [ ! -s "$QM_CONFIG_TMP" ]; then
        rm -f "$QM_CONFIG_TMP"
        return 1
    fi
    mv "$QM_CONFIG_TMP" "$QM_CONFIG"
}

# Bulk read: qm_config_section <section>
# Returns the entire section as a JSON object on stdout.
# Example: qm_config_section watchcat | jq -r '.enabled'
qm_config_section() {
    local section="$1"
    [ -f "$QM_CONFIG" ] || { echo "{}"; return; }
    jq -r --arg s "$section" '.[$s] // {}' "$QM_CONFIG" 2>/dev/null
}
