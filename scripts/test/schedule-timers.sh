#!/bin/sh
# Harness for the scheduled-timer layer:
#   scripts/usr/lib/qmanager/schedule_timer.sh   (shared library)
#   scripts/usr/bin/qmanager_scheduled_reboot_arm
#   scripts/usr/bin/qmanager_tower_schedule_arm
#   scripts/usr/bin/qmanager_auto_update_arm
#
# These helpers write systemd unit files as root from values that arrived in an
# HTTP request. What runs below is the shipped shell, not a reimplementation —
# only the filesystem root is redirected, through the QM_TIMER_ROOT hook the
# library documents, so nothing here can touch the developer's /lib or systemd.
#
# The four invariants this exists to protect, in the order the sections appear:
#
#   1. A newline cannot reach a unit file. systemd units are newline-delimited
#      Key=Value, so one smuggled newline in an "HH:MM" is a second directive,
#      and ExecStart= in a unit root starts is arbitrary root code. Tested at
#      BOTH gates — through the helper's validation, and by calling the write
#      function directly with a malicious line to prove the gate at the write
#      itself stands on its own.
#   2. A rejected schedule arms nothing. Not "arms something harmless" — the
#      unit directory must be untouched, including scratch files.
#   3. Arming twice is idempotent: same unit bytes, one symlink, no debris.
#   4. Disarming something that was never armed succeeds. A teardown that
#      errored on an already-off schedule would push callers toward ignoring
#      its exit status, which is how the previous mechanism came to lie.
#
# Plus a guard the platform demands: every directive emitted into a generated
# unit must exist in systemd 244. A directive from a later release is silently
# ignored there, producing a timer that loads clean and never fires — the exact
# bug this whole layer replaces.
set -eu

LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_LIB="$REPO_ROOT/scripts/usr/lib/qmanager/schedule_timer.sh"
SRC_REBOOT="$REPO_ROOT/scripts/usr/bin/qmanager_scheduled_reboot_arm"
SRC_TOWER="$REPO_ROOT/scripts/usr/bin/qmanager_tower_schedule_arm"
SRC_UPDATE="$REPO_ROOT/scripts/usr/bin/qmanager_auto_update_arm"

for f in "$SRC_LIB" "$SRC_REBOOT" "$SRC_TOWER" "$SRC_UPDATE"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: not found: $f" >&2
        exit 1
    fi
done

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

UNIT_DIR="$TEST_DIR/lib/systemd/system"
WANTS_DIR="$UNIT_DIR/timers.target.wants"
mkdir -p "$UNIT_DIR" "$TEST_DIR/usr/lib/qmanager"
cp "$SRC_LIB" "$TEST_DIR/usr/lib/qmanager/schedule_timer.sh"

QM_TIMER_ROOT="$TEST_DIR"
export QM_TIMER_ROOT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

# ─── fixture helpers ────────────────────────────────────────────────────────

# The paired .service units are shipped by the installer, not generated here.
# Stub them so the helpers' "does the target exist" check passes.
stage_services() {
    for s in qmanager-scheduled-reboot \
             qmanager-tower-schedule-apply qmanager-tower-schedule-clear \
             qmanager-auto-update; do
        printf '[Service]\nType=oneshot\nExecStart=/bin/true\n' \
            > "$UNIT_DIR/$s.service"
    done
}

reset_fixture() {
    rm -rf "$UNIT_DIR"
    mkdir -p "$UNIT_DIR"
    stage_services
}

run_helper() {
    helper="$1"; shift
    HELPER_OUT=$(sh "$helper" "$@" 2>/dev/null) && HELPER_RC=0 || HELPER_RC=$?
}

# Flat-JSON field reader. Deliberately not jq-gated: a harness that silently
# skips its assertions when a tool is missing is the vacuous-test failure this
# repo has already shipped twice. Splitting on commas puts each key on its own
# line; none of the asserted values contain one.
json_field() {
    printf '%s' "$HELPER_OUT" | tr ',' '\n' \
        | sed -n 's/.*"'"$1"'":"\{0,1\}\([^"}]*\)"\{0,1\}.*/\1/p' | head -1
}

