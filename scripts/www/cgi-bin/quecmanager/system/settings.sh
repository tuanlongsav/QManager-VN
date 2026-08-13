#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/config.sh
. /usr/lib/qmanager/platform.sh
. /usr/lib/qmanager/system_config.sh
# =============================================================================
# settings.sh — CGI Endpoint: System Settings (GET + POST)
# =============================================================================
# GET:  Returns current system settings (units, timezone, WAN guard,
#        scheduled reboot, low-power mode).
# POST: Saves settings, scheduled reboot config, or low-power config.
#
# Config: /etc/qmanager/qmanager.conf (settings section)
# Cron:   qmanager_scheduled_reboot markers
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/settings.sh
# Install location: /www/cgi-bin/quecmanager/system/settings.sh
# =============================================================================

qlog_init "cgi_system_settings"
cgi_headers
cgi_handle_options

# --- Helpers -----------------------------------------------------------------

# Strip leading zero from a time component (handle "00" -> "0", not empty)
strip_leading_zero() {
    local v
    v=$(printf '%s' "$1" | sed 's/^0//')
    [ -z "$v" ] && v="0"
    printf '%s' "$v"
}

# =============================================================================
# GET — Fetch all system settings
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching system settings"
    qm_config_init

    # --- WAN Guard status ---
    # Not ported to RM520N-GL; always report false
    wan_guard_enabled="false"

    # --- AT device (informational — atcli_smd11 hardcodes /dev/smd11) ---
    sms_tool_device="/dev/smd11"

    # --- Unit preferences ---
    temp_unit=$(qm_config_get settings temp_unit "celsius")
    distance_unit=$(qm_config_get settings distance_unit "km")

    # --- Hostname (display name) ---
    hostname=$(sys_get_hostname)

    # --- Timezone ---
    timezone=$(sys_get_timezone)
    zonename=$(sys_get_zonename)

    # --- Scheduled reboot ---
    sched_enabled=$(qm_config_get settings sched_reboot_enabled "0")
    sched_time=$(qm_config_get settings sched_reboot_time "04:00")
    sched_days_raw=$(qm_config_get settings sched_reboot_days "0,1,2,3,4,5,6")
    sched_days_json=$(printf '%s' "$sched_days_raw" | jq -Rc 'split(",") | map(tonumber)' 2>/dev/null)
    [ -z "$sched_days_json" ] && sched_days_json="[0,1,2,3,4,5,6]"

    jq -n \
        --argjson wan_guard "$wan_guard_enabled" \
        --arg hostname "$hostname" \
        --arg temp_unit "$temp_unit" \
        --arg distance_unit "$distance_unit" \
        --arg timezone "$timezone" \
        --arg zonename "$zonename" \
        --arg sms_tool_device "$sms_tool_device" \
        --argjson sched_enabled "$sched_enabled" \
        --arg sched_time "$sched_time" \
        --argjson sched_days "$sched_days_json" \
        '{
            success: true,
            settings: {
                wan_guard_enabled: $wan_guard,
                hostname: $hostname,
                temp_unit: $temp_unit,
                distance_unit: $distance_unit,
                timezone: $timezone,
                zonename: $zonename,
                sms_tool_device: $sms_tool_device
            },
            scheduled_reboot: {
                enabled: ($sched_enabled == 1),
                time: $sched_time,
                days: $sched_days
            }
        }'
    exit 0
fi

