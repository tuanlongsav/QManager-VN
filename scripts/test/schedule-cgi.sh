#!/bin/sh
# =============================================================================
# schedule-cgi.sh — the three schedule endpoints, end to end
# =============================================================================
#   scripts/www/cgi-bin/quecmanager/system/settings.sh  (save_scheduled_reboot)
#   scripts/www/cgi-bin/quecmanager/tower/schedule.sh
#   scripts/www/cgi-bin/quecmanager/system/update.sh    (save_auto_update)
#
# All three used to write a cron line into /var/spool/cron/crontabs/root, which
# no daemon on this device reads, and answer {"success":true}. They now hand the
# schedule to a root arm helper and report what it says. What runs below is the
# shipped CGI shell — only the library root and the helper directory are
# redirected, through the QM_LIB_DIR / QM_ARM_BIN_DIR hooks the endpoints
# document, so nothing here touches /usr/lib, /usr/bin or systemd.
#
# The invariants this exists to protect:
#
#   1. A schedule that was not armed is never reported as a success with no
#      warning. `schedule_armed` must be false and `schedule_apply_error` must
#      be present, for every reason the helper can give and for the helper
#      being absent entirely. This is the whole point: the previous mechanism
#      failed silently for years because the response could not express
#      "saved, but nothing is scheduled".
#   2. A rejected schedule never reaches the privileged helper. The helper
#      validates too — it must — but a value the CGI has already refused must
#      not cross the sudo boundary at all, and the user must get the specific
#      error, not a vague arming warning.
#   3. An embedded newline in HH:MM is rejected. update.sh validated with
#      `grep -qE '^[0-9]{2}:[0-9]{2}$'`, and grep anchors are line-based: a
#      two-line value whose first line looked like a time passed. The
#      destination is now a systemd unit file, where a smuggled newline is a
#      second directive and ExecStart= is arbitrary root code.
#   4. A failed teardown is not reported as "off". The old timer may still be
#      counting down, so the response must not claim nothing is scheduled.
#   5. No endpoint writes to a cron spool any more.
set -eu

LC_ALL=C
export LC_ALL

if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq not found" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CGI_SETTINGS="$REPO_ROOT/scripts/www/cgi-bin/quecmanager/system/settings.sh"
CGI_TOWER="$REPO_ROOT/scripts/www/cgi-bin/quecmanager/tower/schedule.sh"
CGI_UPDATE="$REPO_ROOT/scripts/www/cgi-bin/quecmanager/system/update.sh"

for f in "$CGI_SETTINGS" "$CGI_TOWER" "$CGI_UPDATE"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: not found: $f" >&2
        exit 1
    fi
done

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

STUB_LIB="$TEST_DIR/lib"
STUB_BIN="$TEST_DIR/bin"
EMPTY_BIN="$TEST_DIR/empty-bin"
mkdir -p "$STUB_LIB" "$STUB_BIN" "$EMPTY_BIN"

CONFIG_FILE="$TEST_DIR/config.kv"
TOWER_FILE="$TEST_DIR/tower.kv"
ARM_LOG="$TEST_DIR/arm.log"

# --- stub libraries ---------------------------------------------------------
# Only the surface the three endpoints actually touch. Each stub is inert: no
# sudo, no systemd, no /etc.

