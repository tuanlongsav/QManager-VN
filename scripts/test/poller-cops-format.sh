#!/bin/bash
# Regression fixtures for the operator-name format fix in the poller.
#
# Background: AT+COPS? reports the operator in whatever <format> the modem is
# currently holding. On a VN network the numeric form is the PLMN id ("45202"),
# which parse_carrier() copies verbatim into t2_carrier and the dashboard then
# renders as the operator name. The fix is at the AT layer: poll_tier2() issues
# AT+COPS=3,0 (mode 3 = set <format> only, no network action) to select the long
# alphanumeric name before it reads the operator.
#
# The format-set lives in its OWN qcmd call, ahead of the read chain, because
# qcmd collapses any compound response containing ERROR into an empty body — a
# write inside the read chain can therefore cost the whole Tier 2 cycle. Most of
# what this harness guards is that separation.
#
# These tests are static + fixture based; they need no modem.
#
# Run from the repo root:  bash scripts/test/poller-cops-format.sh
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

fail=0
pass_count=0
fail_count=0

ok()   { printf '  PASS  %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail_count=$((fail_count + 1)); fail=1; }

section() { printf '\n== %s ==\n' "$1"; }

poller_src="$REPO_ROOT/scripts/usr/bin/qmanager_poller"
parse_src="$REPO_ROOT/scripts/usr/lib/qmanager/parse_at.sh"

# poll_tier2() with comments stripped. Everything below reasons about executable
# lines only: the rationale comments in poll_tier2 quote the very command
# strings these guards search for, and matching prose would make them cry wolf.
t2_code=$(awk '/^poll_tier2\(\)/,/^\}/' "$poller_src" | grep -v '^[[:space:]]*#')

# =============================================================================
section "Tier 2 requests long alphanumeric operator format"
# =============================================================================

t2_read_ln=$(printf '%s\n' "$t2_code" | grep -n 'qcmd' | grep '+COPS?' | head -1 | cut -d: -f1)
t2_read_line=$(printf '%s\n' "$t2_code" | grep 'qcmd' | grep '+COPS?' | head -1)

if [ -n "$t2_read_line" ]; then
    ok "found the Tier 2 qcmd call containing +COPS?"
else
    bad "no Tier 2 qcmd call with +COPS? — did poll_tier2 move?"
fi

t2_set_ln=$(printf '%s\n' "$t2_code" | grep -n "qcmd 'AT+COPS=3,0'" | head -1 | cut -d: -f1)
t2_set_line=$(printf '%s\n' "$t2_code" | grep "qcmd 'AT+COPS=3,0'" | head -1)

if [ -n "$t2_set_line" ]; then
    ok "format 0 is set with AT+COPS=3,0 — mode 3 takes no network action"
else
    bad "no AT+COPS=3,0 in poll_tier2; operator will report as numeric PLMN"
fi

# The whole point of the split: the write must be its own qcmd invocation, not a
# segment of the read chain. qcmd maps ANY *ERROR* in a compound response to an
# empty body, so a write chained ahead of the reads lets one ERROR delete
# temperature, carrier, SIM slot, phone number and SIM status in one go.
if printf '%s\n' "$t2_read_line" | grep -q '+COPS=3,0'; then
    bad "+COPS=3,0 is chained into the +COPS? read — one ERROR would empty the whole Tier 2 cycle"
else
    ok "+COPS=3,0 is not chained into the read call"
fi

# Same rule generalised: no write of any kind belongs in the read chain. Every
# ';'-separated segment of the chain must be a query (bare or '?'), never an
# assignment.
chain_cmds=$(printf '%s\n' "$t2_read_line" | sed "s/^[^']*'//; s/'.*$//")
chain_writes=$(printf '%s\n' "$chain_cmds" | tr ';' '\n' | grep '=' || true)
if [ -n "$chain_writes" ]; then
    bad "read chain contains write command(s): $(printf '%s' "$chain_writes" | tr '\n' ' ')"
else
    ok "read chain is queries only ($chain_cmds)"
fi

# Order still matters — a format-set after the read only takes effect next pass.
if [ -n "$t2_set_ln" ] && [ -n "$t2_read_ln" ]; then
    if [ "$t2_set_ln" -lt "$t2_read_ln" ]; then
        ok "format-set is issued before the +COPS? read"
    else
        bad "+COPS=3,0 runs after the read — the read still uses the old format"
    fi
fi

# A failing format-set must NOT abort the read: reporting the operator as digits
# is far better than losing temperature, SIM slot, phone number and SIM status.
# Two ways that could regress — gating the read on '&&', or turning on 'set -e'.
if printf '%s\n' "$t2_set_line" | grep -q '&&'; then
    bad "format-set is joined with && — a failed write would skip the Tier 2 read"
else
    ok "format-set does not gate the read with &&"
fi

if grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*e' "$poller_src"; then
    bad "poller runs under 'set -e' — a failed format-set would abort the poll cycle"
else
    ok "poller does not run under 'set -e', so a failed format-set cannot abort the cycle"
fi

# The format must be re-asserted every Tier 2 pass, not set once at boot:
# AT+COPS=2/0 recovery paths elsewhere omit <format> and the setting is not
# guaranteed to survive them or a modem-side reset.
if awk '/^collect_boot_data\(\)/,/^\}/' "$poller_src" | grep -q '+COPS'; then
    # A +COPS read at boot is allowed, but only with its own format-set.
    boot_chain=$(awk '/^collect_boot_data\(\)/,/^\}/' "$poller_src" \
        | grep -v '^[[:space:]]*#' | grep 'qcmd' | grep '+COPS?' | head -1)
    if [ -z "$boot_chain" ]; then
        ok "boot chain mentions +COPS but issues no +COPS? read"
    elif awk '/^collect_boot_data\(\)/,/^\}/' "$poller_src" \
        | grep -v '^[[:space:]]*#' | grep -q "qcmd 'AT+COPS=3,0'"; then
        ok "boot +COPS? read carries its own format-set"
    else
        bad "collect_boot_data reads +COPS? without setting format 0"
    fi
else
    ok "collect_boot_data reads no operator, so it needs no format-set"
fi

# =============================================================================
section "deregister/re-register commands are untouched"
# =============================================================================

# AT+COPS=2 / AT+COPS=0 are network actions (detach / automatic re-attach) and
# belong to watchcat and the CGI layer. The poller must never issue them: a
# poll must not take the radio down.
poller_code=$(grep -v '^[[:space:]]*#' "$poller_src")

if printf '%s\n' "$poller_code" | grep -qE 'COPS=2([^,0-9]|$)'; then
    bad "poller issues AT+COPS=2 (deregister) — polling must not detach the radio"
else
    ok "poller issues no AT+COPS=2 (deregister)"
fi

if printf '%s\n' "$poller_code" | grep -qE 'COPS=0([^,0-9]|$)'; then
    bad "poller issues AT+COPS=0 (re-register) — polling must not re-attach the radio"
else
    ok "poller issues no AT+COPS=0 (re-register)"
fi

# =============================================================================
section "what parse_carrier can and cannot rescue"
# =============================================================================

if [ -f "$parse_src" ]; then
    ok "parse_at.sh found"
else
    bad "parse_at.sh missing at $parse_src"
fi

# parse_at.sh expects the poller's environment (unset load sentinel, qlog_*
# helpers), so every call runs in a subshell with `set +eu` and stubs — the
# same isolation pattern scripts/test/parse-at.sh uses.
carrier_of() {
    (
        set +eu
        qlog_warn() { :; }; qlog_info() { :; }
        qlog_debug() { :; }; qlog_error() { :; }
        # shellcheck source=/dev/null
        . "$parse_src"
        t2_carrier=""
        parse_carrier "$1"
        printf '%s' "$t2_carrier"
    )
}

# Long alphanumeric (format 0) — what the fixed chain now produces.
got=$(carrier_of '+COPS: 0,0,"VinaPhone",2
OK')
[ "$got" = "VinaPhone" ] \
    && ok "format 0 response yields the operator name" \
    || bad "format 0 response yielded '$got', expected 'VinaPhone'"

# Numeric (format 2) with a code no brand table can resolve — 999 is the
# reserved test-network MCC. This is the shape of the original bug and shows
# why the fix has to be at the AT layer: a lookup can only rescue codes it
# knows, so anything else reaches the dashboard as raw digits. (Whether known
# codes get decoded is parse_at.sh's business and is asserted by its own
# harness; asserting it here would just duplicate that coverage.)
got=$(carrier_of '+COPS: 0,2,"99901",2
OK')
[ "$got" = "99901" ] \
    && ok "unmappable numeric code reaches the UI as digits (why the AT-layer pin is the fix)" \
    || bad "unmappable numeric code yielded '$got', expected '99901'"

# Deregistered: "+COPS: 2" carries no operator field at all.
got=$(carrier_of '+COPS: 2
OK')
[ -z "$got" ] \
    && ok "deregistered response clears the carrier" \
    || bad "deregistered response left '$got'"

# =============================================================================
section "the read chain and its fixture stay in sync"
# =============================================================================

# This section used to replay a hand-written response block that already encoded
# the assumption under test — it could not fail. It is now driven from the chain
# string actually present in poll_tier2(): the list of expected response
# prefixes is DERIVED from the source, so adding, removing or renaming a command
# in the chain fails this test until the fixture and the parsing below are
# updated with it.
#
# What is still NOT asserted, and cannot be without a device: that the modem
# answers each command with exactly the line shape below. The fixture is a
# transcription of observed hardware output. Note the fix no longer depends on
# any claim about what AT+COPS=3,0 emits — it is a separate call whose output is
# discarded, so it cannot perturb this response block at all.

# Fixture lines, keyed by the response prefix they carry.
fixture_line() {
    case "$1" in
        '+QTEMP:')    printf '+QTEMP: "modem-tsens","-273"\n+QTEMP: "tsens-pa","46"\n+QTEMP: "modem-cpu","60"' ;;
        '+COPS:')     printf '+COPS: 0,0,"VinaPhone",2' ;;
        '+QUIMSLOT:') printf '+QUIMSLOT: 1' ;;
        '+CNUM:')     printf '+CNUM: "","+84912345678",145' ;;
        '+CPIN:')     printf '+CPIN: READY' ;;
        *)            return 1 ;;
    esac
}

