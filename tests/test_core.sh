#!/usr/bin/env bash
# tests/test_core.sh — Functional tests for WI-01 core utilities
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

assert_true() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected true)"
        FAIL=$((FAIL + 1))
    fi
}

assert_false() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then
        echo "  FAIL: $desc (expected false)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== lib/core.sh ==="

# GUID
guid=$(epac_generate_guid)
assert_true "Generate valid GUID" epac_is_guid "$guid"
assert_false "Reject non-GUID" epac_is_guid "not-a-guid"
assert_true "Accept uppercase GUID" epac_is_guid "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"

# Semver
assert_eq "Semver less" "-1" "$(epac_compare_semver "1.2.3" "1.2.4")"
assert_eq "Semver greater" "1" "$(epac_compare_semver "2.0.0" "1.9.9")"
assert_eq "Semver equal" "0" "$(epac_compare_semver "1.0.0" "1.0.0")"
assert_eq "Semver with v prefix" "0" "$(epac_compare_semver "v1.2.3" "1.2.3")"

# Error info
ei=$(epac_new_error_info "test-file.json")
epac_add_error "$ei" -1 "Something went wrong"
epac_add_error "$ei" 3 "Error at entry 3"
assert_eq "Error count" "2" "$(epac_error_count "$ei")"
assert_true "Has errors" epac_has_errors "$ei"
epac_cleanup_error_info "$ei"

# CI/CD detection
assert_false "Not CI/CD in test" epac_is_cicd

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== lib/json.sh ==="

# Construction
obj=$(epac_json_object)
obj=$(epac_json_set_str "$obj" ".name" "test-policy")
obj=$(epac_json_set "$obj" ".enabled" "true")
obj=$(epac_json_set "$obj" ".count" "42")
assert_eq "JSON get string" "test-policy" "$(epac_json_get "$obj" ".name")"
assert_eq "JSON get bool" "true" "$(epac_json_get "$obj" ".enabled")"
assert_eq "JSON get number" "42" "$(epac_json_get "$obj" ".count")"

# Has
assert_true "Has existing key" epac_json_has "$obj" ".name"
assert_false "Missing key" epac_json_has "$obj" ".missing"

# Type
assert_eq "Type object" "object" "$(epac_json_type "$obj")"
assert_eq "Type string" "string" "$(epac_json_type '"hello"')"
assert_eq "Type array" "array" "$(epac_json_type '[1,2]')"

# Length
assert_eq "Object length" "3" "$(epac_json_length "$obj")"
assert_eq "Array length" "3" "$(epac_json_length '[1,2,3]')"

# Deep merge
base='{"a": 1, "b": {"c": 2, "d": 3}}'
overlay='{"b": {"c": 99, "e": 5}, "f": 6}'
merged=$(epac_deep_merge "$base" "$overlay")
assert_eq "Merge override" "99" "$(epac_json_get "$merged" ".b.c")"
assert_eq "Merge keep" "3" "$(epac_json_get "$merged" ".b.d")"
assert_eq "Merge add nested" "5" "$(epac_json_get "$merged" ".b.e")"
assert_eq "Merge add top" "6" "$(epac_json_get "$merged" ".f")"

# Remove nulls
with_nulls='{"a": 1, "b": null, "c": {"d": null, "e": 2}}'
cleaned=$(epac_remove_null_fields "$with_nulls")
assert_false "Null removed" epac_json_has "$cleaned" ".b"
assert_false "Nested null removed" epac_json_has "$cleaned" ".c.d"
assert_eq "Non-null kept" "2" "$(epac_json_get "$cleaned" ".c.e")"

# Null/empty checks
assert_true "Empty string is null_or_empty" epac_is_null_or_empty ""
assert_true "null is null_or_empty" epac_is_null_or_empty "null"
assert_true "[] is null_or_empty" epac_is_null_or_empty "[]"
assert_true "{} is null_or_empty" epac_is_null_or_empty "{}"
assert_false "Non-empty string" epac_is_null_or_empty '"hello"'
assert_false "Non-empty array" epac_is_null_or_empty '[1]'