cat > "$STUB_LIB/cgi_base.sh" <<'STUB'
[ -n "$_CGI_BASE_LOADED" ] && return 0
_CGI_BASE_LOADED=1
qlog_init()  { :; }
qlog_debug() { :; }
qlog_info()  { :; }
qlog_warn()  { :; }
qlog_error() { :; }
cgi_headers()        { :; }
cgi_handle_options() { :; }
cgi_read_post() {
    POST_DATA=""
    if [ -n "${CONTENT_LENGTH:-}" ] && [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
        POST_DATA=$(dd bs=1 count="$CONTENT_LENGTH" 2>/dev/null)
    fi
}
cgi_success() { printf '{"success":true}\n'; }
cgi_error()   { jq -n --arg e "$1" --arg d "${2:-}" '{success:false,error:$e,detail:$d}'; }
cgi_method_not_allowed() { printf '{"success":false,"error":"method_not_allowed"}\n'; }
pid_alive() { [ -n "$1" ] && [ -d "/proc/$1" ]; }
STUB

# $_SUDO empty: the stub helper is invoked directly, exactly as it would be on a
# device where the CGI already runs as root.
cat > "$STUB_LIB/platform.sh" <<'STUB'
[ -n "$_PLATFORM_LOADED" ] && return 0
_PLATFORM_LOADED=1
_SUDO=""
STUB

# Flat key=value store. QM_CONFIG_FAIL makes every write fail, which is how the
# "bail before touching the timer" path is exercised.
cat > "$STUB_LIB/config.sh" <<'STUB'
[ -n "$_CONFIG_LOADED" ] && return 0
_CONFIG_LOADED=1
qm_config_init() { : > "${QM_TEST_CONFIG}" 2>/dev/null || true; [ -f "${QM_TEST_CONFIG}" ]; }
qm_config_get() {
    v=$(grep "^$1.$2=" "${QM_TEST_CONFIG}" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -z "$v" ] && v="$3"
    printf '%s' "$v"
}
qm_config_set() {
    [ -n "${QM_CONFIG_FAIL:-}" ] && return 1
    printf '%s.%s=%s\n' "$1" "$2" "$3" >> "${QM_TEST_CONFIG}"
}
STUB

cat > "$STUB_LIB/system_config.sh" <<'STUB'
[ -n "$_SYSTEM_CONFIG_LOADED" ] && return 0
_SYSTEM_CONFIG_LOADED=1
sys_get_hostname() { printf 'RM520N-GL'; }
sys_get_timezone() { printf 'UTC0'; }
sys_get_zonename() { printf 'UTC'; }
sys_set_hostname() { return 0; }
sys_set_timezone() { return 0; }
STUB

cat > "$STUB_LIB/semver.sh" <<'STUB'
semver_compare() { return 1; }
STUB

cat > "$STUB_LIB/downloader.sh" <<'STUB'
qm_download_headers() { return 1; }
STUB

# Tower config: the lock-target guard must pass so the schedule path is reached.
# QM_TOWER_FAIL makes the schedule write fail.
cat > "$STUB_LIB/tower_lock_mgr.sh" <<'STUB'
tower_config_init() { : ; }
tower_config_get() {
    case "$1" in
        *lte.cells*) printf '1' ;;
        *) printf 'null' ;;
    esac
}
tower_config_update_schedule() {
    [ -n "${QM_TOWER_FAIL:-}" ] && return 1
    printf 'enabled=%s start=%s end=%s days=%s\n' "$1" "$2" "$3" "$4" >> "${QM_TEST_TOWER}"
}
STUB

# --- stub arm helpers -------------------------------------------------------
# Record the full argv, then answer in whichever shape STUB_ARM_MODE selects.
# The real helper's JSON contract is reproduced exactly: `armed` is the field
# that matters and `success` can be true alongside armed:false.
make_arm_stub() {
    cat > "$STUB_BIN/$1" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$QM_TEST_ARM_LOG"
case "${STUB_ARM_MODE:-armed}" in
    armed)
        if [ "$1" = "teardown" ]; then
            printf '{"success":true,"armed":false,"reason":"","active":"unknown"}\n'
        else
            printf '{"success":true,"armed":true,"reason":"","active":"active"}\n'
        fi ;;
    unit_absent)
        printf '{"success":true,"armed":false,"reason":"unit_absent","active":"unknown"}\n' ;;
    timer_inactive)
        printf '{"success":true,"armed":false,"reason":"timer_inactive","active":"inactive"}\n' ;;
    disarm_failed)
        printf '{"success":false,"armed":false,"error":"disarm_failed","detail":"still present"}\n'
        exit 1 ;;
    silent)
        exit 1 ;;
