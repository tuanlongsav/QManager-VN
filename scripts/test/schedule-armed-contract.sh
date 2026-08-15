#!/bin/sh
# Harness for the "did the schedule actually get armed" contract, across the
# four layers that have to agree on it:
#
#   scripts/www/cgi-bin/quecmanager/system/settings.sh  emits schedule_armed
#   types/system-settings.ts                            declares it
#   components/system-settings/scheduled-operations-card.tsx  reads it
#   lib/i18n/{en,vi}.json                               word the warning
#
# Why this is worth a harness rather than left to review: the failure mode of a
# break here is silence. Scheduled Reboot spent its whole life writing cron
# lines into a spool directory no daemon on this device reads — the save
# reported success and the box never rebooted, and nothing anywhere said so.
# schedule_armed is the field that makes that visible. If the CGI renames it,
# or the card stops reading it, the UI does not error: it goes back to showing
# an unconditional green tick, which looks exactly like everything working.
# Neither tsc nor eslint can see across the shell/TypeScript boundary, so this
# is the only thing that would notice.
#
# These are contract assertions on shipped source, not behaviour tests — there
# is no JS test runner in this repo, and adding one for four greps would cost
# more than it protects. Keep them keyed to the field NAMES, which is what
# actually has to stay in step.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

CGI="$REPO_ROOT/scripts/www/cgi-bin/quecmanager/system/settings.sh"
TYPES="$REPO_ROOT/types/system-settings.ts"
CARD="$REPO_ROOT/components/system-settings/scheduled-operations-card.tsx"
EN="$REPO_ROOT/lib/i18n/en.json"
VI="$REPO_ROOT/lib/i18n/vi.json"

for f in "$CGI" "$TYPES" "$CARD" "$EN" "$VI"; do
    if [ ! -f "$f" ]; then
        echo "  FAIL not found: $f" >&2
        exit 1
    fi
done

failed=0
checks=0

note_fail() {
    printf '  FAIL %s\n' "$1" >&2
    failed=1
}

# want <file> <fixed-string> <message>
want() {
    checks=$((checks + 1))
    grep -qF "$2" "$1" || note_fail "$3"
}

# --- 1. The CGI emits the field ---------------------------------------------
# Checked on the jq response construction, not just anywhere in the file, so a
# leftover mention in a comment cannot satisfy it.
want "$CGI" 'schedule_armed: $armed' \
    "settings.sh no longer emits schedule_armed in its save_scheduled_reboot response"

# The response has to carry the field in BOTH directions. Reporting it only
# when enabling would leave the failed-teardown case — schedule switched off,
# old timer still counting down — indistinguishable from a clean disable, and
# that one ends in an unexpected reboot.
want "$CGI" 'schedule_apply_error' \
    "settings.sh no longer reports schedule_apply_error on an arm/disarm mismatch"

# --- 2. The type declares it -------------------------------------------------
want "$TYPES" 'schedule_armed?: boolean' \
    "SaveActionResponse no longer declares schedule_armed?: boolean"
want "$TYPES" 'schedule_apply_error?: string' \
    "SaveActionResponse no longer declares schedule_apply_error?: string"

# --- 3. The card reads it, and reads it against the request ------------------
want "$CARD" 'result.schedule_armed' \
    "scheduled-operations-card no longer reads result.schedule_armed"

# The comparison is the whole semantic. schedule_armed describes the DEVICE, so
# a bare `=== false` test would fire on every ordinary switch-off, where no
# armed timer is the intended result. Warning on a correct action is how a
# warning stops being read.
want "$CARD" 'result.schedule_armed !== enabled' \
    "scheduled-operations-card no longer compares schedule_armed against the requested enabled state"

# Absent means a device that predates the field. Reading that as "not armed"
# would warn on every save on every such device.
want "$CARD" 'typeof result.schedule_armed === "boolean"' \
    "scheduled-operations-card no longer treats an absent schedule_armed as unknown"

# --- 4. Both dictionaries word both directions -------------------------------
if command -v jq >/dev/null 2>&1; then
    for key in toastNotArmed toastNotDisarmed; do
        for dict in "$EN" "$VI"; do
            checks=$((checks + 1))
            val=$(jq -r --arg k "$key" '.scheduledOperations[$k] // ""' "$dict" 2>/dev/null || true)
            [ -n "$val" ] || note_fail "$(basename "$dict") is missing scheduledOperations.$key"
        done
    done
else
    echo "  SKIP dictionary assertions (jq not on PATH)"
fi

if [ "$failed" -ne 0 ]; then
    exit 1
fi

printf '  OK   %d schedule-armed contract assertions\n' "$checks"
