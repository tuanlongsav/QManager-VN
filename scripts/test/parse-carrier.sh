#!/usr/bin/env bash
# Workstation fixtures for the +COPS operator-name path in parse_at.sh:
# carrier_name_from_code() and the numeric fallback inside parse_carrier().
# Run from repo root: bash scripts/test/parse-carrier.sh
#
# Same shape as scripts/test/parse-at.sh — each case sources parse_at.sh in a
# subshell with the qlog_* functions stubbed out, calls the parser with fixture
# AT output, and asserts on the resulting global. No jq needed here.
#
# What is under test is a safety net, not the primary fix: the poller asks for
# AT+COPS=3,0 so the modem reports a long alphanumeric name, and these cases
# cover what parse_carrier does on the reads where that has not taken effect.
# Most of the assertions below are therefore about what the lookup REFUSES to
# name. That is the point — an unrecognised PLMN reaching the dashboard as bare
# digits is the honest outcome, and a wrong brand name is the one failure the
# user has no way to detect.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail=0
pass_count=0
fail_count=0

ok()   { printf '  PASS  %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail_count=$((fail_count + 1)); fail=1; }
section() { printf '\n== %s ==\n' "$1"; }

PARSE_AT="$REPO_ROOT/scripts/usr/lib/qmanager/parse_at.sh"

section "harness self-check"
if [ -f "$PARSE_AT" ]; then
    ok "parse_at.sh found"
else
    bad "parse_at.sh missing at $PARSE_AT"
    printf '\n%d passed, %d failed, FAILURES\n' "$pass_count" "$fail_count"
    exit 1
fi

# Runs parse_carrier against one fixture and echoes the resulting t2_carrier.
run_parse_carrier() {
    (
        set +eu
        qlog_warn() { :; }
        qlog_info() { :; }
        qlog_debug() { :; }
        qlog_error() { :; }
        . "$PARSE_AT"
        parse_carrier "$1"
        printf '%s' "$t2_carrier"
    )
}

# Calls the lookup directly and echoes whatever it puts on stdout.
run_lookup() {
    (
        set +eu
        qlog_warn() { :; }
        qlog_info() { :; }
        qlog_debug() { :; }
        qlog_error() { :; }
        . "$PARSE_AT"
        carrier_name_from_code "$1"
    )
}

expect() {
    local label="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        ok "$label"
    else
        bad "$label: got '$got', expected '$want'"
    fi
}

# ---------------------------------------------------------------------------
section "carrier_name_from_code — the four networks that own radio"

expect "45201 decodes to MobiFone"         "$(run_lookup 45201)"  "MobiFone"
expect "45202 decodes to VinaPhone"        "$(run_lookup 45202)"  "VinaPhone"
expect "45204 decodes to Viettel"          "$(run_lookup 45204)"  "Viettel"
expect "45205 decodes to Vietnamobile"     "$(run_lookup 45205)"  "Vietnamobile"

# ---------------------------------------------------------------------------
section "carrier_name_from_code — everything else must refuse to answer"

# Withdrawn MNCs. No cell broadcasts these, and a withdrawn code is the one
# that can be reassigned, so a name here could only ever be a lie.
expect "withdrawn 45203 (S-Fone) echoes nothing"     "$(run_lookup 45203)" ""
expect "withdrawn 45206 (EVNTelecom) echoes nothing" "$(run_lookup 45206)" ""

# MVNOs own no radio, so +COPS reports their host's PLMN, not theirs. Naming
# them from a registered PLMN would answer a question nobody asked.
expect "MVNO 45207 (Gmobile) echoes nothing"    "$(run_lookup 45207)" ""
expect "MVNO 45208 (I-Telecom) echoes nothing"  "$(run_lookup 45208)" ""
expect "MVNO 45209 (Wintel) echoes nothing"     "$(run_lookup 45209)" ""

# Six-digit forms decode a 3-digit MNC. Per 3GPP TS 23.003 a 2-digit MNC is
# never zero-padded, so 452002 is MNC 002 — a PLMN that does not exist — and
# must not be treated as a spelling of 452-02.
expect "452002 is not VinaPhone"   "$(run_lookup 452002)" ""
expect "452004 is not Viettel"     "$(run_lookup 452004)" ""

expect "unknown VN MNC echoes nothing"     "$(run_lookup 45299)"  ""
expect "foreign code echoes nothing"       "$(run_lookup 51503)"  ""
expect "empty argument echoes nothing"     "$(run_lookup '')"     ""

# ---------------------------------------------------------------------------
section "parse_carrier — numeric fallback"

# The exact line the RM520N-GLAA returns when +COPS is left in numeric format
# (format field = 2), which is what put "45202" on the dashboard.
sample=$'+COPS: 0,2,"45202",2\nOK'
expect "numeric 45202 becomes VinaPhone" "$(run_parse_carrier "$sample")" "VinaPhone"

# Unknown code: showing the raw number is honest, inventing a name is not.
sample=$'+COPS: 0,2,"45299",2\nOK'
expect "unknown 45299 passes through as digits" "$(run_parse_carrier "$sample")" "45299"

# An MVNO's own PLMN would reach us only over a shared RAN. We do not name it,
# so it must survive as digits rather than acquire a brand.
sample=$'+COPS: 0,2,"45208",2\nOK'
expect "MVNO 45208 passes through as digits" "$(run_parse_carrier "$sample")" "45208"

# A 6-digit code must reach the dashboard untouched, not be folded onto a
# 2-digit row it has nothing to do with.
sample=$'+COPS: 0,2,"452002",2\nOK'
expect "6-digit 452002 passes through as digits" "$(run_parse_carrier "$sample")" "452002"

# Genuine 3-digit MNC (T-Mobile US, 310-260) — proves the pass-through is not
# VN-specific and that we never truncate a long code.
sample=$'+COPS: 0,2,"310260",7\nOK'
expect "genuine 3-digit MNC 310260 passes through" "$(run_parse_carrier "$sample")" "310260"

# A foreign network we have no table for must survive intact too.
sample=$'+COPS: 0,2,"51503",7\nOK'
expect "unknown foreign 51503 passes through as digits" "$(run_parse_carrier "$sample")" "51503"

# ---------------------------------------------------------------------------
section "parse_carrier — alphanumeric names are never rewritten"

sample=$'+COPS: 0,0,"VinaPhone",2\nOK'
expect "long name VinaPhone untouched" "$(run_parse_carrier "$sample")" "VinaPhone"

# Upstream fixture (Smart PH) — proves the fallback is VN-specific, not global.
sample=$'+COPS: 0,0,"Smart",7\nOK'
expect "long name Smart untouched" "$(run_parse_carrier "$sample")" "Smart"

# Names legitimately contain digits; the guard must key on "all digits", not
# "contains a digit", or "3 Ireland" would be handed to the lookup.
sample=$'+COPS: 0,0,"3 Ireland",2\nOK'
expect "name containing a digit untouched" "$(run_parse_carrier "$sample")" "3 Ireland"

# Short alphanumeric format (field 1) is still a name, not a code.
sample=$'+COPS: 0,1,"VNPT",2\nOK'
expect "short name VNPT untouched" "$(run_parse_carrier "$sample")" "VNPT"

# Regression: <oper> may contain commas. Splitting the line on commas used to
# hand back "Telecom Italia", silently dropping the rest of the name — and it
# did so before the numeric fallback ran, so it could mangle a code too.
sample=$'+COPS: 0,0,"Telecom Italia, S.p.A.",2\nOK'
expect "comma inside the name survives" \
    "$(run_parse_carrier "$sample")" "Telecom Italia, S.p.A."

# Same defect, worse shape: two commas plus a trailing AcT field.
sample=$'+COPS: 0,0,"AT&T, Inc., Mobility",7\nOK'
expect "two commas inside the name survive" \
    "$(run_parse_carrier "$sample")" "AT&T, Inc., Mobility"

# Some firmware omits the trailing <AcT>. The name must still come out whole.
sample=$'+COPS: 0,0,"Telecom Italia, S.p.A."\nOK'
expect "comma in name survives with no AcT field" \
    "$(run_parse_carrier "$sample")" "Telecom Italia, S.p.A."

# Leading whitespace before the prefix is tolerated by some firmware.
sample=$'  +COPS: 0,0,"VinaPhone",2\nOK'
expect "leading whitespace before +COPS tolerated" \
    "$(run_parse_carrier "$sample")" "VinaPhone"

# ---------------------------------------------------------------------------
section "parse_carrier — empty stays empty"

# Deregistered: mode only, no operator field at all.
sample=$'+COPS: 2\nOK'
expect "deregistered +COPS: 2 yields empty" "$(run_parse_carrier "$sample")" ""

# No +COPS line in the response at all (compound AT aborted early).
sample=$'+QTEMP: "modem-tsens","42"\nOK'
expect "missing +COPS line yields empty" "$(run_parse_carrier "$sample")" ""

# Present but with an empty operator field.
sample=$'+COPS: 0,2,"",2\nOK'
expect "empty operator field yields empty" "$(run_parse_carrier "$sample")" ""

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed' "$pass_count" "$fail_count"
if [ "$fail" -eq 0 ]; then
    printf ', ALL PASS\n'
    exit 0
else
    printf ', FAILURES\n'
    exit 1
fi
