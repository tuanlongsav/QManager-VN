#!/usr/bin/env bash
# Keep iCloud's hands off this repo's regenerable build artefacts.
#
# WHY THIS EXISTS
# ---------------
# The checkout lives under ~/Desktop and Desktop & Documents sync is on
# (FXICloudDriveDesktop = 1), so CloudDocs indexes and uploads everything here.
# Measured on 2026-08-13, iCloud's own index (client_items in
# ~/Library/Application Support/CloudDocs/session/db/client.db) held 75,412
# items under this repo — 71,029 of them inside node_modules alone. That is
# ~870 MB of pure churn handed to a sync engine already backlogged
# ("pending-scan attempts:8"), and a backlogged CloudDocs resolves races by
# dropping "<name> 2.<ext>" conflict copies. Those have already cost real work:
# stale pre-refactor snapshots under components/ and hooks/ that ESLint read as
# gospel, a duplicated ref inside .git/, and a .next/types/routes.d 2.ts that
# broke `tsc --noEmit` with TS2300.
#
# The repo stays on the Desktop — that is settled. So this moves the artefacts
# somewhere the sync engine will not look, and symlinks them back.
#
# HOW THE EXCLUSION WORKS — AND EXACTLY HOW FAR IT GOES
# -----------------------------------------------------
# CloudDocs skips any path component ending in ".nosync", and it records a
# symlink as a symlink without ever walking into its target. Both were measured
# on this machine rather than taken on faith — a control directory and a
# ".nosync" directory created in the same instant, then read back out of
# CloudDocs' own index:
#
#   on disk:              control/  candidate.nosync/  symlinked  file.nosync
#   in client_items:      control   symlinked
#
# READ THE SCOPE OF THAT EXPERIMENT BEFORE TRUSTING IT. Every item in it was
# created inside the ".nosync" directory, so all it establishes is:
#
#     Content CREATED under a ".nosync" path component is never indexed.
#
# It does NOT establish — and it is NOT true — that ".nosync" hides content
# iCloud has ALREADY indexed. Moving an indexed directory in there achieves the
# opposite of hiding it. From CloudDocs' side the old path just lost its
# contents, so it replicates that as a DELETION; and because the destination is
# invisible to it, it never learns the files still exist. It then applies that
# deletion back to local disk.
#
# This is measured, not theorised. On 2026-08-13 an earlier revision of this
# script `mv`d node_modules — 71,029 already-indexed items — into
# .artifacts.nosync/. With no build tool running and only Apple's `bird`
# (iCloudDriveCore) alive, the destination drained:
#
#     15:18:00   53,863 files / 656M
#     15:18:58   49,063 files / 480M
#     15:19:13   47,623 files / 444M     -> ~6,240 files, ~212 MB destroyed
#
# 27 minutes after that relocation `brctl status` still showed CloudDocs
# uploading a moved database under its OLD path, its modification timestamp
# matching the on-disk file second for second — it was still working through
# pre-move index entries, not stale ones.
#
# THE RULE THAT FALLS OUT OF THAT
# -------------------------------
# --apply must never move already-indexed content into the excluded directory.
# It deletes the original and lets the artefact be REGENERATED at the new path,
# where it is born invisible and the proven property above actually applies.
#
# Two consequences, both enforced below rather than left to good intentions:
#
#   * Every managed artefact needs a documented rebuild command (regen_cmd()).
#     No command means no admission to ARTEFACTS — guard_regenerable() refuses
#     to touch a name it cannot tell you how to rebuild.
#   * Deleting someone's 700 MB node_modules is destructive even when it is
#     regenerable, so --apply on its own only PLANS the deletion and prints it.
#     The deletion itself needs --yes-delete.
#
# WHY THE ARTEFACTS STAY INSIDE THE REPO
# --------------------------------------
# The first design moved them to ~/Library/Caches and symlinked back, which is
# stronger in principle (a target outside ~/Desktop cannot be synced by
# construction). Turbopack vetoed it:
#
#   Error [TurbopackInternalError]: Symlink node_modules is invalid,
#   it points out of the filesystem root
#
# Next 16 refuses any node_modules symlink whose target escapes the project
# root, and node_modules is 94% of the problem, so an exclusion that cannot
# cover it is not worth having. The target therefore has to live inside the
# repo — hence a ".nosync" subdirectory rather than a path outside the tree.
#
# WHY NOT SIMPLY RENAME node_modules TO node_modules.nosync
# ---------------------------------------------------------
# That is the trick usually suggested, and it breaks the build:
#
#   Module not found: Can't resolve 'critters'
#
# Node resolves a bare import by walking up the ancestors of the *real* path
# looking for a directory literally called "node_modules". Rename the directory
# and that walk finds nothing, so packages stop seeing their own siblings.
# Nesting a still-correctly-named node_modules inside a ".nosync" parent keeps
# the walk intact: the ancestor .artifacts.nosync/ does contain "node_modules".
#
# WHAT IS DELIBERATELY NOT MOVED
# ------------------------------
# .git. Earlier revisions of this file recommended relocating it by hand and
# printed copy-pasteable `mv` + "gitdir:" commands to do it. That
# recommendation is WITHDRAWN, on two independent grounds:
#
#   1. It is a `mv` of already-indexed content — exactly the operation
#      documented above, except the victim is the repository rather than a
#      package cache. And .git has no regeneration command, so the
#      delete-and-rebuild strategy that makes the other artefacts safe simply
#      does not exist for it. There is nothing to fall back on.
#   2. The sibling conflict-copy detector grades severity by path, and .git
#      conflict copies are its CRITICAL bucket. Relocating .git moves those
#      copies out from under the path the detector grades on, silently
#      demoting the one class of conflict that can cost commits into a bucket
#      documented as cheap and safe to delete. (The specific hardcoded pattern
#      is being fixed separately, but severity-by-path is inherent to that
#      detector, so moving .git will keep undermining it.)
#
# .git therefore stays where it is and stays synced. --status reports its size
# and says why, and offers nothing to copy-paste.
#
# Usage: bash scripts/dev/icloud-exclude.sh --status
#        bash scripts/dev/icloud-exclude.sh --apply [--yes-delete]
#        bash scripts/dev/icloud-exclude.sh --revert
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$REPO_ROOT"

