#!/bin/sh
# Harness for the hostname apply path:
#   scripts/usr/bin/qmanager_set_hostname            (root helper)
#   sys_hostname_label() / sys_set_hostname() in
#   scripts/usr/lib/qmanager/system_config.sh
#
# The helper writes /etc/hostname and /proc/sys/kernel/hostname as root, which
# a test must not touch, so both files are copied into a fixture tree with
# those paths rewritten. What runs is the shipped logic — validation, atomic
# rename, trap cleanup, the sanitizer — not a reimplementation of it.
#
# The invariant this exists to protect: every label the sanitizer produces must
# be accepted by the helper's RFC 1123 check. If those two ever drift apart,
# the rename silently stops applying again — the exact bug this path was fixed
# for.
set -eu

# POSIX leaves `tr` range behaviour unspecified outside the C locale, and this
# harness feeds it non-ASCII on purpose. The device is unaffected — BusyBox tr
# is locale-blind — but a CI box running under a UTF-8 locale is not covered by
# the standard, so pin the locale rather than relying on it happening to agree.
LC_ALL=C
export LC_ALL

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_HELPER="$REPO_ROOT/scripts/usr/bin/qmanager_set_hostname"
SRC_LIB="$REPO_ROOT/scripts/usr/lib/qmanager/system_config.sh"

for f in "$SRC_HELPER" "$SRC_LIB"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: not found: $f" >&2
        exit 1
    fi
done

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/etc" "$TEST_DIR/lib"

ETC="$TEST_DIR/etc"
PROC="$TEST_DIR/proc_hostname"
HELPER="$TEST_DIR/qmanager_set_hostname"

# Redirect the two privileged write targets into the fixture, and neutralise
# the read-only-rootfs remount (the fixture is always writable, so that branch
# is never reached anyway — this only stops a stray `mount` if it ever were).
sed -e "s#/proc/sys/kernel/hostname#$PROC#g" \
    -e "s#mount -o remount,rw /#true#g" \
    -e "s#/etc/#$ETC/#g" \
    "$SRC_HELPER" > "$HELPER"
chmod +x "$HELPER"

# Stubs for the two libs system_config.sh sources by absolute path.
cat > "$TEST_DIR/lib/config.sh" <<'STUB'
qm_config_init() { :; }
qm_config_get()  { printf '%s' "${3:-}"; }
qm_config_set()  { printf '%s=%s\n' "$2" "$3" >> "$QM_TEST_CONFIG_LOG"; }
qlog_warn()      { printf 'warn: %s\n' "$*" >> "$QM_TEST_WARN_LOG"; }
STUB
cat > "$TEST_DIR/lib/platform.sh" <<'STUB'
_SUDO=""
STUB

LIB="$TEST_DIR/system_config.sh"
sed -e "s#/usr/lib/qmanager/#$TEST_DIR/lib/#g" \
    -e "s#/usr/bin/qmanager_set_hostname#$HELPER#g" \
    "$SRC_LIB" > "$LIB"

QM_TEST_CONFIG_LOG="$TEST_DIR/config.log"
QM_TEST_WARN_LOG="$TEST_DIR/warn.log"
export QM_TEST_CONFIG_LOG QM_TEST_WARN_LOG
: > "$QM_TEST_CONFIG_LOG"
: > "$QM_TEST_WARN_LOG"

# system_config.sh guards against double-sourcing with `[ -n "$_SYSTEM_CONFIG_LOADED" ]`,
# which is an unbound read the first time round. That is fine in the CGI, which
# does not run under `set -u`, but it would abort this harness — so pre-declare
# it rather than relaxing -u for the whole file.
_SYSTEM_CONFIG_LOADED=""
# shellcheck disable=SC1090
. "$LIB"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1" >&2; }

run_helper() {
    # Never quote-splat "$@" through a subshell that would eat the exit code;
    # capture output and status separately.
    HELPER_OUT=$(sh "$HELPER" "$@" 2>/dev/null) && HELPER_RC=0 || HELPER_RC=$?
}

