#!/bin/sh
# The library root is a variable so scripts/test/schedule-cgi.sh can run this
# endpoint against stub libraries. A request cannot introduce it: lighttpd
# exports a request's headers as HTTP_* and nothing else. Same hook as
# settings/quality_thresholds.sh.
LIB_DIR="${QM_LIB_DIR:-/usr/lib/qmanager}"
. "$LIB_DIR/cgi_base.sh"
# For $_SUDO. cgi_base.sh already sources platform.sh, but its fallback stub
# does not define $_SUDO, and the arm helper below has to run as root — so name
# the dependency here rather than inherit it by luck. platform.sh guards against
# double-sourcing.
. "$LIB_DIR/platform.sh"
# =============================================================================
# schedule.sh — CGI Endpoint: Update Tower Lock Schedule
# =============================================================================
# Updates the schedule section of tower_lock.json and arms the pair of systemd
# timers that apply and clear the lock.
#
# POST body:
#   {"enabled": true, "start_time": "08:00", "end_time": "22:00", "days": [1,2,3,4,5]}
#
# When enabled, arms qmanager-tower-schedule-apply.timer (at start_time) and
# qmanager-tower-schedule-clear.timer (at end_time) through the root helper
# /usr/bin/qmanager_tower_schedule_arm. When disabled, tears both down.
#
# Endpoint: POST /cgi-bin/quecmanager/tower/schedule.sh
# Install location: /www/cgi-bin/quecmanager/tower/schedule.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_tower_schedule"
cgi_headers
cgi_handle_options

# --- Load library ------------------------------------------------------------
. "$LIB_DIR/tower_lock_mgr.sh" 2>/dev/null

# Path to the privileged arm helper. Overridable for the same test-only reason
# as LIB_DIR above, and absolute in every case — never resolved through PATH.
TOWER_ARM_HELPER="${QM_ARM_BIN_DIR:-/usr/bin}/qmanager_tower_schedule_arm"

# Turn the arm helper's machine-readable reason into a sentence the user can act
# on. The schedule IS saved in every branch; what failed is the arming, and
# until it is fixed the lock will neither apply nor clear on its own.
tower_arm_message() {
    case "$1" in
        helper_unavailable)
            printf '%s' "Saved the schedule, but it could not be armed — this build does not carry the timer helper yet. Updating QManager installs it." ;;
        unit_absent)
            printf '%s' "Saved the schedule, but it could not be armed — the tower schedule timer units are not installed. Updating QManager installs them." ;;
        no_schedule)
            printf '%s' "Saved the schedule, but it resolves to no day at all, so nothing is scheduled." ;;
        timer_inactive)
            printf '%s' "Saved the schedule, but the system did not start the timers, so the lock will not apply or clear yet. They should arm on the next reboot." ;;
        *)
            printf '%s' "Saved the schedule, but it could not be armed, so the tower lock will not apply or clear on its own." ;;
    esac
}

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Read POST body ----------------------------------------------------------
cgi_read_post

# --- Parse fields using jq ---------------------------------------------------
# IMPORTANT: Cannot use `// empty` for booleans — jq treats `false` as falsy,
# so `false // empty` produces nothing. Use `has()` + `tostring` instead.
ENABLED=$(printf '%s' "$POST_DATA" | jq -r 'if has("enabled") then (.enabled | tostring) else "" end' 2>/dev/null)
START_TIME=$(printf '%s' "$POST_DATA" | jq -r '.start_time // empty' 2>/dev/null)
END_TIME=$(printf '%s' "$POST_DATA" | jq -r '.end_time // empty' 2>/dev/null)
# Get days as comma-separated string (e.g., "1,2,3,4,5")
DAYS_RAW=$(printf '%s' "$POST_DATA" | jq -r '.days // [] | join(",")' 2>/dev/null)
# Get days as JSON array for config update (e.g., "[1,2,3,4,5]")
DAYS_JSON=$(printf '%s' "$POST_DATA" | jq -c '.days // [1,2,3,4,5]' 2>/dev/null)

