#!/usr/bin/env bash
# tests/test_assignment_plans.sh — Tests for assignment plan building
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source all libraries
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

assert_json_eq() {
    local desc="$1" json="$2" query="$3" expected="$4"
    local actual
    actual="$(echo "$json" | jq -r "$query" 2>/dev/null)" || actual="ERROR"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected='$expected', got='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_rc() {
    local desc="$1" expected_rc="$2"; shift 2
    local rc=0
    "$@" 2>/dev/null || rc=$?
    if [[ "$rc" -eq "$expected_rc" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected rc=$expected_rc, got rc=$rc)"
        FAIL=$((FAIL + 1))
    fi
}

###############################################################################
# Test fixtures
###############################################################################

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

write_assignment_file() {
    local dir="$1" name="$2" content="$3"
    mkdir -p "$dir"
    echo "$content" > "${dir}/${name}"
}

ROOT_SCOPE="/providers/Microsoft.Management/managementGroups/root"
SUB_SCOPE="/subscriptions/00000000-0000-0000-0000-000000000001"
POLICY_ID="${ROOT_SCOPE}/providers/Microsoft.Authorization/policyDefinitions/test-policy"
POLICY_SET_ID="${ROOT_SCOPE}/providers/Microsoft.Authorization/policySetDefinitions/test-policy-set"

PAC_ENV='{
    "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/root",
    "pacOwnerId": "pac-owner-1",
    "pacSelector": "epac-dev",
    "deployedBy": "epac-test",
    "cloud": "AzureCloud",
    "policyDefinitionsScopes": ["/providers/Microsoft.Management/managementGroups/root"],
    "desiredState": {
        "strategy": "full",
        "keepDfcSecurityAssignments": false
    }
}'

SCOPE_TABLE="$(jq -n --arg sub "$SUB_SCOPE" --arg root "$ROOT_SCOPE" '{
    ($sub): {scope: $sub, notScopesList: []},
    ($root): {scope: $root, notScopesList: []}
}')"

ALL_POLICY_DEFS="$(jq -n --arg id "$POLICY_ID" '{
    ($id): {
        id: $id,
        name: "test-policy",
        properties: {
            displayName: "Test Policy",
            parameters: {
                effect: {type: "String", defaultValue: "Audit", allowedValues: ["Audit","Deny","Disabled"]}
            },
            policyRule: {
                "if": {field: "type", equals: "Microsoft.Compute/virtualMachines"},
                "then": {effect: "[parameters(\"effect\")]"}
            }
        }
    }
}')"

ALL_POLICY_SET_DEFS="$(jq -n --arg id "$POLICY_SET_ID" --arg pid "$POLICY_ID" '{
    ($id): {
        id: $id,
        name: "test-policy-set",
        properties: {
            displayName: "Test Policy Set",
            parameters: {
                effect: {type: "String", defaultValue: "Audit"}
            },
            policyDefinitions: [
                {policyDefinitionId: $pid, policyDefinitionReferenceId: "testRef", parameters: {effect: {value: "[parameters(\"effect\")]"}}}
            ]
        }
    }
}')"

COMBINED_DETAILS='{
    "policies": {},
    "policySets": {}
}'

EMPTY_DEPLOYED='{"managed": {}, "readOnly": {}}'
EMPTY_REPLACE='{}'
EMPTY_ROLE_IDS='{}'
EMPTY_ROLE_DEFS='{}'
EMPTY_ROLE_ASSIGN_BY_PRINCIPAL='{}'

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Function availability ==="

assert_eq "epac_build_assignment_plan available" "function" \
    "$(type -t epac_build_assignment_plan 2>/dev/null || echo missing)"
assert_eq "_epac_build_assignment_definition_node available" "function" \
    "$(type -t _epac_build_assignment_definition_node 2>/dev/null || echo missing)"
assert_eq "_epac_build_assignment_definition_at_leaf available" "function" \
    "$(type -t _epac_build_assignment_definition_at_leaf 2>/dev/null || echo missing)"
assert_eq "_epac_build_assignment_definition_entry available" "function" \
    "$(type -t _epac_build_assignment_definition_entry 2>/dev/null || echo missing)"
assert_eq "_epac_build_assignment_parameter_object available" "function" \
    "$(type -t _epac_build_assignment_parameter_object 2>/dev/null || echo missing)"
assert_eq "_epac_build_assignment_identity_changes available" "function" \
    "$(type -t _epac_build_assignment_identity_changes 2>/dev/null || echo missing)"
assert_eq "_epac_add_selected_pac_value available" "function" \
    "$(type -t _epac_add_selected_pac_value 2>/dev/null || echo missing)"
assert_eq "_epac_add_selected_pac_array available" "function" \
    "$(type -t _epac_add_selected_pac_array 2>/dev/null || echo missing)"
assert_eq "_epac_merge_assignment_parameters_ex available" "function" \
    "$(type -t _epac_merge_assignment_parameters_ex 2>/dev/null || echo missing)"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Pac-selected value tests ==="

# Direct string
result="$(_epac_add_selected_pac_value '"eastus"' "epac-dev")"
assert_eq "pac value: direct string" '"eastus"' "$result"

# Pac-selector keyed object
result="$(_epac_add_selected_pac_value '{"epac-dev":"eastus","epac-prod":"westus"}' "epac-dev")"
assert_eq "pac value: selector match" '"eastus"' "$result"