# Command echo comes from the real chain, so the worst case for prefix greps
# (an echo line that contains every command name) is reproduced faithfully.
chain_response="AT${chain_cmds#AT}"
missing=""
for cmd in $(printf '%s\n' "$chain_cmds" | tr ';' ' '); do
    # "AT+QTEMP" -> "+QTEMP:", "+CPIN?" -> "+CPIN:"
    prefix="+${cmd#*+}"
    prefix="${prefix%\?}:"
    if line=$(fixture_line "$prefix"); then
        chain_response="${chain_response}
${line}"
    else
        missing="${missing} ${cmd}"
    fi
done
chain_response="${chain_response}
OK"

if [ -n "$missing" ]; then
    bad "read chain grew command(s)$missing with no fixture — add them to fixture_line() and assert them below"
else
    ok "every command in the read chain has a fixture response"
fi

result=$(
    set +eu
    qlog_warn() { :; }; qlog_info() { :; }
    qlog_debug() { :; }; qlog_error() { :; }
    # shellcheck source=/dev/null
    . "$parse_src"
    t2_temperature=""; t2_sim_slot=""; t2_sim_status=""; t2_carrier=""
    parse_temperature "$chain_response"
    parse_carrier "$chain_response"
    parse_sim_slot "$chain_response"
    # Verbatim from poll_tier2(): CNUM field 2 and the isolated CPIN line.
    num=$(printf '%s\n' "$chain_response" | grep '+CNUM:' | head -1 | cut -d',' -f2 | tr -d '"' | tr -d '\r')
    cpin_line=$(printf '%s\n' "$chain_response" | grep '+CPIN:' | head -1)
    parse_sim_status "$cpin_line"
    printf '%s|%s|%s|%s|%s' "$t2_temperature" "$t2_carrier" "$t2_sim_slot" "$num" "$t2_sim_status"
)

case "$result" in
    '53|VinaPhone|1|+84912345678|ready')
        ok "every section of the chain response still parses (temp/carrier/slot/number/SIM)"
        ;;
    *)
        bad "chain response mismatch: '$result' (expected '53|VinaPhone|1|+84912345678|ready')"
        ;;
esac

# The SIM-status path has no "infer sim_not_inserted from CME ERROR" fallback,
# and must not grow one back: qcmd returns an empty body on ERROR, so such a
# branch is unreachable from this caller and would only ever be re-added under
# the false belief that the poller can see the error text.
if printf '%s\n' "$t2_code" | grep -q 'CME ERROR'; then
    bad "poll_tier2 branches on 'CME ERROR' — unreachable, qcmd empties the body on any ERROR"
else
    ok "poll_tier2 has no unreachable 'CME ERROR' branch"
fi

# =============================================================================
printf '\n%s: %d passed, %d failed\n' "$(basename "$0")" "$pass_count" "$fail_count"
exit "$fail"
