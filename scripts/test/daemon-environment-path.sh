#!/usr/bin/env bash
# Harness for the systemd EnvironmentFile= location:
#   scripts/etc/systemd/system/qmanager-{poller,watchcat,ping}.service
#   DAEMON_ENV_FILE / relocate_daemon_environment() in scripts/install_rm520n.sh
#   DAEMON_ENV_FILE in scripts/uninstall_rm520n.sh
#   the re-assert block in scripts/usr/bin/qmanager_setup
#
# The bug this exists to prevent coming back: EnvironmentFile= makes systemd
# inject every KEY=VALUE line of the named file into the unit's process
# environment, and all three of those units run as root. While that file lived
# at /etc/qmanager/environment it sat inside a directory that install_backend()
# and qmanager_setup both chown -R to www-data — the web CGI user — so any CGI
# foothold could set PATH= or LD_PRELOAD= for three root daemons.
#
# There are exactly two ways it comes back, and both are quiet:
#   1. Someone "tidies" the file back under a www-data-owned directory, or
#      introduces an /etc/qmanager* glob that sweeps the sibling into the chown.
#   2. A unit's EnvironmentFile= and the installer's DAEMON_ENV_FILE drift
#      apart. Nothing complains at runtime, because EnvironmentFile= carries a
#      leading '-' in all three units: a path that no longer exists is not an
#      error, it silently means "no overrides". The failure mode is a settings
#      revert, not a crash, so it survives a manual smoke test.
#
# So this checks the paths agree AND that the agreed path is outside every
# directory the shipped scripts hand to www-data — then executes the shipped
# sanitizer against a poisoned fixture to prove the filtering is real.
#
# There is a third way it comes back, and it is the migration itself. The old
# path stays www-data-owned right up until the file leaves it, so during the
# migration the attacker chooses not only the CONTENT of the legacy file but
# its TYPE: a symlink, a directory, a FIFO. Sections 12-14 put each of those
# at the legacy path and require the migration to refuse them. Sections 3 and
# 4 are split because this file's first attempt at "is the env file inside a
# www-data-owned directory" read the wrong word off the chown line and so
# passed the worst regression it exists to catch; section 3 is the self-test
# that keeps section 4 from going quietly vacuous again.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

INSTALLER="scripts/install_rm520n.sh"
UNINSTALLER="scripts/uninstall_rm520n.sh"
SETUP="scripts/usr/bin/qmanager_setup"
UNIT_DIR="scripts/etc/systemd/system"
UNITS="qmanager-poller.service qmanager-watchcat.service qmanager-ping.service"

