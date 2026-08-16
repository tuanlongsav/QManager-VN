#!/bin/sh
# Harness for harden_install_modes() in scripts/install_rm520n.sh.
#
# What it protects, and why a grep would not be enough:
#
# QManager's installed tree was world-writable on fielded devices — /usr/lib/
# qmanager (20 shared libraries), /usrdata/qmanager/www/cgi-bin (66 endpoints),
# /usrdata/qmanager/certs, and /etc/qmanager (auth.json). The FILE modes were
# always right; only the directories were wrong, which is what made it survive
# so long. Delete permission comes from the directory, not the file, so an
# unprivileged local user could not read a root-owned 0600 file but could
# delete it and write its own in its place. Against /usr/lib/qmanager — sourced
# by 20 root daemons — that is arbitrary code execution as root.
#
# The current installer does not CREATE the problem: measured umask is 0022
# everywhere, so mkdir -p yields 0755. It cannot FIX it either, because mkdir
# never changes an existing directory. harden_install_modes() is the repair, and
# a repair that silently stops repairing looks exactly like one that is working.
#
# So this executes the shipped function against a fixture tree with the real
# broken modes and checks the outcome, rather than asserting the source text
# still mentions chmod.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/install_rm520n.sh"

[ -f "$INSTALLER" ] || { echo "  FAIL not found: $INSTALLER" >&2; exit 1; }

failed=0
checks=0
note_fail() { printf '  FAIL %s\n' "$1" >&2; failed=1; }
check()     { checks=$((checks + 1)); }

# --- 1. It is defined, and CALLED ungated ------------------------------------
# Defining it and forgetting the call is the failure this catches: the function
# would still be there for a reader to find, and would never run.
check
grep -q '^harden_install_modes() {' "$INSTALLER" \
    || note_fail "install_rm520n.sh no longer defines harden_install_modes()"

check
if ! awk '/^main\(\)/,0' "$INSTALLER" | grep -q '^ *harden_install_modes$'; then
    note_fail "main() no longer calls harden_install_modes"
fi

# The OTA path always passes --skip-packages, and may pass --frontend-only, so
# a call placed inside either gate would never reach the fielded devices that
# actually carry the loose modes. Assert it sits outside them, the same way
# scrub_legacy_cron does.
check
if awk '/^ *harden_install_modes$/{print prev} {prev=$0}' "$INSTALLER" | grep -q 'DO_PACKAGES\|DO_BACKEND\|DO_FRONTEND'; then
    note_fail "harden_install_modes is gated behind DO_PACKAGES/DO_BACKEND/DO_FRONTEND — OTA updates would skip it"
fi

# --- 2. It actually repairs a broken tree ------------------------------------
# stat -c is GNU/BusyBox; this harness runs on a developer machine, which may be
# macOS with BSD stat. Shim it rather than skip the only check that proves the
# function does anything.
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/bin"
if ! stat -c '%a' "$FIX" >/dev/null 2>&1; then
    cat > "$FIX/bin/stat" <<'SHIM'
#!/bin/sh
if [ "$1" = "-c" ]; then
    f=$2; shift 2
    case "$f" in '%a') exec /usr/bin/stat -f '%OLp' "$@" ;; esac
    exec /usr/bin/stat -f "$f" "$@"
fi
exec /usr/bin/stat "$@"
SHIM
    chmod +x "$FIX/bin/stat"
    PATH="$FIX/bin:$PATH"
    export PATH
fi

R="$FIX/root"
mkdir -p "$R/usr/lib/qmanager" "$R/usrdata/qmanager/www/cgi-bin" \
         "$R/usrdata/qmanager/certs" "$R/etc/qmanager/profiles"
printf 'cert\n' > "$R/usrdata/qmanager/certs/server.crt"
chmod 777 "$R/usr/lib/qmanager" "$R/usrdata/qmanager" \
          "$R/usrdata/qmanager/www/cgi-bin" "$R/usrdata/qmanager/certs" \
          "$R/etc/qmanager" "$R/etc/qmanager/profiles"
chmod 666 "$R/usrdata/qmanager/certs/server.crt"

run_harden() {
    LIB_DIR="$R/usr/lib/qmanager" \
    QMANAGER_ROOT="$R/usrdata/qmanager" \
    WWW_ROOT="$R/usrdata/qmanager/www" \
    CONF_DIR="$R/etc/qmanager" \
    sh -c '
        _log_raw() { :; }
        info() { printf "%s\n" "$*"; }
        mount() { :; }
        eval "$(awk "/^harden_install_modes\(\) \{/,/^\}/" "$1")"
        harden_install_modes
    ' _ "$INSTALLER"
}

out=$(run_harden 2>&1) || note_fail "harden_install_modes exited non-zero on a repairable tree"

for d in usr/lib/qmanager usrdata/qmanager usrdata/qmanager/www/cgi-bin \
         usrdata/qmanager/certs etc/qmanager etc/qmanager/profiles; do
    check
    m=$(stat -c '%a' "$R/$d" 2>/dev/null)
    [ "$m" = "755" ] || note_fail "$d is $m after hardening, expected 755"
done

check
m=$(stat -c '%a' "$R/usrdata/qmanager/certs/server.crt" 2>/dev/null)
[ "$m" = "644" ] || note_fail "server.crt is $m after hardening, expected 644"

# --- 3. Idempotent -----------------------------------------------------------
# It runs on every install and every OTA update. If it reported work on a tree
# it had already fixed, the log line would become noise and stop being read.
check
out2=$(run_harden 2>&1) || true
case "$out2" in
    *Repaired*) note_fail "harden_install_modes reports work on an already-correct tree — not idempotent" ;;
esac

# --- 4. Non-fatal when the tree is absent ------------------------------------
# A fresh device, a --frontend-only run, or an image without /opt: none of these
# may abort the install. Leaving the modes alone is the status quo, so failing
# here would be strictly worse than not running at all.
check
if ! LIB_DIR=/nonexistent/a QMANAGER_ROOT=/nonexistent/b WWW_ROOT=/nonexistent/c \
     CONF_DIR=/nonexistent/d sh -c '
        _log_raw() { :; }
        info() { :; }
        mount() { :; }
        eval "$(awk "/^harden_install_modes\(\) \{/,/^\}/" "$1")"
        harden_install_modes
     ' _ "$INSTALLER" >/dev/null 2>&1; then
    note_fail "harden_install_modes returns non-zero when the paths do not exist — that would abort an install"
fi

# --- 5. /opt/tmp keeps the sticky bit ----------------------------------------
# It is legitimately shared — opkg writes there — so it stays 0777. Without the
# sticky bit one user can delete another's files, including files opkg is midway
# through using. /tmp itself is 1777 for the same reason.
check
grep -q 'chmod 1777 /opt/tmp' "$INSTALLER" \
    || note_fail "install_rm520n.sh no longer creates /opt/tmp sticky (chmod 1777) — a shared scratch dir without the sticky bit lets any user delete another's files"

check
grep -q 'chmod 777 /opt/tmp' "$INSTALLER" \
    && note_fail "install_rm520n.sh still has a non-sticky 'chmod 777 /opt/tmp'"

if [ "$failed" -ne 0 ]; then
    printf '\n  %d check(s) run, install-mode hardening BROKEN\n\n' "$checks" >&2
    exit 1
fi
printf '  OK   installer repairs world-writable install paths (%d checks)\n' "$checks"