# Wildcard
result="$(_epac_add_selected_pac_value '{"*":"centralus"}' "epac-dev")"
assert_eq "pac value: wildcard" '"centralus"' "$result"

# Null input
result="$(_epac_add_selected_pac_value 'null' "epac-dev")"
assert_eq "pac value: null" "null" "$result"

# No match — returns object as-is
result="$(_epac_add_selected_pac_value '{"other-env":"eastus"}' "epac-dev")"
assert_json_eq "pac value: no match returns object" "$result" '.["other-env"]' "eastus"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Pac-selected array tests ==="

# Direct array
result="$(_epac_add_selected_pac_array '["existing"]' '["new1","new2"]' "epac-dev")"
assert_json_eq "pac array: direct array length" "$result" 'length' "3"

# Pac-selector keyed
result="$(_epac_add_selected_pac_array '[]' '{"epac-dev":["a","b"],"epac-prod":["c"]}' "epac-dev")"
assert_json_eq "pac array: selector match length" "$result" 'length' "2"
assert_json_eq "pac array: selector match [0]" "$result" '.[0]' "a"

# Wildcard
result="$(_epac_add_selected_pac_array '["x"]' '{"*":["y"]}' "epac-dev")"
assert_json_eq "pac array: wildcard length" "$result" 'length' "2"

# Null input
result="$(_epac_add_selected_pac_array '["keep"]' 'null' "epac-dev")"
assert_json_eq "pac array: null preserves existing" "$result" 'length' "1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Definition entry tests ==="

# Set up EPAC_TMP_DIR with policy definition files (function reads from files)
export EPAC_TMP_DIR="$(mktemp -d)"
echo "$ALL_POLICY_DEFS" > "$EPAC_TMP_DIR/all_policy_defs.json"
echo "$ALL_POLICY_SET_DEFS" > "$EPAC_TMP_DIR/all_policy_set_defs.json"

# Valid policy by name
result="$(_epac_build_assignment_definition_entry \
    '{"policyName":"test-policy"}' \
    '["'"$ROOT_SCOPE"'"]' \
    "TestNode")"
assert_json_eq "entry: valid policy name" "$result" '.valid' "true"
assert_json_eq "entry: is not policy set" "$result" '.isPolicySet' "false"
assert_json_eq "entry: resolved id" "$result" '.id' "$POLICY_ID"

# Valid policy by ID
result="$(_epac_build_assignment_definition_entry \
    "{\"policyId\":\"$POLICY_ID\"}" \
    '["'"$ROOT_SCOPE"'"]' \
    "TestNode")"
assert_json_eq "entry: valid policy id" "$result" '.valid' "true"
assert_json_eq "entry: policy id resolves" "$result" '.id' "$POLICY_ID"

# Valid policy set by name
result="$(_epac_build_assignment_definition_entry \
    '{"policySetName":"test-policy-set"}' \
    '["'"$ROOT_SCOPE"'"]' \
    "TestNode")"
assert_json_eq "entry: valid policy set" "$result" '.valid' "true"
assert_json_eq "entry: is policy set" "$result" '.isPolicySet' "true"
assert_json_eq "entry: set id" "$result" '.id' "$POLICY_SET_ID"

# Initiative alias
result="$(_epac_build_assignment_definition_entry \
    '{"initiativeName":"test-policy-set"}' \
    '["'"$ROOT_SCOPE"'"]' \
    "TestNode")"
assert_json_eq "entry: initiative alias" "$result" '.valid' "true"
assert_json_eq "entry: initiative isPolicySet" "$result" '.isPolicySet' "true"

# No identifier
result="$(_epac_build_assignment_definition_entry \
    '{}' \
    '["'"$ROOT_SCOPE"'"]' \
    "TestNode")"
assert_json_eq "entry: no identifier invalid" "$result" '.valid' "false"

# Multiple identifiers
result="$(_epac_build_assignment_definition_entry \
    '{"policyName":"test-policy","policySetName":"test-policy-set"}' \
    '["'"$ROOT_SCOPE"'"]' \
    "TestNode")"
assert_json_eq "entry: multiple identifiers invalid" "$result" '.valid' "false"

# Non-existent policy
result="$(_epac_build_assignment_definition_entry \
    '{"policyName":"nonexistent"}' \
    '["'"$ROOT_SCOPE"'"]' \
    "TestNode")"
assert_json_eq "entry: nonexistent invalid" "$result" '.valid' "false"

# Append flag
result="$(_epac_build_assignment_definition_entry \
    '{"policyName":"test-policy","append":true}' \
    '["'"$ROOT_SCOPE"'"]' \
    "TestNode")"
assert_json_eq "entry: append flag" "$result" '.append' "true"

# Keep EPAC_TMP_DIR for plan tests below (will be cleaned up by trap)

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Parameter object tests ==="

# Filters to only definition parameters
result="$(_epac_build_assignment_parameter_object \
    '{"effect":"Deny","extra":"value"}' \
    '{"effect":{"defaultValue":"Audit"}}')"
assert_json_eq "param obj: filters to def params" "$result" '.effect' "Deny"
assert_json_eq "param obj: removes extra" "$result" 'has("extra")' "false"

# Omits when value equals default
result="$(_epac_build_assignment_parameter_object \
    '{"effect":"Audit"}' \
    '{"effect":{"defaultValue":"Audit"}}')"