# The trap must remove both the probe and the temp hostname file on every exit
# path, success or failure. Matching is by shape, not by name: the helper
# suffixes its scratch paths with $$, so their names are not knowable from here
# — and this check previously spelled out the two pre-$$ literals, which meant
# that from the moment the suffix was added no path it tested could exist any
# more. It went vacuously true and kept 13 assertions green while checking
# nothing, which is worse than a red suite because it hides the next leak.
#
# The discriminator that survives a rename: every scratch path these helpers
# use is a dotfile, while everything they legitimately install is not
# (hostname here, localtime/TZ in the timezone helper). So the invariant is
# simply "no dotfile survives in /etc", and it keeps holding if the scratch
# names change again.
#
# Two shell quirks the loop below has to absorb, because this harness runs
# under whatever bash the dev box has and the same logic has to hold for
# BusyBox ash on the device:
#   - `.` and `..`. Bash 5.2 enables `globskipdots` by default and omits them;
#     older bash and BusyBox ash both return them. Skip them explicitly.
#   - An unmatched glob stays literal in POSIX sh, so with globskipdots and a
#     clean /etc the loop sees the pattern itself and nothing else — hence the
#     existence test, without which every run would report `.*` as debris.
# `-L` alongside `-e` because `-e` is false on a *broken* symlink, and a
# symlink whose target went away is exactly the debris a half-finished rename
# leaves behind (the timezone helper stages one).
debris_free() {
    debris_found=""
    for debris_item in "$ETC"/.*; do
        case "${debris_item##*/}" in
            .|..) continue ;;
        esac
        if [ -e "$debris_item" ] || [ -L "$debris_item" ]; then
            debris_found="$debris_found ${debris_item##*/}"
        fi
    done
    [ -z "$debris_found" ]
}

json_field() {
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "$HELPER_OUT" | jq -r "$1"
    else
        printf 'SKIP'
    fi
}

# ─── Valid names are applied to both targets ────────────────────────────────
run_helper "RM520N-GL"
if [ "$HELPER_RC" -eq 0 ]; then
    pass "valid hostname accepted"
else
    fail "valid hostname accepted — rc=$HELPER_RC out=$HELPER_OUT"
fi

if [ "$(cat "$ETC/hostname")" = "RM520N-GL" ]; then
    pass "/etc/hostname written"
else
    fail "/etc/hostname written — got: $(cat "$ETC/hostname" 2>/dev/null)"
fi

# The kernel stores the value verbatim, so the /proc write must carry no
# trailing newline while /etc/hostname (a text file) must have one.
if [ "$(wc -c < "$PROC" | tr -d ' ')" = "9" ]; then
    pass "/proc write has no trailing newline"
else
    fail "/proc write has no trailing newline — got $(wc -c < "$PROC") bytes"
fi

if [ "$(wc -c < "$ETC/hostname" | tr -d ' ')" = "10" ]; then
    pass "/etc/hostname ends with a newline"
else
    fail "/etc/hostname ends with a newline — got $(wc -c < "$ETC/hostname") bytes"
fi

if debris_free; then
    pass "no temp files left after success"
else
    fail "no temp files left after success — left behind:$debris_found"
fi

f=$(json_field '.success')
if [ "$f" = "true" ] || [ "$f" = "SKIP" ]; then
    pass "success JSON reports success:true"
else
    fail "success JSON reports success:true — got: $HELPER_OUT"
fi

# RFC 1123 relaxed RFC 952 to permit a leading digit.
run_helper "5g-modem"
if [ "$HELPER_RC" -eq 0 ]; then
    pass "leading digit accepted (RFC 1123)"
else
    fail "leading digit accepted (RFC 1123) — rc=$HELPER_RC"
fi

# Exactly 63 characters is the RFC 1123 label limit — the boundary must be
# inclusive, not off by one.
NAME63=$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 \
    22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 \
    46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63)
run_helper "$NAME63"
if [ "$HELPER_RC" -eq 0 ]; then
    pass "63-character hostname accepted"
else
    fail "63-character hostname accepted — rc=$HELPER_RC out=$HELPER_OUT"
fi

# ─── Rejections ─────────────────────────────────────────────────────────────
# Record what /etc/hostname holds so we can prove a rejected call never
# disturbs the value already in place.
PREV=$(cat "$ETC/hostname")

reject_case() {
    desc="$1"; expect="$2"; shift 2
    run_helper "$@"
    if [ "$HELPER_RC" -ne 0 ]; then
        pass "rejected: $desc"
    else
        fail "rejected: $desc — helper returned 0 (out=$HELPER_OUT)"
    fi
    got=$(json_field '.error')
    if [ "$got" = "$expect" ] || [ "$got" = "SKIP" ]; then
        pass "rejected: $desc → error=$expect"
    else
        fail "rejected: $desc → error=$expect — got: $got"
    fi
    if debris_free; then
        pass "rejected: $desc leaves no debris"
    else
        fail "rejected: $desc leaves no debris — left behind:$debris_found"
    fi
}

