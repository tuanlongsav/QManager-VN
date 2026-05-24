#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
. /usr/lib/qmanager/detect_hardware.sh
# =============================================================================
# hardware-info.sh — CGI Endpoint: Modem hardware information (GET)
# =============================================================================
# Returns the modem hardware snapshot written by detect_hardware() during
# poller boot. If the snapshot is missing (fresh install, never-booted modem),
# attempts a live probe before responding.
#
# Read by: hooks/use-hardware-info.ts (UI badge + feature gating + band whitelist
# lookup + UnsupportedModelBanner).
#
# Endpoint: GET /cgi-bin/quecmanager/system/hardware-info.sh
# =============================================================================

qlog_init "cgi_hardware_info"
cgi_headers
cgi_handle_options

if [ "$REQUEST_METHOD" != "GET" ]; then
    cgi_method_not_allowed
    exit 0
fi

HARDWARE_INFO_FILE="/etc/qmanager/hardware.json"

# If the snapshot doesn't exist yet, try a live probe. Don't force — if AT path
# is still warming up we'll return an unknown placeholder and the UI will retry.
if [ ! -f "$HARDWARE_INFO_FILE" ]; then
    detect_hardware 2>/dev/null || true
fi

if [ -f "$HARDWARE_INFO_FILE" ]; then
    cat "$HARDWARE_INFO_FILE"
else
    jq -n '{
        model: "unknown",
        firmware: "",
        imei: "",
        soc: "unknown",
        support_tier: "unsupported",
        at_device: "/dev/smd11",
        detected_at: null,
        error: "hardware_info_unavailable"
    }'
fi
