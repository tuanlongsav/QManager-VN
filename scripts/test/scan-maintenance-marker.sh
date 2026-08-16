#!/bin/bash
# Workstation fixtures for the AT maintenance marker (/tmp/qmanager_long_running).
# Run from the repo root:  bash scripts/test/scan-maintenance-marker.sh
#
# WHY THIS HARNESS EXISTS
# The marker had two readers (qmanager_poller drops to ping-only, qmanager_watchcat
# parks in maintenance) and a boot-time deleter, but for a long time NO writer at
# all — so the documented guard was fiction and a 180s AT+QSCAN sweep was invisible
# to the watchdog that reboots the modem when it believes the link died. Nothing in
# the tree tested for the writer, which is precisely why its absence survived.
#
# These are behavioural fixtures, not greps: each test runs the real worker script
# against a fake `qcmd` that records whether the marker existed at the instant the
# AT command was issued. Delete the writer and test 1 fails; delete the cleanup and
# test 2 fails.
#
# HOW THE SANDBOX WORKS
# The workers hardcode absolute paths (/tmp/..., /proc/<pid>), which is correct on
# the modem and untestable on a workstation. Rather than adding env overrides to
# shipped code — the workers are spawned from a CGI, so an overridable path would
# be an injection surface — each worker is copied with /tmp/ and /proc/ rewritten
# into the fixture directory. Everything else about the script under test is
# byte-identical to what ships.
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

SANDBOX_TMP="$work/tmp"
SANDBOX_PROC="$work/proc"
MARKER="$SANDBOX_TMP/qmanager_long_running"
OBSERVED="$work/observed"

mkdir -p "$SANDBOX_TMP" "$SANDBOX_PROC" "$work/bin" "$work/lib"

# --- Stub qlog.sh -------------------------------------------------------------
# The workers open with `. /usr/lib/qmanager/qlog.sh || { ...no-op fallbacks... }`.
# That fallback never runs here: `.` is a POSIX special builtin, so a failed
# source aborts the shell outright before the `||` is reached. On the modem the
# library always exists, so this only ever bites the fixture — supply it.
cat > "$work/lib/qlog.sh" <<'QLOG'
qlog_init()  { :; }
qlog_debug() { :; }
qlog_info()  { :; }
qlog_warn()  { :; }
qlog_error() { :; }
QLOG

# --- The qcmd test double -----------------------------------------------------
# Records marker presence at AT time, one line per invocation, then replies with
# a canned response shaped like the real modem's.
cat > "$work/bin/qcmd" <<'SHIM'
#!/bin/sh
if [ -e "$QM_TEST_MARKER" ]; then
    echo present >> "$QM_TEST_OBSERVED"
else
    echo absent >> "$QM_TEST_OBSERVED"
fi
[ -n "${QM_TEST_SLEEP:-}" ] && sleep "$QM_TEST_SLEEP"
[ -n "${QM_TEST_FAIL:-}" ] && exit 1
case "$1" in
    *QSCAN*)
        printf '+QSCAN: "LTE",452,04,1850,123,-85,-10,30,20,1A2B3C,4D5E,100,3\n' ;;
    *neighbourcell*)
        printf '+QENG: "neighbourcell intra","LTE",1850,123,-10,-85,-60,12\n' ;;
    *nr5g_meas_info*)
        printf '+QNWCFG: "nr5g_meas_info",1,504990,321,-90,-11,10\n' ;;
esac
exit 0
SHIM
chmod +x "$work/bin/qcmd"

# --- Sandbox copies of the two workers ---------------------------------------
sandbox_worker() {
    # $1 = worker name under scripts/usr/bin, $2 = destination path
    sed -e "s#/tmp/#$SANDBOX_TMP/#g" \
        -e "s#/proc/#$SANDBOX_PROC/#g" \
        -e "s#/usr/lib/qmanager/#$work/lib/#g" \
        "$REPO_ROOT/scripts/usr/bin/$1" > "$2"
    chmod +x "$2"
}

sandbox_worker qmanager_cell_scanner      "$work/bin/cell_scanner"
sandbox_worker qmanager_neighbour_scanner "$work/bin/neighbour_scanner"

# Guard the rewrite itself: if the sandbox copy still points at the real /tmp,
# every assertion below would silently test nothing (and scribble on the dev
# machine's /tmp while doing it).
if grep -q '"/tmp/qmanager_long_running"' "$work/bin/cell_scanner" \
   || grep -q '"/tmp/qmanager_long_running"' "$work/bin/neighbour_scanner"; then
    printf '  FAIL  sandbox rewrite did not redirect the marker path\n' >&2
    exit 1
fi

run_worker() {
    # $1 = sandbox worker path; remaining env comes from the caller.
    ( export PATH="$work/bin:$PATH" \
             QM_TEST_MARKER="$MARKER" \
             QM_TEST_OBSERVED="$OBSERVED"
      "$1" >/dev/null 2>&1 ) || true
}

reset_fixture() {
    rm -rf "$SANDBOX_TMP" "$SANDBOX_PROC" "$OBSERVED"
    mkdir -p "$SANDBOX_TMP" "$SANDBOX_PROC"
    : > "$OBSERVED"
}

first_observation() { head -1 "$OBSERVED" 2>/dev/null; }

# =============================================================================
section "cell scanner raises the marker for the duration of the sweep"
# =============================================================================
reset_fixture
run_worker "$work/bin/cell_scanner"

