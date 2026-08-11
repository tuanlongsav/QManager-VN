#!/bin/bash
# Manual fixture: verify the qmanager_health_check redaction patterns mask
# every secret type. Run from a workstation, not the device.
#
#   bash scripts/test/health-check-redaction.sh
set -eu

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/msmtprc" <<'EOF'
host smtp.example.com
user alice@example.com
password supersecret123
EOF

cat > "$work/log.log" <<'EOF'
2026-05-04 10:00:00 GET /api?key=tskey-auth-AbCdEfGhIjKlMnOpQrSt /
Cookie: session=abcdef1234567890
Authorization: Bearer eyJhbGciOiJIUzI1NiJ9
EOF

# Run the same sed expressions used in qmanager_health_check::_redact_tree.
#
# The production script edits in place with `sed -i`, which is fine on the
# modem (GNU/BusyBox sed). This fixture is documented to run on a workstation,
# and BSD sed on macOS reads the argument after -i as a mandatory backup
# suffix — `sed -i -e ...` there consumes "-e" as the suffix and dies. Write to
# a temp file and move it back instead: portable on both seds, while the
# redaction expressions stay byte-identical to the production ones.
#
# The glob expands once, before the loop body runs, so the .redacted temp files
# created below are never picked up as inputs.
for f in "$work"/*; do
    [ -f "$f" ] || continue
    sed \
        -e 's/^\([[:space:]]*password[[:space:]]\).*/\1REDACTED/' \
        -e 's/tskey-[A-Za-z0-9_-]\{20,\}/tskey-REDACTED/g' \
        -e 's/\(Cookie:[[:space:]]\).*/\1REDACTED/I' \
        -e 's/\(Authorization:[[:space:]]\).*/\1REDACTED/I' \
        "$f" > "$f.redacted" && mv "$f.redacted" "$f"
done

fail=0
grep -q 'supersecret123'                "$work/msmtprc" && { echo "FAIL: msmtprc password leaked"; fail=1; }
grep -q 'tskey-auth-AbCdEf'             "$work/log.log" && { echo "FAIL: tskey leaked";           fail=1; }
grep -q 'session=abcdef1234567890'      "$work/log.log" && { echo "FAIL: cookie leaked";          fail=1; }
grep -q 'eyJhbGciOiJIUzI1NiJ9'          "$work/log.log" && { echo "FAIL: bearer leaked";          fail=1; }
grep -q 'password REDACTED'             "$work/msmtprc" || { echo "FAIL: msmtprc not redacted";   fail=1; }
grep -q 'tskey-REDACTED'                "$work/log.log" || { echo "FAIL: tskey not redacted";     fail=1; }
grep -q 'Cookie: REDACTED'              "$work/log.log" || { echo "FAIL: cookie not redacted";    fail=1; }
grep -q 'Authorization: REDACTED'       "$work/log.log" || { echo "FAIL: auth not redacted";      fail=1; }

if [ "$fail" = "0" ]; then echo "OK: all redactions applied"; exit 0
else echo "redaction fixture failed"; exit 1; fi
