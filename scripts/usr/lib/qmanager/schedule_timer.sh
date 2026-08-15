#!/bin/sh
# =============================================================================
# schedule_timer.sh — generate, arm and disarm QManager's scheduled systemd
#                     timers, and gate every value that reaches a unit file
# =============================================================================
# WHY THIS EXISTS
#
# RM520N-GL ships /usr/sbin/crond but nothing ever runs it: there is no crond
# unit, `systemctl is-active crond` reports inactive, and
# /var/spool/cron/crontabs is empty. Three user-facing features used to
# printf a cron line into that directory and report success. Nothing read it,
# so the schedule never fired — a feature that lied. systemd's own timer
# units are the mechanism that actually works on this device, and this library
# is the one place that knows how to build one.
#
# WHAT IT IS
#
# A `.timer` unit is systemd's cron replacement: a small file whose
# `OnCalendar=` line says *when*, and whose `Unit=` line says *what* to start.
# The "what" is a paired `.service` (Type=oneshot) shipped by the installer;
# only the `.timer` is generated here, because only the *when* depends on
# user input.
#
# WHO MAY SOURCE IT
#
# Root arm-helpers under /usr/bin only — never a CGI script directly. Those
# helpers are sudo-reachable from www-data, so every schedule value crossing
# into this file arrived from an HTTP request.
#
# THE INJECTION THREAT, AND WHY THE GATES ARE WHERE THEY ARE
#
# systemd unit files are newline-delimited `Key=Value`. One smuggled newline
# inside an "HH:MM" turns a schedule field into a second directive — and
# `ExecStart=` in a unit root starts is arbitrary code as root. Escaping is
# not attempted anywhere here. Instead there are TWO independent gates:
#
#   1. Entry gates — _qm_validate_hhmm / _qm_validate_days, called by each
#      helper before rendering. Charset-reject FIRST (a `case` bracket
#      negation matches across the *whole* string, unlike an anchored
#      `grep -E '^...$'` which is line-based and would happily pass a
#      two-line value whose first line looks legal), then shape-check.
#
#   2. A write gate — _qm_timer_write re-checks the rendered OnCalendar line
#      against an allowlist that does not contain a newline, and refuses to
#      write at all if it fails. This is what makes a rejected value
#      *structurally* unable to reach the file: a caller that forgets gate 1
#      still cannot produce a multi-line unit body. Gate 2 is not redundant
#      belt-and-braces, it is the invariant the harness pins.
#
# SYSTEMD 244 DIRECTIVE AUDIT
#
# This device runs systemd 244, and a directive from a later release is
# *silently ignored* — which would produce a timer that never fires, i.e. the
# exact bug being fixed. Every directive emitted below predates 244 by years:
#   [Unit]    Description=   v1
#   [Timer]   OnCalendar=    v197
#             Unit=          v197
#             Persistent=    v212
#   [Install] WantedBy=      v1
# Nothing newer is used. AccuracySec= is deliberately left at its 1-minute
# default: cron had no finer granularity either, so the default preserves the
# behaviour these timers replace instead of inventing a new one.
#
# Persistent=false IS LOAD-BEARING, NOT A COPIED DEFAULT
#
# Persistent=true makes systemd catch up a window missed while powered off,
# using a stamp file under /var/lib/systemd/timers/. On this device /var/lib
# is tmpfs — wiped every boot — so systemd would find no stamp on *every*
# boot and conclude the window was always missed. That is not "might loop":
# for the reboot timer it is a guaranteed boot loop. It is also behavioural
# parity, since crond never caught up missed runs either.
#
# TEST HOOK
#
# QM_TIMER_ROOT prefixes every path this library touches, so scripts/test/
# can exercise the shipped logic against a fixture tree. It is unreachable
# from the web path: sudoers defaults to env_reset, which strips it before
# the helper starts. Even if it survived, it only redirects *where* root
# writes a unit whose *content* is still gated above — it cannot inject.
# It is validated as absolute and free of ".." regardless.
# =============================================================================

[ -n "$_SCHEDULE_TIMER_LOADED" ] && return 0
_SCHEDULE_TIMER_LOADED=1