# Everything in the unit directory that is not one of the four staged
# .service stubs: generated timers, symlinks, and any .tmp scratch left behind.
#
# timers.target.wants itself is excluded — only its CONTENTS count. Teardown
# deliberately leaves the empty directory standing: it is shared with every
# other timer on the device (and with the installer, which mkdir -p's it), so
# removing it would be reaching outside what this feature owns.
artefacts() {
    find "$UNIT_DIR" -mindepth 1 ! -name '*.service' ! -path "$WANTS_DIR" \
        2>/dev/null | sort
}
artefact_count() { artefacts | grep -c . || true; }

expect_clean() {
    n=$(artefact_count)
    if [ "$n" -eq 0 ]; then
        pass "$1"
    else
        fail "$1 — unit dir not clean, found: $(artefacts | tr '\n' ' ')"
    fi
}

# Nothing anywhere under the fixture may contain a newline-injected directive.
# Greps the whole tree, not just the file we expect, so a write that lands
# somewhere unexpected is still caught.
expect_no_injection() {
    if find "$TEST_DIR" -type f -exec grep -l 'INJECTED' {} + 2>/dev/null | grep -q .; then
        fail "$1 — injected payload reached a file on disk"
    else
        pass "$1"
    fi
}

json_is() {
    got=$(json_field "$1")
    if [ "$got" = "$2" ]; then
        pass "$3"
    else
        fail "$3 — expected $1=$2, got '$got' (raw: $HELPER_OUT)"
    fi
}

# ─── 1. injected newlines cannot reach a unit file ──────────────────────────
echo "-- newline injection --"
reset_fixture

# The payload is shaped exactly like the real attack: a first line that passes
# a line-based anchored regex, then a second directive. update.sh's current
# `grep -qE '^[0-9]{2}:[0-9]{2}$'` accepts this; the whole-string charset gate
# must not.
NL=$(printf '\n')
EVIL_TIME="04:00${NL}ExecStart=/bin/touch /tmp/INJECTED"
EVIL_DAYS="0,3${NL}ExecStart=/bin/touch /tmp/INJECTED"

run_helper "$SRC_REBOOT" install "$EVIL_TIME" "0,3"
[ "$HELPER_RC" -eq 1 ] && pass "reboot: newline in time is rejected (rc=1)" \
    || fail "reboot: newline in time is rejected — rc=$HELPER_RC out=$HELPER_OUT"
json_is error invalid_time "reboot: newline in time reports invalid_time"
expect_clean "reboot: newline in time wrote nothing"
expect_no_injection "reboot: newline in time left no payload on disk"

run_helper "$SRC_REBOOT" install "04:00" "$EVIL_DAYS"
[ "$HELPER_RC" -eq 1 ] && pass "reboot: newline in day mask is rejected" \
    || fail "reboot: newline in day mask is rejected — rc=$HELPER_RC"
json_is error invalid_days "reboot: newline in day mask reports invalid_days"
expect_clean "reboot: newline in day mask wrote nothing"

run_helper "$SRC_TOWER" install "$EVIL_TIME" "22:00" "1,2"
[ "$HELPER_RC" -eq 1 ] && pass "tower: newline in start_time is rejected" \
    || fail "tower: newline in start_time is rejected — rc=$HELPER_RC"
expect_clean "tower: newline in start_time wrote nothing"

run_helper "$SRC_TOWER" install "08:00" "$EVIL_TIME" "1,2"
[ "$HELPER_RC" -eq 1 ] && pass "tower: newline in end_time is rejected" \
    || fail "tower: newline in end_time is rejected — rc=$HELPER_RC"
expect_clean "tower: newline in end_time wrote nothing"

run_helper "$SRC_UPDATE" install "$EVIL_TIME"
[ "$HELPER_RC" -eq 1 ] && pass "auto-update: newline in time is rejected" \
    || fail "auto-update: newline in time is rejected — rc=$HELPER_RC"
