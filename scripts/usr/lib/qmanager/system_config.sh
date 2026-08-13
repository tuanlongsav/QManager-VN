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
# Returns:
#   0 — display name stored AND applied as the system hostname
#   1 — display name stored, but the system hostname could not be applied
#   2 — nothing stored (empty name, or the config write itself failed)
# Callers must keep 1 and 2 apart. After 1 the stored value is what the UI
# renders, so the failed apply is a warning, not a failed save. After 2 nothing
# was saved at all, and answering "saved" would show the user a name the device
# does not hold.
sys_set_hostname() {
    local name="$1" label
    [ -z "$name" ] && return 2
    # qm_config_set returns non-zero when jq fails or when the write would
    # leave an empty config — it refuses rather than wiping every setting on
    # the device. Ignoring that here reported a save that never happened.
    if ! qm_config_set settings hostname "$name"; then
        qlog_warn "sys_set_hostname: could not store display name '$name'" 2>/dev/null || true
        return 2
    fi
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
# Returns:
#   0 — preference stored AND the zone applied to the running system
#   1 — preference stored, but the zone could not be applied
#   2 — nothing stored (empty TZ string, or a config write itself failed)
# Same contract as sys_set_hostname: 1 is a warning about a value that IS
# saved, 2 means the caller must not report a save at all.
sys_set_timezone() {
    local tz="$1" zn="${2:-}"
    [ -z "$tz" ] && return 2
    if ! qm_config_set settings timezone "$tz"; then
        qlog_warn "sys_set_timezone: could not store timezone '$tz'" 2>/dev/null || true
        return 2
    fi
    # The two keys are always read back as a pair — sys_get_timezone drives the
    # clock, sys_get_zonename drives the picker — so storing one without the
    # other would leave the UI showing a zone the device is not running on.
    # Treat a half-written pair as "not stored".
    if [ -n "$zn" ] && ! qm_config_set settings zonename "$zn"; then
        qlog_warn "sys_set_timezone: could not store zonename '$zn'" 2>/dev/null || true
        return 2
    fi
    # Applying the zone needs root: /etc is root:root 0755, so replacing the
    # /etc/localtime symlink requires write on the directory, which www-data
    # does not have. The previous in-process `ln -sf` therefore no-opped, and
    # because its failure was discarded the picker appeared to work while every
    # timestamp stayed on the old zone. Hand it to the root helper instead and
    # report what actually happened.
    if [ -n "$zn" ]; then
        # Both halves of the setting travel to the helper because they land in
        # two different places: $zn names the zoneinfo file /etc/localtime
        # points at, which is what glibc reads, while $tz is the POSIX TZ spec
        # written to /etc/TZ for the BusyBox applets, which parse that format
        # and not IANA names. Passing only $zn put "Asia/Ho_Chi_Minh" into
        # /etc/TZ, so the two representations of one setting disagreed.
        # An older helper that only takes <zonename> ignores the extra argument.
        if $_SUDO /usr/bin/qmanager_set_timezone "$zn" "$tz" >/dev/null 2>&1; then
            export TZ="$tz"
            return 0
        fi
        qlog_warn "sys_set_timezone: helper failed to apply zone '$zn'" 2>/dev/null || true
        return 1
    fi

    export TZ="$tz"
    return 0
}
