#!/bin/sh
# =============================================================================
# detect_hardware.sh — QManager-VN: probe modem model + firmware once
# =============================================================================
# Reads model (AT+CGMM), firmware (AT+CGMR), and IMEI (AT+CGSN) from the
# modem and writes a JSON snapshot to /etc/qmanager/hardware.json.
#
# Used by:
# - UI hardware badge (about-device page, dashboard footer)
# - Dynamic band whitelist (constants/band-whitelist.ts via CGI)
# - Feature gating (some features only available on specific models)
# - "Unsupported model" banner for best-effort SDXLEMUR variants
#
# Idempotent: if /etc/qmanager/hardware.json already exists with a valid
# model field, this is a no-op. To force re-detect, delete the file or
# call `detect_hardware force`.
#
# Source from poller boot sequence (or any script that has qcmd available)
# and call `detect_hardware`.
# =============================================================================

HARDWARE_INFO_FILE="/etc/qmanager/hardware.json"
QCMD="/usr/bin/qcmd"

# Strip CR + trailing whitespace from AT responses. Parses single-line responses
# from raw atcli_smd11 output that already includes the echoed command + OK.
_dh_parse_at_response() {
    _raw="$1"
    _cmd="$2"
    # Drop echoed command, "OK", and blank lines. Take first non-empty data line.
    printf '%s' "$_raw" \
        | tr -d '\r' \
        | grep -v "^${_cmd}$" \
        | grep -v "^OK$" \
        | grep -v "^$" \
        | head -1
}

# Probe modem with one AT command, return clean value or empty on failure.
_dh_probe() {
    _cmd="$1"
    if [ ! -x "$QCMD" ]; then
        return 1
    fi
    _result=$("$QCMD" "$_cmd" 2>/dev/null) || return 1
    _dh_parse_at_response "$_result" "$_cmd"
}

# Normalize model string: strip Quectel prefix, trim whitespace.
# AT+CGMM on RM520N-GLAA returns "RM520N-GLAA" — already clean.
_dh_normalize_model() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -1
}

# Map model to SoC family. SDXLEMUR = Qualcomm SDX62 (5G Sub-6 Stage 2).
_dh_model_to_soc() {
    case "$1" in
        RM520N-*|RM500Q-*|RM502Q-*) printf 'SDX62 (SDXLEMUR)' ;;
        RM521F-*)                   printf 'SDX65' ;;
        RM551E-*)                   printf 'SDX72' ;;
        *)                          printf 'unknown' ;;
    esac
}

# Whether the model is supported. Used by UI to suppress unsupported banner.
# Returns the support tier: "primary" | "tested" | "best-effort" | "unsupported"
_dh_support_tier() {
    case "$1" in
        RM520N-GLAA)                              printf 'primary' ;;
        RM520N-GL)                                printf 'tested' ;;
        RM520N-EU|RM502Q-AE|RM500Q-GL|RM520N-*)   printf 'best-effort' ;;
        *)                                        printf 'unsupported' ;;
    esac
}

detect_hardware() {
    _force="${1:-}"

    # Skip if already detected, unless forced
    if [ -z "$_force" ] && [ -f "$HARDWARE_INFO_FILE" ]; then
        if grep -q '"model"[[:space:]]*:[[:space:]]*"[^"]\{2,\}"' "$HARDWARE_INFO_FILE" 2>/dev/null; then
            return 0
        fi
    fi

    if [ ! -x "$QCMD" ]; then
        return 1
    fi

    _model=$(_dh_probe "AT+CGMM")
    _firmware=$(_dh_probe "AT+CGMR")
    _imei=$(_dh_probe "AT+CGSN")

    _model=$(_dh_normalize_model "$_model")
    [ -z "$_model" ] && _model="unknown"

    _soc=$(_dh_model_to_soc "$_model")
    _tier=$(_dh_support_tier "$_model")
    _ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

    # Write hardware.json. jq is preferred (always installed via Entware),
    # fallback to manual JSON for unlikely cases where it's missing.
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg model "$_model" \
            --arg firmware "$_firmware" \
            --arg imei "$_imei" \
            --arg soc "$_soc" \
            --arg tier "$_tier" \
            --arg ts "$_ts" \
            '{
                model: $model,
                firmware: $firmware,
                imei: $imei,
                soc: $soc,
                support_tier: $tier,
                at_device: "/dev/smd11",
                detected_at: $ts
            }' > "$HARDWARE_INFO_FILE.tmp" \
            && mv "$HARDWARE_INFO_FILE.tmp" "$HARDWARE_INFO_FILE"
    else
        # Naive escape: only handles values without quotes (model/soc/tier are safe;
        # firmware/imei may need attention but Quectel always returns alphanumerics).
        cat > "$HARDWARE_INFO_FILE.tmp" <<EOF
{
  "model": "$_model",
  "firmware": "$_firmware",
  "imei": "$_imei",
  "soc": "$_soc",
  "support_tier": "$_tier",
  "at_device": "/dev/smd11",
  "detected_at": "$_ts"
}
EOF
        mv "$HARDWARE_INFO_FILE.tmp" "$HARDWARE_INFO_FILE"
    fi

    chmod 644 "$HARDWARE_INFO_FILE"
    return 0
}