assert_json_eq "param obj: omits default match" "$result" 'length' "0"

# Keeps when no default
result="$(_epac_build_assignment_parameter_object \
    '{"effect":"Deny"}' \
    '{"effect":{}}')"
assert_json_eq "param obj: keeps when no default" "$result" '.effect' "Deny"

# Empty inputs
result="$(_epac_build_assignment_parameter_object 'null' '{"effect":{"defaultValue":"Audit"}}')"
assert_json_eq "param obj: empty assignment params" "$result" 'length' "0"

result="$(_epac_build_assignment_parameter_object '{"effect":"Deny"}' 'null')"
assert_json_eq "param obj: empty definition params" "$result" 'length' "0"

# Multiple params, mixed default/non-default
result="$(_epac_build_assignment_parameter_object \
    '{"effect":"Deny","location":"eastus","tag":"value"}' \
    '{"effect":{"defaultValue":"Deny"},"location":{"defaultValue":"westus"},"tag":{}}')"
assert_json_eq "param obj: mixed - no effect (default match)" "$result" 'has("effect")' "false"
assert_json_eq "param obj: mixed - has location" "$result" '.location' "eastus"
assert_json_eq "param obj: mixed - has tag" "$result" '.tag' "value"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Identity changes: new assignment ==="

# New assignment with identity required
NEW_ASSIGNMENT='{
    "id": "/sub/providers/Microsoft.Authorization/policyAssignments/test",
    "displayName": "Test",
    "identityRequired": true,
    "identity": {"type": "SystemAssigned"},
    "managedIdentityLocation": "eastus",
    "requiredRoleAssignments": [
        {"scope": "/sub", "roleDefinitionId": "/providers/Microsoft.Authorization/roleDefinitions/role1", "roleDisplayName": "Contributor", "description": "Test role", "crossTenant": false}
    ]
}'

result="$(_epac_build_assignment_identity_changes "null" "$NEW_ASSIGNMENT" "false" "{}")"
assert_json_eq "identity new: not replaced" "$result" '.replaced' "false"
assert_json_eq "identity new: requires role changes" "$result" '.requiresRoleChanges' "true"
assert_json_eq "identity new: 1 added" "$result" '.added | length' "1"
assert_json_eq "identity new: 0 removed" "$result" '.removed | length' "0"
assert_json_eq "identity new: not user assigned" "$result" '.isUserAssigned' "false"

# New assignment without identity
result="$(_epac_build_assignment_identity_changes "null" '{"identityRequired": false}' "false" "{}")"
assert_json_eq "identity new no identity: no changes" "$result" '.numberOfChanges' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Identity changes: update scenario ==="

EXISTING_ASSIGNMENT='{
    "identity": {"type": "SystemAssigned", "principalId": "principal-1"},
    "location": "eastus"
}'
DESIRED_ASSIGNMENT='{
    "id": "/sub/providers/Microsoft.Authorization/policyAssignments/test",
    "displayName": "Test",
    "identityRequired": true,
    "identity": {"type": "SystemAssigned"},
    "managedIdentityLocation": "eastus",
    "requiredRoleAssignments": [
        {"scope": "/sub", "roleDefinitionId": "role1", "roleDisplayName": "Contributor", "description": "Test role", "crossTenant": false}
    ]
}'

# Same identity, no deployed roles → add new roles
result="$(_epac_build_assignment_identity_changes "$EXISTING_ASSIGNMENT" "$DESIRED_ASSIGNMENT" "false" "{}")"
assert_json_eq "identity update same: not replaced" "$result" '.replaced' "false"
assert_json_eq "identity update same: 1 added" "$result" '.added | length' "1"

# Identity type change → replacement
EXISTING_WITH_UA='{
    "identity": {"type": "UserAssigned", "userAssignedIdentities": {"/uai/1": {"principalId": "p1"}}},
    "location": "eastus"
}'
result="$(_epac_build_assignment_identity_changes "$EXISTING_WITH_UA" "$DESIRED_ASSIGNMENT" "false" "{}")"
assert_json_eq "identity type change: replaced" "$result" '.replaced' "true"

# Location change → replacement
EXISTING_WEST='{
    "identity": {"type": "SystemAssigned", "principalId": "p1"},
    "location": "westus"
}'
DESIRED_EAST='{
    "id": "/sub/providers/Microsoft.Authorization/policyAssignments/test",
    "displayName": "Test",
    "identityRequired": true,
    "identity": {"type": "SystemAssigned"},
    "managedIdentityLocation": "eastus",
    "requiredRoleAssignments": []
}'
result="$(_epac_build_assignment_identity_changes "$EXISTING_WEST" "$DESIRED_EAST" "false" "{}")"
# Note: location detection uses existing.location vs desired.managedIdentityLocation
assert_json_eq "identity location change: replaced" "$result" '.replaced' "true"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Identity changes: delete scenario ==="

EXISTING_FOR_DEL='{
    "identity": {"type": "SystemAssigned", "principalId": "principal-del"},
    "location": "eastus"
}'
ROLE_ASSIGNS_BY_PRINCIPAL='{
    "principal-del": [
        {"scope": "/sub", "roleDefinitionId": "role1", "description": "old role"}
    ]
}'
result="$(_epac_build_assignment_identity_changes "$EXISTING_FOR_DEL" "null" "false" "$ROLE_ASSIGNS_BY_PRINCIPAL")"
assert_json_eq "identity delete: 1 removed" "$result" '.removed | length' "1"
assert_json_eq "identity delete: 0 added" "$result" '.added | length' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Identity changes: user assigned skip ==="

