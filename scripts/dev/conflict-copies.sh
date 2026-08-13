#!/usr/bin/env bash
# Find — and optionally remove — iCloud/Finder conflict copies in this repo.
#
# WHY THIS EXISTS
# ---------------
# The checkout lives under ~/Desktop with iCloud Desktop sync on. A backlogged
# CloudDocs resolves a write race by writing a second file next to the first,
# named "<stem> 2<.ext>". Nothing announces it. The copy is a *stale snapshot*,
# so every tool that globs a directory — ESLint, tsc, git — silently reads two
# generations of the same file and believes the older one.
#
# scripts/dev/icloud-exclude.sh attacks the cause (hide the churn from the sync
# engine). This attacks the symptom, because the cause fix cannot be complete:
# .git is deliberately left synced there, and .git is where a conflict copy does
# the most damage.
#
# WHY DETECTION LIVES HERE AND NOT IN run-all.sh
# ----------------------------------------------
# scripts/test/run-all.sh calls this with --porcelain instead of carrying its
# own find(1). One definition of "what is a conflict copy", in one file. The
# split that produced the bug this script exists to catch was exactly this kind
# of drift: run-all.sh pruned .git, eslint.config.mjs ignored the glob, and
# neither knew what the other could not see.
#
# The reverse split — putting --clean on run-all.sh as a flag — is deliberately
# NOT done. run-all.sh runs from `bun run package`; a build gate that can delete
# files in the working tree is a footgun, and the day it deletes the wrong one
# it will do so inside a build nobody was watching.
#
# WHAT IS GRADED HOW
# ------------------
#   CRITICAL  inside the git directory, wherever `git rev-parse` says that
#             actually is — not a hardcoded ./.git. Can corrupt the repository.
#             Not just theory:
#             this repo has held both `.git/refs/heads/main 2` (a duplicated
#             branch ref) and `.git/index 2` (a stale 538-entry index beside
#             the live 540-entry one). Fails the gate; never auto-deleted.
#   HIGH      build output that a tool re-reads as *input*. `.next/types/
#             routes.d 2.ts` made `tsc --noEmit` fail with TS2300 duplicate
#             identifier, because tsconfig.json includes ".next/types/**/*.ts".
#             Loud, but regenerable, so cleanup here is cheap and safe.
#   WARN      source tree. Misleads ESLint and tsc; costs debugging time, not
#             data — one sync event resurrected all 16 already-fixed
#             react-hooks/set-state-in-effect errors this way.
#   BULK      node_modules. Reported as a count only — see below.
#
# WHY node_modules IS COUNTED BUT NEVER LISTED
# --------------------------------------------
# It is scanned: pruning is how blind spots are born, and skipping it entirely
# would let 71k paths rot unobserved. But its hits are never itemised and never
# offered for per-file cleanup, because the answer there is never "which of
# these two files is the good one" — it is to throw the whole tree away and
# reinstall. NOT with `rm -rf node_modules`: once icloud-exclude.sh has run,
# node_modules is a *symlink* into .artifacts.nosync, so that command deletes
# only the link, orphans ~705 MB behind it, and lets `bun install` rebuild a
# real directory back inside iCloud's view — silently undoing the exclusion for
# the artefact that is 94% of the problem. `find node_modules/ -mindepth 1
# -delete` is correct either way: the trailing slash makes find resolve the
# symlink, so the real tree is emptied and the link is left standing.
# Measured here: 22 hits (all conflict copies of .bin/ shims), which would bury
# the one or two findings that actually need a human under a wall of noise.
# Cost of including it in the scan: 0.38 s vs 0.04 s (measured, warm cache).
#
# Usage: bash scripts/dev/conflict-copies.sh [--list|--porcelain|--clean] [flags]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$REPO_ROOT"