# The ".nosync" suffix is the whole mechanism — renaming this directory to
# anything else silently re-exposes every artefact to iCloud.
ARTEFACT_DIR_NAME=".artifacts.nosync"
ARTEFACT_DIR="$REPO_ROOT/$ARTEFACT_DIR_NAME"

# Admission criterion: regen_cmd() below must know how to rebuild it. --apply
# DELETES these rather than moving them (see the header), so "regenerable" is
# not a nice-to-have property of this list, it is the only thing that makes the
# deletion recoverable. guard_regenerable() re-checks every name against both
# this list and regen_cmd() at the point of use rather than trusting the loop
# that produced it.
#
# "out" is deliberately absent. Each tool was run against a live symlink to see
# whether it wrote through the link or replaced it, and only one replaced it:
#
#   bun install  (1.3.14)   symlink survived, packages landed in the target
#   next build   -> .next   symlink survived
#   next build   -> out     symlink DELETED, real directory recreated
#
# `output: 'export'` clears out/ and rebuilds it every run, so the link would
# be gone again after each build and out/ would sit in the synced tree for
# effectively its whole life. Managing it would buy nothing but a permanent
# conflict to resolve. It is 483 items of the 75,412 measured here — 0.6%.
ARTEFACTS=(node_modules .next .codegraph qmanager-build)

# Belt to the allowlist's braces: names that must never be relocated even if
# somebody adds them to ARTEFACTS by mistake. .git is the one that would hurt.
FORBIDDEN=(.git .github .claude app components hooks lib types scripts docs public constants dependencies ping-daemon)

RC=0
# Deleting is opt-in. --apply alone plans and prints; it never destroys.
ASSUME_DELETE=0
# Artefacts left pointing at an empty directory by this run. Never allowed to
# stay quiet — see print_regen_block() and the exit code.
REGEN_REQUIRED=()

note()  { printf '  %s\n' "$*"; }
warn()  { printf '  WARN %s\n' "$*"; }
err()   { printf '  FAIL %s\n' "$*" >&2; RC=1; }
banner(){ printf '\n== %s ==\n' "$*"; }

# The rebuild table. This is the admission criterion for ARTEFACTS, not
# documentation: an entry with no command here gets refused, not deleted.
regen_cmd() {
    case "$1" in
        node_modules)   printf 'bun install' ;;
        .next)          printf 'bun run build' ;;
        # build.sh consumes out/, which only `next build` produces, so the
        # packaging script is the honest one-liner even though it also runs the
        # shell test suite first.
        qmanager-build) printf 'bun run package' ;;
        # `index` is a from-scratch rebuild; `sync` would only catch up a graph
        # that still exists. Stop the watcher daemon first if one is running —
        # it holds .codegraph/daemon.sock and will keep writing into a deleted
        # directory: `codegraph daemon`.
        .codegraph)     printf 'codegraph index' ;;
        *) return 1 ;;
    esac
}

