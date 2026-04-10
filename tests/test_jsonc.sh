#!/usr/bin/env bash
# tests/test_jsonc.sh — Test JSONC (JSON with comments) parsing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/epac.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected='$expected', got='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== JSONC parsing ==="

# Create a JSONC test file
tmpfile=$(mktemp /tmp/test-jsonc.XXXXXX.jsonc)
cat > "$tmpfile" << 'EOF'
{
    // This is a comment
    "name": "test-policy",
    "description": "A test policy", // inline comment
    "parameters": {
        "effect": {
            "type": "String",
            "defaultValue": "Audit"
        }
    }
}
EOF

result=$(epac_read_jsonc "$tmpfile")
assert_eq "JSONC name" "test-policy" "$(echo "$result" | jq -r '.name')"
assert_eq "JSONC description" "A test policy" "$(echo "$result" | jq -r '.description')"
assert_eq "JSONC nested" "Audit" "$(echo "$result" | jq -r '.parameters.effect.defaultValue')"

rm -f "$tmpfile"

# Test with existing EPAC schema file
if [[ -f "${SCRIPT_DIR}/../Schemas/global-settings-schema.json" ]]; then
    schema=$(epac_read_json "${SCRIPT_DIR}/../Schemas/global-settings-schema.json")
    schema_type=$(echo "$schema" | jq -r '.type // empty')
    assert_eq "Real schema readable" "object" "$schema_type"
fi

echo ""
echo "═══════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