# =============================================================================
# POST — Save settings
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then

    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')

    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: save_settings
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "save_settings" ]; then
        qlog_info "Saving system settings"
        qm_config_init

        # --- Pass 1: parse the whole payload and validate it as a unit -------
        #
        # Each field used to be written the instant it was parsed, so a
        # rejection later in the body left the earlier fields already committed
        # while the client got success:false and re-rendered from its old
        # state — the device and the UI silently disagreeing about three
        # settings. Parse everything, reject the payload as a whole, and only
        # then write. Same two-pass shape as
        # scripts/www/cgi-bin/quecmanager/monitoring/watchdog.sh.
        #
        # Only temp_unit and distance_unit have a domain to validate. A display
        # name is free-form by design (sys_hostname_label derives the kernel
        # label from it) and the timezone table lives in the frontend, so
        # neither can be rejected here. What those two have instead is a
        # privileged apply step that can fail for environmental reasons — not a
        # validation failure, and handled in pass 2.
        p_hostname=$(printf '%s' "$POST_DATA" | jq -r '.hostname // empty')
        p_temp_unit=$(printf '%s' "$POST_DATA" | jq -r '.temp_unit // empty')
        p_distance_unit=$(printf '%s' "$POST_DATA" | jq -r '.distance_unit // empty')
        p_timezone=$(printf '%s' "$POST_DATA" | jq -r '.timezone // empty')
        p_zonename=$(printf '%s' "$POST_DATA" | jq -r '.zonename // empty')

        # --- WAN Guard toggle ---
        # Not ported to RM520N-GL; silently ignore
        # p_wan_guard=$(printf '%s' "$POST_DATA" | jq -r 'if has("wan_guard_enabled") then (.wan_guard_enabled | tostring) else "" end')

        if [ -n "$p_temp_unit" ]; then
            case "$p_temp_unit" in
                celsius|fahrenheit) ;;
                *)
                    cgi_error "invalid_temp_unit" "temp_unit must be 'celsius' or 'fahrenheit'"
                    exit 0
                    ;;
            esac
        fi

        if [ -n "$p_distance_unit" ]; then
            case "$p_distance_unit" in
                km|miles) ;;
                *)
                    cgi_error "invalid_distance_unit" "distance_unit must be 'km' or 'miles'"
                    exit 0
                    ;;
            esac
        fi

        # --- Pass 2: everything validated — commit ---------------------------
        #
        # Two different failures live in this pass and the response must keep
        # them apart:
        #
        #   a failed WRITE — qm_config_set returns non-zero when jq errors or
        #     when the write would leave an empty config. Nothing was stored,
        #     so the only honest answer is success:false; anything else shows
        #     the user a value the device does not hold.
        #
        #   a failed APPLY — the value IS stored, only the privileged side
        #     effect (system hostname, /etc/localtime) did not land. Folding
        #     that into success:false makes the client discard a value that was
        #     in fact saved: nav-user.tsx reads success:false as "the rename
        #     failed" and drops the name the user just typed. So the save stays
        #     successful and the apply result travels in its own field, which
        #     consumers that do not know the field ignore harmlessly.
        hostname_applied="true"
        hostname_apply_error=""
        timezone_applied="true"
        timezone_apply_error=""

        # --- Hostname (display name) ---
        # This field carries two things at once: the display name the sidebar
        # renders, and the system hostname derived from it. The apply half goes
        # through a root helper and genuinely can fail — most plausibly on a
        # device that has not yet taken the update carrying the helper and its
        # sudoers rule, where sudo refuses the call outright.
        if [ -n "$p_hostname" ]; then
            sys_set_hostname "$p_hostname"
            case "$?" in
                0) ;;
                1)
                    hostname_applied="false"
                    hostname_apply_error="Saved the display name, but it could not be applied as the system hostname. Updating QManager installs the helper this needs."
                    qlog_warn "Display name saved but system hostname could not be applied"
                    ;;
                *)
                    cgi_error "hostname_save_failed" \
                        "Could not save the display name — writing the configuration file failed."
                    exit 0
                    ;;
            esac
        fi

        # --- Temperature unit ---
        if [ -n "$p_temp_unit" ]; then
            if ! qm_config_set settings temp_unit "$p_temp_unit"; then
                cgi_error "temp_unit_save_failed" \
                    "Could not save the temperature unit — writing the configuration file failed."
                exit 0
            fi
        fi

        # --- Distance unit ---
        if [ -n "$p_distance_unit" ]; then
            if ! qm_config_set settings distance_unit "$p_distance_unit"; then
                cgi_error "distance_unit_save_failed" \
                    "Could not save the distance unit — writing the configuration file failed."
                exit 0
            fi
        fi

        # --- Timezone ---
        # sys_set_timezone reports a real apply failure (missing zoneinfo
        # database, unwritable /etc, helper not installed), and swallowing it
        # would reproduce the exact bug this endpoint was fixed for: the picker
        # answering {"success":true} while the clock never moved. But an APPLY
        # failure must not abort either — aborting here discarded
        # hostname_applied, so a request that renamed the device AND changed
        # the zone lost the hostname warning entirely. Report it the way the
        # hostname is. A STORE failure (rc 2) is a different thing and does
        # still abort: nothing was written, so success:false is the truth, and
        # a "saved but not applied" warning alongside it would contradict it.
        if [ -n "$p_timezone" ]; then
            sys_set_timezone "$p_timezone" "$p_zonename"
            case "$?" in
                0) ;;
                1)
                    timezone_applied="false"
                    timezone_apply_error="Saved the timezone preference, but it could not be applied — the zoneinfo database may be missing. Retry after: opkg update && opkg install zoneinfo-all"
                    qlog_warn "Timezone saved but could not be applied to the running system"
                    ;;
                *)
                    cgi_error "timezone_save_failed" \
                        "Could not save the timezone — writing the configuration file failed."
                    exit 0
                    ;;
            esac
        fi

        # AT device is hardcoded to /dev/smd11 via atcli_smd11 — no override needed

        qlog_info "System settings saved"
        # Keep the ordinary response byte-identical to what it has always been;
        # each warning field appears only when that half actually failed.
        if [ "$hostname_applied" = "false" ] || [ "$timezone_applied" = "false" ]; then
            jq -n \
                --argjson hn_applied "$hostname_applied" \
                --arg hn_error "$hostname_apply_error" \
                --argjson tz_applied "$timezone_applied" \
                --arg tz_error "$timezone_apply_error" \
                '{success: true}
                 + (if $hn_applied then {} else {hostname_applied: false, hostname_apply_error: $hn_error} end)
                 + (if $tz_applied then {} else {timezone_applied: false, timezone_apply_error: $tz_error} end)'
        else
            echo '{"success":true}'
        fi
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: save_scheduled_reboot
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "save_scheduled_reboot" ]; then
        qlog_info "Saving scheduled reboot settings"
        qm_config_init

        # Parse fields
        ENABLED=$(printf '%s' "$POST_DATA" | jq -r 'if has("enabled") then (.enabled | tostring) else "" end')
        SCHED_TIME=$(printf '%s' "$POST_DATA" | jq -r '.time // empty')
        DAYS_RAW=$(printf '%s' "$POST_DATA" | jq -r '.days // [] | map(tostring) | join(",")' 2>/dev/null)

        if [ -z "$ENABLED" ]; then
            cgi_error "missing_enabled" "enabled field is required"
            exit 0
        fi

        # Validate when enabling
        if [ "$ENABLED" = "true" ]; then
            # Validate time format HH:MM
            case "$SCHED_TIME" in
                [0-2][0-9]:[0-5][0-9]) ;;
                *)
                    cgi_error "invalid_time" "time must be HH:MM format"
                    exit 0
                    ;;
            esac

            # Validate days
            if [ -z "$DAYS_RAW" ]; then
                cgi_error "no_days" "At least one day must be selected"
                exit 0
            fi

            invalid_day=""
            for d in $(printf '%s' "$DAYS_RAW" | tr ',' ' '); do
                case "$d" in
                    0|1|2|3|4|5|6) ;;
                    *) invalid_day="$d" ;;
                esac
            done
            if [ -n "$invalid_day" ]; then
                cgi_error "invalid_day" "Days must be 0-6 (0=Sun, 6=Sat)"
                exit 0
            fi
        fi

        # Defaults for disabled state
        [ -z "$SCHED_TIME" ] && SCHED_TIME="04:00"
        [ -z "$DAYS_RAW" ] && DAYS_RAW="0,1,2,3,4,5,6"

        # Write to config.
        #
        # Bail on the first failed write and leave the crontab alone. The cron
        # entry is what actually reboots the device; the config is what the UI
        # reads back. Installing a cron line for a schedule the config does not
        # hold would give the user a device that reboots at a time no page ever
        # shows — the worst of the two possible mismatches.
        sched_write_failed() {
            cgi_error "sched_save_failed" \
                "Could not save the reboot schedule — writing the configuration file failed. The existing cron entry was left untouched."
            exit 0
        }
        case "$ENABLED" in
            true)  qm_config_set settings sched_reboot_enabled 1 || sched_write_failed ;;
            false) qm_config_set settings sched_reboot_enabled 0 || sched_write_failed ;;
        esac
        qm_config_set settings sched_reboot_time "$SCHED_TIME" || sched_write_failed
        qm_config_set settings sched_reboot_days "$DAYS_RAW" || sched_write_failed

        # --- Manage crontab (write directly to root's crontab file) ---
        # CGI runs as www-data but scheduled scripts need root.
        # BusyBox crond reads /var/spool/cron/crontabs/<user> directly.
        CRON_MARKER="qmanager_scheduled_reboot"
        SCHEDULE_SCRIPT="/usr/bin/qmanager_scheduled_reboot"
        CRON_FILE="/var/spool/cron/crontabs/root"

        current_cron=$(cat "$CRON_FILE" 2>/dev/null || true)
        cleaned_cron=$(printf '%s\n' "$current_cron" | grep -v "$CRON_MARKER")

        if [ "$ENABLED" = "true" ]; then
            sched_hour=$(printf '%s' "$SCHED_TIME" | cut -d: -f1)
            sched_min=$(printf '%s' "$SCHED_TIME" | cut -d: -f2)
            sched_hour=$(strip_leading_zero "$sched_hour")
            sched_min=$(strip_leading_zero "$sched_min")

            new_cron="${cleaned_cron}
