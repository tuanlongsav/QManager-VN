#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/config.sh
. /usr/lib/qmanager/platform.sh
# =============================================================================
# watchdog.sh — CGI Endpoint: Watchdog Settings & Status (GET + POST)
# =============================================================================
# GET:  Returns current watchdog configuration (qmanager.conf) + live status.
# POST: Saves settings, dismisses SIM swap, or requests SIM revert.
#
# Config: /etc/qmanager/qmanager.conf [watchcat] section
# State:  /tmp/qmanager_watchcat.json (read-only, written by daemon)
#
# Endpoint: GET/POST /cgi-bin/quecmanager/monitoring/watchdog.sh
# Install location: /www/cgi-bin/quecmanager/monitoring/watchdog.sh
# =============================================================================

qlog_init "cgi_watchdog"
cgi_headers
cgi_handle_options

WATCHCAT_STATE="/tmp/qmanager_watchcat.json"
SIM_SWAP_FLAG="/tmp/qmanager_sim_swap_detected"
# Must match qmanager_watchcat — persistent, readable by www-data.
SIM_FAILOVER_FILE="/etc/qmanager/sim_failover.json"
RELOAD_FLAG="/tmp/qmanager_watchcat_reload"
REVERT_FLAG="/tmp/qmanager_watchcat_revert_sim"
DISABLED_FLAG="/tmp/qmanager_watchcat_disabled"

# =============================================================================
# Accepted ranges for the numeric watchcat settings
# =============================================================================
# One definition, two consumers: GET clamps stored values into these bounds on
# the way out, POST rejects submitted values outside them. They must never
# drift apart — the moment GET can hand back a value POST refuses, the user is
# locked out of saving anything on this page, which is exactly the bug a second
# hardcoded copy of "5 3600" would reintroduce.
#
# Bounds match the UI inputs in
# components/monitoring/watchdog/watchdog-settings-card.tsx where it constrains
# them (max_failures 1-20, cooldown 10-300, max_reboots_per_hour 1-10).
# check_interval is a fixed Select there (5/10/15/30) with no numeric
# validation of its own — an off-list stored value is submitted back verbatim —
# so it gets a deliberately wide range that still excludes the values that are
# actively harmful.
#
# These are the *policy* bounds and the only place they are defined. The
# qmanager_watchcat daemon separately refuses to sleep on a value it cannot
# parse, or below a hardware floor, because it can be started from a config
# this endpoint never saw. Those are floors only, strictly weaker than the
# range here, and never ceilings — see the block above read_config there before
# changing anything below.
MAX_FAILURES_MIN=1
MAX_FAILURES_MAX=20
CHECK_INTERVAL_MIN=5
CHECK_INTERVAL_MAX=3600
COOLDOWN_MIN=10
COOLDOWN_MAX=300
MAX_REBOOTS_MIN=1
MAX_REBOOTS_MAX=10

# validate_int <value> <min> <max> <field-name>
#
# Rejects the whole request with a JSON error unless <value> is a whole number
# inside [min,max].
#
# The length cap is load-bearing, not belt-and-braces. Checking only that the
# string is all digits lets through something like 99999999999999999999, which
# `[ -lt ]` and `[ -gt ]` cannot parse: both comparisons then print "integer
# expression expected" to stderr and return FALSE, so the || rejection never
# fires and the value is accepted. The guard would fail open at exactly the
# input it exists to stop. Ten or more digits are rejected outright, which
# keeps every accepted value inside signed 32-bit range on this ARMv7 shell
# while still leaving room far above the largest bound here (3600).
validate_int() {
    case "$1" in
        ''|*[!0-9]*|??????????*)
            echo "{\"success\":false,\"error\":\"$4 must be a whole number\"}"
            exit 0 ;;
    esac
    if [ "$1" -lt "$2" ] || [ "$1" -gt "$3" ]; then
        echo "{\"success\":false,\"error\":\"$4 must be between $2 and $3\"}"
        exit 0
    fi
}

