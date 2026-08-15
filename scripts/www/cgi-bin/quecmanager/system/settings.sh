#!/bin/sh
# The library root is a variable so scripts/test/schedule-cgi.sh can run this
# endpoint against stub libraries. A request cannot introduce it: lighttpd
# exports a request's headers as HTTP_* and nothing else. Same hook as
# settings/quality_thresholds.sh.
LIB_DIR="${QM_LIB_DIR:-/usr/lib/qmanager}"
. "$LIB_DIR/cgi_base.sh"
. "$LIB_DIR/config.sh"
. "$LIB_DIR/platform.sh"
. "$LIB_DIR/system_config.sh"
# =============================================================================
# settings.sh — CGI Endpoint: System Settings (GET + POST)
# =============================================================================
# GET:  Returns current system settings (units, timezone, WAN guard,
#        scheduled reboot, low-power mode).
# POST: Saves settings, scheduled reboot config, or low-power config.
#
# Config: /etc/qmanager/qmanager.conf (settings section)
# Timer:  qmanager-scheduled-reboot.timer, armed through the root helper
#         /usr/bin/qmanager_scheduled_reboot_arm
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/settings.sh
# Install location: /www/cgi-bin/quecmanager/system/settings.sh
# =============================================================================

qlog_init "cgi_system_settings"
cgi_headers
cgi_handle_options

# --- Helpers -----------------------------------------------------------------

# Path to the privileged arm helper. Overridable for the same test-only reason
# as LIB_DIR above, and absolute in every case — never resolved through PATH.
SCHED_ARM_HELPER="${QM_ARM_BIN_DIR:-/usr/bin}/qmanager_scheduled_reboot_arm"

