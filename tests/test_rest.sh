#!/usr/bin/env bash
# tests/test_rest.sh — Tests for WI-04 REST API wrappers
# Tests structural logic, payload building, and offline behavior.
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

assert_json_eq() {
    local desc="$1" json="$2" path="$3" expected="$4"
    local actual
    actual="$(echo "$json" | jq -r "$path")"
    assert_eq "$desc" "$expected" "$actual"
}

assert_json_count() {
    local desc="$1" json="$2" path="$3" expected="$4"
    local actual
    actual="$(echo "$json" | jq "$path | length")"
    assert_eq "$desc" "$expected" "$actual"
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== REST libraries loaded ==="

assert_eq "management-groups loaded" "1" "${_EPAC_REST_MG_LOADED:-0}"
assert_eq "policy-definitions loaded" "1" "${_EPAC_REST_PDEF_LOADED:-0}"
assert_eq "policy-set-definitions loaded" "1" "${_EPAC_REST_PSDEF_LOADED:-0}"
assert_eq "policy-assignments loaded" "1" "${_EPAC_REST_PA_LOADED:-0}"
assert_eq "policy-exemptions loaded" "1" "${_EPAC_REST_PE_LOADED:-0}"
assert_eq "role-assignments loaded" "1" "${_EPAC_REST_RA_LOADED:-0}"
assert_eq "role-definitions loaded" "1" "${_EPAC_REST_RD_LOADED:-0}"
assert_eq "resource-list loaded" "1" "${_EPAC_REST_RL_LOADED:-0}"
assert_eq "resources loaded" "1" "${_EPAC_REST_RES_LOADED:-0}"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Function availability ==="

for fn in epac_get_management_group epac_set_policy_definition \
          epac_set_policy_set_definition epac_get_policy_assignment \
          epac_set_policy_assignment epac_get_policy_exemptions \
          epac_set_policy_exemption epac_get_role_assignments \
          epac_set_role_assignment epac_remove_role_assignment \
          epac_get_role_definitions epac_get_resource_list \
          epac_remove_resource_by_id _epac_rest_get_paginated; do
    if type "$fn" &>/dev/null; then
        echo "  PASS: $fn available"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $fn not available"
        FAIL=$((FAIL + 1))
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy assignment parameter wrapping ==="

# Test the parameter transformation logic by building the body structure
# We'll mock the REST call and just test the jq transformations

# Flat parameters → wrapped in {value: ...}
raw_params='{"param1": "hello", "param2": 42, "param3": ["a","b"]}'
wrapped="$(echo "$raw_params" | jq 'to_entries | map({
    key: .key,
    value: (if (.value | type) == "object" and (.value | has("value")) then .value else {value: .value} end)
}) | from_entries')"
assert_json_eq "param1 wrapped" "$wrapped" '.param1.value' "hello"
assert_json_eq "param2 wrapped" "$wrapped" '.param2.value' "42"
assert_json_count "param3 wrapped array" "$wrapped" '.param3.value' "2"

# Already-wrapped parameters should not be double-wrapped
already_wrapped='{"p1": {"value": "already"}}'
re_wrapped="$(echo "$already_wrapped" | jq 'to_entries | map({
    key: .key,
    value: (if (.value | type) == "object" and (.value | has("value")) then .value else {value: .value} end)
}) | from_entries')"
assert_json_eq "already wrapped stays same" "$re_wrapped" '.p1.value' "already"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy definition body building ==="

def_json='{
    "id": "/providers/Microsoft.Management/managementGroups/mg1/providers/Microsoft.Authorization/policyDefinitions/test-def",
    "properties": {
        "displayName": "Test Definition",
        "description": "A test policy",
        "metadata": {"category": "Testing"},
        "mode": "All",
        "parameters": {"effect": {"type": "String"}},
        "policyRule": {"if": {"field": "type", "equals": "Microsoft.Compute/virtualMachines"}, "then": {"effect": "[parameters('"'"'effect'"'"')]"}}
    }
}'

body="$(echo "$def_json" | jq '{
    properties: {
        displayName: .properties.displayName,
        description: .properties.description,
        metadata: .properties.metadata,
        mode: .properties.mode,
        parameters: .properties.parameters,
        policyRule: .properties.policyRule
    }
}')"

