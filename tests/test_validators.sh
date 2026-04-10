#!/usr/bin/env bash
# tests/test_validators.sh — Tests for WI-07 lib/validators.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/epac.sh"
source "${SCRIPT_DIR}/../lib/validators.sh"

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

assert_true() {
    local desc="$1" actual="$2"
    assert_eq "$desc" "true" "$actual"
}

assert_false() {
    local desc="$1" actual="$2"
    assert_eq "$desc" "false" "$actual"
}

assert_rc() {
    local desc="$1" expected_rc="$2"
    shift 2
    set +e
    "$@" >/dev/null 2>/dev/null
    local rc=$?
    set -e
    assert_eq "$desc" "$expected_rc" "$rc"
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Module load check ==="
assert_eq "validators loaded" "1" "${_EPAC_VALIDATORS_LOADED}"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Function availability ==="
for fn in epac_deep_equal epac_confirm_metadata_matches \
          epac_confirm_effect_is_allowed \
          epac_confirm_parameters_definition_match \
          epac_confirm_parameters_usage_matches \
          epac_confirm_policy_definitions_parameters_match \
          epac_confirm_policy_definitions_match \
          epac_confirm_policy_definitions_in_set_match \
          epac_confirm_delete_for_strategy \
          epac_confirm_active_exemptions \
          epac_confirm_policy_definition_used_exists \
          epac_confirm_policy_set_definition_used_exists \
          epac_confirm_valid_policy_resource_name; do
    assert_true "function $fn exists" "$(declare -F "$fn" &>/dev/null && echo true || echo false)"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_deep_equal: primitives ==="
assert_rc "null == null" 0 epac_deep_equal "null" "null"
assert_rc "empty == null" 0 epac_deep_equal "" "null"
assert_rc "1 == 1" 0 epac_deep_equal "1" "1"
assert_rc "1 != 2" 1 epac_deep_equal "1" "2"
assert_rc "true == true" 0 epac_deep_equal "true" "true"
assert_rc "true != false" 1 epac_deep_equal "true" "false"
assert_rc '"hello" == "hello"' 0 epac_deep_equal '"hello"' '"hello"'
assert_rc '"hello" != "world"' 1 epac_deep_equal '"hello"' '"world"'

echo ""
echo "=== epac_deep_equal: null/empty equivalence ==="
assert_rc "null == empty array" 0 epac_deep_equal "null" "[]"
assert_rc "null == empty object" 0 epac_deep_equal "null" "{}"
assert_rc 'null == empty string' 0 epac_deep_equal "null" '""'
assert_rc "empty array == empty array" 0 epac_deep_equal "[]" "[]"

echo ""
echo "=== epac_deep_equal: arrays (order-independent) ==="
assert_rc "[1,2,3] == [1,2,3]" 0 epac_deep_equal '[1,2,3]' '[1,2,3]'
assert_rc "[1,2,3] == [3,1,2]" 0 epac_deep_equal '[1,2,3]' '[3,1,2]'
assert_rc "[1,2] != [1,3]" 1 epac_deep_equal '[1,2]' '[1,3]'
assert_rc "[1,2] != [1,2,3]" 1 epac_deep_equal '[1,2]' '[1,2,3]'
assert_rc "scalar coerced to array" 0 epac_deep_equal '1' '[1]'

echo ""
echo "=== epac_deep_equal: objects ==="
assert_rc '{"a":1} == {"a":1}' 0 epac_deep_equal '{"a":1}' '{"a":1}'
assert_rc '{"a":1,"b":2} == {"b":2,"a":1}' 0 epac_deep_equal '{"a":1,"b":2}' '{"b":2,"a":1}'
assert_rc '{"a":1} != {"a":2}' 1 epac_deep_equal '{"a":1}' '{"a":2}'
assert_rc '{"a":1} != {"b":1}' 1 epac_deep_equal '{"a":1}' '{"b":1}'

echo ""
echo "=== epac_deep_equal: nested ==="
assert_rc "nested equal" 0 epac_deep_equal '{"a":{"b":[1,2]}}' '{"a":{"b":[2,1]}}'
assert_rc "nested not equal" 1 epac_deep_equal '{"a":{"b":[1,2]}}' '{"a":{"b":[1,3]}}'

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_metadata_matches ==="

# Matching metadata (ignoring system fields)
existing_meta='{"pacOwnerId":"owner1","category":"Network","createdBy":"system","updatedOn":"2024-01-01"}'
defined_meta='{"pacOwnerId":"owner1","category":"Network"}'
result="$(epac_confirm_metadata_matches "$existing_meta" "$defined_meta")"
assert_json_eq "Matching metadata: match" "$result" '.match' 'true'
assert_json_eq "Matching metadata: no pacOwnerId change" "$result" '.changePacOwnerId' 'false'

# Metadata with different pacOwnerId
defined_meta2='{"pacOwnerId":"owner2","category":"Network"}'
result="$(epac_confirm_metadata_matches "$existing_meta" "$defined_meta2" "true" 2>/dev/null)"
assert_json_eq "PacOwnerId changed: match" "$result" '.match' 'true'
assert_json_eq "PacOwnerId changed: changePacOwnerId" "$result" '.changePacOwnerId' 'true'

# Non-matching metadata
defined_meta3='{"pacOwnerId":"owner1","category":"Security"}'
result="$(epac_confirm_metadata_matches "$existing_meta" "$defined_meta3")"
assert_json_eq "Non-matching metadata: match" "$result" '.match' 'false'

# Null existing metadata
result="$(epac_confirm_metadata_matches "null" "$defined_meta")"
assert_json_eq "Null existing: match=false" "$result" '.match' 'false'
assert_json_eq "Null existing: changePacOwnerId=true" "$result" '.changePacOwnerId' 'true'

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_effect_is_allowed ==="

result="$(epac_confirm_effect_is_allowed "deny" '["Deny","Audit","Disabled"]')"
assert_eq "Deny found (case-insensitive)" "Deny" "$result"

result="$(epac_confirm_effect_is_allowed "Audit" '["Deny","Audit","Disabled"]')"
assert_eq "Audit found" "Audit" "$result"

result="$(epac_confirm_effect_is_allowed "Modify" '["Deny","Audit","Disabled"]')"
assert_eq "Modify not found → empty" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_parameters_definition_match ==="

# Matching parameters
existing_params='{"effect":{"type":"String","defaultValue":"Audit","allowedValues":["Audit","Deny","Disabled"]}}'
defined_params='{"effect":{"type":"String","defaultValue":"Audit","allowedValues":["Audit","Deny","Disabled"]}}'
result="$(epac_confirm_parameters_definition_match "$existing_params" "$defined_params")"
assert_json_eq "Matching params: match" "$result" '.match' 'true'
assert_json_eq "Matching params: compatible" "$result" '.incompatible' 'false'

# Type change → incompatible
defined_params_type='{"effect":{"type":"Integer","defaultValue":"Audit","allowedValues":["Audit","Deny","Disabled"]}}'
result="$(epac_confirm_parameters_definition_match "$existing_params" "$defined_params_type")"
assert_json_eq "Type change: match" "$result" '.match' 'false'
assert_json_eq "Type change: incompatible" "$result" '.incompatible' 'true'

# Parameter removed → incompatible
result="$(epac_confirm_parameters_definition_match "$existing_params" "{}")"
assert_json_eq "Param removed: match" "$result" '.match' 'false'
assert_json_eq "Param removed: incompatible" "$result" '.incompatible' 'true'

# Parameter added with default → compatible
defined_params_added='{"effect":{"type":"String","defaultValue":"Audit","allowedValues":["Audit","Deny","Disabled"]},"location":{"type":"String","defaultValue":"eastus"}}'
result="$(epac_confirm_parameters_definition_match "$existing_params" "$defined_params_added")"
assert_json_eq "Param added with default: match" "$result" '.match' 'false'
assert_json_eq "Param added with default: compatible" "$result" '.incompatible' 'false'

# Parameter added without default → incompatible
defined_params_no_default='{"effect":{"type":"String","defaultValue":"Audit","allowedValues":["Audit","Deny","Disabled"]},"location":{"type":"String"}}'
result="$(epac_confirm_parameters_definition_match "$existing_params" "$defined_params_no_default")"
assert_json_eq "Param added no default: incompatible" "$result" '.incompatible' 'true'

# Both null
result="$(epac_confirm_parameters_definition_match "null" "null")"
assert_json_eq "Both null: match" "$result" '.match' 'true'

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_parameters_usage_matches ==="

# Matching values
assert_rc "Matching usage" 0 epac_confirm_parameters_usage_matches \
    '{"effect":{"value":"Deny"},"location":{"value":"eastus"}}' \
    '{"effect":{"value":"Deny"},"location":{"value":"eastus"}}'

# Different value
assert_rc "Different value" 1 epac_confirm_parameters_usage_matches \
    '{"effect":{"value":"Deny"}}' \
    '{"effect":{"value":"Audit"}}'

# Different count
assert_rc "Different param count" 1 epac_confirm_parameters_usage_matches \
    '{"effect":{"value":"Deny"}}' \
    '{"effect":{"value":"Deny"},"location":{"value":"eastus"}}'

# Both null
assert_rc "Both null usage" 0 epac_confirm_parameters_usage_matches "null" "null"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_policy_definitions_parameters_match ==="
assert_rc "Exact match" 0 epac_confirm_policy_definitions_parameters_match \
    '{"a":{"value":"x"},"b":{"value":"y"}}' \
    '{"a":{"value":"x"},"b":{"value":"y"}}'

assert_rc "Value differs" 1 epac_confirm_policy_definitions_parameters_match \
    '{"a":{"value":"x"}}' '{"a":{"value":"z"}}'

assert_rc "Key added" 1 epac_confirm_policy_definitions_parameters_match \
    '{"a":{"value":"x"}}' '{"a":{"value":"x"},"b":{"value":"y"}}'

assert_rc "Key removed" 1 epac_confirm_policy_definitions_parameters_match \
    '{"a":{"value":"x"},"b":{"value":"y"}}' '{"a":{"value":"x"}}'

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_policy_definitions_match ==="
pd1='[{"policyDefinitionReferenceId":"ref1","policyDefinitionId":"/p/d1","parameters":{},"groupNames":["g1"]},{"policyDefinitionReferenceId":"ref2","policyDefinitionId":"/p/d2","parameters":{},"groupNames":["g2"]}]'
pd2='[{"policyDefinitionReferenceId":"ref2","policyDefinitionId":"/p/d2","parameters":{},"groupNames":["g2"]},{"policyDefinitionReferenceId":"ref1","policyDefinitionId":"/p/d1","parameters":{},"groupNames":["g1"]}]'
assert_rc "Order-independent match" 0 epac_confirm_policy_definitions_match "$pd1" "$pd2"

pd3='[{"policyDefinitionReferenceId":"ref1","policyDefinitionId":"/p/d1","parameters":{},"groupNames":["g1"]}]'
assert_rc "Different count" 1 epac_confirm_policy_definitions_match "$pd1" "$pd3"

assert_rc "Both null" 0 epac_confirm_policy_definitions_match "null" "null"
assert_rc "null vs empty" 0 epac_confirm_policy_definitions_match "null" "[]"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_policy_definitions_in_set_match ==="
# Same as pd1 but order matters here
assert_rc "Same order match" 0 epac_confirm_policy_definitions_in_set_match "$pd1" "$pd1"

# Different ref at position 0
pd_diff='[{"policyDefinitionReferenceId":"ref99","policyDefinitionId":"/p/d1","parameters":{},"groupNames":["g1"]},{"policyDefinitionReferenceId":"ref2","policyDefinitionId":"/p/d2","parameters":{},"groupNames":["g2"]}]'
assert_rc "Different ref at pos 0" 1 epac_confirm_policy_definitions_in_set_match "$pd1" "$pd_diff"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_delete_for_strategy ==="

assert_rc "thisPaC → delete" 0 epac_confirm_delete_for_strategy "thisPaC" "full"
assert_rc "otherPaC → keep" 1 epac_confirm_delete_for_strategy "otherPaC" "full"
assert_rc "unknownOwner + full → delete" 0 epac_confirm_delete_for_strategy "unknownOwner" "full"
assert_rc "unknownOwner + ownedOnly → keep" 1 epac_confirm_delete_for_strategy "unknownOwner" "ownedOnly"
assert_rc "dfcSecurity + full → delete" 0 epac_confirm_delete_for_strategy "managedByDfcSecurityPolicies" "full" "false"
assert_rc "dfcSecurity + full + keep → keep" 1 epac_confirm_delete_for_strategy "managedByDfcSecurityPolicies" "full" "true"
assert_rc "dfcDefender + full → delete" 0 epac_confirm_delete_for_strategy "managedByDfcDefenderPlans" "full" "false" "false"
assert_rc "dfcDefender + full + keep → keep" 1 epac_confirm_delete_for_strategy "managedByDfcDefenderPlans" "full" "false" "true"
assert_rc "microsoft → keep" 1 epac_confirm_delete_for_strategy "microsoft" "full"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_active_exemptions ==="

now_plus_30="$(date -d '+30 days' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -v+30d '+%Y-%m-%dT%H:%M:%SZ')"
now_minus_5="$(date -d '-5 days' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -v-5d '+%Y-%m-%dT%H:%M:%SZ')"

exemptions="$(jq -n \
    --arg exp_future "$now_plus_30" \
    --arg exp_past "$now_minus_5" \
    '{
        "/ex/active": {
            "name": "active-ex",
            "displayName": "Active Exemption",
            "description": "still valid",
            "exemptionCategory": "Waiver",
            "expiresOn": $exp_future,
            "scope": "/subscriptions/sub1",
            "policyAssignmentId": "/assign/a1",
            "policyDefinitionReferenceIds": null,
            "metadata": {}
        },
        "/ex/expired": {
            "name": "expired-ex",
            "displayName": "Expired Exemption",
            "description": "expired",
            "exemptionCategory": "Mitigated",
            "expiresOn": $exp_past,
            "scope": "/subscriptions/sub1",
            "policyAssignmentId": "/assign/a1",
            "policyDefinitionReferenceIds": null,
            "metadata": {}
        },
        "/ex/orphaned": {
            "name": "orphaned-ex",
            "displayName": "Orphaned Exemption",
            "description": "no assignment",
            "exemptionCategory": "Waiver",
            "scope": "/subscriptions/sub1",
            "policyAssignmentId": "/assign/nonexistent",
            "policyDefinitionReferenceIds": null,
            "metadata": {}
        }
    }')"

