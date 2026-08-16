#!/bin/sh
# Harness for the "will it still be enabled after a reboot" contract, across the
# layers that have to agree on it:
#
#   scripts/usr/lib/qmanager/tower_lock_mgr.sh          records svc_enable's answer
#   scripts/www/cgi-bin/quecmanager/tower/{lock,settings}.sh  emit failover_boot_*
#   types/tower-locking.ts                              declares them
#   components/cellular/tower-locking/*.tsx             read them
#   scripts/www/cgi-bin/quecmanager/monitoring/watchdog.sh    emits boot_enabled
#   hooks/use-watchdog-settings.ts + use-tower-locking.ts     must PASS THE BODY ON
#   components/monitoring/watchdog/watchdog-settings-card.tsx reads boot_enabled
#
# Why this is worth a harness rather than left to review: the failure mode is
# silence, and it already happened twice here.
#
#   1. platform.sh's svc_enable/svc_disable verify that the boot symlink really
#      changed and return that. Four tower call sites threw the answer away, so
#      a failover the user switched on reported success and was gone after the
#      next reboot.
#   2. watchdog.sh has emitted boot_enabled and boot_enable_error for a while,
#      correctly — and nothing in the frontend ever read either one. A backend
#      that reports honestly into a hook that returns a bare boolean is
#      indistinguishable, from the user's chair, from a backend that lies.
#
# (2) is the one this file exists for. A field can be emitted, typed, and still
# reach nobody, because the hook in the middle drops the response body. Neither
# tsc nor eslint can see across the shell/TypeScript boundary, and neither
# notices a correctly-typed value that is simply never read.
#
# Contract assertions on shipped source, not behaviour tests — there is no JS
# test runner here. Keyed to the field NAMES, which is what has to stay in step.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

LIB="$REPO_ROOT/scripts/usr/lib/qmanager/tower_lock_mgr.sh"
CGI_LOCK="$REPO_ROOT/scripts/www/cgi-bin/quecmanager/tower/lock.sh"
CGI_SET="$REPO_ROOT/scripts/www/cgi-bin/quecmanager/tower/settings.sh"
CGI_WD="$REPO_ROOT/scripts/www/cgi-bin/quecmanager/monitoring/watchdog.sh"
SCHED="$REPO_ROOT/scripts/usr/bin/qmanager_tower_schedule"
TYPES="$REPO_ROOT/types/tower-locking.ts"
HOOK_TOWER="$REPO_ROOT/hooks/use-tower-locking.ts"
HOOK_WD="$REPO_ROOT/hooks/use-watchdog-settings.ts"
HELPER="$REPO_ROOT/components/cellular/tower-locking/failover-boot-warning.ts"
LTE="$REPO_ROOT/components/cellular/tower-locking/lte-locking.tsx"
NR="$REPO_ROOT/components/cellular/tower-locking/nr-sa-locking.tsx"
TSET="$REPO_ROOT/components/cellular/tower-locking/tower-settings.tsx"
WDCARD="$REPO_ROOT/components/monitoring/watchdog/watchdog-settings-card.tsx"

for f in "$LIB" "$CGI_LOCK" "$CGI_SET" "$CGI_WD" "$SCHED" "$TYPES" \
         "$HOOK_TOWER" "$HOOK_WD" "$HELPER" "$LTE" "$NR" "$TSET" "$WDCARD"; do
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

# reject <file> <ERE> <message>
reject() {
    checks=$((checks + 1))
    if grep -qE "$2" "$1"; then
        note_fail "$3"
    fi
}

# --- 1. The library records svc_enable's answer ------------------------------
want "$LIB" 'TOWER_FAILOVER_BOOT_ENABLED' \
    "tower_lock_mgr.sh no longer records svc_enable's result in TOWER_FAILOVER_BOOT_ENABLED"

# It has to be a global rather than the return value: the function already
# speaks through stdout, and that channel carries a different answer entirely
# (is the daemon alive right now). Conflating the two is what let a running
# watcher with no boot symlink be reported as success.
want "$LIB" 'if svc_enable qmanager_tower_failover; then' \
    "tower_lock_mgr.sh no longer checks svc_enable — its result is discarded again"