_QM_ROOT="${QM_TIMER_ROOT:-}"
case "$_QM_ROOT" in
    '') ;;
    *..*) _QM_ROOT="" ;;
    /*) ;;
    *) _QM_ROOT="" ;;
esac

# Unit files persist under /lib, matching every other persistence decision on
# this device: `systemctl enable` writes into /etc here while the units live
# in /lib, so the installer and svc_enable() both symlink into /lib by hand.
# Timers get the same treatment — but into timers.target.wants, NOT the
# multi-user.target.wants that services use. A timer symlinked into
# multi-user.target.wants is not wrong so much as unreachable.
_QM_UNIT_DIR="$_QM_ROOT/lib/systemd/system"
_QM_WANTS_DIR="$_QM_ROOT/lib/systemd/system/timers.target.wants"

# --- input gates ------------------------------------------------------------

# _qm_validate_hhmm <value> -> 0 valid / 1 reject
#
# Gate 1a rejects any byte outside [0-9:] anywhere in the value — whitespace,
# shell metacharacters and, critically, a newline. Gate 1b then pins the
# shape, with the hour range clamped to a REAL 00-23. The looser [0-2][0-9]
# spelling used elsewhere in this tree accepts "25:00" and "29:59"; systemd
# rejects those as a calendar parse error, which loads the unit as `failed`
# and fires nothing — silently, unless someone happens to run
# `systemctl list-timers`. An out-of-range hour must be a loud 400, not a
# quiet dead timer.
_qm_validate_hhmm() {
    case "$1" in
        ''|*[!0-9:]*) return 1 ;;
    esac
    case "$1" in
        [01][0-9]:[0-5][0-9]) return 0 ;;
        2[0-3]:[0-5][0-9])    return 0 ;;
        *) return 1 ;;
    esac
}

# _qm_validate_days <csv> -> 0 valid / 1 reject
#
# Same two-gate treatment for a cron-style day mask (0=Sun .. 6=Sat), plus a
# separator check: a leading, trailing or doubled comma is rejected rather
# than silently collapsing to a shorter list, so the days that end up in the
# unit are exactly the days the caller sent.
_qm_validate_days() {
    case "$1" in
        ''|*[!0-9,]*) return 1 ;;
    esac
    case "$1" in
        ,*|*,|*,,*) return 1 ;;
    esac
    for _qm_d in $(printf '%s' "$1" | tr ',' ' '); do
        case "$_qm_d" in
            0|1|2|3|4|5|6) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# --- OnCalendar rendering ---------------------------------------------------

# _qm_oncalendar_weekly <days_csv> <HH:MM>
# Prints a single "OnCalendar=Mon,Wed *-*-* HH:MM:00" line, or nothing when
# the day list resolves to zero days (callers treat empty as "no schedule"
# and tear down, rather than arming a unit with an empty OnCalendar= that
# systemd would reject).
#
# The numeric-to-name mapping is the whole reason this is not a string
# substitution: cron counts weekdays 0-6 with 0=Sunday, while systemd wants
# English abbreviations. Getting it wrong does not crash anything — it arms
# the schedule on the wrong day, a bug indistinguishable from "nothing
# happened" without inspecting `systemctl list-timers`. Hence a hardcoded
# case table, and hence the harness asserting the mapping directly.
#
# The date field is written out in full (`*-*-*`) rather than omitted.
# systemd does accept the short "Mon 04:00:00" form, but the explicit form
# leaves no room for a parser subtlety on this specific 244 build to turn
# into a timer that loads clean and never fires.
_qm_oncalendar_weekly() {
    _qm_days="$1"
    _qm_time="$2"
    _qm_names=""
    for _qm_d in $(printf '%s' "$_qm_days" | tr ',' ' '); do
        _qm_n=""
        case "$_qm_d" in
            0) _qm_n="Sun" ;;
            1) _qm_n="Mon" ;;
            2) _qm_n="Tue" ;;
            3) _qm_n="Wed" ;;
            4) _qm_n="Thu" ;;
            5) _qm_n="Fri" ;;
            6) _qm_n="Sat" ;;
        esac
        [ -z "$_qm_n" ] && continue
        case ",$_qm_names," in
            *",$_qm_n,"*) ;;
            *) _qm_names="${_qm_names:+$_qm_names,}$_qm_n" ;;
        esac
    done
    [ -z "$_qm_names" ] && return 0
    printf 'OnCalendar=%s *-*-* %s:00\n' "$_qm_names" "$_qm_time"
}

# _qm_oncalendar_daily <HH:MM>
# Every-day variant, for schedules that carry no day mask (auto-update).
_qm_oncalendar_daily() {
    printf 'OnCalendar=*-*-* %s:00\n' "$1"
}

# --- filesystem / systemd plumbing -----------------------------------------

# systemctl is skipped entirely under a test root: the fixture has no systemd
# and must never be able to poke the developer's own.
_qm_systemctl() {
    [ -n "$_QM_ROOT" ] && return 0
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl "$@" >/dev/null 2>&1 || true
    return 0
}

# The rootfs is UBIFS, read-only on a stock boot; qmanager_setup remounts it
# rw at every boot but this must not depend on that having happened. No-op if
# already rw, and never attempted under a test root.
_qm_ensure_rw() {
    [ -n "$_QM_ROOT" ] && return 0
    mount -o remount,rw / 2>/dev/null || true
    return 0
}

# _qm_service_present <name.service> -> 0 present / 1 absent
_qm_service_present() {
    [ -f "$_QM_UNIT_DIR/$1" ]
}

# _qm_timer_state <name.timer> -> prints active | inactive | unknown
#
# "unknown" means the question could not be asked (test root, or no
# systemctl), and callers must not read it as failure. "inactive" means
# systemd was asked and said the timer is not counting down — the one signal
# available on-box that distinguishes "unit written" from "unit will fire".
_qm_timer_state() {
    if [ -n "$_QM_ROOT" ] || ! command -v systemctl >/dev/null 2>&1; then
        printf 'unknown'
        return 0
    fi
    _qm_st=$(systemctl is-active "$1" 2>/dev/null)
    case "$_qm_st" in
        active) printf 'active' ;;
        '')     printf 'unknown' ;;
        *)      printf 'inactive' ;;
    esac
}

# _qm_timer_write <name.timer> <name.service> <description> <OnCalendar line>
# -> 0 written and symlinked / 1 refused or failed
#
# GATE 2 (see the header). The OnCalendar line is re-checked here, at the
# only place in the codebase that opens a unit file for writing, against an
# allowlist with no newline in it. A caller that skipped _qm_validate_* still
# cannot get a second directive into the file.
_qm_timer_write() {
    _qm_u="$1"
    _qm_s="$2"
    _qm_desc="$3"
    _qm_line="$4"

    case "$_qm_line" in
        'OnCalendar='*) ;;
        *) return 1 ;;
    esac
    # Allowlist: letters, digits, and exactly the punctuation a calendar spec
    # is built from — comma, dot, colon, asterisk, equals, space, hyphen
    # (hyphen last so it is literal, not a range). A newline is absent by
    # construction, and so is every shell metacharacter.
    #
    # The space and the parentheses below are written as quoted literals. Not
    # cosmetic: a `case` pattern is a WORD, so a bare space would end the
    # pattern and a bare `)` would end the clause — both are syntax errors, and
    # the tempting "fix" of dropping them from the class would silently start
    # rejecting every legitimate calendar line. Quoting keeps them literal
    # inside the bracket in bash, dash, ash and zsh alike.
    case "$_qm_line" in
        *[!A-Za-z0-9,.:*=" "-]*) return 1 ;;
    esac
    # The description is hardcoded by each helper, never user input — gated
    # anyway so that stays true if someone later wires it to a config value.
    case "$_qm_desc" in
        ''|*[!A-Za-z0-9"()".,/_" "-]*) return 1 ;;
    esac

    _qm_ensure_rw

    # Build beside the target and rename over it. rename(2) is atomic, so a
    # daemon-reload racing this write sees either the old unit or the new
    # one, never a half-written file that systemd would cache as broken.
    # "Beside" is load-bearing: rename is only atomic within one filesystem,
    # and /lib is UBIFS while /tmp is a separate tmpfs.
    _qm_tmp="$_QM_UNIT_DIR/.$_qm_u.tmp.$$"
    {
        printf '[Unit]\n'
        printf 'Description=%s\n' "$_qm_desc"
        printf '\n[Timer]\n'
        printf '%s\n' "$_qm_line"
        printf 'Unit=%s\n' "$_qm_s"
        printf 'Persistent=false\n'
        printf '\n[Install]\n'
        printf 'WantedBy=timers.target\n'
    } > "$_qm_tmp" 2>/dev/null

    if [ ! -s "$_qm_tmp" ]; then
        rm -f "$_qm_tmp" 2>/dev/null
        return 1
    fi

    mv -f "$_qm_tmp" "$_QM_UNIT_DIR/$_qm_u" 2>/dev/null || {
        rm -f "$_qm_tmp" 2>/dev/null
        return 1
    }
    mkdir -p "$_QM_WANTS_DIR" 2>/dev/null || return 1
    ln -sf "$_QM_UNIT_DIR/$_qm_u" "$_QM_WANTS_DIR/$_qm_u" 2>/dev/null || return 1
    [ -L "$_QM_WANTS_DIR/$_qm_u" ] || return 1
    return 0
}

# _qm_timer_disarm <name.timer> [name.timer ...] -> 0 gone / 1 still present
#
# Disarm has to be exactly as trustworthy as arm, and for the same reason: a
# teardown that reports success while the unit survives is the same class of
# lie as a save that reports success while nothing is scheduled. So this
# verifies absence afterwards instead of trusting `rm -f`, whose exit status
# says nothing useful when the write itself was refused by a read-only
# rootfs.
#
# Removing something that was never there is success, not an error — the
# caller disabling an already-disabled schedule is the common case, and it
# must not surface a failure.
#
# NOTE: this deliberately does not require the paired .service to exist. A
# device rolled back to a build that predates this feature keeps its .timer
# and its wants-symlink, orphaned and pointing at a unit that is gone; a
# teardown that bailed early on a missing .service could never clean that up.
_qm_timer_disarm() {
    _qm_rc=0

    _qm_need_rw=0
    for _qm_u in "$@"; do
        if [ -e "$_QM_UNIT_DIR/$_qm_u" ] \
            || [ -e "$_QM_WANTS_DIR/$_qm_u" ] || [ -L "$_QM_WANTS_DIR/$_qm_u" ]; then
            _qm_need_rw=1
        fi
    done
    [ "$_qm_need_rw" -eq 1 ] && _qm_ensure_rw

    for _qm_u in "$@"; do
        _qm_systemctl stop "$_qm_u"
        rm -f "$_QM_WANTS_DIR/$_qm_u" 2>/dev/null
        rm -f "$_QM_UNIT_DIR/$_qm_u" 2>/dev/null
    done

    sync 2>/dev/null || true
    _qm_systemctl daemon-reload

    for _qm_u in "$@"; do
        if [ -e "$_QM_UNIT_DIR/$_qm_u" ] \
            || [ -e "$_QM_WANTS_DIR/$_qm_u" ] || [ -L "$_QM_WANTS_DIR/$_qm_u" ]; then
            _qm_rc=1
        fi
    done
    return "$_qm_rc"
}

# _qm_timer_activate <name.timer> [name.timer ...]
# Reload systemd's view and start the timers for the CURRENT boot. The
# wants-symlink alone only takes effect at the next boot; a user who sets a
# 22:00 schedule at 21:00 expects it to fire tonight.
_qm_timer_activate() {
    sync 2>/dev/null || true
    _qm_systemctl daemon-reload
    for _qm_u in "$@"; do
        _qm_systemctl start "$_qm_u"
    done
    return 0
}

# --- response shape ---------------------------------------------------------
#
# One stable JSON shape for every outcome, success or failure, so a consumer
# can always read `.armed` without first branching on `.success`. `.armed` is
# the field that carries the truth this whole change exists to tell: false
# means nothing is scheduled, whatever else the response says.
#
# Every interpolated value is a fixed literal chosen by the helper, so none of
# them can contain a quote or backslash and break the JSON.

# _qm_emit_ok <armed true|false> <reason> <active>
_qm_emit_ok() {
    printf '{"success":true,"armed":%s,"reason":"%s","active":"%s"}\n' "$1" "$2" "$3"
}

# _qm_emit_err <error> <detail>
_qm_emit_err() {
    printf '{"success":false,"armed":false,"error":"%s","detail":"%s"}\n' "$1" "$2"
}