# clamp_int <value> <min> <max> <field-name>
#
# Echoes <value> forced into [min,max] — the read-side counterpart of
# validate_int, over the same bounds.
#
# Nothing validated these settings before, so a config hand-edited over SSH or
# written by an older build can still hold an out-of-range value, and that is a
# live hazard rather than a cosmetic one: the watchcat daemon feeds
# check_interval straight into its sleep, so a stored 0 or 1 spins the recovery
# loop, and a cooldown under 10 lets it escalate through every tier — up to and
# including reboots — with no real pause between them.
#
# Reporting the clamped value is what actually repairs it. Handed the raw
# value, the settings card round-trips it back unchanged on the next save and
# validate_int refuses it, so every save of every watchdog field fails until
# the user SSHes in — and check_interval in particular has no UI control that
# would show them why. Reporting the clamped value instead means their next
# save writes something in range.
#
# Non-numeric and missing values are echoed untouched: qm_config_get already
# substitutes the documented default for an absent or empty key, and anything
# else is a corruption this helper has no honest repair for.
#
# The warnings are redirected to stderr because the only caller reads this
# function through a command substitution: with QLOG_TO_STDOUT=1 the log line
# would otherwise be captured *as* the setting's value, and jq --argjson would
# then reject the whole response.
clamp_int() {
    case "$1" in
        ''|*[!0-9]*)
            echo "$1"; return ;;
        ??????????*)
            # Ten or more digits: certainly above any bound used here, and too
            # wide for [ -gt ] to compare — see validate_int.
            qlog_warn "Stored $4=$1 exceeds maximum $3 — reporting $3" >&2
            echo "$3"; return ;;
    esac
    if [ "$1" -lt "$2" ]; then
        qlog_warn "Stored $4=$1 below minimum $2 — reporting $2" >&2
        echo "$2"
    elif [ "$1" -gt "$3" ]; then
        qlog_warn "Stored $4=$1 above maximum $3 — reporting $3" >&2
        echo "$3"
    else
        echo "$1"
    fi
}

# =============================================================================
# GET — Fetch settings + live status
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    qlog_info "Fetching watchdog settings"
    qm_config_init

    enabled="" max_failures="" check_interval="" cooldown=""
    tier1="" tier2="" tier3="" tier4="" backup_sim="" max_reboots=""

    enabled=$(qm_config_get watchcat enabled 0)
    # Clamped on the way out — see clamp_int for why a stored out-of-range
    # value has to be repaired here rather than passed through.
    max_failures=$(clamp_int "$(qm_config_get watchcat max_failures 5)" \
        "$MAX_FAILURES_MIN" "$MAX_FAILURES_MAX" max_failures)
    check_interval=$(clamp_int "$(qm_config_get watchcat check_interval 10)" \
        "$CHECK_INTERVAL_MIN" "$CHECK_INTERVAL_MAX" check_interval)
    cooldown=$(clamp_int "$(qm_config_get watchcat cooldown 60)" \
        "$COOLDOWN_MIN" "$COOLDOWN_MAX" cooldown)
    tier1=$(qm_config_get watchcat tier1_enabled 1)
    tier2=$(qm_config_get watchcat tier2_enabled 1)
    tier3=$(qm_config_get watchcat tier3_enabled 0)
    tier4=$(qm_config_get watchcat tier4_enabled 1)
    backup_sim=$(qm_config_get watchcat backup_sim_slot "")
    max_reboots=$(clamp_int "$(qm_config_get watchcat max_reboots_per_hour 3)" \
        "$MAX_REBOOTS_MIN" "$MAX_REBOOTS_MAX" max_reboots_per_hour)

    # Read live status from watchcat daemon state file
    status_json='{}'
    if [ -f "$WATCHCAT_STATE" ]; then
        status_json=$(cat "$WATCHCAT_STATE" 2>/dev/null)
    fi

    # Read SIM failover state
    sim_failover_json='{"active":false}'
    if [ -f "$SIM_FAILOVER_FILE" ]; then
        sim_failover_json=$(cat "$SIM_FAILOVER_FILE" 2>/dev/null)
    fi

    # Read SIM swap detection
    sim_swap_json='{"detected":false}'
    if [ -f "$SIM_SWAP_FLAG" ]; then
        sim_swap_json=$(cat "$SIM_SWAP_FLAG" 2>/dev/null)
    fi

    # Check if watchcat was auto-disabled
    auto_disabled="false"
    [ -f "$DISABLED_FLAG" ] && auto_disabled="true"

    jq -n \
        --argjson enabled "$enabled" \
        --argjson max_failures "$max_failures" \
        --argjson check_interval "$check_interval" \
        --argjson cooldown "$cooldown" \
        --argjson tier1 "$tier1" \
        --argjson tier2 "$tier2" \
        --argjson tier3 "$tier3" \
        --argjson tier4 "$tier4" \
        --arg backup_sim "$backup_sim" \
        --argjson max_reboots "$max_reboots" \
        --argjson status "$status_json" \
        --argjson sim_failover "$sim_failover_json" \
        --argjson sim_swap "$sim_swap_json" \
        --argjson auto_disabled "$auto_disabled" \
        '{
            success: true,
            settings: {
                enabled: ($enabled == 1),
                max_failures: $max_failures,
                check_interval: $check_interval,
                cooldown: $cooldown,
                tier1_enabled: ($tier1 == 1),
                tier2_enabled: ($tier2 == 1),
                tier3_enabled: ($tier3 == 1),
                tier4_enabled: ($tier4 == 1),
                backup_sim_slot: (if $backup_sim == "" then null else ($backup_sim | tonumber) end),
                max_reboots_per_hour: $max_reboots
            },
            status: $status,
            sim_failover: $sim_failover,
            sim_swap: $sim_swap,
            auto_disabled: $auto_disabled
        }'
    exit 0
