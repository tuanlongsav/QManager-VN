#!/usr/bin/env bash
# Harness for the install/uninstall half of the crontab -> systemd-timer move:
#   scripts/install_rm520n.sh    scrub_legacy_cron(), unit_is_boot_enabled(),
#                                cleanup_legacy_timers(), TIMERS_WANTS_DIR
#   scripts/uninstall_rm520n.sh  disarm-before-delete ordering, cron scrub
#   scripts/usr/bin/qmanager_setup            the chmod 777 that is now gone
#   scripts/etc/systemd/system/qmanager-*.service   the four timer bodies
#
# Three user-facing schedules used to write /var/spool/cron/crontabs/root on a
# device that runs no crond: saved, reported success, never fired. They arm
# systemd timers now. The checks below guard the four ways that swap can go
# wrong on a real device, in the order they would hurt:
#
#   1. BOOT LOOP. enable_services() symlinks every installed qmanager-*.service
#      into multi-user.target.wants. One of the new units runs `reboot`. If it
#      is ever boot-enabled the device reboots on every boot, and the only thing
#      standing between here and there is that these four units declare no
#      [Install] section and that the installer reads that. Section 4 tests both
#      halves, including that the test itself is not vacuous.
#   2. THE HOLE OUTLIVING THE FEATURE. The sudoers `crontab` grant and the
#      world-writable spool directory existed only to serve the dead mechanism.
#      Sections 1-2 keep them from creeping back.
#   3. SOMEONE ELSE'S CRONTAB. The spool file was mode 0777 on every device that
#      ran the old builds, so it may hold lines QManager did not write. The
#      scrub is by marker, and section 5 plants a foreign line to prove it.
#   4. AN ARMED TIMER POINTING AT NOTHING. Roll back and the .service goes while
#      the .timer stays. Sections 6-7 cover the forward-update sweep and the
#      uninstaller's disarm-before-delete ordering.
#
# Shipped shell is executed, not reimplemented: the functions under test are
# extracted from the installer and eval'd against a fixture tree, with mount and
# systemctl stubbed to no-ops so nothing here can touch the dev machine.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

INSTALLER="scripts/install_rm520n.sh"
UNINSTALLER="scripts/uninstall_rm520n.sh"
SETUP="scripts/usr/bin/qmanager_setup"
SUDOERS="scripts/etc/sudoers.d/qmanager"
UNIT_SRC="scripts/etc/systemd/system"
LIB="scripts/usr/lib/qmanager/schedule_timer.sh"

# The four Type=oneshot bodies the generated timers start. Timer-triggered only:
# never boot-enabled, never shipped with an [Install] section.
TIMER_BODIES="qmanager-scheduled-reboot.service
qmanager-tower-schedule-apply.service
qmanager-tower-schedule-clear.service
qmanager-auto-update.service"

failures=0
pass() { printf '  OK   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$(( failures + 1 )); }

for f in "$INSTALLER" "$UNINSTALLER" "$SETUP" "$SUDOERS" "$LIB"; do
    if [ ! -f "$f" ]; then
        printf '  FAIL not found: %s\n' "$f"
        exit 1
    fi
done

# Read a FOO="bar" constant out of a shell script. First assignment wins.
const_of() {
    sed -n "s/^[[:space:]]*$2=\"\([^\"]*\)\".*/\1/p" "$1" | head -n1
}

# Mode as three or four octal digits, on GNU stat or BSD stat.
mode_of() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%OLp' "$1" 2>/dev/null
}