if [ "$(first_observation)" = "present" ]; then
    ok "marker exists when AT+QSCAN is issued"
else
    bad "marker MISSING when AT+QSCAN is issued (observed: '$(first_observation)') — the poller never enters scan_in_progress and the watchdog never sees maintenance mode"
fi

if [ ! -e "$MARKER" ]; then
    ok "marker cleared after a successful sweep"
else
    bad "marker left behind after a successful sweep — a stuck marker disables the watchdog indefinitely"
fi

if [ ! -e "$SANDBOX_TMP/qmanager_cell_scan.pid" ]; then
    ok "pid file cleared after a successful sweep"
else
    bad "pid file left behind after a successful sweep"
fi

# =============================================================================
section "cell scanner clears the marker on a failed sweep"
# =============================================================================
reset_fixture
QM_TEST_FAIL=1 run_worker "$work/bin/cell_scanner"

if [ "$(first_observation)" = "present" ]; then
    ok "marker raised before the AT command that then failed"
else
    bad "marker MISSING on the failing path (observed: '$(first_observation)')"
fi

if [ ! -e "$MARKER" ]; then
    ok "marker cleared when AT+QSCAN fails"
else
    bad "marker survives a failed sweep — the watchdog stays disabled until the poller's 300s expiry"
fi

# =============================================================================
section "cell scanner clears the marker when interrupted"
# =============================================================================
reset_fixture
# Background the worker DIRECTLY rather than wrapping it in a subshell: `$!` on
# a subshell is the subshell's pid, the signal never reaches the worker, and the
# orphan then runs its cleanup in the middle of a later test.
PATH="$work/bin:$PATH" \
QM_TEST_MARKER="$MARKER" \
QM_TEST_OBSERVED="$OBSERVED" \
QM_TEST_SLEEP=2 \
    "$work/bin/cell_scanner" >/dev/null 2>&1 &
worker_pid=$!
sleep 0.4
kill -TERM "$worker_pid" 2>/dev/null || true
wait "$worker_pid" 2>/dev/null || true

if [ ! -e "$MARKER" ]; then
    ok "marker cleared after SIGTERM mid-scan"
else
    bad "marker survives SIGTERM — the trap does not cover the interrupted path"
fi

# =============================================================================
section "a finishing worker does not unmask the other scan"
# =============================================================================
# The two start endpoints do not share a lock, so a short neighbour read can
# begin inside a 180s sweep. Whichever worker exits first must leave the marker
# alone while the other still holds the AT mutex.
reset_fixture
sleep 5 &
sibling_pid=$!
mkdir -p "$SANDBOX_PROC/$sibling_pid"
echo "$sibling_pid" > "$SANDBOX_TMP/qmanager_neighbour_scan.pid"

run_worker "$work/bin/cell_scanner"

if [ -e "$MARKER" ]; then
    ok "cell scanner leaves the marker up while the neighbour worker is alive"
else
    bad "cell scanner cleared the marker out from under a live neighbour worker"
fi

reset_fixture
echo "$sibling_pid" > "$SANDBOX_TMP/qmanager_cell_scan.pid"
mkdir -p "$SANDBOX_PROC/$sibling_pid"

run_worker "$work/bin/neighbour_scanner"

if [ -e "$MARKER" ]; then
    ok "neighbour scanner leaves the marker up while the cell sweep is alive"
else
    bad "neighbour scanner cleared the marker out from under a live cell sweep"
fi

kill "$sibling_pid" 2>/dev/null || true
wait "$sibling_pid" 2>/dev/null || true

# =============================================================================
section "neighbour scanner raises the marker for the whole read"
# =============================================================================
reset_fixture
run_worker "$work/bin/neighbour_scanner"

if [ "$(first_observation)" = "present" ]; then
    ok "marker exists when the first neighbour AT command is issued"
else
    bad "marker MISSING when the neighbour read starts (observed: '$(first_observation)')"
fi

# The worker issues three AT commands with a settling sleep between them; the
# marker must hold across all of them, not just the first.
if [ "$(sort -u "$OBSERVED" | tr '\n' ' ')" = "present " ]; then
    ok "marker held across every AT command in the read"
else
    bad "marker dropped mid-read (observations: $(tr '\n' ' ' < "$OBSERVED"))"
fi

if [ ! -e "$MARKER" ]; then
    ok "marker cleared after the neighbour read"
else
    bad "marker left behind after the neighbour read"
fi

# =============================================================================
section "the marker path still matches what the readers expect"
# =============================================================================
# The writers and readers agree by string only — there is no shared constant —
# so a rename in one file would restore the original defect silently.
for reader in qmanager_poller qmanager_watchcat; do
    if grep -q '"/tmp/qmanager_long_running"' "$REPO_ROOT/scripts/usr/bin/$reader"; then
        ok "$reader reads /tmp/qmanager_long_running"
    else
        bad "$reader no longer references /tmp/qmanager_long_running — writers and readers have diverged"
    fi
done

for writer in qmanager_cell_scanner qmanager_neighbour_scanner; do
    if grep -q '^LONG_FLAG="/tmp/qmanager_long_running"' "$REPO_ROOT/scripts/usr/bin/$writer"; then
        ok "$writer writes /tmp/qmanager_long_running"
    else
        bad "$writer no longer defines the marker path"
    fi
done

# --- Summary ------------------------------------------------------------------
printf '\n[scan-maintenance-marker] %d passed, %d failed\n' "$pass_count" "$fail_count"
exit "$fail"