fi

# =============================================================================
# POST — Save settings / dismiss SIM swap / revert SIM
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
        qlog_info "Saving watchdog settings"
        qm_config_init

        # --- Pass 1: validate every numeric field before writing anything ----
        #
        # These values drive the recovery ladder directly: a zero or negative
        # check_interval spins the daemon in a busy loop, and a zero cooldown
        # lets it escalate through every tier without pause — up to and
        # including reboots. Previously each field was written the moment it
        # was parsed, so a bad value late in the body left the earlier ones
        # already committed and the config half-applied. Validate the whole
        # payload first, reject as a unit, then write.
        #
        # validate_int and the bounds it is given are defined at the top of
        # this file, shared with the GET handler's clamp.
        v_max_failures=$(printf '%s' "$POST_DATA" | jq -r '.max_failures // empty')
        v_check_interval=$(printf '%s' "$POST_DATA" | jq -r '.check_interval // empty')
        v_cooldown=$(printf '%s' "$POST_DATA" | jq -r '.cooldown // empty')
        v_max_reboots=$(printf '%s' "$POST_DATA" | jq -r '.max_reboots_per_hour // empty')

        [ -n "$v_max_failures" ]   && validate_int "$v_max_failures" \
            "$MAX_FAILURES_MIN"   "$MAX_FAILURES_MAX"   "max_failures"
        [ -n "$v_check_interval" ] && validate_int "$v_check_interval" \
            "$CHECK_INTERVAL_MIN" "$CHECK_INTERVAL_MAX" "check_interval"
        [ -n "$v_cooldown" ]       && validate_int "$v_cooldown" \
            "$COOLDOWN_MIN"       "$COOLDOWN_MAX"       "cooldown"
        [ -n "$v_max_reboots" ]    && validate_int "$v_max_reboots" \
            "$MAX_REBOOTS_MIN"    "$MAX_REBOOTS_MAX"    "max_reboots_per_hour"

        # --- Pass 2: everything validated — commit ---------------------------
        #
        # commit_or_abort <section> <key> <value>
        #
        # qm_config_set returns 1 when jq failed or when it produced an empty
        # temp file, and leaves the live config untouched in that case — so a
        # refusal here means the config store is unwritable right now, not that
        # the file is already damaged. Answering {"success":true} regardless
        # (which is what this handler used to do for all ten writes) tells the
        # user their settings are in force when they are not.
        #
        # Bail on the first refusal rather than pushing on: validation is done,
        # so anything still unwritten stays at its previous value, and because
        # we never reach the reload flag or the service restart below, the
        # running daemon keeps the coherent config it started with instead of
        # reloading a half-updated one.
        #
        # The response admits the partial write. Claiming nothing happened
        # would be a lie the user could act on — they would reopen the page,
        # find settings they never confirmed, and have no idea where they came
        # from. The config key doubles as the field name in the message; every
        # key written here is one the settings card also shows.
        commit_or_abort() {
            qm_config_set "$1" "$2" "$3" && return 0
            qlog_error "Failed to write $1.$2 — aborting save"
            jq -n --arg field "$2" \
                '{success:false,
                  error:("Could not save " + $field + ": writing the configuration file failed. Settings saved before it in this request were already applied — reload the page to see the current values."),
                  failed_field:$field,
                  partial:true}'
            exit 0
        }

        val=""

        val=$(printf '%s' "$POST_DATA" | jq -r '.enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in
                true)  commit_or_abort watchcat enabled 1 ;;
                false) commit_or_abort watchcat enabled 0 ;;
            esac
        fi

        [ -n "$v_max_failures" ]   && commit_or_abort watchcat max_failures   "$v_max_failures"
        [ -n "$v_check_interval" ] && commit_or_abort watchcat check_interval "$v_check_interval"
        [ -n "$v_cooldown" ]       && commit_or_abort watchcat cooldown       "$v_cooldown"

        val=$(printf '%s' "$POST_DATA" | jq -r '.tier1_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) commit_or_abort watchcat tier1_enabled 1 ;; false) commit_or_abort watchcat tier1_enabled 0 ;; esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.tier2_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) commit_or_abort watchcat tier2_enabled 1 ;; false) commit_or_abort watchcat tier2_enabled 0 ;; esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.tier3_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) commit_or_abort watchcat tier3_enabled 1 ;; false) commit_or_abort watchcat tier3_enabled 0 ;; esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.tier4_enabled | if . == null then empty else tostring end')
        if [ -n "$val" ]; then
            case "$val" in true) commit_or_abort watchcat tier4_enabled 1 ;; false) commit_or_abort watchcat tier4_enabled 0 ;; esac
        fi

        val=$(printf '%s' "$POST_DATA" | jq -r '.backup_sim_slot // empty')
        if [ -n "$val" ] && [ "$val" != "null" ]; then
            commit_or_abort watchcat backup_sim_slot "$val"
        else
            commit_or_abort watchcat backup_sim_slot ""
        fi

        [ -n "$v_max_reboots" ] && commit_or_abort watchcat max_reboots_per_hour "$v_max_reboots"

        # Signal running watchcat daemon to reload config (if it's already running)
        touch "$RELOAD_FLAG"

        # Clear auto-disabled flag if user is re-enabling
        new_enabled=""
        new_enabled=$(qm_config_get watchcat enabled 0)
        if [ "$new_enabled" = "1" ]; then
            rm -f "$DISABLED_FLAG"
            # Enable and start the watchcat service
            svc_enable qmanager_watchcat
            ( svc_restart qmanager_watchcat & )
            qlog_info "Watchdog settings saved, watchcat enabled and started"
        else
            # Stop and disable the watchcat service
            svc_stop qmanager_watchcat
            svc_disable qmanager_watchcat
            qlog_info "Watchdog settings saved, watchcat stopped and disabled"
        fi
        echo '{"success":true}'
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: dismiss_sim_swap
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "dismiss_sim_swap" ]; then
        qlog_info "Dismissing SIM swap notification"
        if [ -f "$SIM_SWAP_FLAG" ]; then
            tmp_json=$(jq -c '.dismissed = true' "$SIM_SWAP_FLAG" 2>/dev/null)
            if [ -n "$tmp_json" ]; then
                printf '%s\n' "$tmp_json" > "$SIM_SWAP_FLAG"
            fi
        fi
        echo '{"success":true}'
        exit 0
    fi

    # -------------------------------------------------------------------------
    # action: revert_sim
    # -------------------------------------------------------------------------
    if [ "$ACTION" = "revert_sim" ]; then
        qlog_info "User requesting SIM revert"
        touch "$REVERT_FLAG"
        echo '{"success":true,"message":"SIM revert requested. The watchcat will process this shortly."}'
        exit 0
    fi

    # Unknown action
    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

# Method not allowed
cgi_error "method_not_allowed" "Only GET and POST are supported"