reject_case "empty input"          missing_hostname  ""
reject_case "leading hyphen"       invalid_hostname  "-modem"
reject_case "trailing hyphen"      invalid_hostname  "modem-"
reject_case "space"                invalid_hostname  "my modem"
reject_case "path traversal"       invalid_hostname  "../../etc/passwd"
reject_case "absolute path"        invalid_hostname  "/etc/passwd"
reject_case "command injection"    invalid_hostname  "modem;reboot"
reject_case "shell substitution"   invalid_hostname  'modem$(reboot)'
reject_case "dot (not a label)"    invalid_hostname  "modem.local"
reject_case "underscore"           invalid_hostname  "my_modem"
reject_case "non-ASCII"            invalid_hostname  "modem-nhà"
reject_case "64 characters"        hostname_too_long "${NAME63}a"

if [ "$(cat "$ETC/hostname")" = "$PREV" ]; then
    pass "rejected input never disturbs the installed hostname"
else
    fail "rejected input never disturbs the installed hostname — got: $(cat "$ETC/hostname")"
fi

# ─── Sanitizer: display name → RFC 1123 label ───────────────────────────────
label_case() {
    got=$(sys_hostname_label "$1")
    if [ "$got" = "$2" ]; then
        pass "label: '$1' → '$2'"
    else
        fail "label: '$1' → '$2' — got: '$got'"
    fi
}

label_case "RM520N-GL"            "RM520N-GL"
label_case "5g-modem"             "5g-modem"
label_case "Alex Nguyễn"          "Alex-Nguy-n"
label_case "Modem nhà"            "Modem-nh"
label_case "  --Long's Modem--  " "Long-s-Modem"
# A name written entirely in non-ASCII reduces to nothing and must fall back
# rather than hand the helper an empty string.
label_case "àà"                   "RM520N-GL"
label_case ""                     "RM520N-GL"
label_case "..."                  "RM520N-GL"
# Truncation can land on a hyphen, which RFC 1123 forbids at the end — the
# trim has to run again after the cut.
label_case "$(printf '%s' "$NAME63" | cut -c1-62) x" \
           "$(printf '%s' "$NAME63" | cut -c1-62)"

# ─── The contract between the two layers ────────────────────────────────────
# Anything the sanitizer emits must survive the helper's validation. This is
# the assertion that catches future drift between them.
for raw in "RM520N-GL" "Alex Nguyễn" "Modem nhà" "  --Long's Modem--  " "àà" \
           "..." "5g-modem" "${NAME63}aaaaaaaaaa" "___" "modem.local"; do
    lbl=$(sys_hostname_label "$raw")
    run_helper "$lbl"
    if [ "$HELPER_RC" -eq 0 ]; then
        pass "sanitizer output accepted by helper: '$raw' → '$lbl'"
    else
        fail "sanitizer output accepted by helper: '$raw' → '$lbl' — rc=$HELPER_RC out=$HELPER_OUT"
    fi
done

# ─── sys_set_hostname() reports the truth ───────────────────────────────────
: > "$QM_TEST_CONFIG_LOG"
: > "$QM_TEST_WARN_LOG"
if sys_set_hostname "Alex Nguyễn"; then
    pass "sys_set_hostname returns 0 when the helper succeeds"
else
    fail "sys_set_hostname returns 0 when the helper succeeds"
fi

# The free-form display name is stored verbatim; only the derived label is
# handed to the helper.
if grep -q '^hostname=Alex Nguyễn$' "$QM_TEST_CONFIG_LOG"; then
    pass "display name persisted verbatim, not sanitized"
else
    fail "display name persisted verbatim, not sanitized — got: $(cat "$QM_TEST_CONFIG_LOG")"
fi

if [ "$(cat "$ETC/hostname")" = "Alex-Nguy-n" ]; then
    pass "system hostname is the derived label"
else
    fail "system hostname is the derived label — got: $(cat "$ETC/hostname")"
fi

if sys_set_hostname ""; then
    fail "sys_set_hostname rejects an empty name"
else
    pass "sys_set_hostname rejects an empty name"
fi

# When the helper is missing — a device that has not taken the update carrying
# it — the preference must still be stored and the failure must be reported,
# not swallowed. This is the regression that started all of this.
: > "$QM_TEST_CONFIG_LOG"
: > "$QM_TEST_WARN_LOG"
mv "$HELPER" "$HELPER.hidden"
if sys_set_hostname "Field Unit 7"; then
    fail "sys_set_hostname reports failure when the helper is missing"
else
    pass "sys_set_hostname reports failure when the helper is missing"
fi
if grep -q '^hostname=Field Unit 7$' "$QM_TEST_CONFIG_LOG"; then
    pass "display name still persisted when the apply fails"
else
    fail "display name still persisted when the apply fails"
fi
if [ -s "$QM_TEST_WARN_LOG" ]; then
    pass "failed apply is logged"
else
    fail "failed apply is logged"
fi
mv "$HELPER.hidden" "$HELPER"

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
