#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# autolock.sh — CGI Endpoint: Auto Cell-Lock control (GET + POST)
# =============================================================================
# GET:  Returns current config + state machine status snapshot.
# POST: Toggle enabled, update thresholds. Writes config + (re)starts daemon.
#
# Config: /etc/qmanager/autolock.json
# Status: /tmp/qmanager_autolock_status.json (written by qmanager_autolock)
# Daemon: qmanager-autolock.service
#
# Endpoint: GET/POST /cgi-bin/quecmanager/cellular/autolock.sh
# =============================================================================

qlog_init "cgi_autolock"
cgi_headers
cgi_handle_options

CONFIG_FILE="/etc/qmanager/autolock.json"
STATUS_FILE="/tmp/qmanager_autolock_status.json"
SERVICE="qmanager-autolock"
# Boot-persistence symlink path. RM520N-GL's minimal systemd ignores
# `systemctl enable` (see scripts/usr/lib/qmanager/platform.sh:47), so to
# survive reboots we drop a symlink directly into the wants directory —
# the same pattern install_rm520n.sh uses for every QManager service.
WANTS_LINK="/lib/systemd/system/multi-user.target.wants/${SERVICE}.service"
UNIT_FILE="/lib/systemd/system/${SERVICE}.service"

# Default config (created on first GET if missing)
default_config() {
    jq -n '{
        enabled: false,
        thresholds: {
            rsrp_stable: -85,
            sinr_stable: 5,
            rsrp_lost: -110,
            samples: 3
        }
    }'
}

ensure_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p /etc/qmanager 2>/dev/null
        default_config > "$CONFIG_FILE"
        chmod 644 "$CONFIG_FILE"
    fi
}

read_status() {
    if [ -f "$STATUS_FILE" ]; then
        cat "$STATUS_FILE"
    else
        jq -n '{
            state: "idle",
            stable_count: 0,
            lost_count: 0,
            locked_pci: null,
            locked_earfcn: null,
            message: "Daemon not running",
            updated_at: null
        }'
    fi
}

# =============================================================================
# GET — current config + status
# =============================================================================
if [ "$REQUEST_METHOD" = "GET" ]; then
    ensure_config
    _config=$(cat "$CONFIG_FILE" 2>/dev/null)
    _status=$(read_status)
    _service_active="false"
    if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
        _service_active="true"
    fi
    jq -n \
        --argjson config "$_config" \
        --argjson status "$_status" \
        --arg active "$_service_active" \
        '{
            success: true,
            config: $config,
            status: $status,
            service_active: ($active == "true")
        }'
    exit 0
fi

# =============================================================================
# POST — update config + restart daemon if needed
# =============================================================================
if [ "$REQUEST_METHOD" = "POST" ]; then
    cgi_read_post

    ACTION=$(printf '%s' "$POST_DATA" | jq -r '.action // empty')
    if [ -z "$ACTION" ]; then
        cgi_error "missing_action" "action field is required"
        exit 0
    fi

    ensure_config

    case "$ACTION" in
        save)
            # Merge new fields into existing config (preserves untouched keys).
            # Single jq pass + tmp+mv keeps the read-modify-write atomic on
            # disk — concurrent POSTs can't lose updates the way 5 sequential
            # jq pipes through a shell variable could.
            new_enabled=$(printf '%s' "$POST_DATA" | jq -r '.enabled // empty')
            new_rsrp_stable=$(printf '%s' "$POST_DATA" | jq -r '.rsrp_stable // empty')
            new_sinr_stable=$(printf '%s' "$POST_DATA" | jq -r '.sinr_stable // empty')
            new_rsrp_lost=$(printf '%s' "$POST_DATA" | jq -r '.rsrp_lost // empty')
            new_samples=$(printf '%s' "$POST_DATA" | jq -r '.samples // empty')

            jq_filter='.'
            [ -n "$new_enabled" ]      && jq_filter="$jq_filter | .enabled = $new_enabled"
            [ -n "$new_rsrp_stable" ]  && jq_filter="$jq_filter | .thresholds.rsrp_stable = $new_rsrp_stable"
            [ -n "$new_sinr_stable" ]  && jq_filter="$jq_filter | .thresholds.sinr_stable = $new_sinr_stable"
            [ -n "$new_rsrp_lost" ]    && jq_filter="$jq_filter | .thresholds.rsrp_lost = $new_rsrp_lost"
            [ -n "$new_samples" ]      && jq_filter="$jq_filter | .thresholds.samples = $new_samples"

            if ! jq "$jq_filter" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" 2>/dev/null; then
                rm -f "$CONFIG_FILE.tmp"
                cgi_error "config_write_failed" "Could not update autolock config (jq error)"
                exit 0
            fi
            mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            chmod 644 "$CONFIG_FILE"

            # Re-read the (now atomic) file for the daemon control decision —
            # avoids dependence on the in-memory tmpcfg that no longer exists.
            #
            # Boot persistence uses symlink, not `systemctl enable` — minimal
            # systemd on RM520N-GL silently ignores the enable subcommand
            # (verified in platform.sh:47 and install_rm520n.sh:1594). User
            # report v0.3.1-vn: daemon stuck inactive after restart because
            # the old code relied on enable taking effect.
            final_enabled=$(jq -r '.enabled' "$CONFIG_FILE")
            if [ "$final_enabled" = "true" ]; then
                sudo -n /bin/ln -sf "$UNIT_FILE" "$WANTS_LINK" 2>/dev/null
                sudo -n /bin/systemctl restart "$SERVICE" 2>/dev/null
                qlog_info "Auto-lock enabled, daemon (re)started"
            else
                sudo -n /bin/systemctl stop "$SERVICE" 2>/dev/null
                sudo -n /bin/rm -f "$WANTS_LINK" 2>/dev/null
                qlog_info "Auto-lock disabled, daemon stopped"
            fi

            cgi_success
            ;;

        *)
            cgi_error "unknown_action" "Unknown action: $ACTION"
            ;;
    esac
    exit 0
fi

cgi_method_not_allowed