# QManager Scheduled Reboot — DO NOT EDIT MANUALLY
${sched_min} ${sched_hour} * * ${DAYS_RAW} ${SCHEDULE_SCRIPT}  # ${CRON_MARKER}"

            printf '%s\n' "$new_cron" > "$CRON_FILE"
            qlog_info "Scheduled reboot cron installed: ${SCHED_TIME} days=${DAYS_RAW}"
        else
            if [ -n "$cleaned_cron" ]; then
                printf '%s\n' "$cleaned_cron" > "$CRON_FILE"
            else
                rm -f "$CRON_FILE"
            fi
            qlog_info "Scheduled reboot cron entries removed"
        fi

        # Build response
        DAYS_RESP=$(printf '%s' "$DAYS_RAW" | jq -Rc 'split(",") | map(tonumber)' 2>/dev/null)
        [ -z "$DAYS_RESP" ] && DAYS_RESP="[0,1,2,3,4,5,6]"

        jq -n \
            --argjson enabled "$([ "$ENABLED" = "true" ] && echo true || echo false)" \
            --arg time "$SCHED_TIME" \
            --argjson days "$DAYS_RESP" \
            '{success: true, scheduled_reboot: {enabled: $enabled, time: $time, days: $days}}'
        exit 0
    fi

    # Unknown action
    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

# Method not allowed
cgi_error "method_not_allowed" "Only GET and POST are supported"