# Only ever called after a -d test: `ls -A` on a missing path also prints
# nothing, so this would call a non-existent directory empty.
dir_empty() { [ -z "$(ls -A "$1" 2>/dev/null)" ]; }

need_regen() { REGEN_REQUIRED+=("$1"); }

# Refuse anything off the allowlist, anything on the denylist, and anything
# that is not a single plain path component — the last check stops a stray
# value from escaping the repo root entirely.
guard_regenerable() {
    local name="$1" a f found=0
    case "$name" in
        */*|..|.|'') err "refusing to act on unsafe path component: '$name'"; return 1 ;;
    esac
    for f in "${FORBIDDEN[@]}"; do
        [ "$name" = "$f" ] && { err "refusing to act on '$name' — not regenerable"; return 1; }
    done
    for a in "${ARTEFACTS[@]}"; do
        [ "$name" = "$a" ] && { found=1; break; }
    done
    if [ "$found" -ne 1 ]; then
        err "refusing to act on '$name' — not in the regenerable allowlist"
        return 1
    fi
    # The last gate, and the one that matters most now that --apply deletes:
    # if this script cannot tell the user how to rebuild it, it has no business
    # removing it.
    if ! regen_cmd "$name" >/dev/null; then
        err "refusing to act on '$name' — no documented regeneration command"
        note "     add one to regen_cmd(), or drop it from ARTEFACTS"
        return 1
    fi
    return 0
}

# Classify what currently sits at $REPO_ROOT/$name. Every caller branches on
# this instead of re-stat-ing, so "is this symlink mine?" is decided in exactly
# one place. A symlink pointing anywhere other than our own artefact directory
# is FOREIGN and is never followed, moved, or deleted.
#
# The link is stored relative ("$ARTEFACT_DIR_NAME/$name") so the checkout can
# be renamed or moved wholesale without every symlink dangling.
classify() {
    local name="$1" p="$REPO_ROOT/$1"
    if [ -L "$p" ]; then
        if [ "$(readlink "$p")" = "$ARTEFACT_DIR_NAME/$name" ]; then printf 'linked'; else printf 'foreign'; fi
    elif [ -d "$p" ]; then
        printf 'local'
    elif [ -e "$p" ]; then
        printf 'notdir'
    else
        printf 'absent'
    fi
}

human_size() {
    [ -d "$1" ] || { printf 'n/a'; return; }
    du -sh "$1" 2>/dev/null | cut -f1 | tr -d ' '
}

# --- status ---------------------------------------------------------------
cmd_status() {
    banner "repo"
    note "root:      $REPO_ROOT"
    note "artefacts: $ARTEFACT_DIR"

    banner "sync context"
    local desk tm
    desk="$(defaults read com.apple.finder FXICloudDriveDesktop 2>/dev/null || printf '?')"
    if [ "$desk" = "1" ]; then
        note "iCloud Desktop & Documents sync: ON — exclusion is doing real work here"
    else
        note "iCloud Desktop & Documents sync: off/unknown ($desk) — exclusion is harmless but idle"
    fi
    if [ -d "$ARTEFACT_DIR" ]; then
        tm="$(tmutil isexcluded "$ARTEFACT_DIR" 2>/dev/null || printf '?')"
        note "Time Machine: $tm"
    fi

    banner "artefacts"
    printf '  %-16s %-10s %-8s %s\n' "ARTEFACT" "STATE" "SIZE" "LIVES AT"
    printf '  %-16s %-10s %-8s %s\n' "--------" "-----" "----" "--------"
    local name state dest
    for name in "${ARTEFACTS[@]}"; do
        dest="$ARTEFACT_DIR/$name"
        state="$(classify "$name")"
        case "$state" in
            linked)
                if [ ! -d "$dest" ]; then
                    printf '  %-16s %-10s %-8s %s\n' "$name" "DANGLING" "n/a" "$ARTEFACT_DIR_NAME/$name (missing)"
                    warn "$name points at a target that no longer exists; re-run --apply, then: $(regen_cmd "$name")"
                elif dir_empty "$dest"; then
                    # A live link onto nothing reads as "excluded, all good" to
                    # anyone skimming, and it is the exact state iCloud leaves
                    # behind after eating a target. Say so out loud.
                    printf '  %-16s %-10s %-8s %s\n' "$name" "EMPTY" "0B" "$ARTEFACT_DIR_NAME/$name"
                    warn "$name resolves to an empty directory — the artefact does not exist; run: $(regen_cmd "$name")"
                else
                    printf '  %-16s %-10s %-8s %s\n' "$name" "excluded" "$(human_size "$dest")" "$ARTEFACT_DIR_NAME/$name"
                fi
                ;;
            local)
                printf '  %-16s %-10s %-8s %s\n' "$name" "SYNCED" "$(human_size "$REPO_ROOT/$name")" "$name/ (in the synced tree)"
                ;;
            foreign)
                printf '  %-16s %-10s %-8s %s\n' "$name" "FOREIGN" "n/a" "-> $(readlink "$REPO_ROOT/$name")"
                warn "$name is a symlink this script did not create; it will never be touched"
                ;;
            notdir)
                printf '  %-16s %-10s %-8s %s\n' "$name" "NOTDIR" "n/a" "$name"
                ;;
            absent)
                if [ -d "$dest" ]; then
                    printf '  %-16s %-10s %-8s %s\n' "$name" "ORPHAN" "$(human_size "$dest")" "$ARTEFACT_DIR_NAME/$name"
                    warn "$name has a stale target but no symlink in the repo; --apply will refuse until you resolve it"
                else
                    printf '  %-16s %-10s %-8s %s\n' "$name" "absent" "n/a" "-"
                fi
                ;;
        esac
    done

    banner ".git (not managed, and not recommended for relocation)"
    note "size: $(human_size "$REPO_ROOT/.git"), still synced by iCloud."
    note ""
    note "This script used to print commands for moving .git out of the synced"
    note "tree. That advice is withdrawn and is not coming back:"
    note ""
    note "  * Relocating it means 'mv'ing already-indexed content, which is"
    note "    what destroyed 212 MB of node_modules here on 2026-08-13 — and"
    note "    unlike every artefact above, .git cannot be regenerated, so"
    note "    there is no recovery path when iCloud replicates the deletion."
    note "  * The conflict-copy detector grades severity by path, with .git"
    note "    conflicts as its CRITICAL bucket. Moving .git demotes exactly"
    note "    the conflicts that can cost commits."
    note ""
    note "Live with it synced, or move the whole checkout off ~/Desktop."
    printf '\n'
}

# --- regeneration ---------------------------------------------------------
# The half-applied state — link present, target empty — is the one this whole
# script must never leave quietly. It looks identical to a healthy exclusion in
# a directory listing, and it is what a user arrives in after iCloud has eaten
# a target. So it gets the last word on screen and a distinct exit code.
print_regen_block() {
    [ "${#REGEN_REQUIRED[@]}" -gt 0 ] || return 0
    local name
    banner "ACTION REQUIRED — these links resolve to an EMPTY directory"
    for name in "${REGEN_REQUIRED[@]}"; do
        printf '  %-16s  %s\n' "$name" "$(regen_cmd "$name")"
    done
    printf '\n'
    note "Until each command above has run, that artefact does not exist. The"
    note "symlink resolving is not the same as the contents being there —"
    note "builds, tsc and the codegraph tooling will fail against it."
}

# --- apply ----------------------------------------------------------------
# Idempotent. Already-linked artefacts are verified, absent ones are pre-created
# so the next build writes outside the synced tree from its first byte.
#
# THE ONE THING THIS MUST NOT DO IS `mv`. An artefact that is still a real
# directory in the repo is already in CloudDocs' index at that path; moving it
# under .nosync reads to the sync engine as a deletion it should replicate, and
# it cannot see the destination to learn otherwise. See the header for the
# 212 MB that cost. So the destructive path is delete-then-regenerate, it is
# gated behind --yes-delete, and without that flag --apply only prints a plan.
#
# Conflict policy, stated plainly: if the repo still holds a real directory AND
# a non-empty target already exists, this REFUSES that artefact. It does not
# merge (which would blend two generations of build output) and does not
# clobber (which would silently bin whichever copy is newer). Only a human can
# make that call, so it prints both one-line resolutions and moves on.
cmd_apply() {
    banner "apply"
    mkdir -p "$ARTEFACT_DIR"
    # Regenerable data does not belong in backups either, and this costs one
    # xattr on the parent. Non-fatal: the iCloud exclusion is the point.
    tmutil addexclusion "$ARTEFACT_DIR" 2>/dev/null || true

    local name src dest state
    local planned=()
    for name in "${ARTEFACTS[@]}"; do
        guard_regenerable "$name" || continue
        src="$REPO_ROOT/$name"
        dest="$ARTEFACT_DIR/$name"
        state="$(classify "$name")"
        case "$state" in
            linked)
                # The re-run-after-`bun install` case. bun 1.3.14 was verified
                # to install *through* the symlink rather than replacing it, so
                # normally there is nothing to do — but "the link is fine" and
                # "the artefact is there" are different claims, and reporting
                # the first as if it were the second is how a target iCloud
                # emptied stays invisible. Check the contents, not the link.
                # Missing and empty are both reported and both land in the
                # ACTION REQUIRED block, but only the first is a fault: a
                # vanished target means something removed it behind our back
                # (iCloud, or a stray rm), whereas an empty one is just an
                # artefact we pre-created and nobody has rebuilt yet.
                if [ ! -d "$dest" ]; then
                    err "$name is linked but its target is GONE ($ARTEFACT_DIR_NAME/$name) — something deleted it"
                    mkdir -p "$dest"
                    need_regen "$name"
                elif dir_empty "$dest"; then
                    warn "$name is linked but its target is EMPTY ($ARTEFACT_DIR_NAME/$name) — not yet built"
                    need_regen "$name"
                else
                    note "OK    $name already excluded ($(human_size "$dest"))"
                fi
                ;;
            foreign)
                err "$name is a symlink pointing at $(readlink "$src") — not ours, refusing to touch it"
                ;;
            notdir)
                err "$name exists but is not a directory; refusing"
                ;;
            local)
                if [ -e "$dest" ]; then
                    if [ -d "$dest" ] && dir_empty "$dest"; then
                        rmdir "$dest"
                    else
                        err "$name: two copies exist — repo $(human_size "$src"), target $(human_size "$dest"); refusing to merge or clobber"
                        note "     adopt the target, drop the repo copy:"
                        note "       rm -rf '$src' && ln -s '$ARTEFACT_DIR_NAME/$name' '$src'"
                        note "     discard the target and start clean:"
                        note "       rm -rf '$dest' && bash scripts/dev/icloud-exclude.sh --apply --yes-delete"
                        continue
                    fi
                fi
                if [ "$ASSUME_DELETE" -ne 1 ]; then
                    planned+=("$name")
                    continue
                fi
                # Belt to guard_regenerable()'s braces before an rm -rf: the
                # path must actually be under the repo root we computed.
                case "$src" in
                    "$REPO_ROOT"/*) ;;
                    *) err "$name: '$src' is not under '$REPO_ROOT'; refusing to delete"; continue ;;
                esac
                rm -rf "$src"
                mkdir -p "$dest"
                ln -s "$ARTEFACT_DIR_NAME/$name" "$src"
                note "FRESH $name deleted from the synced tree, relinked empty"
                need_regen "$name"
                ;;
            absent)
                if [ -d "$dest" ]; then
                    err "$name: nothing in the repo but a stale target exists — refusing to guess"
                    note "     adopt it:   ln -s '$ARTEFACT_DIR_NAME/$name' '$src'"
                    note "     discard it: rm -rf '$dest' && bash scripts/dev/icloud-exclude.sh --apply"
                    continue
                fi
                mkdir -p "$dest"
                ln -s "$ARTEFACT_DIR_NAME/$name" "$src"
                note "LINK  $name (was absent; pre-created empty) -> $ARTEFACT_DIR_NAME/$name"
                need_regen "$name"
                ;;
        esac
    done

    [ "${#planned[@]}" -gt 0 ] || return 0

    banner "plan — NOTHING BELOW HAS HAPPENED"
    note "These are still real directories in the synced tree, which means"
    note "iCloud has already indexed them. They cannot be moved into"
    note "$ARTEFACT_DIR_NAME/ — moving indexed content is what destroyed"
    note "212 MB of node_modules here on 2026-08-13 (see the file header)."
    note "The only safe route is to DELETE each one and rebuild it at the"
    note "excluded path, where it is created invisible from its first byte."
    printf '\n'
    printf '  %-8s %-16s %-8s %s\n' "ACTION" "ARTEFACT" "SIZE" "YOU MUST THEN RUN"
    printf '  %-8s %-16s %-8s %s\n' "------" "--------" "----" "-----------------"
    for name in "${planned[@]}"; do
        printf '  %-8s %-16s %-8s %s\n' "DELETE" "$name" "$(human_size "$REPO_ROOT/$name")" "$(regen_cmd "$name")"
    done
    printf '\n'
    note "Nothing has been deleted. To go ahead:"
    note "  bash scripts/dev/icloud-exclude.sh --apply --yes-delete"
}

# --- revert ---------------------------------------------------------------
# Puts the tree back exactly as it was: real directories in the repo, no
# symlinks, no leftover .artifacts.nosync. Artefacts this script never owned
# are left untouched.
cmd_revert() {
    banner "revert"
    local name src dest state
    for name in "${ARTEFACTS[@]}"; do
        guard_regenerable "$name" || continue
        src="$REPO_ROOT/$name"
        dest="$ARTEFACT_DIR/$name"
        state="$(classify "$name")"
        case "$state" in
            linked)
                rm "$src"
                if [ -d "$dest" ]; then
                    mv "$dest" "$src"
                    # --apply pre-creates artefacts that did not exist yet, so
                    # restoring an empty one would leave a directory the repo
                    # never had. Dropping it keeps revert a true inverse.
                    if rmdir "$src" 2>/dev/null; then
                        note "BACK  $name was empty — removed, nothing to restore"
                    else
                        note "BACK  $name restored into the repo"
                    fi
                else
                    note "GONE  $name link removed (target had already vanished; rebuild: $(regen_cmd "$name"))"
                fi
                ;;
            foreign)
                warn "$name is not ours (-> $(readlink "$src")); left alone"
                ;;
            local)
                note "SKIP  $name is already a real directory in the repo"
                ;;
            notdir)
                warn "$name is not a directory; left alone"
                ;;
            absent)
                if [ -d "$dest" ]; then
                    mv "$dest" "$src"
                    note "BACK  $name restored from an orphaned target"
                else
                    note "SKIP  $name absent on both sides"
                fi
                ;;
        esac
    done
    # rmdir, never rm -rf: anything unexpected still living in there survives
    # and stays visible instead of being destroyed by a cleanup step.
    if rmdir "$ARTEFACT_DIR" 2>/dev/null; then
        note "removed empty $ARTEFACT_DIR_NAME/"
    elif [ -d "$ARTEFACT_DIR" ]; then
        warn "$ARTEFACT_DIR_NAME/ is not empty — left in place, inspect it yourself"
    fi
}

usage() {
    printf 'usage: bash scripts/dev/icloud-exclude.sh [--status|--apply [--yes-delete]|--revert]\n\n'
    printf '  --status      report what is excluded, what is not, and where each artefact lives\n'
    printf '  --apply       link up every artefact that costs nothing to link, and PRINT A PLAN\n'
    printf '                for any that would have to be deleted first. Deletes nothing.\n'
    printf '  --yes-delete  with --apply: actually delete those, and print what to re-run.\n'
    printf '  --revert      move everything back into the repo and drop the symlinks\n\n'
    printf 'An artefact already in the synced tree cannot be moved into %s/ —\n' "$ARTEFACT_DIR_NAME"
    printf 'iCloud has indexed it and replicates the move as a deletion. It has to be\n'
    printf 'deleted and rebuilt at the excluded path instead. See the file header.\n\n'
    printf 'Managed: %s\n' "${ARTEFACTS[*]}"
    printf 'Never managed: .git and all tracked source directories.\n\n'
    printf 'Exit: 0 ok  1 something refused or broken  2 bad usage\n'
    printf '      3 applied, but an artefact is empty and must be regenerated first\n'
}

CMD=""
for arg in "$@"; do
    case "$arg" in
        --status|--apply|--revert)
            if [ -n "$CMD" ]; then
                printf 'pick one of --status/--apply/--revert, not both\n' >&2
                exit 2
            fi
            CMD="$arg"
            ;;
        --yes-delete) ASSUME_DELETE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
CMD="${CMD:---status}"

# --yes-delete on anything but --apply is a user who thinks they are arming a
# different command than they are. Refuse rather than ignore it.
if [ "$ASSUME_DELETE" -eq 1 ] && [ "$CMD" != "--apply" ]; then
    printf -- '--yes-delete only applies to --apply\n' >&2
    exit 2
fi

case "$CMD" in
    --status) cmd_status ;;
    --apply)  cmd_apply; cmd_status; print_regen_block ;;
    --revert) cmd_revert; cmd_status ;;
esac

# A pending regeneration is reported in the exit status too, so a wrapper that
# only reads $? still cannot mistake an empty artefact for a working one.
if [ "$RC" -eq 0 ] && [ "${#REGEN_REQUIRED[@]}" -gt 0 ]; then
    exit 3
fi
exit "$RC"
