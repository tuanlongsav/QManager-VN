#!/bin/sh
# The library root is a variable so scripts/test/schedule-cgi.sh can run this
# endpoint against stub libraries. A request cannot introduce it: lighttpd
# exports a request's headers as HTTP_* and nothing else. Same hook as
# settings/quality_thresholds.sh.
LIB_DIR="${QM_LIB_DIR:-/usr/lib/qmanager}"
. "$LIB_DIR/cgi_base.sh"
. "$LIB_DIR/config.sh"
. "$LIB_DIR/semver.sh"
. "$LIB_DIR/downloader.sh"
# For $_SUDO, used by the auto-update arm helper below. cgi_base.sh already
# sources platform.sh, but its fallback stub does not define $_SUDO, and that
# helper has to run as root — so name the dependency here rather than inherit it
# by luck. platform.sh guards against double-sourcing.
. "$LIB_DIR/platform.sh"
# =============================================================================
# update.sh — CGI Endpoint: Software Update (GET + POST)
# =============================================================================
# GET:                   Check for updates via GitHub Releases API
# GET action=status:     Read update progress from status file
# POST action=download:  Stage a version (download + SHA-256 verify)
# POST action=install_staged: Install the staged tarball
# POST action=install:   Legacy one-step install (used by auto-updater)
# POST action=save_prerelease: Toggle pre-release preference
# POST action=save_auto_update: Configure auto-update schedule
#
# Config: UCI quecmanager.update.*
# State:  /tmp/qmanager_update.json, /tmp/qmanager_update.pid
#         /tmp/qmanager_staged.tar.gz, /tmp/qmanager_staged_version
# Timer:  qmanager-auto-update.timer, armed through the root helper
#         /usr/bin/qmanager_auto_update_arm
#
# Endpoint: GET/POST /cgi-bin/quecmanager/system/update.sh
# =============================================================================

qlog_init "cgi_system_update"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------

GITHUB_REPO="tuanlongsav/QManager-VN"
VERSION_FILE="/etc/qmanager/VERSION"
VERSION_PENDING="/etc/qmanager/VERSION.pending"
UPDATES_DIR="/etc/qmanager/updates"
STATUS_FILE="/tmp/qmanager_update.json"
PID_FILE="/tmp/qmanager_update.pid"
UPDATER="/usr/bin/qmanager_update"

# --- Helpers -----------------------------------------------------------------

get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        tr -d '[:space:]' < "$VERSION_FILE"
    else
        echo "0.0.0"
    fi
}

uci_update_get() {
    qm_config_get update "$1" "$2"
}

ensure_update_config() {
    qm_config_init
}

# Path to the privileged arm helper for the auto-update schedule. Overridable
# for the same test-only reason as LIB_DIR above, and absolute in every case —
# never resolved through PATH.
AUTO_UPDATE_ARM_HELPER="${QM_ARM_BIN_DIR:-/usr/bin}/qmanager_auto_update_arm"

# Turn the arm helper's machine-readable reason into a sentence the user can act
# on. The preference IS saved in every branch; what failed is the arming, and
# until it is fixed the device will not check for updates on its own.
auto_update_arm_message() {
    case "$1" in
        helper_unavailable)
            printf '%s' "Saved the auto-update preference, but the schedule could not be armed — this build does not carry the timer helper yet. Update once manually to install it." ;;
        unit_absent)
            printf '%s' "Saved the auto-update preference, but the schedule could not be armed — the auto-update timer unit is not installed. Update once manually to install it." ;;
        timer_inactive)
            printf '%s' "Saved the auto-update preference, but the system did not start the timer, so no automatic check is scheduled yet. It should arm on the next reboot." ;;
        *)
            printf '%s' "Saved the auto-update preference, but the schedule could not be armed, so the device will not check for updates on its own." ;;
    esac
}

# Check if an update process is already running
check_lock() {
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if pid_alive "$pid"; then
            cgi_error "update_in_progress" "An update is already in progress"
            exit 0
        fi
        rm -f "$PID_FILE"
    fi
}

