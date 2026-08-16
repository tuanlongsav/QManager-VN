#!/usr/bin/env bash
# Fixtures for cellular/apn.sh's parse_cgcontrdp — the WAN-profile endpoint's
# private +CGCONTRDP reader. Run from repo root:
#   bash scripts/test/apn-cgcontrdp-parser.sh
#
# apn.sh cannot be sourced (it is CGI: it sources /usr/lib libraries that only
# exist on the modem, then emits headers and runs a request at load time), so
# the function is extracted from the SHIPPED file with awk and sourced on its
# own — the same technique poller-data-used.sh and poller-phase-a.sh use. That
# keeps the fixtures pinned to the real code: edit apn.sh and this harness
# re-reads the edit.
#
# Contract under test — a 5-field TSV, sliced positionally by apn.sh's GET loop
# with `cut -f1..5`:
#   <v4addr>\t<v4gw>\t<dns1>\t<dns2>\t<v6addr>
#
# Three defects these fixtures pin down, all of which shipped in this fork:
#   1. Address family classified by `addr ~ /:/`. 3GPP hands back an IPv6
#      address as 16 dotted-decimal octets, so that test never fired and the
#      IPv6 record of a dual-stack context — emitted SECOND — fell through the
#      IPv4 branch and overwrote address, gateway and both DNS servers.
#   2. Fixed -F(") offsets $6/$8 for DNS. A quoted gateway shifts every later
#      field by two, so dns1 came back holding the GATEWAY and dns2 was lost.
#   3. DNS captured only inside the IPv4 branch, while the endpoint emits plain
#      dns1/dns2 — an IPv6-only attach reported no DNS at all.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
pass_count=0
fail_count=0

ok()      { printf '  PASS  %s\n' "$1"; pass_count=$((pass_count + 1)); }
bad()     { printf '  FAIL  %s\n' "$1"; fail_count=$((fail_count + 1)); fail=1; }
section() { printf '\n== %s ==\n' "$1"; }

APN_SH="$REPO_ROOT/scripts/www/cgi-bin/quecmanager/cellular/apn.sh"

section "harness self-check"
if [ -f "$APN_SH" ]; then
    ok "apn.sh found"
else
    bad "apn.sh missing at $APN_SH"
    printf '\n%s passed, %s failed\n' "$pass_count" "$fail_count"
    exit 1
fi

awk '/^parse_cgcontrdp\(\) \{/,/^\}/' "$APN_SH" > "$work/fn.sh"
# An empty or truncated extraction would make every assertion below vacuously
# "pass" against a function that does nothing, so prove the extraction first.
if grep -q 'CGCONTRDP' "$work/fn.sh" && [ "$(tail -n1 "$work/fn.sh")" = "}" ]; then
    ok "extracted parse_cgcontrdp() from apn.sh ($(wc -l < "$work/fn.sh" | tr -d ' ') lines)"
else
    bad "could not extract parse_cgcontrdp() from apn.sh — fixtures below would be vacuous"
    printf '\n%s passed, %s failed\n' "$pass_count" "$fail_count"
    exit 1
fi

# shellcheck disable=SC1090
. "$work/fn.sh"

# expect <label> <expected-pipe-joined> <raw-response>
# Compares the 5 TSV fields joined with '|' so an empty field is visible in the
# diff rather than collapsing into its neighbour.
expect() {
    local label="$1" want="$2" raw="$3" got
    got=$(parse_cgcontrdp "$raw" | tr '\t' '|')
    if [ "$got" = "$want" ]; then
        ok "$label"
    else
        bad "$label"
        printf '        want: %s\n        got:  %s\n' "$want" "$got"
    fi
}

# --- Fixture building blocks -------------------------------------------------
# IPv6 in +CGCONTRDP is 16 dotted-decimal octets, NOT colon-hex. These are the
# dotted form of 2001:db8:85a3::1 / ::2 and 2001:4860:4860::8888 / ::8844.
V6_ADDR='32.1.13.184.133.163.0.0.0.0.0.0.0.0.0.1'
V6_GW='32.1.13.184.133.163.0.0.0.0.0.0.0.0.0.2'
V6_DNS1='32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.136'
V6_DNS2='32.1.72.96.72.96.0.0.0.0.0.0.0.0.136.68'

