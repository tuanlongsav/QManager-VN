#!/bin/sh
# config.sh — QManager Configuration Helper (RM520N-GL)
# Drop-in replacement for UCI get/set/commit operations.
# Uses a single JSON config file with jq for reads and writes.

[ -n "$_CONFIG_LOADED" ] && return 0
_CONFIG_LOADED=1

QM_CONFIG="/etc/qmanager/qmanager.conf"
QM_CONFIG_TMP="/etc/qmanager/qmanager.conf.tmp"

# Create default config if missing, empty, or unparseable.
#
# Non-empty is not a strong enough test: a truncated or malformed file (power
# loss mid-write, a half-finished manual edit) still passes -s, and from then
# on every jq call against it fails. Validate the JSON and move a bad file
# aside rather than deleting it, so the original is still there to inspect.
qm_config_init() {
    if [ -s "$QM_CONFIG" ]; then
        jq -e . "$QM_CONFIG" >/dev/null 2>&1 && return 0
        mv "$QM_CONFIG" "${QM_CONFIG}.corrupt" 2>/dev/null || rm -f "$QM_CONFIG"
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
