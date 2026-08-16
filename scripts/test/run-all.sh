#!/usr/bin/env bash
# Pre-build gate for QManager. Six checks:
#   1. bash -n syntax check across daemons, libraries, CGI handlers, harnesses
#   2. CRLF detector (warn-only — installer normalizes on-device)
#   3. iCloud/Finder conflict-copy detector (graded; only .git findings are fatal)
#   4. i18n dictionary parity (en.json vs vi.json) — fatal
#   5. iCloud exclusion drift (warn-only)
#   6. sudoers hygiene — visudo grammar, no wildcard grants — fatal
#
# Fatal: a syntax failure (every bad file is reported, then the run aborts), a
# conflict copy inside .git, an i18n parity failure, or any sudoers finding.
# Conflict copies outside .git, exclusion drift and every CRLF finding are
# warn-only.
#
# Cost: ~3.7 s wall on a dev machine (measured 3.68-3.70 s over three warm
# runs), of which:
#   step 4  ~2 s   — two jq processes per shared dictionary key (~600 at the
#                    current ~317 keys), each behind a grep/sort/tr pipeline.
#                    This gate scales with the dictionary, not the shell tree.
#   step 3  ~0.4 s — up from ~0.01 s. The old scan pruned .git, out/ and
#                    node_modules and so walked only ~700 paths; it now walks
#                    all ~75k, node_modules included. That prune was not a
#                    saving, it was a blind spot: it hid `.git/index 2`, a
#                    stale 538-entry git index beside the live 540-entry one.
#                    0.4 s is the honest price of looking everywhere.
# Still cheap enough to sit in front of every `bun run package`, but it is no
# longer instant; if it ever stops feeling free, step 4 is the one to look at.
# Run from repo root via `bash scripts/test/run-all.sh` or `bun run package`.
#
# Functional harnesses (jq-dependent) live in scripts/test/*.sh and run via
# `bash scripts/test/run-harnesses.sh` (or `bun run test:harness`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

START=$(date +%s)
fail() { printf '\n[run-all] FAIL: %s (%ds)\n\n' "$1" "$(($(date +%s) - START))" >&2; exit 1; }

# --- 1. bash -n syntax check ---------------------------------------------
printf '\n== bash -n syntax check ==\n'
syntax_total=0
syntax_failed=0