# --- 2. No bare svc_enable/svc_disable left on the tower unit ----------------
# A bare call is exactly the bug: the status is computed, verified, and thrown
# away. Matching on a line that is nothing but the call catches a revert.
for f in "$CGI_LOCK" "$CGI_SET"; do
    reject "$f" '^[[:space:]]*svc_disable qmanager_tower_failover[[:space:]]*$' \
        "$(basename "$f") calls svc_disable qmanager_tower_failover without checking the result"
done

# --- 3. Both CGIs emit the pair, inside the jq response ----------------------
# Checked on the response construction rather than anywhere in the file, so a
# leftover mention in a comment cannot satisfy it.
for f in "$CGI_LOCK" "$CGI_SET"; do
    want "$f" 'failover_boot_enabled:false' \
        "$(basename "$f") no longer emits failover_boot_enabled in its jq response"
    want "$f" 'failover_boot_error:$boot_err' \
        "$(basename "$f") no longer emits failover_boot_error in its jq response"
done

# Emitted ONLY on failure. If the fields were always present, an older device
# omitting them would be indistinguishable from a new device reporting success,
# and the frontend's absent-means-unknown rule would have nothing to stand on.
want "$CGI_LOCK" 'if $boot_err == "" then {} else' \
    "lock.sh no longer omits the boot fields on success — absence must mean nothing to report"

# --- 4. The unattended call site at least logs ------------------------------
# qmanager_tower_schedule runs from a systemd timer: no HTTP response, no user.
# A log line is the only surface it has, which also makes it the easiest of the
# five call sites to lose without noticing.
want "$SCHED" 'TOWER_FAILOVER_BOOT_ENABLED' \
    "qmanager_tower_schedule no longer reports a failed boot-enable anywhere"

# --- 5. The types declare them ----------------------------------------------
want "$TYPES" 'failover_boot_enabled?: boolean' \
    "tower-locking.ts no longer declares failover_boot_enabled?: boolean"
want "$TYPES" 'failover_boot_error?: string' \
    "tower-locking.ts no longer declares failover_boot_error?: string"

# --- 6. THE BLOCKER: the hooks must pass the body on ------------------------
# This is the check that would have caught bug (2). A hook returning a bare
# boolean discards the response, so the field can be emitted and typed and
# still reach nobody. tsc cannot see this; it is a correctly-typed value that
# is simply never read.
want "$HOOK_WD" 'boot_enabled' \
    "use-watchdog-settings.ts no longer carries boot_enabled — saveSettings is dropping the response body again"
reject "$HOOK_WD" 'saveSettings: \(.*\) => Promise<boolean>' \
    "use-watchdog-settings.ts narrowed saveSettings back to Promise<boolean> — the response body cannot reach the card"

want "$HOOK_TOWER" 'failover_boot_enabled' \
    "use-tower-locking.ts no longer carries failover_boot_enabled — the lock/settings response body is being dropped"

# --- 7. The components read it, with the right comparison -------------------
# Note the semantics differ from schedule_armed deliberately. schedule_armed
# describes the DEVICE and must be compared against what was requested, because
# a stale timer can outlive a disable. svc_enable/svc_disable already verify
# direction-aware: success means the boot state matches what was asked, either
# way. So `=== false` is correct here, and a `!== enabled` comparison would be
# wrong. Absence still means unknown, and `=== false` gives that for free.
# The three tower cards share one helper rather than repeating the comparison,
# so the semantics are asserted once where they live, and each card is asserted
# to actually call it. That is the pairing that matters: a fourth tower call
# site added later without the helper is the realistic regression, and it shows
# up here as a card that never imports it.
want "$HELPER" 'failover_boot_enabled === false' \
    "failover-boot-warning.ts no longer tests failover_boot_enabled === false — a falsy check would warn when the field is absent"
want "$HELPER" 'result.failover_boot_error ||' \
    "failover-boot-warning.ts no longer prefers the server's error string over the local fallback"