# BRE, and every metacharacter here is spelled the portable way on purpose.
# BSD find(1) reads -regex as a *basic* regular expression, where + is a literal
# character and not a quantifier, so every repetition is written \{m,n\}.
#
# Anatomy: <stem> <counter>[.<ext>[.<ext>...]]
#
#   [0-9]\{1,3\}   CloudDocs counts 2, 3, ... and this repo has produced
#                  "foo 10.ts", so a single digit is too tight. Capping at three
#                  is what keeps prose out: "docs/rfc 2024.md" is four digits and
#                  does not match, while a counter never gets near 1000.
#
#   \(\.[A-Za-z][A-Za-z0-9_-]*\)\{0,\}
#                  Zero or more dotted segments, so all of these land:
#                    "main 2"             no extension at all — it was a git ref
#                    "daemon 2.pid"       one plain segment
#                    "codegraph 2.db-wal" hyphen inside the extension. The
#                                         predecessor's [A-Za-z0-9] could not
#                                         see this, and two live SQLite sidecars
#                                         sat unreported in .codegraph/ because
#                                         of it.
#                    "archive 2.tar.gz"   two segments
#                  Each segment must START with a letter. That single constraint
#                  is what stops "version 1.2.3" from reading as stem "version"
#                  plus extension ".2.3"; the price is that a purely numeric
#                  extension ("backup 2.001") is not recognised, which no tool
#                  in this repo produces.
#
# KNOWN FALSE POSITIVE, accepted: a legitimate "Chapter 2.md" is indistinguish-
# able by name from a conflict copy of "Chapter.md" — the shapes are identical,
# so no pattern can separate them. It is graded WARN and, with no "Chapter.md"
# beside it, verdicts as ORPHAN, which --clean never deletes. It becomes
# deletable only when a *different* "Chapter.md" sits next to it and is the
# newer of the two, i.e. exactly the situation a real conflict copy creates.
CONFLICT_RE='.*/[^/]*[ ][0-9]\{1,3\}\(\.[A-Za-z][A-Za-z0-9_-]*\)\{0,\}$'

MODE=list
ASSUME_YES=0
INCLUDE_NEWER=0

note() { printf '  %s\n' "$*"; }

# --- detection ------------------------------------------------------------