# Turn the arm helper's machine-readable reason into a sentence the user can act
# on. Every branch says the same two things, because both are true: the schedule
# IS saved, and the device will NOT reboot until the arming problem is resolved.
sched_arm_message() {
    case "$1" in
        helper_unavailable)
            printf '%s' "Saved the reboot schedule, but it could not be armed — this build does not carry the timer helper yet. Updating QManager installs it." ;;
        unit_absent)
            printf '%s' "Saved the reboot schedule, but it could not be armed — the reboot timer unit is not installed. Updating QManager installs it." ;;
        no_schedule)
            printf '%s' "Saved the reboot schedule, but it resolves to no day at all, so no reboot is scheduled." ;;
        timer_inactive)
            printf '%s' "Saved the reboot schedule, but the system did not start the timer, so no reboot is scheduled yet. It should arm on the next reboot." ;;
        *)
            printf '%s' "Saved the reboot schedule, but it could not be armed, so the device will not reboot on its own." ;;
    esac
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

        # Validate when enabling.
        #
        # The arm helper validates these again — it must, since it runs as root
        # on values that arrived over HTTP. This copy exists so a bad request
        # gets a specific error where it was parsed, instead of a generic
        # "could not be armed" warning from one layer down.
        if [ "$ENABLED" = "true" ]; then
            # HH:MM with a real 00-23 hour. The looser [0-2][0-9] this used to
            # carry accepts "25:00"; cron ignored the line, systemd instead
            # rejects the calendar and loads the timer as failed — a schedule
            # that saves clean and never fires, which is the failure being
            # fixed. A `case` pattern matches the whole string, so an embedded
            # newline cannot slip past it the way it can past an anchored
            # `grep -E`, which matches line by line.
            case "$SCHED_TIME" in
                [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
                *)
                    cgi_error "invalid_time" "time must be HH:MM, 00:00-23:59"
                    exit 0
                    ;;
            esac

            # Validate days
            if [ -z "$DAYS_RAW" ]; then
                cgi_error "no_days" "At least one day must be selected"
                exit 0
            fi

            # A leading, trailing or doubled comma is rejected rather than
            # silently collapsing: the loop below word-splits, so empty fields
            # vanish there and the stored mask would quietly differ from the
            # one sent.
            case "$DAYS_RAW" in
                ,*|*,|*,,*)
                    cgi_error "invalid_day" "days must be a comma-separated list of 0-6"
                    exit 0
                    ;;
            esac

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
        # Bail on the first failed write and leave the timer alone. The timer is
        # what actually reboots the device; the config is what the UI reads
        # back. Arming a timer for a schedule the config does not hold would
        # give the user a device that reboots at a time no page ever shows — the
        # worst of the two possible mismatches.
        sched_write_failed() {
            cgi_error "sched_save_failed" \
                "Could not save the reboot schedule — writing the configuration file failed. The existing schedule was left untouched."
            exit 0
        }
        case "$ENABLED" in
            true)  qm_config_set settings sched_reboot_enabled 1 || sched_write_failed ;;
            false) qm_config_set settings sched_reboot_enabled 0 || sched_write_failed ;;
        esac
        qm_config_set settings sched_reboot_time "$SCHED_TIME" || sched_write_failed
        qm_config_set settings sched_reboot_days "$DAYS_RAW" || sched_write_failed

        # --- Arm (or disarm) the systemd timer -------------------------------
        #
        # This used to printf a line into /var/spool/cron/crontabs/root. Nothing
        # on this device reads that file: there is no crond unit, the binary
        # never runs, and the spool directory is empty. So the toggle reported
        # success and the box never rebooted — not once, for any user. systemd's
        # own timers are the mechanism that actually fires here.
        #
        # The CGI runs as www-data and cannot write /lib/systemd/system, so the
        # unit is generated by a root helper reached through an exact-path
        # sudoers rule — the same shape as the hostname and timezone helpers.
        if [ "$ENABLED" = "true" ]; then
            arm_resp=$($_SUDO "$SCHED_ARM_HELPER" install "$SCHED_TIME" "$DAYS_RAW" 2>/dev/null)
        else
            arm_resp=$($_SUDO "$SCHED_ARM_HELPER" teardown 2>/dev/null)
        fi

        # Read .armed, never .success. The helper answers success:true with
        # armed:false when it did its job and there is still nothing scheduled —
        # an older base without the .service, or a timer systemd declined to
        # start. A green tick over that response rebuilds the exact bug this
        # replaces, one layer up.
        schedule_armed="false"
        arm_reason=""
        if [ -z "$arm_resp" ]; then
            # No JSON at all: the helper is missing, or sudo refused it. Either
            # way the device carries no new schedule.
            arm_reason="helper_unavailable"
        else
            case "$(printf '%s' "$arm_resp" | jq -r '.armed // false' 2>/dev/null)" in
                true) schedule_armed="true" ;;
            esac
            arm_reason=$(printf '%s' "$arm_resp" | jq -r '.reason // .error // ""' 2>/dev/null)
        fi

        # schedule_armed answers one question — is a reboot scheduled on this
        # device right now — and arm_error appears only when that answer
        # disagrees with what was asked for. Disabling successfully is
        # armed:false with no error; it is the intended outcome, not a warning.
        arm_error=""
        if [ "$ENABLED" = "true" ]; then
            if [ "$schedule_armed" != "true" ]; then
                arm_error=$(sched_arm_message "$arm_reason")
                qlog_warn "Scheduled reboot saved but not armed (reason=${arm_reason:-unknown})"
            else
                qlog_info "Scheduled reboot armed: ${SCHED_TIME} days=${DAYS_RAW}"
            fi
        elif [ -n "$arm_reason" ]; then
            # Teardown reports "" on success. Anything else means the old unit
            # may still be on disk and counting down, so the schedule the user
            # just switched off can still fire. Report it as still armed:
            # guessing "off" here would be the comfortable answer, not the true
            # one, and the failure it hides is an unexpected reboot.
            schedule_armed="true"
            arm_error="Saved the schedule as disabled, but the existing timer could not be removed — the device may still reboot on the old schedule."
            qlog_warn "Scheduled reboot disable saved but timer not removed (reason=${arm_reason})"
        else
            qlog_info "Scheduled reboot timer removed"
        fi

        # Build response
        DAYS_RESP=$(printf '%s' "$DAYS_RAW" | jq -Rc 'split(",") | map(tonumber)' 2>/dev/null)
        [ -z "$DAYS_RESP" ] && DAYS_RESP="[0,1,2,3,4,5,6]"

        # schedule_armed always travels, in both directions — it is the fact the
        # old response was missing. schedule_apply_error appears only when the
        # save and the arming disagree, matching how save_settings reports a
        # failed hostname or timezone apply: the preference is stored either
        # way, so this is a warning on a successful save, never a failed one.
        jq -n \
            --argjson enabled "$([ "$ENABLED" = "true" ] && echo true || echo false)" \
            --arg time "$SCHED_TIME" \
            --argjson days "$DAYS_RESP" \
            --argjson armed "$schedule_armed" \
            --arg arm_error "$arm_error" \
            '{success: true,
              scheduled_reboot: {enabled: $enabled, time: $time, days: $days},
              schedule_armed: $armed}
             + (if $arm_error == "" then {} else {schedule_apply_error: $arm_error} end)'
        exit 0
    fi

    # Unknown action
    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

# Method not allowed
cgi_error "method_not_allowed" "Only GET and POST are supported"