esac
exit 0
STUB
    chmod +x "$STUB_BIN/$1"
}
make_arm_stub qmanager_scheduled_reboot_arm
make_arm_stub qmanager_tower_schedule_arm
make_arm_stub qmanager_auto_update_arm

# --- runner -----------------------------------------------------------------

PASS=0
FAILED=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL: $1" >&2; }

# run_post <cgi> <json body> [arm mode] [bin dir]
run_post() {
    _cgi="$1"
    _body="$2"
    _mode="${3:-armed}"
    _bin="${4:-$STUB_BIN}"
    : > "$ARM_LOG"
    : > "$CONFIG_FILE"
    : > "$TOWER_FILE"
    printf '%s' "$_body" | env \
        REQUEST_METHOD=POST \
        CONTENT_TYPE=application/json \
        CONTENT_LENGTH="$(printf '%s' "$_body" | wc -c | tr -d ' ')" \
        QM_LIB_DIR="$STUB_LIB" \
        QM_ARM_BIN_DIR="$_bin" \
        QM_TEST_CONFIG="$CONFIG_FILE" \
        QM_TEST_TOWER="$TOWER_FILE" \
        QM_TEST_ARM_LOG="$ARM_LOG" \
        STUB_ARM_MODE="$_mode" \
        _SKIP_AUTH=1 \
        sh "$_cgi"
}

arm_log() { cat "$ARM_LOG" 2>/dev/null; }

check() {
    _label="$1"; _json="$2"; _filter="$3"
    if printf '%s' "$_json" | jq -e "$_filter" >/dev/null 2>&1; then
        pass "$_label"
    else
        fail "$_label — got: $_json"
    fi
}

echo "== scheduled reboot (settings.sh) =="

# 1. Armed: the response says so, and the helper saw the exact schedule.
RES=$(run_post "$CGI_SETTINGS" '{"action":"save_scheduled_reboot","enabled":true,"time":"04:30","days":[1,3]}')
check "enable + armed -> schedule_armed true, no warning" "$RES" \
    '.success == true and .schedule_armed == true and (has("schedule_apply_error") | not)
     and .scheduled_reboot.time == "04:30" and .scheduled_reboot.days == [1,3]'
if [ "$(arm_log)" = "install 04:30 1,3" ]; then
    pass "helper invoked as: install 04:30 1,3"
else
    fail "helper argv — got: $(arm_log)"
fi

# 2-3. The two ways arming can fail while the save succeeds. Both must warn.
for mode in unit_absent timer_inactive; do
    RES=$(run_post "$CGI_SETTINGS" '{"action":"save_scheduled_reboot","enabled":true,"time":"04:30","days":[1,3]}' "$mode")
    check "enable + $mode -> saved, armed false, warning present" "$RES" \
        '.success == true and .schedule_armed == false
         and (.schedule_apply_error | type == "string" and length > 0)'
done

# 4. Helper absent entirely (a device on an older OTA base): no JSON comes back
#    at all, and the endpoint must still refuse to claim a schedule.
RES=$(run_post "$CGI_SETTINGS" '{"action":"save_scheduled_reboot","enabled":true,"time":"04:30","days":[1,3]}' armed "$EMPTY_BIN")
check "enable + helper missing -> saved, armed false, warning present" "$RES" \
    '.success == true and .schedule_armed == false
     and (.schedule_apply_error | test("Updating QManager"))'

# 5. Disable is armed:false BY DESIGN and must not warn — otherwise every user
#    who turns the feature off sees an error.
RES=$(run_post "$CGI_SETTINGS" '{"action":"save_scheduled_reboot","enabled":false,"time":"04:30","days":[1,3]}')
check "disable -> armed false, no warning" "$RES" \
    '.success == true and .schedule_armed == false and (has("schedule_apply_error") | not)'
if [ "$(arm_log)" = "teardown" ]; then
    pass "helper invoked as: teardown"
else
    fail "teardown argv — got: $(arm_log)"
fi