# Where the git directory REALLY is, as ./-prefixed repo-relative prefixes, one
# per line.
#
# It is not reliably ./.git. A gitdir: pointer file can aim it anywhere — that
# is how worktrees and submodules work — and worktrees split the directory again
# into a per-worktree half (--git-dir) and a shared half (--git-common-dir,
# which holds refs and objects). Asking git where it lives costs one call and
# survives all of those; hardcoding ./.git meant that the moment it moved,
# a duplicated branch ref graded HIGH — the bucket this file documents as
# "regenerable, so cleanup here is cheap and safe", which for a ref is false.
#
# git is queried, not required: outside a repo, or on a machine with no git,
# both commands fail, GIT_DIRS keeps only the ./.git literal, and scanning still
# works. Only the CRITICAL upgrade is lost.
resolve_git_dirs() {
    local d abs
    printf './.git\n'
    command -v git >/dev/null 2>&1 || return 0
    for d in "$(git rev-parse --git-dir 2>/dev/null || true)" \
             "$(git rev-parse --git-common-dir 2>/dev/null || true)"; do
        [ -n "$d" ] || continue
        abs="$(cd -- "$d" 2>/dev/null && pwd -P)" || continue
        [ -n "$abs" ] || continue
        # Anything outside the repo root is unreachable by our find(1) walk, so
        # a prefix for it would only ever be dead weight.
        case "$abs" in
            "$REPO_ROOT") printf './\n' ;;
            "$REPO_ROOT"/*) printf './%s\n' "${abs#"$REPO_ROOT"/}" ;;
        esac
    done
}
GIT_DIRS="$(resolve_git_dirs | sort -u)"

severity_of() {
    local path="$1" gd
    while IFS= read -r gd; do
        [ -n "$gd" ] || continue
        case "$path" in
            "$gd"/*) printf 'CRITICAL'; return ;;
        esac
    done <<<"$GIT_DIRS"
    case "$path" in
        # .next/.codegraph/qmanager-build are symlinks into .artifacts.nosync
        # once icloud-exclude.sh has run, so find reports the real path; both
        # spellings are listed so an unexcluded checkout grades the same.
        ./.artifacts.nosync/*|./.next/*|./out/*|./.codegraph/*|./qmanager-build/*)
            printf 'HIGH' ;;
        *)
            printf 'WARN' ;;
    esac
}

# Emits "SEVERITY<TAB>PAYLOAD", one per line. PAYLOAD is a path, except for the
# single BULK line where it is a count. Tab-separated because every path this
# tool ever reports contains a space by construction.
scan() {
    local path bulk=0
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        case "$path" in
            */node_modules/*) bulk=$((bulk + 1)); continue ;;
        esac
        printf '%s\t%s\n' "$(severity_of "$path")" "$path"
    done < <(find . -regex "$CONFLICT_RE" -print 2>/dev/null | sort)
    [ "$bulk" -gt 0 ] && printf 'BULK\t%s\n' "$bulk"
    return 0
}

# --- comparison -----------------------------------------------------------

# "routes.d 2.ts" -> "routes.d.ts";  "index 2" -> "index";
# "codegraph 2.db-wal" -> "codegraph.db-wal". Same shape as CONFLICT_RE above,
# and it has to stay that way — a copy the pattern can see but this cannot
# would be compared against a nonexistent original and mis-verdicted ORPHAN.
original_of() {
    printf '%s\n' "$1" | sed 's/ [0-9]\{1,3\}\(\(\.[A-Za-z][A-Za-z0-9_-]*\)\{0,\}\)$/\1/'
}

# Modification time as "<seconds> <nanoseconds>", the fraction zero-padded to
# exactly 9 digits.
#
# WHY SUB-SECOND, AND WHY TWO FIELDS
# ----------------------------------
# The predecessor asked stat for '%m' — whole seconds — and CloudDocs does not
# write in that regime. Measured here: an original at ...475.945664063 and its
# conflict copy at ...475.945766647, 100 MICROSECONDS apart. Truncated to
# seconds those are equal, "is the copy newer" answered false, and the copy —
# which held the only instance of a real change — was graded STALE and deleted
# by --clean --yes. The NEWER verdict is the one thing standing between that
# flag and data loss, so it has to engage at the resolution the writer uses.
#
# Two integers rather than one 19-digit nanosecond value: awk would be the
# obvious comparator but its numbers are C doubles, good for ~15-16 significant
# decimal digits, and a nanosecond epoch needs 19 — the rounding would land
# squarely on the digits that carry the whole distinction. Seconds and the
# 9-digit fraction each compare exactly as shell integers.
#
# BSD stat first, GNU second, and each answer is VALIDATED rather than trusted
# on exit status. On GNU, -f is --file-system: `stat -f '%Fm' x` does not fail
# cleanly there, it prints a block of filesystem statistics to stdout and only
# then exits non-zero, so a plain `||` chain would hand back that block glued to
# the GNU answer. Neither call follows symlinks: the mtime of the link itself is
# what CloudDocs stamped.
mtime_parts_of() {
    local raw sec frac
    raw="$(stat -f '%Fm' "$1" 2>/dev/null || true)"
    case "$raw" in
        ''|*[!0-9.]*|*.*.*) raw="$(stat -c '%.9Y' "$1" 2>/dev/null || true)" ;;
    esac
    case "$raw" in
        ''|*[!0-9.]*|*.*.*) raw='0' ;;
    esac
    sec="${raw%%.*}"
    frac="${raw#"$sec"}"
    frac="${frac#.}"
    # Right-pad, then take 9: makes "5" (deciseconds) and "500000000" the same
    # quantity, and truncates a stat that ever offers more precision than nanos.
    frac="${frac}000000000"
    printf '%s %s\n' "${sec:-0}" "${frac:0:9}"
}

# True when $1 was modified strictly after $2. Explicit returns throughout —
# a bare `[ ... ]` left as the last statement of a then-branch would trip the
# script's own `set -e` the moment it evaluated false.
newer_than() {
    local a b a_s a_n b_s b_n
    a="$(mtime_parts_of "$1")"
    b="$(mtime_parts_of "$2")"
    a_s="${a% *}"; a_n="${a#* }"
    b_s="${b% *}"; b_n="${b#* }"
    if [ "$a_s" -gt "$b_s" ]; then return 0; fi
    if [ "$a_s" -lt "$b_s" ]; then return 1; fi
    if [ "$a_n" -gt "$b_n" ]; then return 0; fi
    return 1
}

# One word describing the copy relative to its original. Anything that is not
# IDENTICAL or STALE is something a human has to decide about.
#   ORPHAN    no original — the copy may be the only surviving version
#   DIR       a duplicated directory; recursive deletion is not this tool's job
#   TYPE      copy and original are not the same kind of thing
#   NEWER     content differs AND the copy is the more recent write
#   SAMETIME  content differs and the two mtimes are equal to the nanosecond.
#             Not a theoretical bucket: a sync engine writing both sides of a
#             race can land them in the same timestamp tick, and "we cannot tell
#             which is current" is the opposite of "safe to delete" — so it gets
#             its own verdict instead of falling into STALE, which is what the
#             old `-gt`-or-else-STALE branch did with it.
verdict_of() {
    local copy="$1" orig="$2"
    [ -e "$orig" ] || [ -L "$orig" ] || { printf 'ORPHAN'; return; }
    [ -L "$copy" ] || [ ! -d "$copy" ] || { printf 'DIR'; return; }
    if [ -L "$copy" ] || [ -L "$orig" ]; then
        if [ -L "$copy" ] && [ -L "$orig" ] && [ "$(readlink "$copy")" = "$(readlink "$orig")" ]; then
            printf 'IDENTICAL'
        else
            printf 'TYPE'
        fi
        return
    fi
    if cmp -s "$copy" "$orig"; then printf 'IDENTICAL'; return; fi
    if newer_than "$copy" "$orig"; then printf 'NEWER'; return; fi
    if newer_than "$orig" "$copy"; then printf 'STALE'; return; fi
    printf 'SAMETIME'
}

# Every line here is a claim the tool makes right before a human decides whether
# to delete something, so each one states only what was actually established:
# IDENTICAL follows a cmp(1) (or a readlink comparison), and STALE/NEWER follow
# a nanosecond-resolution mtime comparison — the wording used to promise an
# ordering the whole-second comparison had not measured.
verdict_gloss() {
    case "$1" in
        IDENTICAL) printf 'same bytes (or same symlink target) — deleting loses nothing' ;;
        STALE)     printf 'content differs, and the original was written later' ;;
        NEWER)     printf 'DIFFERS AND IS NEWER — may hold work the original lost' ;;
        SAMETIME)  printf 'content differs, mtimes equal to the nanosecond — undecidable' ;;
        ORPHAN)    printf 'no original beside it — possibly the only copy' ;;
        DIR)       printf 'a directory, not a file — inspect and remove by hand' ;;
        TYPE)      printf 'copy and original are different kinds of file' ;;
    esac
}

# --- reports --------------------------------------------------------------

cmd_list() {
    local report sev payload n_crit=0 n_high=0 n_warn=0 bulk=0
    report="$(scan)"

    printf '\n== conflict copies under %s ==\n' "$REPO_ROOT"
    if [ -z "$report" ]; then
        note 'none found.'
        printf '\n'
        return 0
    fi

    while IFS=$'\t' read -r sev payload; do
        case "$sev" in
            CRITICAL) n_crit=$((n_crit + 1)) ;;
            HIGH)     n_high=$((n_high + 1)) ;;
            WARN)     n_warn=$((n_warn + 1)) ;;
            BULK)     bulk="$payload" ;;
        esac
    done <<<"$report"

    report_block "$report" CRITICAL "$n_crit" \
        'inside .git — can corrupt the repository; resolve these by hand first'
    report_block "$report" HIGH "$n_high" \
        'in build output — a tool may be reading this as input (tsc reads .next/types)'
    report_block "$report" WARN "$n_warn" \
        'in the source tree — ESLint and tsc will read the stale copy as real'

    if [ "$bulk" -gt 0 ]; then
        printf '\n  BULK      %s in node_modules\n' "$bulk"
        note '            not listed and not cleaned individually; the fix is to'
        note '            empty the tree THROUGH the link and reinstall:'
        note '              find node_modules/ -mindepth 1 -delete && bun install'
        note '            (not `rm -rf node_modules` — after icloud-exclude.sh'
        note '            that is a symlink, and removing it re-syncs 705 MB)'
    fi
    printf '\n'
    [ "$n_crit" -eq 0 ]
}

# Prints one severity section with its per-file verdict, so `--list` already
# answers "is this safe to delete" without a second command.
report_block() {
    local report="$1" want="$2" count="$3" gloss="$4" sev payload orig v
    [ "$count" -gt 0 ] || return 0
    printf '\n  %-9s %d — %s\n' "$want" "$count" "$gloss"
    while IFS=$'\t' read -r sev payload; do
        [ "$sev" = "$want" ] || continue
        orig="$(original_of "$payload")"
        v="$(verdict_of "$payload" "$orig")"
        printf '            %-9s %s\n' "$v" "$payload"
    done <<<"$report"
}

# --- cleanup --------------------------------------------------------------
#
# Dry run unless --yes. A conflict copy is occasionally the *better* version:
# CloudDocs writes the copy when it cannot decide which write won, so "the one
# with the suffix" carries no implication about which content is current.
cmd_clean() {
    local report sev payload orig v deleted=0 kept=0 crit=0

    report="$(scan)"
    if [ -z "$report" ]; then
        printf '\n== clean ==\n'
        note 'nothing to do — no conflict copies found.'
        printf '\n'
        return 0
    fi

    crit=$(printf '%s\n' "$report" | grep -c $'^CRITICAL\t' || true)
    if [ "$crit" -gt 0 ]; then
        printf '\n== STOP: %d conflict copy/copies inside .git ==\n' "$crit"
        printf '%s\n' "$report" | grep $'^CRITICAL\t' | cut -f2- | sed 's/^/       /'
        note ''
        note 'Nothing was deleted, here or anywhere else in the tree.'
        note 'A duplicated ref or index is not a file-management problem, it is a'
        note 'repository-integrity one, and only you can tell which side is real:'
        note ''
        note '  git fsck --full            # what does git itself think is wrong'
        note '  git show-ref               # for a duplicated ref: compare the two'
        note '  git status && git stash list   # for `index 2`: is the live index sane'
        note ''
        note 'Once you have looked and are satisfied, remove it yourself, then'
        note 're-run this to clean the rest of the tree.'
        printf '\n'
        return 2
    fi

    if [ "$ASSUME_YES" -eq 1 ]; then
        printf '\n== clean (DELETING) ==\n'
    else
        printf '\n== clean (dry run — nothing will be deleted) ==\n'
    fi

    while IFS=$'\t' read -r sev payload; do
        [ "$sev" = "HIGH" ] || [ "$sev" = "WARN" ] || continue
        orig="$(original_of "$payload")"
        v="$(verdict_of "$payload" "$orig")"
        case "$v" in
            IDENTICAL|STALE)
                if [ "$ASSUME_YES" -eq 1 ]; then
                    rm -f -- "$payload"
                    printf '  DELETED  %-9s %s\n' "$v" "$payload"
                    deleted=$((deleted + 1))
                else
                    printf '  would rm %-9s %s\n' "$v" "$payload"
                    printf '           %s\n' "$(verdict_gloss "$v")"
                    deleted=$((deleted + 1))
                fi
                ;;
            NEWER)
                if [ "$ASSUME_YES" -eq 1 ] && [ "$INCLUDE_NEWER" -eq 1 ]; then
                    rm -f -- "$payload"
                    printf '  DELETED  %-9s %s  (--include-newer)\n' "$v" "$payload"
                    deleted=$((deleted + 1))
                else
                    printf '  KEPT     %-9s %s\n' "$v" "$payload"
                    printf '           %s\n' "$(verdict_gloss "$v")"
                    printf '           diff "%s" "%s"\n' "$orig" "$payload"
                    printf '           delete anyway with: --clean --yes --include-newer\n'
                    kept=$((kept + 1))
                fi
                ;;
            # No --include-newer escape hatch here on purpose: that flag says
            # "I have read the diff and the copy is the newer one", and the
            # whole point of SAMETIME is that nothing established which is
            # newer. There is no verdict left to override, only a diff to read.
            SAMETIME)
                printf '  KEPT     %-9s %s\n' "$v" "$payload"
                printf '           %s\n' "$(verdict_gloss "$v")"
                printf '           diff "%s" "%s"\n' "$orig" "$payload"
                kept=$((kept + 1))
                ;;
            *)
                printf '  KEPT     %-9s %s\n' "$v" "$payload"
                printf '           %s\n' "$(verdict_gloss "$v")"
                kept=$((kept + 1))
                ;;
        esac
    done <<<"$report"

    printf '\n'
    if [ "$ASSUME_YES" -eq 1 ]; then
        note "deleted $deleted, kept $kept for review."
    else
        note "$deleted would be deleted, $kept need your eyes first."
        note 'Re-run with --clean --yes to do it.'
    fi
    printf '\n'
}

usage() {
    printf 'usage: bash scripts/dev/conflict-copies.sh [--list|--porcelain|--clean] [--yes] [--include-newer]\n\n'
    printf '  --list        (default) graded report with a per-file safe-to-delete verdict\n'
    printf '  --porcelain   SEVERITY<TAB>PAYLOAD, one per line, for scripts/test/run-all.sh\n'
    printf '  --clean       show what deletion would do; deletes nothing on its own\n'
    printf '  --yes         with --clean, actually delete the IDENTICAL and STALE copies\n'
    printf '  --include-newer  with --clean --yes, also delete copies that differ and are\n'
    printf '                newer. Read the dry run first; these can hold the only copy of\n'
    printf '                a change.\n\n'
    printf 'Never deleted by this tool: anything under the resolved git directory\n'
    printf '(reported, then it stops — found via git rev-parse, so a relocated .git or a\n'
    printf 'worktree is covered too), anything under node_modules (counted only),\n'
    printf 'directories, orphans, and copies whose mtime ties the original to the\n'
    printf 'nanosecond — not even with --include-newer.\n'
    # %s, not a bare format string: printf(1) would read a leading "--" as its
    # own end-of-options marker and print an error instead of the line.
    printf '%s\n' '--list exits non-zero when a .git conflict copy exists.'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --list)          MODE=list ;;
        --porcelain)     MODE=porcelain ;;
        --clean)         MODE=clean ;;
        --yes|-y)        ASSUME_YES=1 ;;
        --include-newer) INCLUDE_NEWER=1 ;;
        -h|--help)       usage; exit 0 ;;
        *)               usage >&2; exit 2 ;;
    esac
    shift
done

case "$MODE" in
    list)      cmd_list ;;
    porcelain) scan ;;
    clean)     cmd_clean ;;
esac