expect_clean "auto-update: newline in time wrote nothing"
expect_no_injection "auto-update: newline in time left no payload on disk"

# The gate at the write itself, exercised directly. This is the assertion that
# says a FUTURE caller which forgets to validate still cannot produce a
# multi-line unit body — the entry gates above could be removed and this one
# would still hold the line.
(
    _SCHEDULE_TIMER_LOADED=""
    # shellcheck source=/dev/null
    . "$TEST_DIR/usr/lib/qmanager/schedule_timer.sh"
    MALICIOUS="OnCalendar=Mon *-*-* 04:00:00${NL}ExecStart=/bin/touch /tmp/INJECTED"
    if _qm_timer_write "probe.timer" "probe.service" "probe" "$MALICIOUS"; then
        exit 1
    fi
    exit 0
) && pass "write gate refuses a multi-line OnCalendar even without prior validation" \
  || fail "write gate refuses a multi-line OnCalendar even without prior validation"
expect_clean "write gate left no file behind"
expect_no_injection "write gate left no payload on disk"

# Same gate, other metacharacters — a command substitution or a semicolon has
# no business in a calendar spec.
(
    _SCHEDULE_TIMER_LOADED=""
    # shellcheck source=/dev/null
    . "$TEST_DIR/usr/lib/qmanager/schedule_timer.sh"
    if _qm_timer_write "probe.timer" "probe.service" "probe" 'OnCalendar=$(reboot)'; then
        exit 1
    fi
    if _qm_timer_write "probe.timer" "probe.service" "probe" 'Description=x'; then
        exit 1
    fi
    exit 0
) && pass "write gate refuses metacharacters and non-OnCalendar lines" \
  || fail "write gate refuses metacharacters and non-OnCalendar lines"
expect_clean "write gate (metacharacters) left no file behind"

# ─── 2. a rejected schedule arms nothing ────────────────────────────────────
echo
echo "-- rejected schedules arm nothing --"
reset_fixture

reject_case() {
    desc="$1"; expect="$2"; helper="$3"; shift 3
    run_helper "$helper" "$@"
    if [ "$HELPER_RC" -ne 0 ]; then
        pass "rejected: $desc"
    else
        fail "rejected: $desc — helper returned 0 (out=$HELPER_OUT)"
    fi
    json_is error "$expect" "rejected: $desc → error=$expect"
    json_is armed false "rejected: $desc → armed=false"
    expect_clean "rejected: $desc armed nothing"
}

# Hour 24-29 is the one that matters most: the loose [0-2][0-9] shape used
# elsewhere in this tree accepts it, and systemd then refuses to load the unit
# — a timer that exists, reports saved, and never fires.
reject_case "hour 24"            invalid_time  "$SRC_REBOOT" install "24:00" "0"
reject_case "hour 29"            invalid_time  "$SRC_REBOOT" install "29:59" "0"
reject_case "minute 60"          invalid_time  "$SRC_REBOOT" install "04:60" "0"
reject_case "single-digit hour"  invalid_time  "$SRC_REBOOT" install "4:00"  "0"
reject_case "empty time"         invalid_time  "$SRC_REBOOT" install ""      "0"
reject_case "seconds appended"   invalid_time  "$SRC_REBOOT" install "04:00:00" "0"
reject_case "day 7"              invalid_days  "$SRC_REBOOT" install "04:00" "7"
reject_case "negative day"       invalid_days  "$SRC_REBOOT" install "04:00" "-1"
reject_case "empty day mask"     invalid_days  "$SRC_REBOOT" install "04:00" ""
reject_case "doubled comma"      invalid_days  "$SRC_REBOOT" install "04:00" "0,,1"
reject_case "trailing comma"     invalid_days  "$SRC_REBOOT" install "04:00" "0,"
reject_case "leading comma"      invalid_days  "$SRC_REBOOT" install "04:00" ",0"
reject_case "unknown verb"       invalid_action "$SRC_REBOOT" enable "04:00" "0"
reject_case "no verb"            invalid_action "$SRC_REBOOT"
reject_case "tower bad end"      invalid_end_time "$SRC_TOWER" install "08:00" "24:00" "1"
reject_case "update hour 24"     invalid_time  "$SRC_UPDATE" install "24:00"