EXISTING_UA='{
    "identity": {"type": "UserAssigned", "userAssignedIdentities": {"/uai/x": {"principalId": "p-ua"}}},
    "location": "eastus"
}'
DESIRED_UA='{
    "id": "/sub/providers/Microsoft.Authorization/policyAssignments/test",
    "displayName": "Test",
    "identityRequired": true,
    "identity": {"type": "UserAssigned", "userAssignedIdentities": {"/uai/x": {}}},
    "managedIdentityLocation": "eastus",
    "requiredRoleAssignments": [
        {"scope": "/sub", "roleDefinitionId": "role1", "roleDisplayName": "Contributor", "description": "Test", "crossTenant": false}
    ]
}'
result="$(_epac_build_assignment_identity_changes "$EXISTING_UA" "$DESIRED_UA" "false" "{}")"
assert_json_eq "identity UA: is user assigned" "$result" '.isUserAssigned' "true"
assert_json_eq "identity UA: 0 added (skips)" "$result" '.added | length' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Identity changes: XOR scenarios ==="

# Existing has identity, desired does not
EX_WITH_IDENT='{
    "identity": {"type": "SystemAssigned", "principalId": "p1"},
    "location": "eastus"
}'
DESIRED_NO_IDENT='{
    "id": "/sub/pa/test",
    "displayName": "Test",
    "identityRequired": false
}'
result="$(_epac_build_assignment_identity_changes "$EX_WITH_IDENT" "$DESIRED_NO_IDENT" "false" "{}")"
assert_json_eq "identity xor remove: replaced" "$result" '.replaced' "true"
assert_json_eq "identity xor remove: has removedIdentity" "$result" '.changedIdentityStrings | index("removedIdentity") != null' "true"

# Existing has no identity, desired does
EX_NO_IDENT='{
    "identity": null,
    "location": "eastus"
}'
DESIRED_WITH_IDENT='{
    "id": "/sub/pa/test",
    "displayName": "Test",
    "identityRequired": true,
    "identity": {"type": "SystemAssigned"},
    "managedIdentityLocation": "eastus",
    "requiredRoleAssignments": []
}'
result="$(_epac_build_assignment_identity_changes "$EX_NO_IDENT" "$DESIRED_WITH_IDENT" "false" "{}")"
assert_json_eq "identity xor add: replaced" "$result" '.replaced' "true"
assert_json_eq "identity xor add: has addedIdentity" "$result" '.changedIdentityStrings | index("addedIdentity") != null' "true"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment plan: setup temp files ==="