# 6. A teardown that did not take: the old timer may still reboot the device.
RES=$(run_post "$CGI_SETTINGS" '{"action":"save_scheduled_reboot","enabled":false,"time":"04:30","days":[1,3]}' disarm_failed)
check "disable + disarm_failed -> still armed, warning present" "$RES" \
    '.success == true and .schedule_armed == true
     and (.schedule_apply_error | test("may still reboot"))'

# 7-9. Rejected input must never reach the privileged helper.
RES=$(run_post "$CGI_SETTINGS" '{"action":"save_scheduled_reboot","enabled":true,"time":"25:00","days":[1]}')
check "hour 25 rejected" "$RES" '.success == false and .error == "invalid_time"'
[ -z "$(arm_log)" ] && pass "hour 25 never reached the helper" || fail "helper called with 25:00"

RES=$(run_post "$CGI_SETTINGS" '{"action":"save_scheduled_reboot","enabled":true,"time":"04:00\nExecStart=/tmp/pwn","days":[1]}')
check "newline in time rejected" "$RES" '.success == false and .error == "invalid_time"'
[ -z "$(arm_log)" ] && pass "newline never reached the helper" || fail "helper called with a newline"

RES=$(run_post "$CGI_SETTINGS" '{"action":"save_scheduled_reboot","enabled":true,"time":"04:00","days":["1","","3"]}')
check "doubled comma in days rejected" "$RES" '.success == false and .error == "invalid_day"'
[ -z "$(arm_log)" ] && pass "malformed day mask never reached the helper" || fail "helper called with a malformed mask"

# 10. A failed config write must leave the schedule alone rather than arm one
#     the UI will never show.
RES=$(QM_CONFIG_FAIL=1 run_post "$CGI_SETTINGS" '{"action":"save_scheduled_reboot","enabled":true,"time":"04:30","days":[1,3]}')
check "config write failure -> success false" "$RES" '.success == false and .error == "sched_save_failed"'
[ -z "$(arm_log)" ] && pass "config write failure armed nothing" || fail "armed despite a failed config write"

echo "== tower lock schedule (tower/schedule.sh) =="

RES=$(run_post "$CGI_TOWER" '{"enabled":true,"start_time":"08:00","end_time":"22:00","days":[1,2,3,4,5]}')
check "enable + armed -> schedule_armed true, no warning" "$RES" \
    '.success == true and .schedule_armed == true and (has("schedule_apply_error") | not)
     and .start_time == "08:00" and .end_time == "22:00"'
if [ "$(arm_log)" = "install 08:00 22:00 1,2,3,4,5" ]; then
    pass "helper invoked as: install 08:00 22:00 1,2,3,4,5"
else
    fail "helper argv — got: $(arm_log)"
fi

RES=$(run_post "$CGI_TOWER" '{"enabled":true,"start_time":"08:00","end_time":"22:00","days":[1,2]}' unit_absent)
check "enable + unit_absent -> saved, armed false, warning present" "$RES" \
    '.success == true and .schedule_armed == false
     and (.schedule_apply_error | type == "string" and length > 0)'

RES=$(run_post "$CGI_TOWER" '{"enabled":false,"start_time":"08:00","end_time":"22:00","days":[1,2]}')
check "disable -> armed false, no warning" "$RES" \
    '.success == true and .schedule_armed == false and (has("schedule_apply_error") | not)'
[ "$(arm_log)" = "teardown" ] && pass "helper invoked as: teardown" || fail "teardown argv — got: $(arm_log)"

RES=$(run_post "$CGI_TOWER" '{"enabled":true,"start_time":"08:00","end_time":"24:00","days":[1]}')
check "hour 24 rejected" "$RES" '.success == false and .error == "invalid_end_time"'
[ -z "$(arm_log)" ] && pass "hour 24 never reached the helper" || fail "helper called with 24:00"

