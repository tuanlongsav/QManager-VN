#!/bin/sh
. /usr/lib/qmanager/cgi_base.sh
# =============================================================================
# cell_scan_start.sh — CGI Endpoint: Start Cell Scan
# =============================================================================
# Spawns the qmanager_cell_scanner background worker.
# Enforces singleton — only ONE scan may run at a time.
#
# Endpoint: POST /cgi-bin/quecmanager/at_cmd/cell_scan_start.sh
# Response: {"success": true}
#       or: {"success": false, "error": "already_running|start_failed"}
#
# Install location: /www/cgi-bin/quecmanager/at_cmd/cell_scan_start.sh
# =============================================================================

# --- Logging -----------------------------------------------------------------
qlog_init "cgi_cell_scan"
cgi_headers
cgi_handle_options

# --- Configuration -----------------------------------------------------------
PID_FILE="/tmp/qmanager_cell_scan.pid"
RESULT_FILE="/tmp/qmanager_cell_scan_result.json"
ERROR_FILE="/tmp/qmanager_cell_scan_error"
SCANNER_BIN="/usr/bin/qmanager_cell_scanner"
# The real singleton. Named for the whole scan family rather than for this
# endpoint because a full sweep and a neighbour read must never overlap — both
# serialize through the same AT mutex (/tmp/qmanager_at.lock), and a two-second
# read fired into a 180s sweep just sits blocked with no way to tell the user
# why. neighbour_scan_start.sh does not join this lock yet; when it does, the
# other_scan_running branch below starts firing without any change here.
SCAN_LOCK="/tmp/qmanager_scan.lock"

# --- Validate method ---------------------------------------------------------
if [ "$REQUEST_METHOD" != "POST" ]; then
    cgi_error "method_not_allowed" "Use POST"
    exit 0
fi

# --- Stale PID file cleanup (cosmetic only) -----------------------------------
# This no longer guards exclusion — the flock taken below is the singleton.
# pid_alive() is just `[ -d /proc/$1 ]` (platform.sh), which proves *a* process
# exists, not that it is our scanner, so it must never be load-bearing here.
# It is kept only so a stale pid file does not linger and so the busy branch
# below has a clean file to inspect when deciding which message to return.
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
    if ! pid_alive "$OLD_PID"; then
        qlog_info "Cleaning stale cell scan PID file (PID: $OLD_PID)"
        rm -f "$PID_FILE"
    fi
fi

# --- Acquire the scan lock ----------------------------------------------------
# The lock file is created lazily and world-writable, matching qcmd's treatment
# of /tmp/qmanager_at.lock: root daemons and www-data CGIs share it. It is
# opened READ-ONLY — a read-only fd is enough for flock -x, and it keeps this
# working if a root component ever creates the file first.
#
# NEVER unlink this file while a request could be in flight: unlinking detaches
# the name without releasing the lock, and the next opener would lock a brand
# new inode with no error reported anywhere.
if [ ! -e "$SCAN_LOCK" ]; then
    : > "$SCAN_LOCK" 2>/dev/null
    chmod 666 "$SCAN_LOCK" 2>/dev/null
fi
if [ ! -r "$SCAN_LOCK" ]; then
    # `exec 9<` on an unreadable path would kill the shell before any body was
    # written, so the client would see an empty 200 instead of an error.
    qlog_error "Scan lock $SCAN_LOCK is not readable — cannot serialize scans"
    cgi_error "start_failed" "Scan lock unavailable"
    exit 0
fi
exec 9<"$SCAN_LOCK"

if ! flock -x -n 9; then
    # Busy. The pid file is cosmetic, so it only decides WHICH message to
    # return, never whether to spawn. other_scan_running MUST stay distinct
    # from already_running: the frontend reads already_running as "attach to
    # the in-flight run and start polling", which for a scan of the other kind
    # would attach the poll loop to a pid file that does not exist, yield idle
    # one second later, and drop the UI back to nothing.
    if [ -f "$PID_FILE" ] && pid_alive "$(cat "$PID_FILE" 2>/dev/null)"; then
        qlog_warn "Cell scan already running"
        cgi_error "already_running" "A cell scan is already in progress"
    else
        qlog_warn "Cell scan blocked — another scan holds the modem"
        cgi_error "other_scan_running" "Another scan is using the modem. Wait for it to finish."
    fi
    exit 0
fi

# --- Clean up previous results -----------------------------------------------
rm -f "$RESULT_FILE" "$ERROR_FILE"

# --- Launch scanner in background --------------------------------------------
# fd 9 (the flock just acquired) is inherited by this subshell and by the
# worker — nothing here closes it. A flock lives on the open file description
# rather than on the acquiring process, so it survives this CGI exiting and is
# released by the kernel only when the worker's last fd closes, on a clean exit
# and on a SIGKILL alike. That makes the singleton self-healing: no stale-lock
# sweep is ever needed, and acquire-then-spawn is atomic from the client's side,
# which closes the old check-then-act window rather than merely narrowing it.
#
# The CGI writes the pid itself instead of sleeping for the worker to write it.
# `$!` here is the worker's pid — the same value the worker writes as `$$` — so
# the two agree rather than race, and the first status poll can never arrive
# before the pid file exists and read the running scan as idle.
( "$SCANNER_BIN" </dev/null >/dev/null 2>&1 & echo $! > "$PID_FILE" )

# The 0.8s sleep this replaced doubled as the only detector for a missing or
# non-executable binary. Keep a short look for that: a healthy worker holds the
# modem for 30-180s, so a pid that is already gone this early means the spawn
# itself failed, not that the scan finished.
sleep 0.2
NEW_PID=$(cat "$PID_FILE" 2>/dev/null)
if ! pid_alive "$NEW_PID"; then
    rm -f "$PID_FILE"
    qlog_error "Cell scanner failed to start"
    cgi_error "start_failed" "Scanner process did not start"
    exit 0
fi

qlog_info "Cell scan started (PID: $NEW_PID)"
jq -n --argjson pid "$NEW_PID" '{"success": true, "pid": $pid}'
