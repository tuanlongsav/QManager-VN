#!/bin/bash
# Workstation fixtures for the cell-scan start endpoint's singleton.
# Run from the repo root:  bash scripts/test/scan-singleton.sh
#
# WHY THIS HARNESS EXISTS
# cell_scan_start.sh used to test a pid file and then act, with a window before
# the worker wrote its pid, so two POSTs could both pass the guard and both spawn
# a worker — and the first one to finish would then clear the pid file and the
# maintenance marker while the second still held the AT mutex for up to another
# 180s. The guard is now a flock held on an fd the worker inherits.
#
# WHAT IS AND IS NOT UNDER TEST
# `flock` is not present on macOS, so this fixture stubs it and drives the
# endpoint through both outcomes. That means the KERNEL semantics (lock lives on
# the open file description, survives the CGI exiting, released on SIGKILL) are
# NOT what these tests prove — those are properties of flock(2), verified on
# hardware. What is proven here is the endpoint's own control flow: that a
# refused lock returns the right error code and spawns nothing, that an acquired
# lock spawns exactly one worker and publishes its pid before returning, and that
# the lock file is never unlinked. Those are the parts that were hand-written and
# so are the parts that can regress.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
pass_count=0
fail_count=0

ok()   { printf '  PASS  %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail_count=$((fail_count + 1)); fail=1; }
section() { printf '\n== %s ==\n' "$1"; }

if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP  jq not on PATH — the endpoint emits its whole response through jq" >&2
    exit 0
fi

SANDBOX_TMP="$work/tmp"
PID_FILE="$SANDBOX_TMP/qmanager_cell_scan.pid"
SCAN_LOCK="$SANDBOX_TMP/qmanager_scan.lock"
SPAWN_SENTINEL="$work/spawned"

mkdir -p "$SANDBOX_TMP" "$work/bin" "$work/lib"

# --- Stub cgi_base.sh ---------------------------------------------------------
# Mirrors the shipped helpers the endpoint actually calls. cgi_error keeps the
# real JSON shape because the assertions below read `.error` out of it.
#
# pid_alive is `kill -0` here rather than the shipped `[ -d /proc/$1 ]`: the
# fixture's processes are all the same user, and the /proc form only exists so a
# www-data CGI can see a root daemon. Nothing under test depends on which.
cat > "$work/lib/cgi_base.sh" <<'CGIBASE'
qlog_init()  { :; }
qlog_debug() { :; }
qlog_info()  { :; }
qlog_warn()  { :; }
qlog_error() { :; }
cgi_headers()        { :; }
cgi_handle_options() { :; }
cgi_error() {
    jq -n --arg error "$1" --arg detail "${2:-}" \
        '{"success":false,"error":$error,"detail":$detail}'
}
pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
CGIBASE

# --- Stub flock ---------------------------------------------------------------
# Exit status is the whole contract the endpoint reads from it.
cat > "$work/bin/flock" <<'FLOCK'
#!/bin/sh
exit "${QM_TEST_FLOCK_RC:-0}"
FLOCK
chmod +x "$work/bin/flock"

# --- Fake worker --------------------------------------------------------------
# Records that it ran, then lives long enough for the endpoint's 0.2s liveness
# check to see it — a real sweep holds the modem for 30-180s.
cat > "$work/bin/fake_scanner" <<FAKE
#!/bin/sh
echo ran >> "$SPAWN_SENTINEL"
sleep 3
FAKE
chmod +x "$work/bin/fake_scanner"

# --- Sandbox copy of the endpoint ---------------------------------------------
sed -e "s#/tmp/#$SANDBOX_TMP/#g" \
    -e "s#/usr/lib/qmanager/#$work/lib/#g" \
    -e "s#/usr/bin/qmanager_cell_scanner#$work/bin/fake_scanner#g" \
    "$REPO_ROOT/scripts/www/cgi-bin/quecmanager/at_cmd/cell_scan_start.sh" \
    > "$work/bin/cell_scan_start.sh"
chmod +x "$work/bin/cell_scan_start.sh"

# Guard the rewrite: an un-redirected copy would spawn the real scanner path and
# scribble on the dev machine's /tmp while every assertion passed vacuously.
if grep -q 'SCAN_LOCK="/tmp/' "$work/bin/cell_scan_start.sh"; then
    printf '  FAIL  sandbox rewrite did not redirect the endpoint paths\n' >&2
    exit 1
fi

reset_fixture() {
    rm -rf "$SANDBOX_TMP" "$SPAWN_SENTINEL"
    mkdir -p "$SANDBOX_TMP"
}

# Runs the endpoint and echoes its response body.
run_endpoint() {
    ( export PATH="$work/bin:$PATH" REQUEST_METHOD="${QM_TEST_METHOD:-POST}"
      "$work/bin/cell_scan_start.sh" 2>/dev/null ) || true
}

spawn_count() { [ -f "$SPAWN_SENTINEL" ] && wc -l < "$SPAWN_SENTINEL" | tr -d ' ' || echo 0; }

# The worker is spawned in the background, so "did it run" needs a bounded wait
# rather than an instant look — on macOS the FIRST exec of a freshly written
# script costs a few hundred ms of security checks, which is longer than the
# endpoint's own 0.2s liveness pause. Poll up to $1 tenths of a second.
# The negative assertions use the same wait so "nothing spawned" cannot pass
# merely because the check was faster than the spawn.
wait_for_spawn() {
    _tenths=0
    while [ "$_tenths" -lt "$1" ]; do
        [ -f "$SPAWN_SENTINEL" ] && return 0
        sleep 0.1
        _tenths=$((_tenths + 1))
    done
    return 1
}

# Pay the first-exec cost once, before anything is being measured.
"$work/bin/fake_scanner" >/dev/null 2>&1 &
warmup_pid=$!
sleep 0.5
kill "$warmup_pid" 2>/dev/null || true
wait "$warmup_pid" 2>/dev/null || true
rm -f "$SPAWN_SENTINEL"

kill_workers() {
    if [ -f "$PID_FILE" ]; then
        kill "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null || true
    fi
}

# =============================================================================
section "lock acquired — the scan starts"
# =============================================================================
reset_fixture
body=$(QM_TEST_FLOCK_RC=0 run_endpoint)
wait_for_spawn 30 || true

if [ "$(printf '%s' "$body" | jq -r '.success')" = "true" ]; then
    ok "returns success when the lock is free"
else
    bad "expected success, got: $body"
fi

if [ "$(spawn_count)" = "1" ]; then
    ok "spawns exactly one worker"
else
    bad "spawned $(spawn_count) workers, expected 1"
fi

# The endpoint must publish the pid itself. If it waits for the worker to do it,
# the response can beat the pid file and the client's first status poll reads a
# perfectly healthy scan as idle.
if [ -s "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    ok "pid file names a live worker by the time the response is written"
else
    bad "pid file missing or stale when the endpoint returned"
fi

if [ "$(printf '%s' "$body" | jq -r '.pid')" = "$(cat "$PID_FILE")" ]; then
    ok "response pid matches the pid file"
else
    bad "response pid $(printf '%s' "$body" | jq -r '.pid') != pid file $(cat "$PID_FILE" 2>/dev/null)"
fi

if [ -e "$SCAN_LOCK" ]; then
    ok "lock file still exists after the request"
else
    bad "lock file was unlinked — the next opener would lock a new inode and the singleton would silently stop working"
fi

kill_workers

# =============================================================================
section "lock refused — nothing is spawned"
# =============================================================================
# Our own worker still running: the client should be told to attach to it.
reset_fixture
echo $$ > "$PID_FILE"   # a pid that is definitely alive
body=$(QM_TEST_FLOCK_RC=1 run_endpoint)
wait_for_spawn 8 || true

if [ "$(printf '%s' "$body" | jq -r '.error')" = "already_running" ]; then
    ok "returns already_running when our own worker holds the lock"
else
    bad "expected already_running, got: $body"
fi

if [ "$(spawn_count)" = "0" ]; then
    ok "spawns nothing while the lock is held"
else
    bad "spawned a second worker while the lock was held — the singleton is not real"
fi

# Someone else holds the lock. This MUST NOT reuse already_running: the frontend
# reads that as "attach and poll", which against another scan's run would poll a
# pid file that does not exist, resolve to idle, and drop the UI back to nothing.
reset_fixture
body=$(QM_TEST_FLOCK_RC=1 run_endpoint)
wait_for_spawn 8 || true

if [ "$(printf '%s' "$body" | jq -r '.error')" = "other_scan_running" ]; then
    ok "returns other_scan_running when the holder is not our worker"
else
    bad "expected other_scan_running, got: $body"
fi

if [ "$(spawn_count)" = "0" ]; then
    ok "spawns nothing when another scan holds the lock"
else
    bad "spawned a worker into another scan's run"
fi

# A stale pid file must not be mistaken for a live worker.
reset_fixture
echo 999999 > "$PID_FILE"
body=$(QM_TEST_FLOCK_RC=1 run_endpoint)

if [ "$(printf '%s' "$body" | jq -r '.error')" = "other_scan_running" ]; then
    ok "a stale pid file does not masquerade as our own running scan"
else
    bad "expected other_scan_running for a stale pid file, got: $body"
fi

# =============================================================================
section "spawn failure is still detected"
# =============================================================================
# The 0.2s liveness check replaced a 0.8s sleep that had quietly been the only
# detector for a missing or non-executable binary.
reset_fixture
chmod -x "$work/bin/fake_scanner"
body=$(QM_TEST_FLOCK_RC=0 run_endpoint)
chmod +x "$work/bin/fake_scanner"

if [ "$(printf '%s' "$body" | jq -r '.error')" = "start_failed" ]; then
    ok "reports start_failed when the worker binary cannot run"
else
    bad "expected start_failed, got: $body"
fi

if [ ! -e "$PID_FILE" ]; then
    ok "removes the pid file of a worker that never started"
else
    bad "left a pid file for a worker that never started"
fi

# =============================================================================
section "method guard runs before anything else"
# =============================================================================
reset_fixture
body=$(QM_TEST_METHOD=GET QM_TEST_FLOCK_RC=0 run_endpoint)
wait_for_spawn 8 || true

if [ "$(printf '%s' "$body" | jq -r '.error')" = "method_not_allowed" ]; then
    ok "rejects a non-POST request"
else
    bad "expected method_not_allowed, got: $body"
fi

if [ "$(spawn_count)" = "0" ]; then
    ok "a GET spawns nothing"
else
    bad "a GET spawned a worker"
fi

kill_workers

printf '\n[scan-singleton] %d passed, %d failed\n' "$pass_count" "$fail_count"
exit "$fail"