RES=$(run_post "$CGI_TOWER" '{"enabled":true,"start_time":"08:00\nExecStart=/tmp/pwn","end_time":"22:00","days":[1]}')
check "newline in start_time rejected" "$RES" '.success == false and .error == "invalid_start_time"'
[ -z "$(arm_log)" ] && pass "newline never reached the helper" || fail "helper called with a newline"

RES=$(QM_TOWER_FAIL=1 run_post "$CGI_TOWER" '{"enabled":true,"start_time":"08:00","end_time":"22:00","days":[1]}')
check "tower config write failure -> success false" "$RES" \
    '.success == false and .error == "schedule_save_failed"'
[ -z "$(arm_log)" ] && pass "config write failure armed nothing" || fail "armed despite a failed config write"

echo "== auto-update (update.sh) =="

RES=$(run_post "$CGI_UPDATE" '{"action":"save_auto_update","enabled":true,"time":"03:00"}')
check "enable + armed -> schedule_armed true, no warning" "$RES" \
    '.success == true and .schedule_armed == true and (has("schedule_apply_error") | not)'
[ "$(arm_log)" = "install 03:00" ] && pass "helper invoked as: install 03:00" \
    || fail "helper argv — got: $(arm_log)"

RES=$(run_post "$CGI_UPDATE" '{"action":"save_auto_update","enabled":true,"time":"03:00"}' unit_absent)
check "enable + unit_absent -> saved, armed false, warning present" "$RES" \
    '.success == true and .schedule_armed == false
     and (.schedule_apply_error | type == "string" and length > 0)'

RES=$(run_post "$CGI_UPDATE" '{"action":"save_auto_update","enabled":false,"time":"03:00"}')
check "disable -> armed false, no warning" "$RES" \
    '.success == true and .schedule_armed == false and (has("schedule_apply_error") | not)'
[ "$(arm_log)" = "teardown" ] && pass "helper invoked as: teardown" || fail "teardown argv — got: $(arm_log)"

RES=$(run_post "$CGI_UPDATE" '{"action":"save_auto_update","enabled":false,"time":"03:00"}' disarm_failed)
check "disable + disarm_failed -> still armed, warning present" "$RES" \
    '.success == true and .schedule_armed == true
     and (.schedule_apply_error | test("may still update"))'

# The regression this endpoint specifically needed: `grep -qE '^..$'` matched
# line by line, so this exact value passed validation and flowed on into the
# file being written.
RES=$(run_post "$CGI_UPDATE" '{"action":"save_auto_update","enabled":true,"time":"03:00\nExecStart=/tmp/pwn"}')
check "newline in time rejected (grep-anchor regression)" "$RES" \
    '.success == false and .error == "invalid_value"'
[ -z "$(arm_log)" ] && pass "newline never reached the helper" || fail "helper called with a newline"

RES=$(run_post "$CGI_UPDATE" '{"action":"save_auto_update","enabled":true,"time":"99:99"}')
check "hour 99 rejected" "$RES" '.success == false and .error == "invalid_value"'
[ -z "$(arm_log)" ] && pass "hour 99 never reached the helper" || fail "helper called with 99:99"

RES=$(QM_CONFIG_FAIL=1 run_post "$CGI_UPDATE" '{"action":"save_auto_update","enabled":true,"time":"03:00"}')
check "config write failure -> success false" "$RES" \
    '.success == false and .error == "auto_update_save_failed"'
[ -z "$(arm_log)" ] && pass "config write failure armed nothing" || fail "armed despite a failed config write"

echo "== no endpoint writes a cron spool =="

# Comments still explain why the crontab is gone; nothing may still write it.
if grep -n 'crontabs' "$CGI_SETTINGS" "$CGI_TOWER" "$CGI_UPDATE" \
    | grep -v '^[^:]*:[0-9]*: *#' >/dev/null 2>&1; then
    fail "a schedule endpoint still references the cron spool outside a comment"
else
    pass "no cron spool writes remain in the three endpoints"
fi

echo
echo "schedule-cgi: $PASS passed, $FAILED failed"
[ "$FAILED" -eq 0 ] || exit 1