# --- Validate ----------------------------------------------------------------
if [ -z "$ENABLED" ]; then
    cgi_error "no_enabled" "Missing enabled field"
    exit 0
fi

if [ "$ENABLED" = "true" ]; then
    # The arm helper validates these again — it must, since it runs as root on
    # values that arrived over HTTP. This copy exists so a bad request gets a
    # specific error where it was parsed, instead of a generic "could not be
    # armed" warning from one layer down.
    #
    # HH:MM with a real 00-23 hour. The looser [0-2][0-9] this used to carry
    # accepts "25:00"; cron ignored such a line, systemd instead rejects the
    # calendar and loads the timer as failed — a schedule that saves clean and
    # never fires, which is the failure being fixed. A `case` pattern matches
    # the whole string, so an embedded newline cannot slip past it the way it
    # can past an anchored `grep -E`, which matches line by line.
    case "$START_TIME" in
        [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
        *)
            cgi_error "invalid_start_time" "start_time must be HH:MM, 00:00-23:59"
            exit 0
            ;;
    esac
    case "$END_TIME" in
        [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
        *)
            cgi_error "invalid_end_time" "end_time must be HH:MM, 00:00-23:59"
            exit 0
            ;;
    esac

    # Validate days
    if [ -z "$DAYS_RAW" ]; then
        cgi_error "no_days" "At least one day must be selected"
        exit 0
    fi

    # A leading, trailing or doubled comma is rejected rather than silently
    # collapsing: the loop below word-splits, so empty fields vanish there and
    # the armed mask would quietly differ from the one sent.
    case "$DAYS_RAW" in
        ,*|*,|*,,*)
            cgi_error "invalid_day" "days must be a comma-separated list of 0-6"
            exit 0
            ;;
    esac

    # Validate each day is 0-6
    invalid_day=""
    for d in $(echo "$DAYS_RAW" | tr ',' ' '); do
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

# Ensure config exists
tower_config_init

# --- Scenario 1 guard: Reject enable if no lock targets configured -----------
if [ "$ENABLED" = "true" ]; then
    # Check LTE: at least one cell with earfcn+pci (using jq)
    has_lte=$(tower_config_get '.lte.cells | map(select(. != null)) | length')
    [ -z "$has_lte" ] && has_lte="0"

    # Check NR-SA: pci and arfcn are non-null (using jq)
    nr_pci=$(tower_config_get '.nr_sa.pci')
    nr_arfcn=$(tower_config_get '.nr_sa.arfcn')
    has_nr="false"
    if [ -n "$nr_pci" ] && [ "$nr_pci" != "null" ] && \
       [ -n "$nr_arfcn" ] && [ "$nr_arfcn" != "null" ]; then
        has_nr="true"
    fi

    if [ "$has_lte" = "0" ] && [ "$has_nr" = "false" ]; then
        cgi_error "no_lock_targets" "Configure LTE or NR-SA lock targets before enabling schedule"
        exit 0
    fi
fi

qlog_info "Schedule update: enabled=$ENABLED start=$START_TIME end=$END_TIME days=$DAYS_RAW"

# --- Update config file schedule section using jq (atomic, safe) -------------
# Use defaults for schedule params if not provided (when disabling)
[ -z "$START_TIME" ] && START_TIME="08:00"
[ -z "$END_TIME" ] && END_TIME="22:00"
[ -z "$DAYS_JSON" ] || [ "$DAYS_JSON" = "null" ] && DAYS_JSON="[1,2,3,4,5]"

# Bail before touching the timers if the config write failed. The timers are
# what actually move the lock; the config is what the UI reads back. Arming a
# schedule the config does not hold would apply a tower lock at a time no page
# ever shows.
if ! tower_config_update_schedule "$ENABLED" "$START_TIME" "$END_TIME" "$DAYS_JSON"; then
    cgi_error "schedule_save_failed" \
        "Could not save the schedule — writing tower_lock.json failed. The existing schedule was left untouched."
    exit 0
fi

