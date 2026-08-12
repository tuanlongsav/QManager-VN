#!/bin/sh
# system_config.sh — System settings abstraction (RM520N-GL)
# Replaces UCI system.@system[0].* reads/writes with standard Linux APIs.
# Hostname and timezone are stored in qmanager.conf for persistence across
# read-only rootfs remounts, and applied to the live system.

[ -n "$_SYSTEM_CONFIG_LOADED" ] && return 0
_SYSTEM_CONFIG_LOADED=1

. /usr/lib/qmanager/config.sh
# For $_SUDO. platform.sh guards against double-sourcing, and depending on the
# caller to have loaded it first would make sys_set_timezone silently run
# without sudo in any script that ordered its sources differently.
. /usr/lib/qmanager/platform.sh

# --- Hostname ----------------------------------------------------------------

# Get current hostname
# Falls back to qmanager.conf → /etc/hostname → "RM520N-GL"
sys_get_hostname() {
    local h
    h=$(qm_config_get settings hostname "")
    if [ -z "$h" ] && [ -f /etc/hostname ]; then
        h=$(cat /etc/hostname 2>/dev/null | tr -d '[:space:]')
    fi
    [ -z "$h" ] && h="RM520N-GL"
    printf '%s' "$h"
}

# Set hostname (persists to config + applies live)
sys_set_hostname() {
    local name="$1"
    [ -z "$name" ] && return 1
    qm_config_set settings hostname "$name"
    # Apply to running system
    echo "$name" > /proc/sys/kernel/hostname 2>/dev/null
    # Persist to /etc/hostname (requires remount if rootfs is ro)
    if [ -w /etc/hostname ] || mount -o remount,rw / 2>/dev/null; then
        echo "$name" > /etc/hostname 2>/dev/null
    fi
}

# --- Timezone ----------------------------------------------------------------

# Get current timezone string (POSIX TZ, e.g., "UTC0", "PST8PDT")
sys_get_timezone() {
    local tz
    tz=$(qm_config_get settings timezone "UTC0")
    printf '%s' "$tz"
}

# Get timezone display name (e.g., "America/Los_Angeles")
sys_get_zonename() {
    local zn
    zn=$(qm_config_get settings zonename "UTC")
    printf '%s' "$zn"
}

# Set timezone (persists to config + applies live)
# Args: $1 = POSIX TZ string, $2 = zone name (IANA, e.g., "Asia/Manila")
sys_set_timezone() {
    local tz="$1" zn="${2:-}"
    [ -z "$tz" ] && return 1
    qm_config_set settings timezone "$tz"
    [ -n "$zn" ] && qm_config_set settings zonename "$zn"
    # Applying the zone needs root: /etc is root:root 0755, so replacing the
    # /etc/localtime symlink requires write on the directory, which www-data
    # does not have. The previous in-process `ln -sf` therefore no-opped, and
    # because its failure was discarded the picker appeared to work while every
    # timestamp stayed on the old zone. Hand it to the root helper instead and
    # report what actually happened.
    if [ -n "$zn" ]; then
        if $_SUDO /usr/bin/qmanager_set_timezone "$zn" >/dev/null 2>&1; then
            export TZ="$tz"
            return 0
        fi
        qlog_warn "sys_set_timezone: helper failed to apply zone '$zn'" 2>/dev/null || true
        return 1
    fi

    export TZ="$tz"
    return 0
}
