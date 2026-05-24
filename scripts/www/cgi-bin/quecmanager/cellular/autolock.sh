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
            # Merge new fields into existing config (preserves untouched keys)
            new_enabled=$(printf '%s' "$POST_DATA" | jq -r '.enabled // empty')
            new_rsrp_stable=$(printf '%s' "$POST_DATA" | jq -r '.rsrp_stable // empty')
            new_sinr_stable=$(printf '%s' "$POST_DATA" | jq -r '.sinr_stable // empty')
            new_rsrp_lost=$(printf '%s' "$POST_DATA" | jq -r '.rsrp_lost // empty')
            new_samples=$(printf '%s' "$POST_DATA" | jq -r '.samples // empty')

            tmpcfg=$(cat "$CONFIG_FILE")
            if [ -n "$new_enabled" ]; then
                tmpcfg=$(printf '%s' "$tmpcfg" | jq --argjson v "$new_enabled" '.enabled = $v')
            fi
            if [ -n "$new_rsrp_stable" ]; then
                tmpcfg=$(printf '%s' "$tmpcfg" | jq --argjson v "$new_rsrp_stable" '.thresholds.rsrp_stable = $v')
            fi
            if [ -n "$new_sinr_stable" ]; then
                tmpcfg=$(printf '%s' "$tmpcfg" | jq --argjson v "$new_sinr_stable" '.thresholds.sinr_stable = $v')
            fi
            if [ -n "$new_rsrp_lost" ]; then
                tmpcfg=$(printf '%s' "$tmpcfg" | jq --argjson v "$new_rsrp_lost" '.thresholds.rsrp_lost = $v')
            fi
            if [ -n "$new_samples" ]; then
                tmpcfg=$(printf '%s' "$tmpcfg" | jq --argjson v "$new_samples" '.thresholds.samples = $v')
            fi
            printf '%s' "$tmpcfg" > "$CONFIG_FILE"
            chmod 644 "$CONFIG_FILE"

            # Start or stop daemon based on enabled flag
            final_enabled=$(printf '%s' "$tmpcfg" | jq -r '.enabled')
            if [ "$final_enabled" = "true" ]; then
                sudo -n systemctl enable "$SERVICE" 2>/dev/null
                sudo -n systemctl restart "$SERVICE" 2>/dev/null
                qlog_info "Auto-lock enabled, daemon (re)started"
            else
                sudo -n systemctl stop "$SERVICE" 2>/dev/null
                sudo -n systemctl disable "$SERVICE" 2>/dev/null
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
