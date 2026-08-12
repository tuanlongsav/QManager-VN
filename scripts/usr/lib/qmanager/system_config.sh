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

# Reduce a free-form display name to something the kernel will accept as a
# hostname. settings.hostname carries two things at once: onboarding asks for
# it as "Your name" and the sidebar renders it verbatim, so values like
# "Alex Nguyen" or "Modem nha" — with spaces, apostrophes or diacritics — are
# normal and must keep working. Rejecting them outright to satisfy RFC 1123
# would break the rename dialog, so derive a label instead and leave the stored
# name untouched. Multi-byte characters map to one hyphen per byte, which the
# squeeze then folds back into one.
sys_hostname_label() {
    local label
    label=$(printf '%s' "$1" | tr -c 'A-Za-z0-9-' '-' | tr -s '-' | sed 's/^-*//; s/-*$//')
    # Truncate after squeezing, then trim again: cutting at 63 can land on a
    # hyphen, and RFC 1123 does not allow a label to end with one.
    label=$(printf '%.63s' "$label" | sed 's/-*$//')
    # A name written entirely in non-ASCII reduces to nothing.
    [ -z "$label" ] && label="RM520N-GL"
    printf '%s' "$label"
}

# Set hostname (persists the display name to config + applies to the system)
# Returns 0 when the system hostname was applied, 1 when only the preference
# was stored. Callers must keep the two apart: the stored value is what the UI
# renders, so a failed apply is a warning, not a failed save.
sys_set_hostname() {
    local name="$1" label
    [ -z "$name" ] && return 1
    qm_config_set settings hostname "$name"
    # Applying needs root three times over: /proc/sys/kernel/hostname is
    # root-only, /etc is root:root 0755 so creating a file there needs write on
    # the directory, and remounting a read-only rootfs has no sudoers grant at
    # all. The previous in-process writes therefore all no-opped, and since
    # every one of them was 2>/dev/null with no return value checked, the
    # rename dialog reported success while the hostname never moved. Hand the
    # work to the root helper and report what actually happened.
    label=$(sys_hostname_label "$name")
    if $_SUDO /usr/bin/qmanager_set_hostname "$label" >/dev/null 2>&1; then
        return 0
    fi
    qlog_warn "sys_set_hostname: helper failed to apply hostname '$label'" 2>/dev/null || true
    return 1
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