# Write all temp files needed by the refactored epac_build_assignment_plan
echo "$SCOPE_TABLE" | jq 'with_entries(.key |= ascii_downcase)' > "$EPAC_TMP_DIR/scope_table_lower.json"
echo "$EMPTY_ROLE_IDS" > "$EPAC_TMP_DIR/policy_role_ids.json"
echo "$EMPTY_DEPLOYED" > "$EPAC_TMP_DIR/deployed_assignments.json"
# Pre-extract compact lookup files (matches build-deployment-plans.sh logic)
jq -n --argjson cd "$COMBINED_DETAILS" '$cd | {
  policies: (.policies | map_values({parameters: (.parameters // {})})),
  policySets: (.policySets | map_values({parameters: (.parameters // {})}))
}' > "$EPAC_TMP_DIR/policy_params.json"
echo "$ALL_POLICY_DEFS" | jq 'map_values(null)' > "$EPAC_TMP_DIR/policy_def_index.json"
echo "$ALL_POLICY_SET_DEFS" | jq 'map_values(null)' > "$EPAC_TMP_DIR/policy_set_def_index.json"
echo "$COMBINED_DETAILS" > "$EPAC_TMP_DIR/combined_policy_details.json"

# Helper to update deployed assignments in the temp file
_test_set_deployed() {
    echo "$1" > "$EPAC_TMP_DIR/deployed_assignments.json"
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment plan: empty folder ==="

result="$(epac_build_assignment_plan \
    "/nonexistent" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"
assert_json_eq "empty folder: no new" "$result" '.assignments.new | length' "0"
assert_json_eq "empty folder: no changes" "$result" '.assignments.numberOfChanges' "0"
assert_json_eq "empty folder: no role changes" "$result" '.roleAssignments.numberOfChanges' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment plan: simple new assignment ==="

SIMPLE_DIR="${TEST_DIR}/simple_assignment"
write_assignment_file "$SIMPLE_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "test",
    assignment: {
        name: "test-assign",
        displayName: "Test Assignment",
        description: "A test assignment"
    },
    definitionEntry: {
        policyName: $pname
    },
    scope: {
        "epac-dev": $sub
    }
}')"

_test_set_deployed "$EMPTY_DEPLOYED"
result="$(epac_build_assignment_plan \
    "$SIMPLE_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

assert_json_eq "simple new: 1 new assignment" "$result" '.assignments.new | length' "1"
assert_json_eq "simple new: numberOfChanges=1" "$result" '.assignments.numberOfChanges' "1"

# Get the assignment ID
EXPECTED_ASSIGN_ID="${SUB_SCOPE}/providers/Microsoft.Authorization/policyAssignments/test-assign"
assert_json_eq "simple new: correct id" "$result" ".assignments.new[\"${EXPECTED_ASSIGN_ID}\"].id" "$EXPECTED_ASSIGN_ID"
assert_json_eq "simple new: correct name" "$result" ".assignments.new[\"${EXPECTED_ASSIGN_ID}\"].name" "test-assign"
assert_json_eq "simple new: correct displayName" "$result" ".assignments.new[\"${EXPECTED_ASSIGN_ID}\"].displayName" "Test Assignment"
assert_json_eq "simple new: correct description" "$result" ".assignments.new[\"${EXPECTED_ASSIGN_ID}\"].description" "A test assignment"
assert_json_eq "simple new: correct defId" "$result" ".assignments.new[\"${EXPECTED_ASSIGN_ID}\"].policyDefinitionId" "$POLICY_ID"
assert_json_eq "simple new: correct scope" "$result" ".assignments.new[\"${EXPECTED_ASSIGN_ID}\"].scope" "$SUB_SCOPE"
assert_json_eq "simple new: pacOwnerId" "$result" ".assignments.new[\"${EXPECTED_ASSIGN_ID}\"].metadata.pacOwnerId" "pac-owner-1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment plan: unchanged assignment ==="

UNCHANGED_DIR="${TEST_DIR}/unchanged_assignment"
write_assignment_file "$UNCHANGED_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "unch",
    assignment: {
        name: "unch-assign",
        displayName: "Unchanged Assignment",
        description: "No changes"
    },
    definitionEntry: {
        policyName: $pname
    },
    scope: {
        "epac-dev": $sub
    }
}')"

UNCH_ID="${SUB_SCOPE}/providers/Microsoft.Authorization/policyAssignments/unch-assign"
DEPLOYED_UNCH="$(jq -n \
    --arg id "$UNCH_ID" \
    --arg pid "$POLICY_ID" \
    --arg sub "$SUB_SCOPE" \
    '{
        managed: {
            ($id): {
                id: $id,
                scope: $sub,
                properties: {
                    displayName: "Unchanged Assignment",
                    description: "No changes",
                    policyDefinitionId: $pid,
                    enforcementMode: "Default",
                    metadata: {"pacOwnerId": "pac-owner-1", "deployedBy": "epac-test"},
                    parameters: {},
                    notScopes: [],
                    nonComplianceMessages: [],
                    overrides: [],
                    resourceSelectors: []
                }
            }
        },
        readOnly: {}
    }')"

_test_set_deployed "$DEPLOYED_UNCH"
result="$(epac_build_assignment_plan \
    "$UNCHANGED_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

assert_json_eq "unchanged: numberUnchanged=1" "$result" '.assignments.numberUnchanged' "1"
assert_json_eq "unchanged: numberOfChanges=0" "$result" '.assignments.numberOfChanges' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment plan: delete extra deployed ==="

DELETE_DIR="${TEST_DIR}/delete_assignment"
mkdir -p "$DELETE_DIR"
# Empty dir — no desired assignments

DEL_ID="${SUB_SCOPE}/providers/Microsoft.Authorization/policyAssignments/old-assign"
DEPLOYED_DEL="$(jq -n --arg id "$DEL_ID" --arg sub "$SUB_SCOPE" '{
    managed: {
        ($id): {
            id: $id,
            scope: $sub,
            properties: {
                displayName: "Old Assignment",
                policyDefinitionId: "some-policy",
                enforcementMode: "Default",
                metadata: {"pacOwnerId": "pac-owner-1"}
            }
        }
    },
    readOnly: {}
}')"

_test_set_deployed "$DEPLOYED_DEL"
result="$(epac_build_assignment_plan \
    "$DELETE_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

assert_json_eq "delete: 1 deletion" "$result" '.assignments.delete | length' "1"
assert_json_eq "delete: has correct id" "$result" ".assignments.delete[\"${DEL_ID}\"] | type" "object"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment plan: update scenario ==="

UPDATE_DIR="${TEST_DIR}/update_assignment"
write_assignment_file "$UPDATE_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "upd",
    assignment: {
        name: "upd-assign",
        displayName: "Updated Display Name",
        description: "Updated description"
    },
    definitionEntry: {
        policyName: $pname
    },
    scope: {
        "epac-dev": $sub
    }
}')"

UPD_ID="${SUB_SCOPE}/providers/Microsoft.Authorization/policyAssignments/upd-assign"
DEPLOYED_UPD="$(jq -n \
    --arg id "$UPD_ID" \
    --arg pid "$POLICY_ID" \
    --arg sub "$SUB_SCOPE" \
    '{
        managed: {
            ($id): {
                id: $id,
                scope: $sub,
                properties: {
                    displayName: "Old Display Name",
                    description: "Old description",
                    policyDefinitionId: $pid,
                    enforcementMode: "Default",
                    metadata: {"pacOwnerId": "pac-owner-1", "deployedBy": "epac-test"},
                    parameters: {},
                    notScopes: [],
                    nonComplianceMessages: [],
                    overrides: [],
                    resourceSelectors: []
                }
            }
        },
        readOnly: {}
    }')"

_test_set_deployed "$DEPLOYED_UPD"
result="$(epac_build_assignment_plan \
    "$UPDATE_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

assert_json_eq "update: 1 update" "$result" '.assignments.update | length' "1"
assert_json_eq "update: numberOfChanges=1" "$result" '.assignments.numberOfChanges' "1"
assert_json_eq "update: new displayName" "$result" ".assignments.update[\"${UPD_ID}\"].displayName" "Updated Display Name"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment plan: replace due to definition change ==="

REPL_DIR="${TEST_DIR}/replace_assignment"
write_assignment_file "$REPL_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "repl",
    assignment: {
        name: "repl-assign",
        displayName: "Replace Assignment",
        description: "Same"
    },
    definitionEntry: {
        policyName: $pname
    },
    scope: {
        "epac-dev": $sub
    }
}')"

REPL_ID="${SUB_SCOPE}/providers/Microsoft.Authorization/policyAssignments/repl-assign"
DEPLOYED_REPL="$(jq -n \
    --arg id "$REPL_ID" \
    --arg pid "$POLICY_ID" \
    --arg sub "$SUB_SCOPE" \
    '{
        managed: {
            ($id): {
                id: $id,
                scope: $sub,
                properties: {
                    displayName: "Replace Assignment",
                    description: "Same",
                    policyDefinitionId: $pid,
                    enforcementMode: "Default",
                    metadata: {"pacOwnerId": "pac-owner-1", "deployedBy": "epac-test"},
                    parameters: {},
                    notScopes: [],
                    nonComplianceMessages: [],
                    overrides: [],
                    resourceSelectors: []
                }
            }
        },
        readOnly: {}
    }')"