# Boundary values that must be ACCEPTED — a validator that rejects everything
# would pass every test above while breaking the feature.
run_helper "$SRC_REBOOT" install "00:00" "0,1,2,3,4,5,6"
json_is armed true "boundary: 00:00 across all seven days is accepted"
run_helper "$SRC_REBOOT" install "23:59" "6"
json_is armed true "boundary: 23:59 is accepted"

# ─── 3. generated unit content ──────────────────────────────────────────────
echo
echo "-- generated unit content --"
reset_fixture

run_helper "$SRC_REBOOT" install "04:30" "0,3,6"
json_is success true "reboot: install succeeds"
json_is armed   true "reboot: install reports armed=true"
UNIT_FILE="$UNIT_DIR/qmanager-scheduled-reboot.timer"

if [ -f "$UNIT_FILE" ]; then
    pass "reboot: timer unit written"
else
    fail "reboot: timer unit written"
fi

# The cron weekday numbering (0=Sun) is not systemd's; a wrong mapping arms the
# schedule on the wrong day, which looks identical to "nothing happened".
if grep -qx 'OnCalendar=Sun,Wed,Sat \*-\*-\* 04:30:00' "$UNIT_FILE"; then
    pass "reboot: 0,3,6 maps to Sun,Wed,Sat at 04:30"
else
    fail "reboot: 0,3,6 maps to Sun,Wed,Sat at 04:30 — got: $(grep OnCalendar "$UNIT_FILE")"
fi

# /var/lib is tmpfs on this device, so systemd finds no timestamp stamp file on
# ANY boot and a Persistent=true timer fires immediately every time — a boot
# loop for the reboot unit specifically.
if grep -qx 'Persistent=false' "$UNIT_FILE"; then
    pass "reboot: Persistent=false"
else
    fail "reboot: Persistent=false — got: $(grep Persistent "$UNIT_FILE" || echo '<absent>')"
fi

if grep -qx 'WantedBy=timers.target' "$UNIT_FILE"; then
    pass "reboot: WantedBy=timers.target"
else
    fail "reboot: WantedBy=timers.target"
fi

if [ -L "$WANTS_DIR/qmanager-scheduled-reboot.timer" ]; then
    pass "reboot: symlinked into timers.target.wants (not multi-user.target.wants)"
else
    fail "reboot: symlinked into timers.target.wants"
fi

# systemd 244 silently ignores directives from later releases, so a unit that
# looks right can still never fire. Pin the emitted key set.
ALLOWED="Description OnCalendar Unit Persistent WantedBy"
unknown=""
for k in $(sed -n 's/^\([A-Za-z][A-Za-z0-9]*\)=.*/\1/p' "$UNIT_FILE" | sort -u); do
    case " $ALLOWED " in
        *" $k "*) ;;
        *) unknown="$unknown $k" ;;
    esac
done
if [ -z "$unknown" ]; then
    pass "reboot: emits only directives that exist in systemd 244"
else
    fail "reboot: emits only directives that exist in systemd 244 — unknown:$unknown"
fi

# Auto-update has no day mask; it must render the every-day form, not a
# weekday list that happens to contain all seven.
run_helper "$SRC_UPDATE" install "03:15"
json_is armed true "auto-update: install reports armed=true"
if grep -qx 'OnCalendar=\*-\*-\* 03:15:00' "$UNIT_DIR/qmanager-auto-update.timer"; then
    pass "auto-update: renders the daily OnCalendar form"
else
    fail "auto-update: renders the daily OnCalendar form — got: $(grep OnCalendar "$UNIT_DIR/qmanager-auto-update.timer" 2>/dev/null)"
fi