# Fetch URL to a file, capturing HTTP headers for rate-limit detection.
# Transport is curl or wget, whichever the device has (see downloader.sh).
# Header format differs between the two — the rate-limit parsing below uses
# case-insensitive grep so it works with either.
http_api_fetch() {
    local url="$1" out_file="$2" header_file="$3" timeout="${4:-15}"
    qm_download_headers "$url" "$out_file" "$header_file" "$timeout"
}

# =============================================================================
# GET — Check for updates / Read status
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    action=$(echo "$QUERY_STRING" | sed -n 's/.*action=\([^&]*\).*/\1/p')

    # --- Status polling ---
    if [ "$action" = "status" ]; then
        if [ -f "$STATUS_FILE" ]; then
            cat "$STATUS_FILE"
        else
            jq -n '{"status":"idle"}'
        fi
        exit 0
    fi

    # --- Reboot ack: /reboot/ page tells the OTA worker it has loaded ---
    # Worker waits up to REBOOT_ACK_TIMEOUT for this file before rebooting,
    # so the static reboot page is in browser memory before the device dies.
    if [ "$action" = "reboot_ack" ]; then
        touch /tmp/qmanager_reboot_ack 2>/dev/null
        jq -n '{"success":true}'
        exit 0
    fi

    # --- Update check ---
    qlog_info "Checking for updates"
    ensure_update_config

    current_version=$(get_current_version)
    include_prerelease=$(uci_update_get include_prerelease "1")
    auto_enabled=$(uci_update_get auto_update_enabled "0")
    auto_time=$(uci_update_get auto_update_time "03:00")

    # Query GitHub Releases API with header capture for rate-limit detection
    api_url="https://api.github.com/repos/$GITHUB_REPO/releases"
    tmp_body="/tmp/qm_update_api_body.json"
    tmp_headers="/tmp/qm_update_api_headers.txt"
    rm -f "$tmp_body" "$tmp_headers"

    # Detect stale pending-version file (previous install interrupted before reboot)
    pending_version=""
    if [ -f "$VERSION_PENDING" ]; then
        pending_version=$(tr -d '[:space:]' < "$VERSION_PENDING" 2>/dev/null)
    fi

    if ! http_api_fetch "$api_url" "$tmp_body" "$tmp_headers"; then
        rm -f "$tmp_body" "$tmp_headers"
        jq -n \
            --arg cv "$current_version" \
            --argjson prerelease "$include_prerelease" \
            --arg auto_en "$auto_enabled" \
            --arg auto_time "$auto_time" \
            --argjson pif "$([ -n "$pending_version" ] && echo true || echo false)" \
            --arg pv "$pending_version" \
            '{
                success: true, current_version: $cv,
                latest_version: null, update_available: false,
                changelog: null, current_changelog: null,
                download_url: null, download_size: null,
                available_versions: [], download_state: null,
                include_prerelease: ($prerelease == 1),
                auto_update_enabled: ($auto_en == "1"),
                auto_update_time: $auto_time,
                previous_install_failed: $pif,
                pending_version: (if $pv == "" then null else $pv end),
                check_error: "Unable to check for updates. Check your internet connection."
            }'
        exit 0
    fi

    # Check for rate limiting (HTTP 403)
    if grep -qi "403 Forbidden\|HTTP/[0-9.]* 403" "$tmp_headers" 2>/dev/null; then
        # Try to parse reset time
        reset_ts=$(grep -i 'x-ratelimit-reset' "$tmp_headers" | sed 's/.*: *//;s/\r//' | head -1)
        wait_msg="Rate limit reached. Try again later."
        if [ -n "$reset_ts" ]; then
            now_ts=$(date +%s 2>/dev/null)
            if [ -n "$now_ts" ] && [ -n "$reset_ts" ] && [ "$reset_ts" -gt "$now_ts" ] 2>/dev/null; then
                wait_mins=$(( (reset_ts - now_ts + 59) / 60 ))
                wait_msg="Rate limit reached. Try again in ${wait_mins} minute(s)."
            fi
        fi
        rm -f "$tmp_body" "$tmp_headers"
        jq -n \
            --arg cv "$current_version" \
            --argjson prerelease "$include_prerelease" \
            --arg err "$wait_msg" \
            --arg auto_en "$auto_enabled" \
            --arg auto_time "$auto_time" \
            --argjson pif "$([ -n "$pending_version" ] && echo true || echo false)" \
            --arg pv "$pending_version" \
            '{
                success: true, current_version: $cv,
                latest_version: null, update_available: false,
                changelog: null, current_changelog: null,
                download_url: null, download_size: null,
                available_versions: [], download_state: null,
                include_prerelease: ($prerelease == 1),
                auto_update_enabled: ($auto_en == "1"),
                auto_update_time: $auto_time,
                previous_install_failed: $pif,
                pending_version: (if $pv == "" then null else $pv end),
                check_error: $err
            }'
        exit 0
    fi

    api_response=$(cat "$tmp_body" 2>/dev/null)
    rm -f "$tmp_body" "$tmp_headers"

    # Filter by pre-release preference
    if [ "$include_prerelease" = "1" ]; then
        release_filter='.[0]'
    else
        release_filter='[ .[] | select(.prerelease == false) ] | .[0]'
    fi

    # Extract release info
    latest_tag=$(echo "$api_response" | jq -r "$release_filter | .tag_name // empty")
    changelog=$(echo "$api_response" | jq -r "$release_filter | .body // empty")

    # Extract current version's changelog from the same API response
    current_changelog=""
    if [ -n "$current_version" ] && [ "$current_version" != "0.0.0" ]; then
        current_changelog=$(echo "$api_response" | jq -r \
            --arg cv "$current_version" \
            '[ .[] | select(.tag_name == $cv) ] | .[0].body // empty')
    fi

    # Detect staged download state
    download_state="null"
    staged_tarball="/tmp/qmanager_staged.tar.gz"
    staged_version_file="/tmp/qmanager_staged_version"

    if [ -f "$PID_FILE" ]; then
        pid=$(cat "$PID_FILE" 2>/dev/null)
        if pid_alive "$pid" && [ -f "$STATUS_FILE" ]; then
            download_state=$(cat "$STATUS_FILE" 2>/dev/null)
        fi
    elif [ -f "$staged_tarball" ] && [ -f "$staged_version_file" ]; then
        staged_ver=$(cat "$staged_version_file" 2>/dev/null)
        staged_size=$(du -k "$staged_tarball" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}')
        download_state=$(jq -n \
            --arg status "ready" \
            --arg version "$staged_ver" \
            --arg message "Download verified ($staged_size)" \
            --arg size "$staged_size" \
            '{status: $status, version: $version, message: $message, size: $size}')
    fi

    # Build available_versions list from API response
    available_versions=$(echo "$api_response" | jq \
        --arg cv "$current_version" \
        '[ .[] | {
            tag: .tag_name,
            has_assets: ((.assets | length) > 0),
            asset_size: (if (.assets | length) > 0 then
                (.assets[0].size / 1048576 * 10 | floor / 10 | tostring + " MB")
            else null end),
            is_current: (.tag_name == $cv)
        }]')

    # Download URL from GitHub Releases (stable, redirect handled by curl -L)
    download_url=""
    if [ -n "$latest_tag" ]; then
        download_url="https://github.com/${GITHUB_REPO}/releases/download/${latest_tag}/qmanager.tar.gz"
    fi
    download_size=""

    update_available="false"
    if [ -n "$latest_tag" ]; then
        semver_compare "$latest_tag" "$current_version"
        case $? in
            0) update_available="true" ;;
        esac
    fi

    jq -n \
        --arg cv "$current_version" \
        --arg lv "${latest_tag:-}" \
        --argjson ua "$update_available" \
        --arg cl "$changelog" \
        --arg ccl "$current_changelog" \
        --arg dl "${download_url:-}" \
        --arg ds "$download_size" \
        --argjson av "$available_versions" \
        --argjson ds_obj "$download_state" \
        --argjson prerelease "$include_prerelease" \
        --arg auto_en "$auto_enabled" \
        --arg auto_time "$auto_time" \
        --argjson pif "$([ -n "$pending_version" ] && echo true || echo false)" \
        --arg pv "$pending_version" \
        '{
            success: true,
            current_version: $cv,
            latest_version: (if $lv == "" then null else $lv end),
            update_available: $ua,
            changelog: (if $cl == "" then null else $cl end),
            current_changelog: (if $ccl == "" then null else $ccl end),
            download_url: (if $dl == "" then null else $dl end),
            download_size: (if $ds == "" then null else $ds end),
            available_versions: $av,
            download_state: $ds_obj,
            include_prerelease: ($prerelease == 1),
            auto_update_enabled: ($auto_en == "1"),
            auto_update_time: $auto_time,
            previous_install_failed: $pif,
            pending_version: (if $pv == "" then null else $pv end),
            check_error: null
        }'
    exit 0