# Mark the policy as replaced
REPLACE_DEFS="$(jq -n --arg id "$POLICY_ID" '{($id): true}')"

_test_set_deployed "$DEPLOYED_REPL"
result="$(epac_build_assignment_plan \
    "$REPL_DIR" "$PAC_ENV" \
    "$REPLACE_DEFS" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

assert_json_eq "replace: 1 replacement" "$result" '.assignments.replace | length' "1"
assert_json_eq "replace: numberOfChanges=1" "$result" '.assignments.numberOfChanges' "1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Recursive tree: children nodes ==="

TREE_DIR="${TEST_DIR}/tree_assignment"
write_assignment_file "$TREE_DIR" "tree.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "root",
    assignment: {
        name: "",
        displayName: "Root ",
        description: ""
    },
    scope: {
        "epac-dev": $sub
    },
    children: [
        {
            nodeName: "child1",
            assignment: {
                name: "child1-assign",
                displayName: "Child1",
                description: "First child"
            },
            definitionEntry: {
                policyName: $pname
            }
        },
        {
            nodeName: "child2",
            assignment: {
                name: "child2-assign",
                displayName: "Child2",
                description: "Second child"
            },
            definitionEntry: {
                policyName: $pname
            }
        }
    ]
}')"

_test_set_deployed "$EMPTY_DEPLOYED"
result="$(epac_build_assignment_plan \
    "$TREE_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

assert_json_eq "tree: 2 new assignments" "$result" '.assignments.new | length' "2"

C1_ID="${SUB_SCOPE}/providers/Microsoft.Authorization/policyAssignments/child1-assign"
C2_ID="${SUB_SCOPE}/providers/Microsoft.Authorization/policyAssignments/child2-assign"
assert_json_eq "tree: child1 displayName" "$result" ".assignments.new[\"${C1_ID}\"].displayName" "Root Child1"
assert_json_eq "tree: child2 displayName" "$result" ".assignments.new[\"${C2_ID}\"].displayName" "Root Child2"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Enforcement mode validation ==="

EM_DIR="${TEST_DIR}/em_assignment"
write_assignment_file "$EM_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "em-test",
    assignment: {
        name: "em-assign",
        displayName: "EM Test",
        description: ""
    },
    enforcementMode: "DoNotEnforce",
    definitionEntry: {
        policyName: $pname
    },
    scope: {
        "epac-dev": $sub
    }
}')"

_test_set_deployed "$EMPTY_DEPLOYED"
result="$(epac_build_assignment_plan \
    "$EM_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

assert_json_eq "enforcement mode: DoNotEnforce" "$result" '.assignments.new | to_entries[0].value.enforcementMode' "DoNotEnforce"

# Invalid enforcement mode
EM_BAD_DIR="${TEST_DIR}/em_bad_assignment"
write_assignment_file "$EM_BAD_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "em-bad",
    assignment: {name: "em-bad", displayName: "EM Bad"},
    enforcementMode: "InvalidMode",
    definitionEntry: {policyName: $pname},
    scope: {"epac-dev": $sub}
}')"

_test_set_deployed "$EMPTY_DEPLOYED"
result="$(epac_build_assignment_plan \
    "$EM_BAD_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"
assert_json_eq "enforcement mode invalid: 0 new" "$result" '.assignments.new | length' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Metadata accumulation ==="

META_DIR="${TEST_DIR}/meta_assignment"
write_assignment_file "$META_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "meta-root",
    assignment: {name: "meta-assign", displayName: "Meta Test"},
    metadata: {category: "Compliance", version: "1.0"},
    definitionEntry: {policyName: $pname},
    scope: {"epac-dev": $sub},
    children: [{
        nodeName: "child",
        metadata: {version: "2.0", extra: "value"}
    }]
}')"