# CID 1, bearer 5, IPv4, gateway BARE (empty field between two commas).
V4_BARE='+CGCONTRDP: 1,5,"internet","10.110.61.83",,"10.151.151.44","10.151.151.48"'
# Same context, same CID, gateway QUOTED — observed minutes apart on one modem.
V4_QUOTED='+CGCONTRDP: 1,5,"internet","10.110.61.83","10.110.61.84","10.151.151.44","10.151.151.48"'
V6_QUOTED="+CGCONTRDP: 1,6,\"internet\",\"$V6_ADDR\",\"$V6_GW\",\"$V6_DNS1\",\"$V6_DNS2\""
V6_BARE="+CGCONTRDP: 1,6,\"internet\",\"$V6_ADDR\",,\"$V6_DNS1\",\"$V6_DNS2\""

# ---------------------------------------------------------------------------
section "single-family contexts"

expect "IPv4-only, bare gateway" \
    '10.110.61.83||10.151.151.44|10.151.151.48|' \
    "$(printf '%s\nOK\n' "$V4_BARE")"

# Defect 2 in isolation: with fixed $6/$8 this returned dns1=10.110.61.84 (the
# GATEWAY) and dns2=10.151.151.44, and dropped the gateway itself.
expect "IPv4-only, quoted gateway does not shift DNS" \
    '10.110.61.83|10.110.61.84|10.151.151.44|10.151.151.48|' \
    "$(printf '%s\nOK\n' "$V4_QUOTED")"

# Defect 1 + 3: 16 octets must classify as IPv6, and DNS must still be reported
# even though no IPv4 record exists. The gateway stays IPv4-only on purpose —
# the endpoint emits that field as ipv4_gateway.
expect "IPv6-only reports its address and its DNS" \
    "||$V6_DNS1|$V6_DNS2|$V6_ADDR" \
    "$(printf '%s\nOK\n' "$V6_QUOTED")"

expect "IPv6-only, bare gateway" \
    "||$V6_DNS1|$V6_DNS2|$V6_ADDR" \
    "$(printf '%s\nOK\n' "$V6_BARE")"

# Colon-hex is kept as a fallback for firmwares that do emit it.
expect "IPv6 in colon-hex form still classifies as IPv6" \
    '||2001:4860:4860::8888|2001:4860:4860::8844|2001:db8:85a3::1' \
    "$(printf '+CGCONTRDP: 1,6,"internet","2001:db8:85a3::1","2001:db8:85a3::2","2001:4860:4860::8888","2001:4860:4860::8844"\nOK\n')"

# A gateway can also be bare but non-empty. Reading it out of the separator run
# is what keeps this case from being mistaken for a quoted gateway.
expect "IPv4, bare but non-empty gateway" \
    '10.110.61.83|10.110.61.84|10.151.151.44|10.151.151.48|' \
    "$(printf '+CGCONTRDP: 1,5,"internet","10.110.61.83",10.110.61.84,"10.151.151.44","10.151.151.48"\nOK\n')"

# Quoted gateway with dns2 omitted. This is exactly where counting quoted
# tokens fails: four tokens looks like the bare-gateway layout, so the gateway
# would be dropped and reported as dns1 instead.
expect "IPv4, quoted gateway, dns2 omitted" \
    '10.110.61.83|10.110.61.84|10.151.151.44||' \
    "$(printf '+CGCONTRDP: 1,5,"internet","10.110.61.83","10.110.61.84","10.151.151.44"\nOK\n')"

# ---------------------------------------------------------------------------
section "dual-stack — the overwrite case"

# THE regression. The IPv6 record arrives second; under the colon test it fell
# into the IPv4 branch and clobbered address, gateway and both DNS servers, so
# this returned the IPv6 address as ipv4_address and left field 5 empty — which
# is why status_ipv6 could never read "up".
expect "IPv4 record then IPv6 record — IPv6 must not clobber IPv4" \
    "10.110.61.83||10.151.151.44|10.151.151.48|$V6_ADDR" \
    "$(printf '%s\n%s\nOK\n' "$V4_BARE" "$V6_QUOTED")"