# Strip comment lines before grepping for a forbidden construct. Every rule
# below is *explained* in a comment that names the thing it forbids, so a
# comment-blind grep would fail on the documentation of its own rule.
code_of() { grep -vE '^[[:space:]]*#' "$1"; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

# =============================================================================
printf '\n-- 1. the two root grants that served the dead mechanism are gone --\n'
# =============================================================================

# `www-data ALL=(root) NOPASSWD: /usr/bin/crontab` — a bare command name in
# sudoers matches ANY arguments, so this let the web user rewrite root's crontab
# wholesale. It was the largest escalation surface in the file and it bought
# nothing, because nothing on this device ever ran the result.
if code_of "$SUDOERS" | grep -qE '(^|[[:space:]])/usr/bin/crontab([[:space:]]|$)'; then
    fail "sudoers still grants /usr/bin/crontab"
else
    pass "sudoers no longer grants /usr/bin/crontab"
fi

for h in qmanager_scheduled_reboot_arm qmanager_tower_schedule_arm qmanager_auto_update_arm; do
    if code_of "$SUDOERS" | grep -q "/usr/bin/$h"; then
        pass "sudoers grants $h"
    else
        fail "sudoers does not grant $h — the CGI cannot arm anything"
    fi
done

# `chmod 777 /var/spool/cron/crontabs`, re-applied on every boot. A
# world-writable root crontab directory is a root-scheduling path for any local
# user the moment something starts crond.
if code_of "$SETUP" | grep -qE 'chmod[[:space:]]+[0-7]*777[[:space:]]+/var/spool/cron'; then
    fail "qmanager_setup still chmods the cron spool world-writable"
else
    pass "qmanager_setup no longer widens the cron spool"
fi
if code_of "$SETUP" | grep -q '/var/spool/cron'; then
    fail "qmanager_setup still creates or touches /var/spool/cron"
else
    pass "qmanager_setup no longer touches /var/spool/cron at all"
fi

# =============================================================================
printf '\n-- 2. installer and uninstaller agree on where timers are wanted --\n'
# =============================================================================

# A .timer symlinked into multi-user.target.wants is not an error systemd
# reports — it is simply never pulled in. That failure is indistinguishable from
# the "saved, nothing happens" bug this whole change exists to fix, so the path
# gets its own constant in both scripts and the library, and they must agree.
INSTALL_TW=$(const_of "$INSTALLER" TIMERS_WANTS_DIR)
UNINSTALL_TW=$(const_of "$UNINSTALLER" TIMERS_WANTS_DIR)

if [ -z "$INSTALL_TW" ]; then
    fail "$INSTALLER defines no TIMERS_WANTS_DIR"
elif [ "$INSTALL_TW" != "/lib/systemd/system/timers.target.wants" ]; then
    fail "TIMERS_WANTS_DIR is '$INSTALL_TW', not the timers.target.wants path"
else
    pass "installer TIMERS_WANTS_DIR=$INSTALL_TW"
fi
if [ "$UNINSTALL_TW" != "$INSTALL_TW" ]; then
    fail "uninstaller TIMERS_WANTS_DIR='$UNINSTALL_TW' != installer '$INSTALL_TW'"
else
    pass "uninstaller agrees"
fi
# The library is what actually writes the symlink; the installer and uninstaller
# only clean up after it. If they disagree, the cleanup silently sweeps nothing.
if grep -q '_QM_WANTS_DIR="\$_QM_ROOT/lib/systemd/system/timers.target.wants"' "$LIB"; then
    pass "schedule_timer.sh links into the same directory"
else
    fail "schedule_timer.sh's _QM_WANTS_DIR no longer matches $INSTALL_TW"
fi

# =============================================================================
printf '\n-- 3. the four timer bodies exist and start what the helpers name --\n'
# =============================================================================

# Interface contract with the arm helpers: these exact unit names, these exact
# ExecStart lines. A mismatch is not a crash — the helper reports
# armed:false/unit_absent and the UI shows "not scheduled" forever.
check_body() {
    local unit="$1" want_exec="$2"
    local path="$UNIT_SRC/$unit"
    if [ ! -f "$path" ]; then
        fail "$unit is missing — its arm helper can never arm anything"
        return
    fi
    local got_exec
    got_exec=$(sed -n 's/^ExecStart=//p' "$path" | head -n1)
    if [ "$got_exec" = "$want_exec" ]; then
        pass "$unit starts $want_exec"
    else
        fail "$unit ExecStart is '$got_exec', expected '$want_exec'"
    fi
    if grep -q '^Type=oneshot' "$path"; then
        pass "$unit is Type=oneshot"
    else
        fail "$unit is not Type=oneshot"
    fi
    # RemainAfterExit=yes leaves the unit "active" after it exits, and systemd
    # will not start an already-active unit: the second and every later trigger
    # is discarded. A schedule that fires exactly once is a subtler version of
    # the bug being fixed. It matters most on the tower pair — a clear that
    # fires once leaves the modem locked to one cell indefinitely.
    if code_of "$path" | grep -q '^RemainAfterExit'; then
        fail "$unit sets RemainAfterExit — it would fire only once, ever"
    else
        pass "$unit does not set RemainAfterExit"
    fi
}

check_body qmanager-scheduled-reboot.service     "/usr/bin/qmanager_scheduled_reboot"
check_body qmanager-tower-schedule-apply.service "/usr/bin/qmanager_tower_schedule apply"
check_body qmanager-tower-schedule-clear.service "/usr/bin/qmanager_tower_schedule clear"
check_body qmanager-auto-update.service          "/usr/bin/qmanager_auto_update"

# Each helper hardcodes the pair it manages. Read those names back out and
# require the .service half to be a unit this tree actually ships.
for h in scripts/usr/bin/qmanager_scheduled_reboot_arm \
         scripts/usr/bin/qmanager_tower_schedule_arm \
         scripts/usr/bin/qmanager_auto_update_arm; do
    [ -f "$h" ] || { fail "arm helper missing: $h"; continue; }
    hname=$(basename "$h")
    named=$(sed -n 's/^SERVICE[A-Z_]*="\([^"]*\)".*/\1/p' "$h")
    if [ -z "$named" ]; then
        fail "$hname names no .service — cannot verify the pairing"
        continue
    fi
    for svc in $named; do
        if [ -f "$UNIT_SRC/$svc" ]; then
            pass "$hname pairs with shipped $svc"
        else
            fail "$hname pairs with $svc, which this tree does not ship"
        fi
    done
done

# =============================================================================
printf '\n-- 4. no timer body can be boot-enabled --\n'
# =============================================================================

eval "$(awk '/^unit_is_boot_enabled\(\) \{$/,/^\}$/' "$INSTALLER")"

if ! declare -f unit_is_boot_enabled >/dev/null; then
    fail "could not extract unit_is_boot_enabled() from $INSTALLER"
else
    # Self-test first. A gate that answered "no" to everything would pass every
    # boot-loop check below while silently disabling the whole product.
    printf '[Unit]\nDescription=x\n\n[Service]\nExecStart=/bin/true\n\n[Install]\nWantedBy=multi-user.target\n' \
        > "$FIX/with-install.service"
    printf '[Unit]\nDescription=x\n\n[Service]\nExecStart=/bin/true\n' \
        > "$FIX/without-install.service"
    if unit_is_boot_enabled "$FIX/with-install.service"; then
        pass "gate says yes to a unit with [Install]"
    else
        fail "gate says no to a unit WITH [Install] — every service would stop being enabled"
    fi
    if unit_is_boot_enabled "$FIX/without-install.service"; then
        fail "gate says yes to a unit without [Install] — the boot-loop guard is open"
    else
        pass "gate says no to a unit without [Install]"
    fi

    # Now every unit this tree actually ships.
    for unit in "$UNIT_SRC"/qmanager*.service; do
        [ -f "$unit" ] || continue
        uname_=$(basename "$unit")
        is_body=0
        for b in $TIMER_BODIES; do
            [ "$uname_" = "$b" ] && is_body=1
        done
        if [ "$is_body" = "1" ]; then
            if unit_is_boot_enabled "$unit"; then
                fail "$uname_ WOULD be boot-enabled — it is timer-triggered (reboot/lock/update on every boot)"
            else
                pass "$uname_ is not boot-enabled"
            fi
        else
            if unit_is_boot_enabled "$unit"; then
                pass "$uname_ is still boot-enabled"
            else
                fail "$uname_ lost its [Install] section — it will no longer start at boot"
            fi
        fi
    done
fi

# The gate is only worth anything if enable_services() consults it before
# linking. Check the call, not just the definition.
if awk '/^enable_services\(\) \{$/,/^\}$/' "$INSTALLER" | grep -q 'unit_is_boot_enabled'; then
    pass "enable_services() consults the gate"
else
    fail "enable_services() never calls unit_is_boot_enabled — the blanket glob is back"
fi

# =============================================================================
printf '\n-- 5. the legacy cron scrub is surgical --\n'
# =============================================================================

# Run the shipped function against a fixture spool. mount is stubbed because the
# real one is a remount of / — this harness runs on a developer's machine.
run_scrub() (
    set +e
    CRON_SPOOL_DIR="$1"
    CRON_SPOOL_FILE="$1/root"
    LEGACY_CRON_MARKERS=$(const_of "$INSTALLER" LEGACY_CRON_MARKERS)
    mount() { :; }
    info() { :; }
    warn() { printf 'WARN %s\n' "$*"; }
    _log_raw() { :; }
    eval "$(awk '/^scrub_legacy_cron\(\) \{$/,/^\}$/' "$INSTALLER")"
    scrub_legacy_cron
)

MARKERS=$(const_of "$INSTALLER" LEGACY_CRON_MARKERS)
if [ -z "$MARKERS" ]; then
    fail "installer defines no LEGACY_CRON_MARKERS — the scrub cannot be surgical"
else
    pass "markers: $MARKERS"
fi

# 5a — a spool holding our three lines and one that is not ours.
S1="$FIX/spool1"; mkdir -p "$S1"; chmod 0777 "$S1"
cat > "$S1/root" <<'EOF'
0 4 * * 0,3 /usr/bin/qmanager_scheduled_reboot  # qmanager_scheduled_reboot
15 2 * * * /usr/bin/qmanager_tower_schedule apply  # qmanager_tower_schedule
30 3 * * * /usr/bin/qmanager_auto_update # qmanager_auto_update
*/5 * * * * /usr/local/bin/backup.sh
EOF
run_scrub "$S1" >/dev/null 2>&1
if [ ! -f "$S1/root" ]; then
    fail "the whole crontab was deleted — a line QManager did not write was destroyed"
elif grep -q 'backup.sh' "$S1/root" && ! grep -q qmanager "$S1/root"; then
    pass "our three lines removed, the foreign line kept"
else
    printf '%s\n' "--- remaining ---" >&2; sed 's/^/       /' "$S1/root" >&2
    fail "scrub left the wrong lines behind"
fi
m=$(mode_of "$S1")
if [ "${m: -3}" = "700" ]; then
    pass "spool directory narrowed from 0777 to 0700"
else
    fail "spool directory is mode $m, still not 0700"
fi

# 5b — a spool holding nothing but ours. An empty file left behind would imply
# something is still scheduled; the file itself has to go.
S2="$FIX/spool2"; mkdir -p "$S2"
cat > "$S2/root" <<'EOF'
0 4 * * 1 /usr/bin/qmanager_scheduled_reboot  # qmanager_scheduled_reboot

EOF
run_scrub "$S2" >/dev/null 2>&1
if [ -e "$S2/root" ]; then
    fail "an empty root crontab was left behind"
else
    pass "a crontab that was entirely ours is removed"
fi

# 5c — nothing to scrub. The desired end state is that this file does not exist,
# so a fresh install must not conjure one.
S3="$FIX/spool3"; mkdir -p "$S3"
run_scrub "$S3" >/dev/null 2>&1
if [ -e "$S3/root" ]; then
    fail "the scrub created a crontab where there was none"
else
    pass "no crontab is created when there was none"
fi

# 5d — a spool with no QManager lines at all is left byte-for-byte alone.
S4="$FIX/spool4"; mkdir -p "$S4"
printf '*/5 * * * * /usr/local/bin/backup.sh\n0 0 * * * /opt/bin/rotate\n' > "$S4/root"
before=$(cat "$S4/root")
run_scrub "$S4" >/dev/null 2>&1
if [ "$(cat "$S4/root" 2>/dev/null)" = "$before" ]; then
    pass "a crontab with none of our markers is untouched"
else
    fail "a crontab with none of our markers was modified"
fi

# 5e — placement. qmanager_update always invokes the installer with
# --skip-packages, and may pass --frontend-only, so a scrub nested inside either
# gate would never reach the devices that actually carry the stale crontab.
main_body=$(awk '/^main\(\) \{$/,/^\}$/' "$INSTALLER")
scrub_line=$(printf '%s\n' "$main_body" | grep -n '^[[:space:]]*scrub_legacy_cron[[:space:]]*$' | cut -d: -f1 | head -n1)
pkg_line=$(printf '%s\n' "$main_body" | grep -n 'DO_PACKAGES" = "1" \] && install_dependencies' | cut -d: -f1 | head -n1)
backend_line=$(printf '%s\n' "$main_body" | grep -n 'if \[ "\$DO_BACKEND" = "1" \]; then' | cut -d: -f1 | head -n1)
if [ -z "$scrub_line" ]; then
    fail "main() never calls scrub_legacy_cron"
elif [ -n "$pkg_line" ] && [ "$scrub_line" -gt "$pkg_line" ]; then
    fail "scrub_legacy_cron runs after the DO_PACKAGES gate — OTA passes --skip-packages"
elif [ -n "$backend_line" ] && [ "$scrub_line" -gt "$backend_line" ]; then
    fail "scrub_legacy_cron runs inside the DO_BACKEND block"
else
    pass "scrub_legacy_cron runs unconditionally, before both gates"
fi

# =============================================================================
printf '\n-- 6. orphaned timers are swept, armed ones are not --\n'
# =============================================================================

# A .timer is generated from the user's own schedule and is NEVER in the source
# tree, so the "not in source, therefore legacy" rule the service sweep uses
# would delete every armed schedule on every update. The sweep keys on the
# pairing instead: a timer whose Unit= no longer ships is the rollback orphan.
run_timer_sweep() (
    set +e
    SYSTEMD_DIR="$1"
    TIMERS_WANTS_DIR="$1/timers.target.wants"
    SRC_SCRIPTS="$2"
    LEGACY_TIMERS_REMOVED=0
    systemctl() { :; }
    info() { :; }
    warn() { :; }
    _log_raw() { :; }
    eval "$(awk '/^cleanup_legacy_timers\(\) \{$/,/^\}$/' "$INSTALLER")"
    cleanup_legacy_timers
    printf '%s' "$LEGACY_TIMERS_REMOVED"
)

TS="$FIX/units"; TW="$TS/timers.target.wants"
mkdir -p "$TW" "$FIX/src/etc/systemd/system"

# Shipped pair — armed and must survive.
cp "$UNIT_SRC/qmanager-scheduled-reboot.service" "$FIX/src/etc/systemd/system/"
cp "$UNIT_SRC/qmanager-scheduled-reboot.service" "$TS/"
printf '[Timer]\nOnCalendar=Mon *-*-* 04:00:00\nUnit=qmanager-scheduled-reboot.service\n' \
    > "$TS/qmanager-scheduled-reboot.timer"
ln -sf "$TS/qmanager-scheduled-reboot.timer" "$TW/qmanager-scheduled-reboot.timer"

# Orphan — the .service it names is not in the source tree (a rollback removed
# it), so systemd would fire this forever and log "unit not found".
printf '[Timer]\nOnCalendar=*-*-* 03:00:00\nUnit=qmanager-retired-thing.service\n' \
    > "$TS/qmanager-retired-thing.timer"
ln -sf "$TS/qmanager-retired-thing.timer" "$TW/qmanager-retired-thing.timer"

# Dangling symlink — the other half of the same story, and the half that
# survives if the .timer was removed by hand.
ln -sf "$TS/qmanager-vanished.timer" "$TW/qmanager-vanished.timer"

removed=$(run_timer_sweep "$TS" "$FIX/src")

if [ -f "$TS/qmanager-scheduled-reboot.timer" ] && [ -L "$TW/qmanager-scheduled-reboot.timer" ]; then
    pass "an armed timer whose service still ships is left alone"
else
    fail "the sweep deleted a live armed schedule"
fi
if [ ! -e "$TS/qmanager-retired-thing.timer" ] && [ ! -L "$TW/qmanager-retired-thing.timer" ]; then
    pass "an orphaned timer and its symlink are removed"
else
    fail "an orphaned timer survived the sweep"
fi
if [ ! -L "$TW/qmanager-vanished.timer" ]; then
    pass "a dangling wants-symlink is removed"
else
    fail "a dangling wants-symlink survived the sweep"
fi
if [ "$removed" = "2" ]; then
    pass "sweep counted 2 removals"
else
    fail "sweep counted '$removed' removals, expected 2"
fi

# The service sweep must keep globbing only .service. Widening it to .timer
# would delete every armed schedule on every update.
if awk '/^cleanup_legacy_scripts\(\) \{$/,/^\}$/' "$INSTALLER" \
    | grep -qE 'SYSTEMD_DIR"?/qmanager-\*\.timer'; then
    fail "cleanup_legacy_scripts globs .timer against the source tree — it would delete armed schedules"
else
    pass "the source-tree sweep still only globs .service"
fi

# =============================================================================
printf '\n-- 7. the uninstaller disarms before it deletes --\n'
# =============================================================================

# The arm helpers and the library they source are removed with /usr/bin and
# /usr/lib. Delete first and the shipped teardown path is gone, leaving systemd
# holding a counting-down unit aimed at a binary that no longer exists.
disarm_line=$(grep -n '_armer" teardown' "$UNINSTALLER" | cut -d: -f1 | head -n1)
unit_rm_line=$(grep -n 'rm -f "\$unit_file"' "$UNINSTALLER" | cut -d: -f1 | head -n1)
bin_rm_line=$(grep -n 'rm -f "\$BIN_DIR"/qmanager_\*' "$UNINSTALLER" | cut -d: -f1 | head -n1)
lib_rm_line=$(grep -n 'rm -rf "\$LIB_DIR"' "$UNINSTALLER" | cut -d: -f1 | head -n1)

if [ -z "$disarm_line" ]; then
    fail "uninstaller never calls the arm helpers' teardown"
else
    pass "uninstaller calls teardown on the arm helpers"
    for pair in "$bin_rm_line:the arm helpers" "$lib_rm_line:schedule_timer.sh" \
                "$unit_rm_line:the unit files"; do
        ln_=${pair%%:*}; what=${pair#*:}
        if [ -n "$ln_" ] && [ "$disarm_line" -lt "$ln_" ]; then
            pass "disarm runs before removing $what"
        else
            fail "disarm runs AFTER removing $what (line $disarm_line vs $ln_)"
        fi
    done
fi

# Backstop for a device whose helpers are already gone (partial install, or a
# rollback that removed them): the uninstaller must sweep the units itself.
if grep -q 'SYSTEMD_DIR"/qmanager-\*\.timer' "$UNINSTALLER"; then
    pass "uninstaller sweeps leftover .timer units directly"
else
    fail "uninstaller has no filesystem backstop for .timer units"
fi
if grep -q 'TIMERS_WANTS_DIR"/qmanager-\*\.timer' "$UNINSTALLER"; then
    pass "uninstaller sweeps leftover timers.target.wants symlinks"
else
    fail "uninstaller leaves timers.target.wants symlinks behind"
fi

# The uninstaller must not depend on the crontab binary it no longer grants.
if code_of "$UNINSTALLER" | grep -qE '(^|[^_[:alnum:]])crontab[[:space:]]+(-l|-)([[:space:]]|$)'; then
    fail "uninstaller still shells out to the crontab binary"
else
    pass "uninstaller edits the spool file directly"
fi

printf '\n'
if [ "$failures" -gt 0 ]; then
    printf '[installer-schedule-timers] FAIL: %d check(s) failed\n\n' "$failures" >&2
    exit 1
fi
printf '[installer-schedule-timers] PASS\n\n'