assignments='{ "/assign/a1": {"id": "/assign/a1"} }'

result="$(epac_confirm_active_exemptions "$exemptions" "$assignments")"
assert_json_eq "All exemptions count" "$result" '.all | length' '3'
assert_json_eq "Active count" "$result" '.active | length' '1'
assert_json_eq "Expired count" "$result" '.expired | length' '1'
assert_json_eq "Orphaned count" "$result" '.orphaned | length' '1'
assert_json_eq "Active status" "$result" '.active["/ex/active"].status' 'active'
assert_json_eq "Expired status" "$result" '.expired["/ex/expired"].status' 'expired'
assert_json_eq "Orphaned status" "$result" '.orphaned["/ex/orphaned"].status' 'orphaned'

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_policy_definition_used_exists ==="

all_defs='{ "/subscriptions/sub1/providers/Microsoft.Authorization/policyDefinitions/my-policy": {}, "/providers/Microsoft.Authorization/policyDefinitions/builtin-policy": {} }'
scopes='["/subscriptions/sub1", "/providers/Microsoft.Management/managementGroups/mg1"]'

# By ID
result="$(epac_confirm_policy_definition_used_exists "/providers/Microsoft.Authorization/policyDefinitions/builtin-policy" "" "$scopes" "$all_defs" 2>/dev/null)"
assert_eq "Find by ID" "/providers/Microsoft.Authorization/policyDefinitions/builtin-policy" "$result"