failures=0
pass() { printf '  OK   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; failures=$(( failures + 1 )); }

for f in "$INSTALLER" "$UNINSTALLER" "$SETUP"; do
    if [ ! -f "$f" ]; then
        printf '  FAIL not found: %s\n' "$f"
        exit 1
    fi
done

# Read a FOO="bar" constant out of a shell script. First assignment wins.
const_of() {
    sed -n "s/^[[:space:]]*$2=\"\([^\"]*\)\".*/\1/p" "$1" | head -n1
}

printf '\n-- 1. installer and uninstaller agree on the path --\n'

INSTALL_ENV=$(const_of "$INSTALLER" DAEMON_ENV_FILE)
UNINSTALL_ENV=$(const_of "$UNINSTALLER" DAEMON_ENV_FILE)

if [ -z "$INSTALL_ENV" ]; then
    fail "$INSTALLER defines no DAEMON_ENV_FILE constant"
elif [ "${INSTALL_ENV#/}" = "$INSTALL_ENV" ]; then
    fail "DAEMON_ENV_FILE is not an absolute path: $INSTALL_ENV"
else
    pass "installer DAEMON_ENV_FILE=$INSTALL_ENV"
fi

if [ "$UNINSTALL_ENV" != "$INSTALL_ENV" ]; then
    fail "uninstaller DAEMON_ENV_FILE='$UNINSTALL_ENV' != installer '$INSTALL_ENV'"
else
    pass "uninstaller agrees"
fi

[ -n "$INSTALL_ENV" ] || exit 1
ENV_DIR=$(dirname "$INSTALL_ENV")

printf '\n-- 2. every unit points at that exact path --\n'

# Scan ALL shipped units, not just the three known consumers: a unit added
# later with the old path is exactly the drift this is here to catch.
seen_units=0
for unit_path in "$UNIT_DIR"/*.service; do
    [ -f "$unit_path" ] || continue
    unit=$(basename "$unit_path")
    # Directives only. A commented-out example must not count as a consumer,
    # and must not be able to fail this check either.
    while IFS= read -r value; do
        seen_units=$(( seen_units + 1 ))
        # Strip the leading '-' (systemd's "absent is not an error" marker).
        value="${value#-}"
        if [ "$value" = "$INSTALL_ENV" ]; then
            pass "$unit -> $value"
        else
            fail "$unit EnvironmentFile='$value' != DAEMON_ENV_FILE '$INSTALL_ENV'"
        fi
    done < <(grep -h '^EnvironmentFile=' "$unit_path" | sed 's/^EnvironmentFile=//')
done

# The three known consumers must each still declare one. Losing the directive
# outright would silently drop operator overrides the same way a wrong path
# does, and would otherwise sail past the loop above.
for unit in $UNITS; do
    if grep -q '^EnvironmentFile=' "$UNIT_DIR/$unit" 2>/dev/null; then
        pass "$unit declares EnvironmentFile="
    else
        fail "$unit has no EnvironmentFile= directive"
    fi
done

if [ "$seen_units" -eq 0 ]; then
    fail "no EnvironmentFile= directive found in any unit"
fi

# --- www-data chown extraction -------------------------------------------
#
# Everything below exists because the obvious way to do this does not work.
# The first version of this check took the LAST FIELD of every line matching
# `chown .*www-data`. That reads the target correctly only when the command is
# the whole line and the path is the last word on it, which is a coincidence of
# how this tree happens to be written today, not a property of shell:
#
#   chown -R www-data:www-data /etc 2>/dev/null || true
#
# ends in `true`, so the field-extractor harvested "true", discarded it as
# non-absolute, and reported that it had checked everything. That mutation
# hands the whole of /etc — /etc/qmanager.env included — to the web user, and
# it passed this harness green. So the parser has to understand the command,
# not the line: flags (-R, -hR, --recursive), quoting, variables, redirections,
# `||`/`&&`/`;` tails, and backslash continuations.

# Look a constant up across all three shipped scripts, tolerating both
# FOO="bar" and FOO=bar. Fails (1) when the name is defined nowhere.
const_any() {
    local name="$1" v f
    for f in "$INSTALLER" "$UNINSTALLER" "$SETUP"; do
        [ -f "$f" ] || continue
        v=$(sed -n "s/^[[:space:]]*$name=\"\([^\"]*\)\".*/\1/p" "$f" | head -n1)
        [ -n "$v" ] || v=$(sed -n "s/^[[:space:]]*$name=\([^[:space:]\"';#]*\).*/\1/p" "$f" | head -n1)
        if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    done
    return 1
}

strip_quotes() {
    local t="$1"
    t="${t//\"/}"
    t="${t//\'/}"
    printf '%s' "$t"
}