# The tower pair: two units, two boundaries, one shared day mask.
run_helper "$SRC_TOWER" install "08:00" "22:00" "1,2,3,4,5"
json_is armed true "tower: install reports armed=true"
if grep -qx 'OnCalendar=Mon,Tue,Wed,Thu,Fri \*-\*-\* 08:00:00' \
        "$UNIT_DIR/qmanager-tower-schedule-apply.timer" \
   && grep -qx 'OnCalendar=Mon,Tue,Wed,Thu,Fri \*-\*-\* 22:00:00' \
        "$UNIT_DIR/qmanager-tower-schedule-clear.timer"; then
    pass "tower: apply and clear carry the two boundaries and the shared mask"
else
    fail "tower: apply and clear carry the two boundaries and the shared mask"
fi
if [ -L "$WANTS_DIR/qmanager-tower-schedule-apply.timer" ] \
   && [ -L "$WANTS_DIR/qmanager-tower-schedule-clear.timer" ]; then
    pass "tower: both halves symlinked"
else
    fail "tower: both halves symlinked"
fi

# ─── 4. arming twice is idempotent ──────────────────────────────────────────
echo
echo "-- idempotency --"
reset_fixture

run_helper "$SRC_REBOOT" install "04:30" "0,3,6"
FIRST=$(cat "$UNIT_DIR/qmanager-scheduled-reboot.timer")
FIRST_N=$(artefact_count)
run_helper "$SRC_REBOOT" install "04:30" "0,3,6"
json_is armed true "second identical arm still reports armed=true"
SECOND=$(cat "$UNIT_DIR/qmanager-scheduled-reboot.timer")
SECOND_N=$(artefact_count)

if [ "$FIRST" = "$SECOND" ]; then
    pass "arming twice produces byte-identical unit content"
else
    fail "arming twice produces byte-identical unit content"
fi
if [ "$FIRST_N" = "$SECOND_N" ]; then
    pass "arming twice leaves the same artefact count ($FIRST_N), no accumulation"
else
    fail "arming twice leaves the same artefact count — $FIRST_N then $SECOND_N"
fi
# The atomic write stages a .tmp beside the target; a crash-free run must never
# leave one, or the next daemon-reload sees junk in the unit directory.
if artefacts | grep -q '\.tmp\.'; then
    fail "arming twice leaves no scratch files — found: $(artefacts | grep '\.tmp\.' | tr '\n' ' ')"
else
    pass "arming twice leaves no scratch files"
fi

# Re-arming with a DIFFERENT schedule must replace, not accumulate: a stale
# timer firing on the old schedule beside the new one is worse than either.
run_helper "$SRC_REBOOT" install "05:00" "1"
if grep -qx 'OnCalendar=Mon \*-\*-\* 05:00:00' "$UNIT_DIR/qmanager-scheduled-reboot.timer" \
   && [ "$(grep -c '^OnCalendar=' "$UNIT_DIR/qmanager-scheduled-reboot.timer")" = "1" ]; then
    pass "re-arming replaces the schedule rather than appending to it"
else
    fail "re-arming replaces the schedule rather than appending to it"
fi

# ─── 5. disarming ───────────────────────────────────────────────────────────
echo
echo "-- disarm --"
reset_fixture

# Never armed at all — the common case when a user saves a schedule that was
# already off.
run_helper "$SRC_REBOOT" teardown
[ "$HELPER_RC" -eq 0 ] && pass "teardown of a never-armed timer succeeds" \
    || fail "teardown of a never-armed timer succeeds — rc=$HELPER_RC out=$HELPER_OUT"
json_is success true  "teardown of a never-armed timer reports success=true"
json_is armed   false "teardown of a never-armed timer reports armed=false"
expect_clean "teardown of a never-armed timer leaves nothing"

run_helper "$SRC_TOWER" teardown
[ "$HELPER_RC" -eq 0 ] && pass "tower teardown of a never-armed pair succeeds" \
    || fail "tower teardown of a never-armed pair succeeds — rc=$HELPER_RC"