# --- Arm (or disarm) the systemd timer pair ---------------------------------
#
# This used to printf two lines into /var/spool/cron/crontabs/root. Nothing on
# this device reads that file: there is no crond unit, the binary never runs,
# and the spool directory is empty. So the schedule never applied a lock and
# never cleared one, while the page showed it as active.
#
# One helper call manages both boundaries, all-or-nothing, because half a
# schedule is worse than none: an apply that fires with no clear leaves the
# modem pinned to one cell indefinitely.
#
# The CGI runs as www-data and cannot write /lib/systemd/system, so the units
# are generated by a root helper reached through an exact-path sudoers rule.
if [ "$ENABLED" = "true" ]; then
    arm_resp=$($_SUDO "$TOWER_ARM_HELPER" install "$START_TIME" "$END_TIME" "$DAYS_RAW" 2>/dev/null)
else
    arm_resp=$($_SUDO "$TOWER_ARM_HELPER" teardown 2>/dev/null)
fi

# Read .armed, never .success. The helper answers success:true with armed:false
# when it did its job and there is still nothing scheduled — an older base
# without the .service units, or timers systemd declined to start. A green tick
# over that response rebuilds the exact bug this replaces, one layer up.
schedule_armed="false"
arm_reason=""
if [ -z "$arm_resp" ]; then
    # No JSON at all: the helper is missing, or sudo refused it. Either way the
    # device carries no new schedule.
    arm_reason="helper_unavailable"
else
    case "$(printf '%s' "$arm_resp" | jq -r '.armed // false' 2>/dev/null)" in
        true) schedule_armed="true" ;;
    esac
    arm_reason=$(printf '%s' "$arm_resp" | jq -r '.reason // .error // ""' 2>/dev/null)
fi

# schedule_armed answers one question — will the lock apply and clear on this
# device — and schedule_apply_error appears only when that answer disagrees with
# what was asked for. Disabling successfully is armed:false with no error; it is
# the intended outcome, not a warning.
arm_error=""
if [ "$ENABLED" = "true" ]; then
    if [ "$schedule_armed" != "true" ]; then
        arm_error=$(tower_arm_message "$arm_reason")
        qlog_warn "Tower schedule saved but not armed (reason=${arm_reason:-unknown})"
    else
        qlog_info "Tower schedule armed: apply at ${START_TIME}, clear at ${END_TIME}, days=${DAYS_RAW}"
    fi
elif [ -n "$arm_reason" ]; then
    # Teardown reports "" on success. Anything else means the old units may
    # still be on disk and counting down, so the schedule the user just switched
    # off can still move the lock. Report it as still armed: guessing "off" here
    # would be the comfortable answer, not the true one.
    schedule_armed="true"
    arm_error="Saved the schedule as disabled, but the existing timers could not be removed — the tower lock may still apply and clear on the old schedule."
    qlog_warn "Tower schedule disable saved but timers not removed (reason=${arm_reason})"
else
    qlog_info "Tower schedule timers removed"
fi

# --- Response (using jq for guaranteed valid JSON) ---------------------------
# Reconstruct days as JSON array for response
DAYS_RESP=$(printf '%s' "$DAYS_RAW" | jq -Rc 'split(",") | map(tonumber)' 2>/dev/null)
[ -z "$DAYS_RESP" ] && DAYS_RESP="$DAYS_JSON"

# schedule_armed always travels, in both directions — it is the fact the old
# response was missing. schedule_apply_error appears only when the save and the
# arming disagree, so a consumer that does not know either field is unaffected.
jq -n \
    --argjson enabled "$ENABLED" \
    --arg start "$START_TIME" \
    --arg end "$END_TIME" \
    --argjson days "$DAYS_RESP" \
    --argjson armed "$schedule_armed" \
    --arg arm_error "$arm_error" \
    '{success: true, enabled: $enabled, start_time: $start, end_time: $end, days: $days,
      schedule_armed: $armed}
     + (if $arm_error == "" then {} else {schedule_apply_error: $arm_error} end)'