_test_set_deployed "$EMPTY_DEPLOYED"
result="$(epac_build_assignment_plan \
    "$META_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

# Check metadata merge: child overrides parent's version, adds extra, parent's category preserved
FIRST_KEY="$(echo "$result" | jq -r '.assignments.new | keys[0]')"
assert_json_eq "meta: category preserved" "$result" ".assignments.new[\"${FIRST_KEY}\"].metadata.category" "Compliance"
assert_json_eq "meta: version overridden" "$result" ".assignments.new[\"${FIRST_KEY}\"].metadata.version" "2.0"
assert_json_eq "meta: extra added" "$result" ".assignments.new[\"${FIRST_KEY}\"].metadata.extra" "value"
assert_json_eq "meta: pacOwnerId set" "$result" ".assignments.new[\"${FIRST_KEY}\"].metadata.pacOwnerId" "pac-owner-1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Role assignments for DINE policy ==="

DINE_POLICY_ID="${ROOT_SCOPE}/providers/Microsoft.Authorization/policyDefinitions/dine-policy"
DINE_ALL_DEFS="$(echo "$ALL_POLICY_DEFS" | jq --arg id "$DINE_POLICY_ID" '.[$id] = {
    id: $id, name: "dine-policy",
    properties: {
        displayName: "DINE Policy",
        parameters: {},
        policyRule: {
            "if": {field: "type", equals: "Microsoft.Compute/virtualMachines"},
            "then": {effect: "DeployIfNotExists", details: {roleDefinitionIds: ["/providers/Microsoft.Authorization/roleDefinitions/r1"]}}
        }
    }
}')"

DINE_ROLE_IDS="$(jq -n --arg id "$DINE_POLICY_ID" '{($id): ["/providers/Microsoft.Authorization/roleDefinitions/r1"]}')"
DINE_ROLE_DEFS='{ "/providers/Microsoft.Authorization/roleDefinitions/r1": "Contributor" }'

DINE_DIR="${TEST_DIR}/dine_assignment"
write_assignment_file "$DINE_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" '{
    nodeName: "dine",
    assignment: {name: "dine-assign", displayName: "DINE Assignment", description: ""},
    definitionEntry: {policyName: "dine-policy"},
    managedIdentityLocations: {"epac-dev": "eastus"},
    scope: {"epac-dev": $sub}
}')"

_test_set_deployed "$EMPTY_DEPLOYED"
echo "$DINE_ALL_DEFS" > "$EPAC_TMP_DIR/all_policy_defs.json"
echo "$DINE_ALL_DEFS" | jq 'map_values(null)' > "$EPAC_TMP_DIR/policy_def_index.json"
echo "$DINE_ROLE_IDS" > "$EPAC_TMP_DIR/policy_role_ids.json"
result="$(epac_build_assignment_plan \
    "$DINE_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$DINE_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

DINE_ASSIGN_ID="${SUB_SCOPE}/providers/Microsoft.Authorization/policyAssignments/dine-assign"
assert_json_eq "dine: 1 new assignment" "$result" '.assignments.new | length' "1"
assert_json_eq "dine: identity required" "$result" ".assignments.new[\"${DINE_ASSIGN_ID}\"].identityRequired" "true"
assert_json_eq "dine: SystemAssigned" "$result" ".assignments.new[\"${DINE_ASSIGN_ID}\"].identity.type" "SystemAssigned"
assert_json_eq "dine: role assignments added" "$result" '.roleAssignments.added | length' "1"
assert_json_eq "dine: role scope" "$result" ".roleAssignments.added[0].scope" "$SUB_SCOPE"

# Restore default policy defs and role IDs after DINE test
echo "$ALL_POLICY_DEFS" > "$EPAC_TMP_DIR/all_policy_defs.json"
echo "$ALL_POLICY_DEFS" | jq 'map_values(null)' > "$EPAC_TMP_DIR/policy_def_index.json"
echo "$EMPTY_ROLE_IDS" > "$EPAC_TMP_DIR/policy_role_ids.json"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Multiple scopes ==="

MULTI_SCOPE_TABLE="$(jq -n --arg s1 "$SUB_SCOPE" --arg s2 "/subscriptions/00000000-0000-0000-0000-000000000002" '{
    ($s1): {scope: $s1, notScopesList: []},
    ($s2): {scope: $s2, notScopesList: []}
}')"

MSCOPE_DIR="${TEST_DIR}/multi_scope"
write_assignment_file "$MSCOPE_DIR" "assign.jsonc" "$(jq -n --arg pname "test-policy" '{
    nodeName: "ms",
    assignment: {name: "ms-assign", displayName: "Multi Scope", description: ""},
    definitionEntry: {policyName: $pname},
    scope: {"epac-dev": "/subscriptions/00000000-0000-0000-0000-000000000001"}
}')"

_test_set_deployed "$EMPTY_DEPLOYED"
echo "$MULTI_SCOPE_TABLE" | jq 'with_entries(.key |= ascii_downcase)' > "$EPAC_TMP_DIR/scope_table_lower.json"
result="$(epac_build_assignment_plan \
    "$MSCOPE_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

# Single scope assigned (scope in file maps to one subscription)
assert_json_eq "multi scope: 1 new" "$result" '.assignments.new | length' "1"