run_helper "$SRC_UPDATE" teardown
[ "$HELPER_RC" -eq 0 ] && pass "auto-update teardown of a never-armed timer succeeds" \
    || fail "auto-update teardown of a never-armed timer succeeds — rc=$HELPER_RC"

# Armed, then torn down — both the unit and its wants-symlink must go.
run_helper "$SRC_REBOOT" install "04:00" "0"
[ -f "$UNIT_DIR/qmanager-scheduled-reboot.timer" ] \
    && pass "disarm precondition: timer is armed" \
    || fail "disarm precondition: timer is armed"
run_helper "$SRC_REBOOT" teardown
json_is armed false "teardown after arming reports armed=false"
expect_clean "teardown removes both the unit and the wants-symlink"

# Teardown is idempotent too.
run_helper "$SRC_REBOOT" teardown
[ "$HELPER_RC" -eq 0 ] && pass "teardown twice in a row succeeds" \
    || fail "teardown twice in a row succeeds — rc=$HELPER_RC"

# Orphan cleanup: a device rolled back to a build predating this feature keeps
# the .timer while losing the .service. Teardown must still clean it, which is
# why it does not gate on the paired service existing.
run_helper "$SRC_TOWER" install "08:00" "22:00" "1"
rm -f "$UNIT_DIR/qmanager-tower-schedule-apply.service" \
      "$UNIT_DIR/qmanager-tower-schedule-clear.service"
run_helper "$SRC_TOWER" teardown
[ "$HELPER_RC" -eq 0 ] && pass "teardown cleans an orphaned timer whose .service is gone" \
    || fail "teardown cleans an orphaned timer whose .service is gone — rc=$HELPER_RC"
if [ -e "$UNIT_DIR/qmanager-tower-schedule-apply.timer" ] \
   || [ -e "$WANTS_DIR/qmanager-tower-schedule-apply.timer" ] \
   || [ -L "$WANTS_DIR/qmanager-tower-schedule-apply.timer" ]; then
    fail "orphaned timer actually removed"
else
    pass "orphaned timer actually removed"
fi

# ─── 6. honest reporting when the target unit is absent ─────────────────────
echo
echo "-- honest reporting --"
rm -rf "$UNIT_DIR"
mkdir -p "$UNIT_DIR"          # no .service stubs at all

run_helper "$SRC_REBOOT" install "04:00" "0"
json_is success true       "unit_absent: does not hard-error the caller"
json_is armed   false      "unit_absent: reports armed=false, not a false green"
json_is reason  unit_absent "unit_absent: names the reason"
expect_clean "unit_absent: arms nothing"

# Half a tower pair is not a schedule: an apply with no clear leaves the modem
# locked to one cell forever.
stage_services
rm -f "$UNIT_DIR/qmanager-tower-schedule-clear.service"
run_helper "$SRC_TOWER" install "08:00" "22:00" "1"
json_is armed false "tower: refuses to arm when only one half of the pair exists"
if [ -e "$UNIT_DIR/qmanager-tower-schedule-apply.timer" ]; then
    fail "tower: no half-armed pair left behind"
else
    pass "tower: no half-armed pair left behind"
fi

# ─── 7. the QM_TIMER_ROOT hook cannot escape ────────────────────────────────
echo
echo "-- test hook containment --"
reset_fixture

# A relative or traversing prefix must fall back to the real root rather than
# being honoured. Real root is not writable here, so the write fails — the
# point is that the value is not used as given.
OUT=$(QM_TIMER_ROOT="../../tmp/evil" sh "$SRC_REBOOT" install "04:00" "0" 2>/dev/null || true)
if [ -e "$TEST_DIR/../../tmp/evil" ]; then
    fail "QM_TIMER_ROOT rejects a traversing prefix"
else
    pass "QM_TIMER_ROOT rejects a traversing prefix"
fi
if printf '%s' "$OUT" | grep -q '"armed":true'; then
    fail "QM_TIMER_ROOT rejects a traversing prefix — helper reported armed against real /lib"
else
    pass "QM_TIMER_ROOT falls back to the real root, which is not writable here"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