fi

# =============================================================================
# POST — Install / Rollback / Save preferences
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')
    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    # --- Save pre-release preference ---
    if [ "$ACTION" = "save_prerelease" ]; then
        ensure_update_config
        enabled=$(printf '%s' "$POST_DATA" | jq -r '(.enabled) | if . == null then empty else tostring end')
        case "$enabled" in
            true)  qm_config_set update include_prerelease 1 ;;
            false) qm_config_set update include_prerelease 0 ;;
            *) cgi_error "invalid_value" "enabled must be true or false"; exit 0 ;;
        esac
        cgi_success
        exit 0
    fi

    # --- Save auto-update preference ---
    if [ "$ACTION" = "save_auto_update" ]; then
        ensure_update_config
        enabled=$(printf '%s' "$POST_DATA" | jq -r '(.enabled) | if . == null then empty else tostring end')
        auto_time=$(printf '%s' "$POST_DATA" | jq -r '.time // empty')

        case "$enabled" in
            true|false) ;;
            *) cgi_error "invalid_value" "enabled must be true or false"; exit 0 ;;
        esac
        # HH:MM with a real 00-23 hour, matched as a whole string.
        #
        # Two separate defects in the line this replaces, both of which produced
        # a schedule that saves clean and never fires. First, `grep -E` anchors
        # are LINE-based: a value carrying an embedded newline whose second line
        # looked like a time passed the check while the whole multi-line value
        # flowed on into the file being written — and the file in question is
        # now a systemd unit, where a smuggled newline is a second directive.
        # A `case` pattern matches the entire string, so the newline is simply
        # not a time. Second, [0-9]{2} accepted "99:99"; systemd rejects that as
        # a calendar parse error and loads the timer as failed, silently.
        case "$auto_time" in
            [01][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]) ;;
            *) cgi_error "invalid_value" "time must be HH:MM, 00:00-23:59"; exit 0 ;;
        esac

        # Bail on a failed write and leave the timer alone. The timer is what
        # actually installs updates; the config is what the UI reads back.
        # Arming a schedule the config does not hold would have the device
        # update itself at a time no page ever shows.
        auto_write_failed() {
            cgi_error "auto_update_save_failed" \
                "Could not save the auto-update preference — writing the configuration file failed. The existing schedule was left untouched."
            exit 0
        }
        case "$enabled" in
            true)  qm_config_set update auto_update_enabled 1 || auto_write_failed ;;
            false) qm_config_set update auto_update_enabled 0 || auto_write_failed ;;
        esac
        qm_config_set update auto_update_time "$auto_time" || auto_write_failed

        # --- Arm (or disarm) the systemd timer -------------------------------
        #
        # This used to printf a daily line into /var/spool/cron/crontabs/root.
        # Nothing on this device reads that file: there is no crond unit, the
        # binary never runs, and the spool directory is empty. So the switch has
        # read "on" while the device has never once updated itself unattended.
        #
        # The CGI runs as www-data and cannot write /lib/systemd/system, so the
        # unit is generated by a root helper reached through an exact-path
        # sudoers rule.
        if [ "$enabled" = "true" ]; then
            arm_resp=$($_SUDO "$AUTO_UPDATE_ARM_HELPER" install "$auto_time" 2>/dev/null)
        else
            arm_resp=$($_SUDO "$AUTO_UPDATE_ARM_HELPER" teardown 2>/dev/null)
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

        # schedule_armed answers one question — will this device check for
        # updates on its own — and schedule_apply_error appears only when that
        # answer disagrees with what was asked for. Disabling successfully is
        # armed:false with no error; it is the intended outcome, not a warning.
        arm_error=""
        if [ "$enabled" = "true" ]; then
            if [ "$schedule_armed" != "true" ]; then
                arm_error=$(auto_update_arm_message "$arm_reason")
                qlog_warn "Auto-update saved but not armed (reason=${arm_reason:-unknown})"
            else
                qlog_info "Auto-update armed daily at ${auto_time}"
            fi
        elif [ -n "$arm_reason" ]; then
            # Teardown reports "" on success. Anything else means the old unit
            # may still be on disk and counting down, so a device the user just
            # took off automatic updates can still install one unattended —
            # which reboots it. Report it as still armed rather than guess the
            # comfortable answer.
            schedule_armed="true"
            arm_error="Saved auto-update as disabled, but the existing timer could not be removed — the device may still update itself on the old schedule."
            qlog_warn "Auto-update disable saved but timer not removed (reason=${arm_reason})"
        else
            qlog_info "Auto-update timer removed"
        fi

        # schedule_armed always travels, in both directions — it is the fact the
        # old response ({"success":true} and nothing else) was missing.
        # schedule_apply_error appears only when the save and the arming
        # disagree, so a consumer that knows neither field is unaffected.
        jq -n \
            --argjson armed "$schedule_armed" \
            --arg arm_error "$arm_error" \
            '{success: true, schedule_armed: $armed}
             + (if $arm_error == "" then {} else {schedule_apply_error: $arm_error} end)'
        exit 0
    fi

    # --- Download update (stage without installing) ---
    if [ "$ACTION" = "download" ]; then
        check_lock

        version=$(printf '%s' "$POST_DATA" | jq -r '.version // empty')
        if [ -z "$version" ]; then
            cgi_error "missing_version" "version is required"; exit 0
        fi

        download_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/qmanager.tar.gz"
        checksum_url="https://github.com/${GITHUB_REPO}/releases/download/${version}/sha256sum.txt"

        jq -n '{"success":true,"status":"starting"}'
        ( sudo -n "$UPDATER" download "$download_url" "$checksum_url" "$version" </dev/null >/dev/null 2>&1 & )
        exit 0
    fi

    # --- Install staged tarball ---
    if [ "$ACTION" = "install_staged" ]; then
        check_lock

        if [ ! -f "/tmp/qmanager_staged.tar.gz" ]; then
            cgi_error "no_staged" "No staged download found. Download first."
            exit 0
        fi

        jq -n '{"success":true,"status":"starting"}'
        ( sudo -n "$UPDATER" install_staged </dev/null >/dev/null 2>&1 & )
        exit 0
    fi

    # --- Install update ---
    if [ "$ACTION" = "install" ]; then
        check_lock

        download_url=$(printf '%s' "$POST_DATA" | jq -r '.download_url // empty')
        version=$(printf '%s' "$POST_DATA" | jq -r '.version // empty')
        download_size=$(printf '%s' "$POST_DATA" | jq -r '.download_size // empty')

        if [ -z "$download_url" ]; then
            cgi_error "missing_url" "download_url is required"; exit 0
        fi

        # Respond immediately, spawn background updater (double-fork)
        jq -n '{"success":true,"status":"starting"}'
        ( sudo -n "$UPDATER" install "$download_url" "$version" "$download_size" </dev/null >/dev/null 2>&1 & )
        exit 0
    fi

    # --- Rollback ---
    if [ "$ACTION" = "rollback" ]; then
        check_lock

        if [ ! -f "$UPDATES_DIR/previous_version" ]; then
            cgi_error "no_rollback" "No previous version available for rollback"
            exit 0
        fi

        rollback_version=$(cat "$UPDATES_DIR/previous_version" 2>/dev/null)
        rollback_url="https://github.com/${GITHUB_REPO}/releases/download/${rollback_version}/qmanager.tar.gz"
        jq -n --arg v "$rollback_version" '{"success":true,"status":"starting","version":$v}'
        ( sudo -n "$UPDATER" rollback "$rollback_url" "$rollback_version" </dev/null >/dev/null 2>&1 & )
        exit 0
    fi

    cgi_error "unknown_action" "Unknown action: $ACTION"
    exit 0
fi

cgi_method_not_allowed