# The trailing '(' is load-bearing: without it the bare name also matches the
# import line, so a card that imports the helper and never calls it passes.
# That is not hypothetical — it is what a half-finished edit leaves behind, and
# eslint's unused-import rule does not fire on a named import that is
# referenced nowhere in a .tsx it still type-checks against.
for f in "$LTE" "$NR" "$TSET"; do
    want "$f" 'warnIfFailoverBootFailed(' \
        "$(basename "$f") no longer calls warnIfFailoverBootFailed — its boot-persistence miss is silent again"
done

want "$WDCARD" 'boot_enabled === false' \
    "watchdog-settings-card no longer warns on boot_enabled === false"

# --- 8. Warning, not error --------------------------------------------------
# The save genuinely succeeded; only the boot persistence did not. Reporting it
# as an error would tell the user their settings were lost, which is a
# different untruth from the one being fixed.
want "$HELPER" 'toast.warning' \
    "failover-boot-warning.ts no longer uses toast.warning for the boot-persistence miss"
want "$WDCARD" 'toast.warning' \
    "watchdog-settings-card no longer uses toast.warning for the boot-persistence miss"

# --- 9. The globals actually reach the caller -------------------------------
# Everything above greps source text, and that is not enough here. The first
# version of this fix was textually perfect and half dead: the CGI captured the
# function with `x=$(tower_spawn_failover_watcher)`, command substitution ran it
# in a subshell, and every global it set was discarded when the substitution
# ended. All the greps passed. The boot answer simply arrived empty at runtime.
#
# So: reject the capture form outright, then EXECUTE the function against stubs
# and prove the caller can see what it set. A grep cannot tell you a variable
# survived; only running it can.
for f in "$CGI_LOCK" "$CGI_SET" "$SCHED"; do
    reject "$f" '=\$\(tower_spawn_failover_watcher\)' \
        "$(basename "$f") captures tower_spawn_failover_watcher with \$(...) — the subshell discards TOWER_FAILOVER_BOOT_ENABLED and the boot warning never fires"
done

# The second global is load-bearing in a way that is easy to miss: lock.sh feeds
# it straight to `jq --argjson`, where an empty string is not valid JSON. jq
# exits, the CGI emits nothing, resp.json() throws in the browser, and a lock
# that actually succeeded is reported to the user as "Failed to lock tower".
# So it has to be seeded at library scope, not only inside the function.
want "$LIB" 'TOWER_FAILOVER_WATCHER_ALIVE="false"' \
    "tower_lock_mgr.sh no longer seeds TOWER_FAILOVER_WATCHER_ALIVE — an empty value reaches jq --argjson and takes the whole response down"

checks=$((checks + 1))
runtime=$(
    sh -c '
        tower_config_get() { printf "true"; }
        svc_stop() { :; }
        svc_start() { :; }
        svc_enable() { return 1; }   # force the boot-enable failure branch
        qlog_warn() { :; }
        qlog_info() { :; }
        pid_alive() { return 1; }
        sleep() { :; }
        TOWER_FAILOVER_PID=/nonexistent
        eval "$(awk "/^tower_spawn_failover_watcher\(\) \{/,/^\}/" "$1")"
        tower_spawn_failover_watcher >/dev/null 2>&1
        printf "%s|%s" "$TOWER_FAILOVER_BOOT_ENABLED" "$TOWER_FAILOVER_WATCHER_ALIVE"
    ' _ "$LIB" 2>/dev/null || true
)
# Both globals, not just the boot one. Losing the daemon-alive global does not
# break the warning — it breaks the whole response, via jq --argjson.
[ "$runtime" = "false|false" ] || note_fail "tower_spawn_failover_watcher did not leave both globals set in the caller after svc_enable failed (got '$runtime', want 'false|false') — either the warning cannot fire or jq --argjson receives an empty value"

if [ "$failed" -ne 0 ]; then
    printf '\n  %d check(s) run, contract BROKEN\n\n' "$checks" >&2
    exit 1
fi
printf '  OK   failover/watchdog boot-persistence contract holds (%d checks)\n' "$checks"
