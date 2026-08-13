#!/usr/bin/env bash
# Functional harness runner. Discovers and runs every scripts/test/*.sh
# (excluding self, run-all.sh and i18n-parity.sh — see the skip list below).
# Most assertions depend on jq.
#
# Run from repo root via `bash scripts/test/run-harnesses.sh` or
# `bun run test:harness`.
#
# This is the deeper, slower pass: it executes the shipped shell against
# fixtures. run-all.sh is the cheap pre-build gate in front of every
# `bun run package` — four checks (bash -n syntax, CRLF, conflict copies, i18n
# parity), ~3 s wall of which the parity step alone is ~2 s.
set -euo pipefail

# When invoked from bun on Windows (e.g. `bun run test:harness` from
# PowerShell), `bash` resolves to C:\Windows\system32\bash.exe — WSL bash.
# WSL Ubuntu typically lacks `jq`, which makes the harnesses report
# misleading "did not produce valid JSON" failures. Mirror build.sh:
# detect WSL and re-exec under Git Bash so the harnesses see the same
# toolchain the tarball will rely on. No-op on real Linux/macOS (the
# /proc/version check fails) and on Git Bash directly (no "microsoft"
# string). See feedback_bun_bash_is_wsl.md.
if [ -z "${QMANAGER_GIT_BASH_REEXEC:-}" ] \
    && [ -r /proc/version ] \
    && grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
    GIT_BASH="/mnt/c/Program Files/Git/usr/bin/bash.exe"
    if [ -x "$GIT_BASH" ]; then
        echo "[run-harnesses] Detected WSL bash — re-execing under Git Bash for jq access" >&2
        export QMANAGER_GIT_BASH_REEXEC=1
        exec "$GIT_BASH" "$0" "$@"
    fi
    echo "[run-harnesses] ERROR: Detected WSL bash but Git Bash not found at $GIT_BASH" >&2
    echo "[run-harnesses] Install 'Git for Windows' (https://git-scm.com/download/win), or run from a Git Bash shell." >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

START=$(date +%s)
fail() { printf '\n[run-harnesses] FAIL: %s (%ds)\n\n' "$1" "$(($(date +%s) - START))" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
    echo "[run-harnesses] WARN: jq not on PATH — jq-dependent assertions will be skipped where guarded" >&2
fi

printf '\n== harnesses ==\n'
harness_count=0
for h in scripts/test/*.sh; do
    [ -f "$h" ] || continue
    name=$(basename "$h")
    # i18n-parity.sh is skipped here rather than run twice. It is not a
    # functional harness — it diffs the two frontend dictionaries and puts no
    # shell under test — and run-all.sh already runs it as a fatal step, so
    # nothing can be packaged past a parity break whether or not this runner
    # touches it. Discovering it here as well bought a second ~2 s pass (about
    # a tenth of this runner's wall time) of a read-only, idempotent check:
    # cost without signal. To check parity on its own, run it directly:
    # `bash scripts/test/i18n-parity.sh`.
    case "$name" in run-all.sh|run-harnesses.sh|i18n-parity.sh) continue ;; esac
    harness_count=$((harness_count + 1))
    printf '\n-- %s --\n' "$name"
    "$BASH" "$h" || fail "harness $name failed"
done

printf '\n[run-harnesses] PASS: %d harnesses (%ds)\n\n' \
    "$harness_count" "$(($(date +%s) - START))"