# Equality
assert_true "Equal objects (different order)" epac_json_equal '{"a":1,"b":2}' '{"b":2,"a":1}'
assert_false "Different objects" epac_json_equal '{"a":1}' '{"a":2}'

# Delete
obj2=$(epac_json_delete "$obj" ".enabled")
assert_false "Deleted key gone" epac_json_has "$obj2" ".enabled"
assert_true "Other key still there" epac_json_has "$obj2" ".name"

# Append to array
arr=$(epac_json_array)
arr=$(epac_json_append "$arr" "." '"item1"')
arr=$(epac_json_append "$arr" "." '"item2"')
assert_eq "Array length after append" "2" "$(epac_json_length "$arr")"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== lib/utils.sh ==="

# String scrubbing
assert_eq "Trim" "hello" "$(epac_scrub_string "  hello  " -t)"
assert_eq "Lowercase" "hello" "$(epac_scrub_string "HELLO" -l)"
assert_eq "Replace spaces" "hello-world" "$(epac_scrub_string "hello world" -s -S "-")"
assert_eq "Max length" "hel" "$(epac_scrub_string "hello" -m 3)"
assert_eq "Combined" "hello-world" "$(epac_scrub_string "  Hello World  " -t -l -s -S "-")"

# Scope ID parsing
scope_mg=$(epac_split_scope_id "/providers/Microsoft.Management/managementGroups/myMG")
assert_eq "MG scope type" "managementGroup" "$(epac_json_get "$scope_mg" ".type")"
assert_eq "MG name" "myMG" "$(epac_json_get "$scope_mg" ".managementGroupName")"

scope_sub=$(epac_split_scope_id "/subscriptions/11111111-2222-3333-4444-555555555555")
assert_eq "Sub scope type" "subscription" "$(epac_json_get "$scope_sub" ".type")"
assert_eq "Sub ID" "11111111-2222-3333-4444-555555555555" "$(epac_json_get "$scope_sub" ".subscriptionId")"

scope_rg=$(epac_split_scope_id "/subscriptions/sub-id/resourceGroups/myRG")
assert_eq "RG scope type" "resourceGroup" "$(epac_json_get "$scope_rg" ".type")"
assert_eq "RG name" "myRG" "$(epac_json_get "$scope_rg" ".resourceGroupName")"

# Policy resource ID parsing
res=$(epac_split_policy_resource_id "/subscriptions/sub-id/providers/Microsoft.Authorization/policyDefinitions/myDef")
assert_eq "Policy def type" "policyDefinitions" "$(epac_json_get "$res" ".resourceType")"
assert_eq "Policy def name" "myDef" "$(epac_json_get "$res" ".name")"

# Parameter name extraction
assert_eq "Parameter name" "myParam" "$(epac_get_parameter_name "[parameters('myParam')]")"
assert_eq "No parameter" "" "$(epac_get_parameter_name "plain-value")"

# Math helpers
assert_eq "Ceil div 10/3" "4" "$(epac_ceil_div 10 3)"
assert_eq "Min 3,5" "3" "$(epac_min 3 5)"
assert_eq "Max 3,5" "5" "$(epac_max 3 5)"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== lib/output.sh ==="

# Theme loading (should get default theme)
theme=$(epac_get_theme)
assert_eq "Theme has name" "Default Modern Theme" "$(epac_json_get "$theme" ".name")"
assert_eq "Theme header char" "┏" "$(epac_json_get "$theme" ".characters.header.topLeft")"

# Header output (just ensure it doesn't crash)
epac_write_header "Test Header" "Test Subtitle" > /dev/null 2>&1
echo "  PASS: Write header without crash"
PASS=$((PASS + 1))

# Section output
epac_write_section "Test Section" 0 > /dev/null 2>&1
echo "  PASS: Write section without crash"
PASS=$((PASS + 1))

# Status output
epac_write_status "Test message" "success" 2 > /dev/null 2>&1
echo "  PASS: Write status without crash"
PASS=$((PASS + 1))

# Progress output
epac_write_progress 5 10 "Testing" 0 > /dev/null 2>&1
echo "  PASS: Write progress without crash"
PASS=$((PASS + 1))

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
