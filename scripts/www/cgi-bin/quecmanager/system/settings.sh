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

        val=""

        # --- WAN Guard toggle ---
        # Not ported to RM520N-GL; silently ignore
        # val=$(printf '%s' "$POST_DATA" | jq -r 'if has("wan_guard_enabled") then (.wan_guard_enabled | tostring) else "" end')

        # --- Hostname (display name) ---
        # This field carries two things at once. The display name the sidebar
        # renders is saved by qm_config_set and, from the user's point of view,
        # simply succeeds. The system hostname derived from it goes through a
        # root helper and genuinely can fail — most plausibly on a device that
        # has not yet taken the update carrying the helper and its sudoers rule,
        # where sudo refuses the call outright.
        #
        # Those two must not share one success flag. nav-user.tsx treats
        # success:false as "the rename failed", discarding the name the user
        # just typed and leaving the dialog open — even though that name was
        # stored. So the save stays successful and the apply result travels in
        # its own field, which older consumers ignore harmlessly.
        hostname_applied="true"
        val=$(printf '%s' "$POST_DATA" | jq -r '.hostname // empty')
        if [ -n "$val" ]; then
            if ! sys_set_hostname "$val"; then
                hostname_applied="false"
                qlog_warn "Display name saved but system hostname could not be applied"
            fi
        fi

        # --- Temperature unit ---
        val=$(printf '%s' "$POST_DATA" | jq -r '.temp_unit // empty')
        if [ -n "$val" ]; then
            case "$val" in
                celsius|fahrenheit) qm_config_set settings temp_unit "$val" ;;
                *)
                    cgi_error "invalid_temp_unit" "temp_unit must be 'celsius' or 'fahrenheit'"
                    exit 0
                    ;;
            esac
        fi

        # --- Distance unit ---
        val=$(printf '%s' "$POST_DATA" | jq -r '.distance_unit // empty')
        if [ -n "$val" ]; then
            case "$val" in
                km|miles) qm_config_set settings distance_unit "$val" ;;
                *)
                    cgi_error "invalid_distance_unit" "distance_unit must be 'km' or 'miles'"
                    exit 0
                    ;;
            esac
        fi

        # --- Timezone ---
        val=$(printf '%s' "$POST_DATA" | jq -r '.timezone // empty')
        zn=$(printf '%s' "$POST_DATA" | jq -r '.zonename // empty')
        if [ -n "$val" ]; then
            # Check the result. sys_set_timezone now reports a real failure
            # (missing zoneinfo database, unwritable /etc, helper not
            # installed), and swallowing it here would reproduce the exact bug
            # this endpoint was fixed for: the picker answering {"success":true}
            # while the clock never moved. The preference is already persisted
            # at this point, so the message says the value was saved but not
            # applied rather than implying nothing happened.
            if ! sys_set_timezone "$val" "$zn"; then
                cgi_error "timezone_apply_failed" \
                    "Saved the preference but could not apply the timezone — the zoneinfo database may be missing. Retry after: opkg update && opkg install zoneinfo-all"
                exit 0
            fi
        fi

        # AT device is hardcoded to /dev/smd11 via atcli_smd11 — no override needed

        qlog_info "System settings saved"
        # Keep the ordinary response byte-identical to what it has always been;
        # the extra fields appear only when there is something to report.
        if [ "$hostname_applied" = "false" ]; then
            jq -n '{
                success: true,
                hostname_applied: false,
                hostname_apply_error: "Saved the display name, but it could not be applied as the system hostname. Updating QManager installs the helper this needs."
            }'
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

        # Write to config
        case "$ENABLED" in
            true)  qm_config_set settings sched_reboot_enabled 1 ;;
            false) qm_config_set settings sched_reboot_enabled 0 ;;
        esac
        qm_config_set settings sched_reboot_time "$SCHED_TIME"
        qm_config_set settings sched_reboot_days "$DAYS_RAW"

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