# Expand $FOO / ${FOO} against those constants. Fails (1) on anything it
# cannot name — $(command), $1, ${x:-y} — because guessing there would be
# worse than saying "read this one by hand".
resolve_token() {
    local t="$1" name val guard=0
    while [ "${t#*\$}" != "$t" ]; do
        guard=$(( guard + 1 ))
        [ "$guard" -gt 8 ] && return 1
        if [[ "$t" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; then
            name="${BASH_REMATCH[1]}"
            val=$(const_any "$name") || return 1
            t="${t//\$\{$name\}/$val}"
        elif [[ "$t" =~ \$([A-Za-z_][A-Za-z0-9_]*) ]]; then
            name="${BASH_REMATCH[1]}"
            val=$(const_any "$name") || return 1
            t="${t//\$$name/$val}"
        else
            return 1
        fi
    done
    printf '%s' "$t"
}

# One shell command per line: backslash continuations joined (a chown whose
# targets wrap onto the next line is still ONE command), comment lines and
# trailing comments dropped, and `;` `&&` `||` `|` split so that the tail of
# `chown ... 2>/dev/null || true` is parsed as the separate `true` it is.
# Deliberately NOT split on braces — ${CONF_DIR} has to reach the resolver.
command_segments() {
    awk '
        function emit(l,   n, i, parts, p) {
            sub(/^[[:space:]]+/, "", l)
            if (l ~ /^#/) return
            sub(/[[:space:]]#.*$/, "", l)
            gsub(/&&|\||;/, "\n", l)
            n = split(l, parts, "\n")
            for (i = 1; i <= n; i++) {
                p = parts[i]
                sub(/^[[:space:]]+/, "", p)
                if (p != "") print p
            }
        }
        {
            line = buf $0
            buf = ""
            if (sub(/\\[[:space:]]*$/, " ", line)) { buf = line; next }
            emit(line)
        }
        END { if (buf != "") emit(buf) }
    ' "$1"
}

# Print every absolute path the named file hands to www-data, one per line as
# "T <file> <path>". Emits "U <file> <token>" for an operand the resolver
# could not expand: an unexpanded "$FOO" compared as a literal would sail past
# the containment test below while naming a directory that does contain the
# file, so the caller treats that as fatal rather than as an empty result.
wwwdata_chown_targets() {
    local file="$1"
    local seg cmd owner w n i j
    local -a words
    # Globbing off for the whole parse. Both word-splits below are deliberate,
    # and a target written as /etc/qmanager* has to reach the containment test
    # as the pattern it is rather than as whatever it happens to match in the
    # directory this harness was run from.
    set -f
    while IFS= read -r seg; do
        # shellcheck disable=SC2206
        words=($seg)
        n=${#words[@]}
        [ "$n" -gt 1 ] || continue

        i=0
        [ "${words[0]}" = "sudo" ] && i=1
        [ "$i" -lt "$n" ] || continue
        cmd="${words[$i]##*/}"       # /bin/chown and chown are one command
        case "$cmd" in
            chown|install) ;;
            *) continue ;;
        esac
        i=$(( i + 1 ))

        owner=""
        local targets=""
        if [ "$cmd" = "install" ]; then
            j=$i
            while [ "$j" -lt "$n" ]; do
                w="${words[$j]}"
                case "$w" in
                    -o|--owner)  j=$(( j + 1 )); owner="${words[$j]:-}" ;;
                    --owner=*)   owner="${w#--owner=}" ;;
                    # Flags that consume the next word — skip the argument too
                    # so a mode like 0700 is never mistaken for an operand.
                    -g|-m|-t|--group|--mode|--target-directory) j=$(( j + 1 )) ;;
                    -*) : ;;
                    *)  targets="$targets $w" ;;
                esac
                j=$(( j + 1 ))
            done
        else
            # chown has no option taking a SEPARATE argument — the long forms
            # (--reference=FILE, --from=OWNER) are '='-joined — so every '-'
            # token is a flag and the first operand after them is the owner
            # spec. That is what makes -R, -hR, -h -R and --recursive all fall
            # out for free instead of needing a list of flags to strip.
            j=$i
            while [ "$j" -lt "$n" ]; do
                case "${words[$j]}" in
                    --) j=$(( j + 1 )); break ;;
                    -*) j=$(( j + 1 )); continue ;;
                    *)  break ;;
                esac
            done
            [ "$j" -lt "$n" ] || continue
            owner="${words[$j]}"
            j=$(( j + 1 ))
            while [ "$j" -lt "$n" ]; do
                targets="$targets ${words[$j]}"
                j=$(( j + 1 ))
            done
        fi

        owner=$(strip_quotes "$owner")
        case "$owner" in
            *'$'*)
                if ! owner=$(resolve_token "$owner"); then
                    printf 'U %s %s\n' "$file" "$seg"
                    continue
                fi
                ;;
        esac
        case "$owner" in
            *www-data*) ;;
            *) continue ;;
        esac

        local rw
        for w in $targets; do
            w=$(strip_quotes "$w")
            case "$w" in
                *'$'*)
                    # Into a second variable: assigning the failed expansion
                    # back over $w would report an empty token and lose the
                    # one name that makes the failure actionable.
                    if ! rw=$(resolve_token "$w"); then
                        printf 'U %s %s\n' "$file" "$w"
                        continue
                    fi
                    w="$rw"
                    ;;
            esac
            # Trailing slashes would break the prefix comparison: "/etc/" is
            # not a prefix of "/etc/qmanager.env" as a string, but it is the
            # same directory.
            while [ "$w" != "/" ] && [ "${w%/}" != "$w" ]; do w="${w%/}"; done
            case "$w" in
                # Only absolute targets can contain an absolute env file.
                # Relative ones depend on a cwd nothing here ever sets.
                /*) printf 'T %s %s\n' "$file" "$w" ;;
            esac
        done
    done < <(command_segments "$file")
    set +f
}

printf '\n-- 3. the chown parser can still see the chowns --\n'

# A parser that silently extracts nothing turns every containment test below
# into a green check of an empty list. So the parser is tested first, against
# a fixture whose answer is known, covering every form a future edit might
# reasonably use. If this block fails, the containment result underneath it
# means nothing.
PARSE_FIX=$(mktemp -d)
trap 'rm -rf "$PARSE_FIX"' EXIT
cat > "$PARSE_FIX/fixture.sh" <<'PARSEFIX'
chown -R www-data:www-data /etc
chown --recursive www-data:www-data "/etc/quoted"
chown -hR www-data:www-data ${CONF_DIR}
chown -h -R www-data:www-data /etc/twoflags
chown -R www-data:www-data /etc/tail 2>/dev/null || true
sudo /bin/chown www-data:www-data '/etc/viasudo'
install -d -o www-data -g www-data -m 0700 /etc/installed
chown -R www-data:www-data /tmp/wrapped-a \
      /tmp/wrapped-b
chown root:root /etc/not-a-target
chown -R www-data:www-data /etc/trailing-slash/
# chown -R www-data:www-data /etc/commented
PARSEFIX

parse_got=$(wwwdata_chown_targets "$PARSE_FIX/fixture.sh" | sed -n 's/^T [^ ]* //p' | sort | tr '\n' ' ')
parse_want="/etc /etc/installed /etc/qmanager /etc/quoted /etc/tail /etc/trailing-slash /etc/twoflags /etc/viasudo /tmp/wrapped-a /tmp/wrapped-b "
if [ "$parse_got" = "$parse_want" ]; then
    pass "parser reads flags, quotes, \$VAR, sudo, install -d, continuations and command tails"
else
    printf '       want: %s\n' "$parse_want"
    printf '       got:  %s\n' "$parse_got"
    fail "the chown parser no longer extracts what it must — every containment check below is now vacuous"
fi
rm -rf "$PARSE_FIX"

printf '\n-- 4. the path is outside every www-data-owned directory --\n'

# Scan every script that runs as ROOT on the device, not just the three that
# happen to do it today: those are the only ones that can hand a path to
# www-data. CGI handlers are excluded on purpose — they already run AS
# www-data, so they have nothing to grant.
ownership_sources=$(
    {
        printf '%s\n%s\n%s\n' "$INSTALLER" "$UNINSTALLER" "$SETUP"
        for f in scripts/usr/bin/*; do
            [ -f "$f" ] || continue
            head -c 2 "$f" 2>/dev/null | grep -q '^#!' && printf '%s\n' "$f"
        done
        ls scripts/usr/lib/qmanager/*.sh 2>/dev/null || true
        ls scripts/etc/udev/scripts/*.sh 2>/dev/null || true
    } | sort -u
)

scan_out=$(for f in $ownership_sources; do wwwdata_chown_targets "$f"; done)

unresolved=$(printf '%s\n' "$scan_out" | grep '^U ' || true)
if [ -n "$unresolved" ]; then
    printf '%s\n' "$unresolved" | sed 's/^U /       /'
    fail "cannot resolve the above www-data chown operand(s) — check by hand"
else
    pass "resolved every www-data chown operand"
fi

resolved_dirs=$(printf '%s\n' "$scan_out" | sed -n 's/^T [^ ]* //p' | sort -u | tr '\n' ' ')

# Second anti-vacuity guard, this one against the real tree rather than a
# fixture: $CONF_DIR is chowned to www-data in both install_backend() and
# qmanager_setup, so if it is missing from the scan the scan is broken.
CONF_DIR_VAL=$(const_of "$INSTALLER" CONF_DIR)
case " $resolved_dirs " in
    *" $CONF_DIR_VAL "*) pass "scan found the known www-data chown of $CONF_DIR_VAL" ;;
    *) fail "scan did not find the www-data chown of $CONF_DIR_VAL — the scan is broken, not the tree" ;;
esac

containment_hits=0
for d in $resolved_dirs; do
    # Ancestor-or-self, not equality. `chown -R www-data:www-data /etc` makes
    # /etc/qmanager.env www-data-owned without the two paths being equal, and
    # even WITHOUT -R it makes /etc itself www-data-owned — which is write
    # access to the directory, which is unlink+create on every file in it.
    # Owning any ancestor is owning the file.
    case "$INSTALL_ENV" in
        "$d"|"$d"/*)
            fail "$INSTALL_ENV is at or under www-data-owned '$d' — this is the escalation, verbatim"
            containment_hits=$(( containment_hits + 1 ))
            continue
            ;;
    esac
    # A wildcard in the chown target matches paths the literal string does
    # not: /etc/qmanager* covers /etc/qmanager.env. Unquoted on purpose here
    # so the shell glob-matches; check 5 catches the same shape by text.
    case "$d" in
        *'*'*|*'?'*|*'['*)
            case "$INSTALL_ENV" in
                $d)
                    fail "$INSTALL_ENV is matched by the www-data chown glob '$d'"
                    containment_hits=$(( containment_hits + 1 ))
                    ;;
            esac
            ;;
    esac
done
if [ "$containment_hits" -eq 0 ]; then
    pass "$INSTALL_ENV is under none of: $resolved_dirs"
fi

# Belt and braces: name the specific directory this file was moved out of, so
# the regression is caught even if the chown that made it dangerous is ever
# refactored into a form the scan above does not recognise.
case "$INSTALL_ENV" in
    "$CONF_DIR_VAL"|"$CONF_DIR_VAL"/*)
        fail "$INSTALL_ENV is back inside CONF_DIR ($CONF_DIR_VAL)" ;;
    *)
        pass "not inside CONF_DIR ($CONF_DIR_VAL)" ;;
esac

printf '\n-- 5. no glob can sweep the sibling back into the chown --\n'

# A wildcard directly after the directory NAME — /etc/qmanager* or "$CONF_DIR"*
# — matches /etc/qmanager.env as well as /etc/qmanager. A wildcard after a
# slash (/etc/qmanager/*) cannot, and is left alone. Comment lines are skipped:
# the warnings that explain this rule name the pattern on purpose.
glob_hits=$(
    grep -rn -E '(/etc/qmanager|\$\{?CONF_DIR\}?)"?\*' scripts/ 2>/dev/null \
        | grep -v '^scripts/test/daemon-environment-path.sh:' \
        | awk -F: '{ line = $0; sub(/^[^:]*:[0-9]*:/, "", line); \
                     sub(/^[[:space:]]+/, "", line); \
                     if (line !~ /^#/) print $0 }'
)
if [ -n "$glob_hits" ]; then
    printf '%s\n' "$glob_hits" | sed 's/^/       /'
    fail "found a glob that matches the config dir NAME — it also matches $INSTALL_ENV"
else
    pass "no /etc/qmanager* or \$CONF_DIR* glob in executable code"
fi

printf '\n-- 6. the file is pinned root-owned and unreadable by others --\n'

# Ownership/mode is not what closes the hole (the directory does), but it is
# what stops a future accident inside a root-owned directory from being
# immediately exploitable, and it is the only thing protecting the quarantine
# and backup sidecars.
if grep -q 'chown root:root "\$DAEMON_ENV_FILE"' "$INSTALLER"; then
    pass "installer chowns root:root"
else
    fail "installer never chowns \$DAEMON_ENV_FILE to root:root"
fi
if grep -q 'chmod 600 "\$DAEMON_ENV_FILE"' "$INSTALLER"; then
    pass "installer chmods 600"
else
    fail "installer never chmods \$DAEMON_ENV_FILE to 600"
fi
if grep -q "chown root:root $INSTALL_ENV" "$SETUP" && grep -q "chmod 600 $INSTALL_ENV" "$SETUP"; then
    pass "qmanager_setup re-asserts root:root 0600 every boot"
else
    fail "qmanager_setup does not re-assert root:root 0600 on $INSTALL_ENV"
fi
if grep -E "chown.*www-data.*$(printf '%s' "$INSTALL_ENV" | sed 's/[.]/\\./g')" "$SETUP" "$INSTALLER" >/dev/null 2>&1; then
    fail "something chowns $INSTALL_ENV to www-data"
else
    pass "nothing chowns $INSTALL_ENV to www-data"
fi

printf '\n-- 7. the installer never READS the legacy path --\n'

# This is the invariant that replaced the migration. The old code copied the
# legacy file through a key allowlist; two adversarial passes broke it, the
# second by racing the several separate lookups that the guards and the read
# each had to perform. A POSIX shell cannot open a path once and then prove the
# thing it opened is the thing it checked, so the answer was to stop touching
# it: report_legacy_daemon_environment() reports and returns.
#
# Any of the verbs below reintroduces a root process dereferencing a path that
# www-data owns, which is the whole vulnerability.
fn=$(awk '/^report_legacy_daemon_environment\(\) \{$/,/^\}$/' "$INSTALLER")
if [ -z "$fn" ]; then
    fail "could not extract report_legacy_daemon_environment() from $INSTALLER"
else
    body=$(printf '%s' "$fn" | grep -v '^[[:space:]]*#')
    # Operator advice is printed, not executed, so the file verbs inside a
    # warn/info/logger string are text. A command substitution inside one is
    # NOT text, so that check keeps looking at the whole body.
    code=$(printf '%s' "$body" | grep -vE '^[[:space:]]*(warn|info|logger)\b' | grep -vE '^[[:space:]]*logger ')
    bad=""
    printf '%s' "$body" | grep -qE '<[[:space:]]*"?\$LEGACY_DAEMON_ENV_FILE' && bad="$bad read-redirect"
    printf '%s' "$code" | grep -qE '\b(cat|head|tail|grep|sed|awk|cp|mv|rm|install|chmod|chown|touch|stat)\b[^|]*\$LEGACY_DAEMON_ENV_FILE' && bad="$bad file-verb"
    printf '%s' "$body" | grep -qE '\$\([^)]*\$LEGACY_DAEMON_ENV_FILE' && bad="$bad command-substitution"
    if [ -n "$bad" ]; then
        fail "report_legacy_daemon_environment() touches the legacy path:$bad"
    else
        pass "the legacy path is only ever tested for existence, never opened or modified"
    fi
fi

printf '\n-- 8. uninstall --purge removes the new path --\n'

# rm -rf "$CONF_DIR" does not reach a sibling, so the file needs removing by
# name or --purge quietly stops meaning what its help text promises.
purge_block=$(sed -n '/^if \[ "\$PURGE" = "1" \]; then/,/^elif /p' "$UNINSTALLER")
if printf '%s' "$purge_block" | grep -q 'rm -f "\$DAEMON_ENV_FILE"'; then
    pass "--purge removes \$DAEMON_ENV_FILE"
else
    fail "--purge does not remove \$DAEMON_ENV_FILE"
fi

printf '\n-- 9. a hostile legacy path is reported, not dereferenced --\n'

# Behavioural counterpart to check 7: point the legacy path at a root-only
# secret and confirm the function neither reads it nor echoes it, and leaves
# the planted link exactly where it was so the operator can see the tampering.
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/etc/qmanager"
printf 'AUTH_TOKEN=s3cr3t\nDB_PASSWORD=hunter2\n' > "$FIX/secret"
chmod 600 "$FIX/secret"
ln -s "$FIX/secret" "$FIX/etc/qmanager/environment"

out=$(
    set +e
    LEGACY_DAEMON_ENV_FILE="$FIX/etc/qmanager/environment"
    DAEMON_ENV_FILE="$FIX/etc/qmanager.env"
    warn() { printf 'WARN %s\n' "$*"; }
    info() { printf 'INFO %s\n' "$*"; }
    eval "$(awk '/^report_legacy_daemon_environment\(\) \{$/,/^\}$/' "$INSTALLER")"
    report_legacy_daemon_environment
    printf 'RC=%s\n' "$?"
)

if printf '%s' "$out" | grep -qE 's3cr3t|hunter2|AUTH_TOKEN|DB_PASSWORD'; then
    fail "the secret behind the symlink leaked into the installer output"
else
    pass "nothing behind the symlink was read or echoed"
fi
if printf '%s' "$out" | grep -q 'RC=0'; then
    pass "returned 0 — a hostile legacy path does not abort the install"
else
    fail "did not return 0 on a hostile legacy path"
fi
if [ -h "$FIX/etc/qmanager/environment" ]; then
    pass "the planted symlink was left in place as evidence"
else
    fail "the planted symlink was removed or replaced"
fi
# The destination IS created unconditionally (empty, with a header comment) so
# an operator edits a file that is already root:root 0600. What must never
# happen is any byte of it coming from the source.
if [ -e "$FIX/etc/qmanager.env" ] && grep -qE 's3cr3t|hunter2|AUTH_TOKEN|DB_PASSWORD' "$FIX/etc/qmanager.env" 2>/dev/null; then
    fail "the destination file carries content from the hostile source"
else
    pass "the destination carries nothing from the hostile source"
fi

printf '\n'
if [ "$failures" -gt 0 ]; then
    printf '[daemon-environment-path] FAIL: %d check(s) failed\n\n' "$failures" >&2
    exit 1
fi
printf '[daemon-environment-path] PASS\n\n'
