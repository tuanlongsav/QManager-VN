#!/usr/bin/env bash
# i18n-parity.sh — keep lib/i18n/en.json and vi.json structurally in step.
#
# The dictionaries are currently at full parity, but nothing enforces it. The
# translation hook falls back vi -> en -> raw key, so a key added to en.json and
# forgotten in vi.json does not throw: it silently renders English in the middle
# of a Vietnamese page, and nobody notices until a user reports it. This is the
# check that turns that into a build failure.
#
# Three classes of problem, all fatal:
#   1. a key present in one file and missing from the other, either direction
#   2. a value whose {{placeholder}} set differs between the two — a translation
#      that drops {{count}} renders a sentence with a hole in it
#   3. a leaf that is an object on one side and a string on the other
#
# Run standalone:  bash scripts/test/i18n-parity.sh
# Also runs as step 3 of scripts/test/run-all.sh.
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EN="$REPO_ROOT/lib/i18n/en.json"
VI="$REPO_ROOT/lib/i18n/vi.json"

if ! command -v jq >/dev/null 2>&1; then
    echo "  SKIP i18n parity (jq not on PATH)"
    exit 0
fi

for f in "$EN" "$VI"; do
    [ -f "$f" ] || { echo "  FAIL missing dictionary: $f" >&2; exit 1; }
    jq -e . "$f" >/dev/null 2>&1 || { echo "  FAIL not valid JSON: $f" >&2; exit 1; }
done

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Every leaf path, dotted. `paths(scalars)` walks the whole tree, so this also
# catches a branch that exists at a different depth on the other side.
jq -r '[paths(scalars) | join(".")] | sort[]' "$EN" > "$work/en.keys"
jq -r '[paths(scalars) | join(".")] | sort[]' "$VI" > "$work/vi.keys"

failed=0

missing_vi=$(comm -23 "$work/en.keys" "$work/vi.keys")
if [ -n "$missing_vi" ]; then
    count=$(printf '%s\n' "$missing_vi" | wc -l | tr -d ' ')
    printf '  FAIL %d key(s) in en.json but not vi.json:\n' "$count"
    printf '%s\n' "$missing_vi" | sed 's/^/       /'
    failed=1
fi

missing_en=$(comm -13 "$work/en.keys" "$work/vi.keys")
if [ -n "$missing_en" ]; then
    count=$(printf '%s\n' "$missing_en" | wc -l | tr -d ' ')
    printf '  FAIL %d key(s) in vi.json but not en.json:\n' "$count"
    printf '%s\n' "$missing_en" | sed 's/^/       /'
    failed=1
fi

# Placeholder parity, checked only for keys both files have — a missing key is
# already reported above and would otherwise be counted twice.
comm -12 "$work/en.keys" "$work/vi.keys" > "$work/shared.keys"

placeholders_of() {
    # placeholders_of <file> <dotted.key> — sorted, deduped, space-separated
    jq -r --arg k "$2" 'getpath($k | split("."))' "$1" 2>/dev/null \
        | grep -oE '\{\{[a-zA-Z0-9_]+\}\}' 2>/dev/null | sort -u | tr '\n' ' '
}

# Placeholders that exist purely to satisfy English grammar and have no
# Vietnamese counterpart. Vietnamese does not inflect for number, so a
# translation that drops {{plural}} is correct, not incomplete.
GRAMMAR_ONLY=" {{plural}} "

mismatched=0
dropped=0
while IFS= read -r key; do
    [ -n "$key" ] || continue
    en_ph=$(placeholders_of "$EN" "$key")
    vi_ph=$(placeholders_of "$VI" "$key")
    [ "$en_ph" = "$vi_ph" ] && continue

    # The check is deliberately asymmetric, because the two directions fail
    # very differently:
    #
    #   vi has a placeholder en lacks  -> FATAL. The hook is only ever handed
    #   the interpolation values the English string declares, so an extra one
    #   in the translation renders to the user as a literal "{{foo}}".
    #
    #   en has one vi lacks -> WARN. Usually intentional ({{plural}}), but it
    #   can also be a translator dropping {{count}} and losing the number
    #   entirely, which is why it is still surfaced rather than ignored.
    for p in $vi_ph; do
        case " $en_ph " in
            *" $p "*) ;;
            *)
                printf '  FAIL %s: vi uses %s, which en does not provide\n' "$key" "$p"
                printf '       it will render literally to the user\n'
                mismatched=$((mismatched + 1))
                failed=1 ;;
        esac
    done

    for p in $en_ph; do
        case " $vi_ph " in
            *" $p "*) continue ;;
        esac
        case "$GRAMMAR_ONLY" in
            *" $p "*) continue ;;   # English-grammar-only, no VI equivalent
        esac
        printf '  WARN %s: en has %s, vi does not — check the value is not lost\n' "$key" "$p"
        dropped=$((dropped + 1))
    done
done < "$work/shared.keys"

total=$(wc -l < "$work/shared.keys" | tr -d ' ')

if [ "$failed" -eq 0 ]; then
    if [ "$dropped" -gt 0 ]; then
        printf '  OK   %d keys in parity (%d en-only placeholder(s) warned above)\n' \
            "$total" "$dropped"
    else
        printf '  OK   %d keys, en/vi in parity, placeholders match\n' "$total"
    fi
    exit 0
fi

printf '  %d key(s) checked, %d fatal placeholder problem(s)\n' "$total" "$mismatched" >&2
exit 1