# By name across scopes
result="$(epac_confirm_policy_definition_used_exists "" "my-policy" "$scopes" "$all_defs" 2>/dev/null)"
assert_eq "Find by name" "/subscriptions/sub1/providers/Microsoft.Authorization/policyDefinitions/my-policy" "$result"

# Not found
set +e
result="$(epac_confirm_policy_definition_used_exists "" "nonexistent" "$scopes" "$all_defs" "true" 2>/dev/null)"
rc=$?
set -e
assert_eq "Not found → exit code 1" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_policy_set_definition_used_exists ==="

all_set_defs='{ "/subscriptions/sub1/providers/Microsoft.Authorization/policySetDefinitions/my-set": {} }'

result="$(epac_confirm_policy_set_definition_used_exists "/subscriptions/sub1/providers/Microsoft.Authorization/policySetDefinitions/my-set" "" "$scopes" "$all_set_defs" 2>/dev/null)"
assert_eq "Find set by ID" "/subscriptions/sub1/providers/Microsoft.Authorization/policySetDefinitions/my-set" "$result"

result="$(epac_confirm_policy_set_definition_used_exists "" "my-set" "$scopes" "$all_set_defs" 2>/dev/null)"
assert_eq "Find set by name" "/subscriptions/sub1/providers/Microsoft.Authorization/policySetDefinitions/my-set" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_confirm_valid_policy_resource_name ==="
assert_rc "Valid name" 0 epac_confirm_valid_policy_resource_name "my-policy-name_v1.0"
assert_rc "Invalid: contains <" 1 epac_confirm_valid_policy_resource_name "my<policy"
assert_rc "Invalid: contains >" 1 epac_confirm_valid_policy_resource_name "my>policy"
assert_rc "Invalid: contains *" 1 epac_confirm_valid_policy_resource_name "my*policy"
assert_rc "Invalid: contains %" 1 epac_confirm_valid_policy_resource_name "my%policy"
assert_rc "Invalid: contains &" 1 epac_confirm_valid_policy_resource_name "my&policy"
assert_rc "Invalid: contains :" 1 epac_confirm_valid_policy_resource_name "my:policy"
assert_rc "Invalid: contains ?" 1 epac_confirm_valid_policy_resource_name "my?policy"
assert_rc "Invalid: contains +" 1 epac_confirm_valid_policy_resource_name "my+policy"
assert_rc "Invalid: contains /" 1 epac_confirm_valid_policy_resource_name "my/policy"
assert_rc "Invalid: contains \\" 1 epac_confirm_valid_policy_resource_name 'my\policy'
assert_rc "Invalid: trailing space" 1 epac_confirm_valid_policy_resource_name "my-policy "
assert_rc "Valid: hyphens/underscores/dots" 0 epac_confirm_valid_policy_resource_name "my-policy_v1.0(test)"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (total: $((PASS + FAIL)))"
echo "════════════════════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]] || exit 1