# Restore default scope table after multi-scope test
echo "$SCOPE_TABLE" | jq 'with_entries(.key |= ascii_downcase)' > "$EPAC_TMP_DIR/scope_table_lower.json"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Node name concatenation ==="

# Test deep nesting
DEEP_DIR="${TEST_DIR}/deep_tree"
write_assignment_file "$DEEP_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "L1",
    assignment: {name: "L1-", displayName: "L1 "},
    scope: {"epac-dev": $sub},
    children: [{
        nodeName: "L2",
        assignment: {name: "L2-", displayName: "L2 "},
        children: [{
            nodeName: "L3",
            assignment: {name: "L3", displayName: "L3"},
            definitionEntry: {policyName: $pname}
        }]
    }]
}')"

_test_set_deployed "$EMPTY_DEPLOYED"
result="$(epac_build_assignment_plan \
    "$DEEP_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

DEEP_ID="${SUB_SCOPE}/providers/Microsoft.Authorization/policyAssignments/L1-L2-L3"
assert_json_eq "deep tree: concatenated name" "$result" ".assignments.new[\"${DEEP_ID}\"].name" "L1-L2-L3"
assert_json_eq "deep tree: concatenated displayName" "$result" ".assignments.new[\"${DEEP_ID}\"].displayName" "L1 L2 L3"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Both definitionEntry and definitionEntryList error ==="

BOTH_DIR="${TEST_DIR}/both_def"
write_assignment_file "$BOTH_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "both",
    assignment: {name: "both", displayName: "Both"},
    definitionEntry: {policyName: $pname},
    definitionEntryList: [{policyName: $pname}],
    scope: {"epac-dev": $sub}
}')"

_test_set_deployed "$EMPTY_DEPLOYED"
result="$(epac_build_assignment_plan \
    "$BOTH_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"
assert_json_eq "both error: 0 new" "$result" '.assignments.new | length' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Merge parameters ex: basic ==="

MERGE_BASE='{"parameters": {"existing": "val"}, "nonComplianceMessages": []}'
MERGE_INSTRUCTIONS='{
    "csvParameterArray": [
        {"flatPolicyEntryKey": "pk1", "name": "TestPolicy", "policyId": "pid1", "effect": "Deny", "parameters": "{}"}
    ],
    "effectColumn": "effect",
    "parametersColumn": "parameters",
    "nonComplianceMessageColumn": null
}'
MERGE_FLAT='{"pk1": {"policySetList": {"psid1": {"effectParameterName": "effect", "effectDefault": "Audit", "effectAllowedValues": ["Audit","Deny","Disabled"], "effectAllowedOverrides": [], "isEffectParameterized": true, "policyDefinitionReferenceId": "ref1"}}}}'

result="$(_epac_merge_assignment_parameters_ex "TestNode" "psid1" "$MERGE_BASE" "$MERGE_INSTRUCTIONS" "$MERGE_FLAT" "$COMBINED_DETAILS" "{}")"
assert_json_eq "merge params: no errors" "$result" '.hasErrors' "false"
assert_json_eq "merge params: effect set" "$result" '.parameters.effect' "Deny"
assert_json_eq "merge params: existing preserved" "$result" '.parameters.existing' "val"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Result structure ==="

STRUCT_DIR="${TEST_DIR}/struct_test"
write_assignment_file "$STRUCT_DIR" "assign.jsonc" "$(jq -n --arg sub "$SUB_SCOPE" --arg pname "test-policy" '{
    nodeName: "struct",
    assignment: {name: "struct-assign", displayName: "Structure Test", description: ""},
    definitionEntry: {policyName: $pname},
    scope: {"epac-dev": $sub}
}')"

_test_set_deployed "$EMPTY_DEPLOYED"
result="$(epac_build_assignment_plan \
    "$STRUCT_DIR" "$PAC_ENV" \
    "$EMPTY_REPLACE" "$EMPTY_ROLE_DEFS" \
    "$EMPTY_ROLE_ASSIGN_BY_PRINCIPAL" 2>/dev/null)"

assert_json_eq "structure: has assignments key" "$result" '.assignments | type' "object"
assert_json_eq "structure: has new" "$result" '.assignments.new | type' "object"
assert_json_eq "structure: has update" "$result" '.assignments.update | type' "object"
assert_json_eq "structure: has replace" "$result" '.assignments.replace | type' "object"
assert_json_eq "structure: has delete" "$result" '.assignments.delete | type' "object"
assert_json_eq "structure: has numberUnchanged" "$result" '.assignments | has("numberUnchanged")' "true"
assert_json_eq "structure: has numberOfChanges" "$result" '.assignments | has("numberOfChanges")' "true"
assert_json_eq "structure: has roleAssignments" "$result" '.roleAssignments | type' "object"
assert_json_eq "structure: has roleAssignments.added" "$result" '.roleAssignments.added | type' "array"
assert_json_eq "structure: has roleAssignments.updated" "$result" '.roleAssignments.updated | type' "array"
assert_json_eq "structure: has roleAssignments.removed" "$result" '.roleAssignments.removed | type' "array"
assert_json_eq "structure: has numberTotalChanges" "$result" 'has("numberTotalChanges")' "true"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════════════"
echo "Total: $((PASS + FAIL))  Pass: ${PASS}  Fail: ${FAIL}"
echo "═══════════════════════════════════════════════════════════════════════"

exit "$FAIL"