# Order is not guaranteed; first record of each family wins either way.
expect "IPv6 record then IPv4 record — IPv4 DNS still wins as first non-empty" \
    "10.110.61.83||$V6_DNS1|$V6_DNS2|$V6_ADDR" \
    "$(printf '%s\n%s\nOK\n' "$V6_QUOTED" "$V4_BARE")"

# ---------------------------------------------------------------------------
section "mixed gateway quoting on one CID"

# The reason offsets cannot be fixed: one CID emits a bare gateway on its IPv4
# record and a quoted one on its IPv6 record in the SAME response.
expect "bare gw (v4) + quoted gw (v6) in one response" \
    "10.110.61.83||10.151.151.44|10.151.151.48|$V6_ADDR" \
    "$(printf '%s\n%s\nOK\n' "$V4_BARE" "$V6_QUOTED")"

expect "quoted gw (v4) + bare gw (v6) in one response" \
    "10.110.61.83|10.110.61.84|10.151.151.44|10.151.151.48|$V6_ADDR" \
    "$(printf '%s\n%s\nOK\n' "$V4_QUOTED" "$V6_BARE")"

# ---------------------------------------------------------------------------
section "transport quirks"

# Some firmwares glue successive records with a bare CR instead of CRLF. Without
# the tr normalisation both records land on one awk line and the second is
# invisible — the dual-stack fix would then be untestable in the field.
expect "CR-glued records are split before parsing" \
    "10.110.61.83||10.151.151.44|10.151.151.48|$V6_ADDR" \
    "$(printf '%s\r%s\r\nOK\n' "$V4_BARE" "$V6_QUOTED")"

# apn.sh only calls this for a defined+active context, but qcmd returns an EMPTY
# body whenever any part of a compound response contains ERROR, and an inactive
# context returns a bare OK. Both must yield five empty fields, not a crash.
expect "empty input yields five empty fields" '||||' ""
expect "bare OK yields five empty fields" '||||' "$(printf 'OK\n')"

# ---------------------------------------------------------------------------
section "arity contract"

# apn.sh slices this output with cut -f1..5. A widened or reordered tuple would
# silently shift ipv4_gateway into dns1 for every profile row.
arity_ok=1
for fixture in "$V4_BARE" "$V4_QUOTED" "$V6_QUOTED" "" "$(printf '%s\n%s' "$V4_BARE" "$V6_QUOTED")"; do
    nf=$(parse_cgcontrdp "$fixture" | awk -F'\t' '{print NF; exit}')
    if [ "$nf" != "5" ]; then
        bad "parse_cgcontrdp emitted $nf fields, contract is 5"
        arity_ok=0
        break
    fi
done
if [ "$arity_ok" = "1" ]; then
    ok "every fixture emits exactly 5 tab-separated fields"
fi

# ---------------------------------------------------------------------------
section "sidecar path"

# The profile-name sidecar must not drift back to /usrdata/qmanager: that
# directory is created 0755 root:root by install_backend()'s bare `mkdir -p`,
# and this CGI runs as www-data, so every save there silently no-ops.
name_file=$(sed -n 's/^NAME_FILE="\([^"]*\)".*/\1/p' "$APN_SH" | head -n1)
case "$name_file" in
    /etc/qmanager/*) ok "NAME_FILE is under www-data-owned /etc/qmanager ($name_file)" ;;
    "")              bad "NAME_FILE assignment not found in apn.sh" ;;
    *)               bad "NAME_FILE is '$name_file' — must live under /etc/qmanager" ;;
esac

# The migration that moves fielded devices across has to exist and be wired
# into install_backend(), or an upgrade strands the user's saved names.
INSTALLER="$REPO_ROOT/scripts/install_rm520n.sh"
if grep -q '^migrate_apn_names() {' "$INSTALLER"; then
    ok "migrate_apn_names() defined in install_rm520n.sh"
else
    bad "migrate_apn_names() missing from install_rm520n.sh"
fi
if awk '/^install_backend\(\) \{/,/^\}/' "$INSTALLER" | grep -q '^ *migrate_apn_names$'; then
    ok "migrate_apn_names called from install_backend()"
else
    bad "migrate_apn_names is never called from install_backend()"
fi

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$pass_count" "$fail_count"
exit "$fail"