# Emit one path per line: shell scripts in well-known dirs, plus extension-less
# daemons in scripts/usr/bin/ that start with a shebang (skips compiled
# binaries like qmanager_discord).
emit_scripts() {
    for f in scripts/usr/bin/*; do
        [ -f "$f" ] || continue
        head -c 2 "$f" 2>/dev/null | grep -q '^#!' && printf '%s\n' "$f"
    done
    ls scripts/usr/lib/qmanager/*.sh 2>/dev/null || true
    find scripts/www/cgi-bin/quecmanager -type f -name '*.sh' 2>/dev/null || true
    ls scripts/test/*.sh 2>/dev/null || true
    # Dev-machine tooling. It never ships to the modem, but it does delete and
    # relocate files here, so a syntax error in it is not a cheap mistake.
    ls scripts/dev/*.sh 2>/dev/null || true
}

while IFS= read -r f; do
    [ -n "$f" ] || continue
    syntax_total=$((syntax_total + 1))
    if ! err=$("$BASH" -n "$f" 2>&1); then
        printf '  FAIL %s\n' "$f"
        printf '%s\n' "$err" | sed 's/^/       /'
        syntax_failed=$((syntax_failed + 1))
    fi
done < <(emit_scripts)

if [ "$syntax_failed" -gt 0 ]; then
    fail "$syntax_failed of $syntax_total scripts have syntax errors"
fi
printf '  OK   %d scripts parsed cleanly\n' "$syntax_total"

# --- 2. CRLF detector (warn-only) ----------------------------------------
printf '\n== CRLF check (warn-only) ==\n'

# -U: read in binary mode so MSYS/Windows grep doesn't strip \r before matching.
# -I: skip binary files. Both flags are no-ops on Linux.
crlf_files=$(
    {
        grep -rUIl $'\r' scripts \
            --include='*.sh' --include='*.service' --include='*.rules' \
            2>/dev/null || true
        # If/then form rather than `&&` chain — under `set -e`, a chain whose
        # last command fails (grep finding no CRLF, the common case) would
        # propagate a non-zero exit out of this command substitution and kill
        # the whole script silently. See feedback_set_e_traps.md.
        for f in scripts/usr/bin/*; do
            if [ -f "$f" ] && grep -qUI $'\r' "$f" 2>/dev/null; then
                printf '%s\n' "$f"
            fi
        done
        find scripts -path '*/sudoers.d/*' -type f 2>/dev/null | while IFS= read -r f; do
            if [ -f "$f" ] && grep -qUI $'\r' "$f" 2>/dev/null; then
                printf '%s\n' "$f"
            fi
        done
    } | sort -u
)

if [ -n "$crlf_files" ]; then
    count=$(printf '%s\n' "$crlf_files" | wc -l | tr -d ' ')
    printf '  WARN %d file(s) have CRLF line endings:\n' "$count"
    printf '%s\n' "$crlf_files" | sed 's/^/       /'
    printf '       Installer normalizes on-device, but fix your editor.\n'
else
    printf '  OK   no CRLF detected\n'
fi

# --- 3. iCloud/Finder conflict copies (graded; .git is fatal) ------------
# "use-i18n 2.ts" sitting beside "use-i18n.ts". These are stale snapshots the
# sync layer leaves behind, and they are actively misleading: one sync event
# resurrected all 16 react-hooks/set-state-in-effect errors that had already
# been fixed, because ESLint was reading the copies. ESLint now ignores the
# pattern, so without this warning they would accumulate completely unseen.
#
# Detection deliberately lives in scripts/dev/conflict-copies.sh, not here, so
# the gate and the cleanup tool cannot disagree about what counts as a conflict
# copy. The previous version of this block carried its own find(1) and pruned
# ./.git — which hid `.git/index 2`, a stale 538-entry index sitting beside the
# live 540-entry one, for as long as it existed.
printf '\n== conflict-copy check ==\n'
CONFLICT_SCAN="$REPO_ROOT/scripts/dev/conflict-copies.sh"
# Committed alongside this file. If it is gone the checkout is incomplete, and
# a detector that silently does not run is the exact failure mode this whole
# section exists to prevent.
[ -f "$CONFLICT_SCAN" ] || fail "scripts/dev/conflict-copies.sh is missing — conflict-copy detection cannot run"

# `|| scan_rc=$?` rather than a bare assignment: this file runs under
# `set -e`, so a detector that exits non-zero would abort the whole gate at
# this line with no banner and no message — the run would simply stop mid-way
# and look like it passed everything before it. A detector that cannot run
# must say so, which is the same principle as the existence check above.
scan_rc=0
conflict_report=$(bash "$CONFLICT_SCAN" --porcelain) || scan_rc=$?
if [ "$scan_rc" -ne 0 ] && [ -z "$conflict_report" ]; then
    fail "conflict-copy detector exited $scan_rc without reporting anything"
fi
n_crit=0; n_high=0; n_warn=0; n_bulk=0
if [ -n "$conflict_report" ]; then
    while IFS=$'\t' read -r sev payload; do
        case "$sev" in
            CRITICAL) n_crit=$((n_crit + 1)) ;;
            HIGH)     n_high=$((n_high + 1)) ;;
            WARN)     n_warn=$((n_warn + 1)) ;;
            BULK)     n_bulk="$payload" ;;
        esac
    done <<<"$conflict_report"
fi

# Printed worst-first so the line that matters is the one still on screen.
print_conflicts() {
    printf '%s\n' "$conflict_report" | grep $'^'"$1"$'\t' | cut -f2- | sed 's/^/       /'
}
if [ "$n_crit" -gt 0 ]; then
    printf '  CRIT %d conflict copy/copies INSIDE .git:\n' "$n_crit"
    print_conflicts CRITICAL
    printf '       A duplicated ref, index or object can corrupt the repository.\n'
    printf '       Stop and look: git fsck --full, git show-ref, git status.\n'
fi
if [ "$n_high" -gt 0 ]; then
    printf '  HIGH %d conflict copy/copies in build output:\n' "$n_high"
    print_conflicts HIGH
    printf '       Regenerable, but tools re-read build output as input: a stale\n'
    printf '       .next/types/routes.d 2.ts fails tsc with TS2300 duplicate identifier.\n'
fi
if [ "$n_warn" -gt 0 ]; then
    printf '  WARN %d conflict copy/copies in the source tree:\n' "$n_warn"
    print_conflicts WARN
    printf '       Stale duplicates — the real files are in git.\n'
fi
if [ "$n_bulk" -gt 0 ]; then
    printf '  INFO %d conflict copy/copies in node_modules (not listed).\n' "$n_bulk"
    # NOT `rm -rf node_modules`. After scripts/dev/icloud-exclude.sh has run,
    # node_modules is a symlink into .artifacts.nosync/: that command deletes the
    # link, orphans ~705 MB behind it, and lets `bun install` rebuild a real
    # directory back inside the synced tree — quietly re-exposing the one
    # artefact that accounts for 94% of everything iCloud indexes here.
    #
    # The trailing slash is the whole trick: it makes find(1) resolve the
    # symlink, so this empties the real tree and leaves the link standing. It
    # behaves identically on an unexcluded checkout where node_modules is a plain
    # directory. A glob (`rm -rf node_modules/*`) would have been the obvious
    # spelling and is wrong to print here — the user's shell is zsh, where an
    # unmatched glob is a hard error, and node_modules/* matches nothing when the
    # tree holds only dotted entries.
    printf '       Regenerable in bulk, but empty it THROUGH the link:\n'
    printf '         find node_modules/ -mindepth 1 -delete && bun install\n'
fi
if [ "$((n_crit + n_high + n_warn + n_bulk))" -eq 0 ]; then
    printf '  OK   no conflict copies\n'
elif [ "$n_crit" -gt 0 ]; then
    # Deliberately NOT pointed at --clean. With a .git finding present it prints
    # "== STOP ==", deletes nothing anywhere in the tree and exits 2 — the same
    # dead end the node_modules-only case below avoids, for the same reason.
    printf '       conflict-copies.sh --clean refuses to touch anything while a\n'
    printf '       .git finding exists; resolve that by hand first, then re-run it.\n'
elif [ "$((n_high + n_warn))" -gt 0 ]; then
    # Not offered for a node_modules-only run: --clean deliberately refuses to
    # touch node_modules, so pointing at it there would be a dead end.
    printf '       Review and remove: bash scripts/dev/conflict-copies.sh --clean\n'
fi
# Deferred so the HIGH/WARN/INFO detail above is printed before the abort.
if [ "$n_crit" -gt 0 ]; then
    fail "$n_crit conflict copy/copies inside .git — resolve before building"
fi

# --- 4. i18n dictionary parity -------------------------------------------
printf '\n== i18n parity ==\n'
if ! bash "$REPO_ROOT/scripts/test/i18n-parity.sh"; then
    fail "en.json / vi.json are out of parity"
fi

# --- 5. iCloud exclusion drift (warn-only) --------------------------------
# The exclusion is not self-healing, and two separate forces undo it.
#
# A tool can recreate the path: a `next build` racing another one replaced the
# .next symlink with a real directory. And iCloud can undo it outright — if
# CloudDocs still holds live index rows for a path, it restores its own idea of
# that path as a directory and renames the symlink to "<name> 2". That is what
# happened to .next and .codegraph overnight on 2026-08-15, while node_modules
# and qmanager-build survived: those two had been deleted and rebuilt, so their
# rows had already tombstoned and there was nothing left to restore from.
#
# Either way the artefact silently lands back in the synced tree and nothing
# says so, which is how 642 MB of .codegraph got re-exposed unnoticed. Warn
# rather than fail: a fresh clone has no exclusion applied at all and must not
# be blocked from building.
printf '\n== iCloud exclusion drift (warn-only) ==\n'
drift=0
for _a in node_modules .next .codegraph qmanager-build; do
    [ -e "$REPO_ROOT/$_a" ] || continue
    if [ ! -L "$REPO_ROOT/$_a" ] && [ -d "$REPO_ROOT/$_a" ]; then
        printf '  WARN %s is a real directory in the synced tree, not a link into .artifacts.nosync/\n' "$_a"
        drift=$((drift + 1))
    fi
done
if [ "$drift" -gt 0 ]; then
    printf '       iCloud is indexing it again. Check with:\n'
    printf '         bash scripts/dev/icloud-exclude.sh --status\n'
else
    printf '  OK   no drift (or exclusion not applied)\n'
fi

# --- 6. sudoers hygiene (fatal) -------------------------------------------
# Two failure modes, and this project has already paid for both.
#
# GRAMMAR. sudo refuses EVERY request when any file it reads fails to parse,
# and sudoers.d is read in full, so a single malformed drop-in disables every
# rule in the directory. On the modem www-data is the only sudo user, which
# makes that one stray character an outage of every privileged action the web
# UI has — service control, iptables, reboot, DNS, and qmanager_update with
# them, so the device cannot even pull down the fix. An unescaped ':' in the
# custom-DNS chown rule shipped exactly this once, and the Phase 1 audit had
# approved it: an audit reviews policy, and only visudo checks grammar
# (docs/reference/custom-dns.md). Checking here means a bad rule cannot reach a
# tarball at all; the installer repeats the check on-device for the same file.
#
# WILDCARDS. sudo matches command arguments as ONE space-joined string, so a
# '*' does not stay inside the argument it was written in — it matches across
# word boundaries (sudoers(5), "Wildcards in command arguments"). That is how
# `rm -f /lib/.../wants/qmanager*.service` also matched
# `... /lib/.../wants/qmanagerX /etc/shadow /evil.service` and deleted all three
# as root, and how `/bin/systemctl start *` reached every unit on the device.
#
# The file now contains no wildcard at all, so the assertion is simply that it
# stays that way. Matching known-bad forms would only catch the shapes somebody
# already thought of; this catches the next one too. Each exact grant is also
# asserted individually, because a missing one fails SILENTLY at runtime —
# platform.sh discards sudo's stderr, watchdog.sh backgrounds its restart, and
# the tower call sites drop svc_enable's return value entirely. An upstream
# merge is the realistic way a wildcard returns, and nothing else would notice.
printf '\n== sudoers hygiene ==\n'
SUDOERS_SRC="scripts/etc/sudoers.d/qmanager"
[ -f "$SUDOERS_SRC" ] || fail "$SUDOERS_SRC is missing"

# Comment-blind. Every rule below is explained in a comment that names the very
# construct it forbids, so a comment-reading grep would trip over the
# documentation of its own rule.
sudoers_code=$(grep -vE '^[[:space:]]*#' "$SUDOERS_SRC" || true)

if printf '%s\n' "$sudoers_code" | grep -q '\*'; then
    printf '%s\n' "$sudoers_code" | grep -n '\*' | sed 's/^/       /' || true
    fail "sudoers contains a wildcard grant (see above) — name the arguments in full"
fi
printf '  OK   no wildcard in any grant\n'

# Matched with grep -F on the exact single-spaced string, which also pins the
# spacing: sudo compares the joined argument string, so a stray double space
# would pass visudo and then silently never match at runtime.
sudoers_missing=0
sudoers_wanted=0
while IFS= read -r g; do
    [ -n "$g" ] || continue
    sudoers_wanted=$((sudoers_wanted + 1))
    if ! printf '%s\n' "$sudoers_code" | grep -qF "$g"; then
        printf '  FAIL missing grant: %s\n' "$g"
        sudoers_missing=$((sudoers_missing + 1))
    fi
done <<'GRANTS'
/bin/systemctl restart qmanager-watchcat
/bin/systemctl stop qmanager-watchcat
/bin/systemctl start qmanager-tower-failover
/bin/systemctl stop qmanager-tower-failover
/bin/ln -sf /lib/systemd/system/qmanager-watchcat.service /lib/systemd/system/multi-user.target.wants/qmanager-watchcat.service
/bin/ln -sf /lib/systemd/system/qmanager-tower-failover.service /lib/systemd/system/multi-user.target.wants/qmanager-tower-failover.service
/bin/rm -f /lib/systemd/system/multi-user.target.wants/qmanager-watchcat.service
/bin/rm -f /lib/systemd/system/multi-user.target.wants/qmanager-tower-failover.service
GRANTS
[ "$sudoers_missing" -eq 0 ] \
    || fail "$sudoers_missing required grant(s) missing from $SUDOERS_SRC"
printf '  OK   all %d required grants present\n' "$sudoers_wanted"

visudo_bin=""
for v in /usr/sbin/visudo /opt/sbin/visudo /sbin/visudo; do
    [ -x "$v" ] && { visudo_bin="$v"; break; }
done
if [ -n "$visudo_bin" ]; then
    # -cf checks the named file instead of the live /etc/sudoers, and ignores
    # its owner and mode, so a plain temp copy is enough. Strip CRLF first:
    # that is what install_file writes on-device, so it is what must parse.
    sudoers_tmp=$(mktemp)
    # `tr` sits between mktemp and the rm calls below; under `set -e` a failure
    # there would exit without cleaning up.
    trap 'rm -f "$sudoers_tmp"' EXIT
    tr -d '\r' < "$SUDOERS_SRC" > "$sudoers_tmp"
    if "$visudo_bin" -cf "$sudoers_tmp" >/dev/null 2>&1; then
        rm -f "$sudoers_tmp"
        printf '  OK   visudo -cf parses cleanly\n'
    else
        # visudo names the file it was handed, so map the temp path back to the
        # real one — a bare "tmp.A0nEmh:81: syntax error" makes the line number
        # useless to whoever has to go fix it.
        "$visudo_bin" -cf "$sudoers_tmp" 2>&1 \
            | sed "s|$sudoers_tmp|$SUDOERS_SRC|g; s/^/       /" || true
        rm -f "$sudoers_tmp"
        fail "$SUDOERS_SRC does not parse — see visudo output above"
    fi
else
    printf '  WARN visudo not found — grammar unchecked on this host\n'
fi

printf '\n[run-all] PASS: %d scripts (%ds)\n\n' \
    "$syntax_total" "$(($(date +%s) - START))"