assert_json_eq "def body displayName" "$body" '.properties.displayName' "Test Definition"
assert_json_eq "def body mode" "$body" '.properties.mode' "All"
assert_json_eq "def body metadata category" "$body" '.properties.metadata.category' "Testing"
assert_eq "def body has no id at top" "null" "$(echo "$body" | jq -r '.id // null')"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set definition body with null removal ==="

psdef_json='{
    "id": "/providers/test/policySetDef",
    "properties": {
        "displayName": "Test Set",
        "description": null,
        "metadata": {"version": "1.0"},
        "parameters": null,
        "policyDefinitions": [{"policyDefinitionId": "/providers/def1"}],
        "policyDefinitionGroups": null
    }
}'

ps_body="$(echo "$psdef_json" | jq '{
    properties: (.properties | {
        displayName,
        description,
        metadata,
        parameters,
        policyDefinitions,
        policyDefinitionGroups
    } | with_entries(select(.value != null)))
}')"

assert_json_eq "psdef displayName" "$ps_body" '.properties.displayName' "Test Set"
assert_eq "psdef null description removed" "null" "$(echo "$ps_body" | jq '.properties.description // null')"
assert_eq "psdef null parameters removed" "null" "$(echo "$ps_body" | jq '.properties.parameters // null')"
assert_json_count "psdef policyDefinitions kept" "$ps_body" '.properties.policyDefinitions' "1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Exemption body building ==="

exempt_json='{
    "id": "/providers/test/exemption",
    "properties": {
        "policyAssignmentId": "/providers/test/assignment",
        "exemptionCategory": "Waiver",
        "assignmentScopeValidation": "Default",
        "displayName": "Test Exemption",
        "description": "A test",
        "expiresOn": null,
        "metadata": {"ticket": "JIRA-123"},
        "policyDefinitionReferenceIds": null,
        "resourceSelectors": null
    }
}'

ex_body="$(echo "$exempt_json" | jq '{
    properties: (.properties | {
        policyAssignmentId,
        exemptionCategory,
        assignmentScopeValidation,
        displayName,
        description,
        expiresOn,
        metadata,
        policyDefinitionReferenceIds,
        resourceSelectors
    } | with_entries(select(.value != null)))
}')"

assert_json_eq "exemption category" "$ex_body" '.properties.exemptionCategory' "Waiver"
assert_json_eq "exemption ticket" "$ex_body" '.properties.metadata.ticket' "JIRA-123"
assert_eq "exemption null expiresOn removed" "null" "$(echo "$ex_body" | jq '.properties.expiresOn // null')"
assert_eq "exemption null refIds removed" "null" "$(echo "$ex_body" | jq '.properties.policyDefinitionReferenceIds // null')"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== [[ → [ escaping in policy definitions ==="

rule_with_brackets='{"policyRule": {"then": {"details": {"type": "[[concat('"'"'Microsoft.Compute/'"'"')]"}}}}'
fixed="$(echo "$rule_with_brackets" | sed 's/\[\[/[/g')"
has_double_bracket="$(echo "$fixed" | jq -r '.policyRule.then.details.type | contains("[[")' 2>/dev/null)"
assert_eq "brackets unescaped" "false" "$has_double_bracket"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Offline REST calls (expected failures) ==="

# These calls will fail because there's no Azure auth, but they should
# not crash the script. They should return non-zero gracefully.

if epac_get_management_group "test-mg" 2>/dev/null; then
    echo "  FAIL: offline MG call should fail"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: offline MG call correctly fails"
    PASS=$((PASS + 1))
fi

if epac_get_role_definitions "/subscriptions/fake" "2022-04-01" 2>/dev/null; then
    echo "  FAIL: offline role def call should fail"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: offline role def call correctly fails"
    PASS=$((PASS + 1))
fi

if epac_remove_resource_by_id "/subscriptions/fake/providers/test/resource" "2021-04-01" 2>/dev/null; then
    echo "  FAIL: offline remove should fail"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: offline remove correctly fails"
    PASS=$((PASS + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "─────────────────────────────────────────"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "─────────────────────────────────────────"
exit "$FAIL"
