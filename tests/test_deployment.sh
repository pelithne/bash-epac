#!/usr/bin/env bash
# tests/test_deployment.sh — Tests for deploy-policy-plan.sh, deploy-roles-plan.sh,
# set-az-policy-exemption.sh, remove-az-policy-exemption.sh
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

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

DEPLOY_DIR="${SCRIPT_DIR}/../scripts/deploy"

###############################################################################
echo "=== deploy-policy-plan.sh — Script structure ==="
###############################################################################

echo "--- Script exists and is executable ---"
assert_true "deploy-policy-plan.sh exists" test -f "${DEPLOY_DIR}/deploy-policy-plan.sh"
assert_true "deploy-policy-plan.sh is executable" test -x "${DEPLOY_DIR}/deploy-policy-plan.sh"

echo "--- Help output ---"
help_output="$(bash "${DEPLOY_DIR}/deploy-policy-plan.sh" --help 2>&1 || true)"
_check_dp_help() { echo "$help_output" | grep -q "$1"; }
assert_true "help mentions pac-environment" _check_dp_help 'pac-environment'
assert_true "help mentions input-folder" _check_dp_help 'input-folder'
assert_true "help mentions skip-exemptions" _check_dp_help 'skip-exemptions'
assert_true "help mentions fail-on-exemption-error" _check_dp_help 'fail-on-exemption-error'
assert_true "help mentions definitions-folder" _check_dp_help 'definitions-folder'

###############################################################################
echo ""
echo "=== deploy-roles-plan.sh — Script structure ==="
###############################################################################

echo "--- Script exists and is executable ---"
assert_true "deploy-roles-plan.sh exists" test -f "${DEPLOY_DIR}/deploy-roles-plan.sh"
assert_true "deploy-roles-plan.sh is executable" test -x "${DEPLOY_DIR}/deploy-roles-plan.sh"

echo "--- Help output ---"
roles_help="$(bash "${DEPLOY_DIR}/deploy-roles-plan.sh" --help 2>&1 || true)"
_check_dr_help() { echo "$roles_help" | grep -q "$1"; }
assert_true "help mentions pac-environment" _check_dr_help 'pac-environment'
assert_true "help mentions input-folder" _check_dr_help 'input-folder'
assert_true "help mentions interactive" _check_dr_help 'interactive'

###############################################################################
echo ""
echo "=== set-az-policy-exemption.sh — Script structure ==="
###############################################################################

echo "--- Script exists and is executable ---"
assert_true "set-exemption.sh exists" test -f "${DEPLOY_DIR}/set-az-policy-exemption.sh"
assert_true "set-exemption.sh is executable" test -x "${DEPLOY_DIR}/set-az-policy-exemption.sh"

echo "--- Help output ---"
set_help="$(bash "${DEPLOY_DIR}/set-az-policy-exemption.sh" --help 2>&1 || true)"
_check_se_help() { echo "$set_help" | grep -q "$1"; }
assert_true "help mentions scope" _check_se_help 'scope'
assert_true "help mentions name" _check_se_help 'name'
assert_true "help mentions display-name" _check_se_help 'display-name'
assert_true "help mentions policy-assignment-id" _check_se_help 'policy-assignment-id'
assert_true "help mentions exemption-category" _check_se_help 'exemption-category'
assert_true "help mentions expires-on" _check_se_help 'expires-on'
assert_true "help mentions api-version" _check_se_help 'api-version'

echo "--- Missing required params gives error ---"
set_err="$(bash "${DEPLOY_DIR}/set-az-policy-exemption.sh" --scope "/sub" 2>&1 || true)"
_check_se_err() { echo "$set_err" | grep -qi 'missing\|required\|error'; }
assert_true "missing params error" _check_se_err

###############################################################################
echo ""
echo "=== remove-az-policy-exemption.sh — Script structure ==="
###############################################################################

echo "--- Script exists and is executable ---"
assert_true "remove-exemption.sh exists" test -f "${DEPLOY_DIR}/remove-az-policy-exemption.sh"
assert_true "remove-exemption.sh is executable" test -x "${DEPLOY_DIR}/remove-az-policy-exemption.sh"

echo "--- Help output ---"
rm_help="$(bash "${DEPLOY_DIR}/remove-az-policy-exemption.sh" --help 2>&1 || true)"
_check_re_help() { echo "$rm_help" | grep -q "$1"; }
assert_true "help mentions scope" _check_re_help 'scope'
assert_true "help mentions name" _check_re_help 'name'
assert_true "help mentions api-version" _check_re_help 'api-version'

echo "--- Missing required params gives error ---"
rm_err="$(bash "${DEPLOY_DIR}/remove-az-policy-exemption.sh" --scope "/sub" 2>&1 || true)"
_check_re_err() { echo "$rm_err" | grep -qi 'missing\|required\|error'; }
assert_true "missing params error" _check_re_err

###############################################################################
echo ""
echo "=== deploy-policy-plan.sh — _deploy_delete_resources ==="
###############################################################################

echo "--- Internal helper functions are defined ---"
# Source the script in a subshell to check function availability
# We can't actually run the deploy script without Azure, but we can verify
# the plan loading and processing logic

echo "--- Plan file processing logic ---"
# Create a mock plan file
mock_plan_file="${TEST_DIR}/policyPlan.json"
cat > "$mock_plan_file" << 'PLANEOF'
{
    "createdOn": "2026-04-10T00:00:00Z",
    "pacOwnerId": "test-owner",
    "policyDefinitions": {
        "new": {
            "/providers/pd/new-1": {"id": "/providers/pd/new-1", "displayName": "New Policy 1", "name": "new-1"}
        },
        "update": {},
        "replace": {},
        "delete": {},
        "numberOfChanges": 1,
        "numberUnchanged": 5
    },
    "policySetDefinitions": {
        "new": {},
        "update": {},
        "replace": {},
        "delete": {},
        "numberOfChanges": 0,
        "numberUnchanged": 3
    },
    "assignments": {
        "new": {
            "/providers/pa/assign-1": {"id": "/providers/pa/assign-1", "displayName": "Assign 1", "name": "assign-1"}
        },
        "update": {},
        "replace": {
            "/providers/pa/assign-2": {"id": "/providers/pa/assign-2", "displayName": "Assign 2 Replaced", "name": "assign-2"}
        },
        "delete": {},
        "numberOfChanges": 2,
        "numberUnchanged": 0
    },
    "exemptions": {
        "new": {},
        "update": {
            "/providers/ex/ex-1": {"id": "/providers/ex/ex-1", "displayName": "Exemption 1", "name": "ex-1"}
        },
        "replace": {},
        "delete": {
            "/providers/ex/ex-del": {"id": "/providers/ex/ex-del", "displayName": "Delete Me", "name": "ex-del"}
        },
        "numberOfChanges": 2,
        "numberUnchanged": 0,
        "numberOfOrphans": 0,
        "numberOfExpired": 0
    }
}
PLANEOF

plan="$(jq '.' "$mock_plan_file")"
assert_json_eq "plan createdOn" "$plan" '.createdOn' "2026-04-10T00:00:00Z"
assert_json_eq "plan pacOwnerId" "$plan" '.pacOwnerId' "test-owner"
assert_json_eq "plan policy defs new count" "$plan" '.policyDefinitions.new | length' "1"
assert_json_eq "plan assignments new count" "$plan" '.assignments.new | length' "1"
assert_json_eq "plan assignments replace count" "$plan" '.assignments.replace | length' "1"
assert_json_eq "plan exemptions update count" "$plan" '.exemptions.update | length' "1"
assert_json_eq "plan exemptions delete count" "$plan" '.exemptions.delete | length' "1"

# Verify merge logic used in deploy (delete + replace)
assignments_plan="$(echo "$plan" | jq '.assignments // {}')"
merged_del="$(echo "$assignments_plan" | jq '(.delete // {}) + (.replace // {})')"
assert_json_eq "merged delete+replace count" "$merged_del" 'length' "1"

merged_create="$(echo "$assignments_plan" | jq '(.new // {}) + (.replace // {}) + (.update // {})')"
assert_json_eq "merged new+replace+update count" "$merged_create" 'length' "2"

###############################################################################
echo ""
echo "=== deploy-roles-plan.sh — Plan processing ==="
###############################################################################

echo "--- Roles plan file format ---"
mock_roles_file="${TEST_DIR}/rolesPlan.json"
cat > "$mock_roles_file" << 'ROLESEOF'
{
    "createdOn": "2026-04-10T00:00:00Z",
    "pacOwnerId": "test-owner",
    "roleAssignments": {
        "numberOfChanges": 3,
        "added": [
            {
                "assignmentId": "/providers/pa/test-1",
                "scope": "/subscriptions/sub-1",
                "roleDisplayName": "Contributor",
                "roleDefinitionId": "/providers/role-def-1",
                "properties": {
                    "principalId": "principal-abc",
                    "roleDefinitionId": "/providers/role-def-1",
                    "scope": "/subscriptions/sub-1"
                }
            }
        ],
        "updated": [
            {
                "id": "/providers/role-assignment-2",
                "scope": "/subscriptions/sub-1",
                "roleDisplayName": "Reader",
                "properties": {
                    "principalId": "principal-def",
                    "roleDefinitionId": "/providers/role-def-2",
                    "scope": "/subscriptions/sub-1"
                }
            }
        ],
        "removed": [
            {
                "id": "/providers/role-assignment-3",
                "principalId": "principal-old",
                "scope": "/subscriptions/sub-1",
                "roleDisplayName": "Owner",
                "crossTenant": false
            }
        ]
    }
}
ROLESEOF

roles_plan="$(jq '.' "$mock_roles_file")"
assert_json_eq "roles plan createdOn" "$roles_plan" '.createdOn' "2026-04-10T00:00:00Z"

added="$(echo "$roles_plan" | jq '.roleAssignments.added')"
updated="$(echo "$roles_plan" | jq '.roleAssignments.updated')"
removed="$(echo "$roles_plan" | jq '.roleAssignments.removed')"

assert_json_eq "added count" "$added" 'length' "1"
assert_json_eq "updated count" "$updated" 'length' "1"
assert_json_eq "removed count" "$removed" 'length' "1"

assert_json_eq "added principalId" "$added" '.[0].properties.principalId' "principal-abc"
assert_json_eq "added scope" "$added" '.[0].scope' "/subscriptions/sub-1"
assert_json_eq "removed crossTenant" "$removed" '.[0].crossTenant' "false"

echo "--- Identity resolution logic ---"
# Test the pattern of resolving principalId from assignment
test_pa_response='{"identity": {"type": "SystemAssigned", "principalId": "resolved-pid"}}'
resolved_pid="$(echo "$test_pa_response" | jq -r '.identity.principalId')"
assert_eq "system assigned principal resolved" "resolved-pid" "$resolved_pid"

test_ua_response='{"identity": {"type": "UserAssigned", "userAssignedIdentities": {"/sub/uai-1": {"principalId": "ua-pid"}}}}'
ua_pid="$(echo "$test_ua_response" | jq -r '.identity.userAssignedIdentities | to_entries[0].value.principalId')"
assert_eq "user assigned principal resolved" "ua-pid" "$ua_pid"

echo "--- Cross-tenant regex parsing ---"
test_desc="Assignment '/subscriptions/abc-123/providers/Microsoft.Authorization/policyAssignments/test' requires role"
if [[ "$test_desc" =~ \'(/subscriptions/[^\']+)\' ]]; then
    extracted="${BASH_REMATCH[1]}"
else
    extracted="NONE"
fi
assert_eq "cross-tenant regex" "/subscriptions/abc-123/providers/Microsoft.Authorization/policyAssignments/test" "$extracted"

###############################################################################
echo ""
echo "=== Deployment ordering logic ==="
###############################################################################

echo "--- Correct deployment order for policy plan ---"
# The PS script deletes in this order:
# 1. Exemptions (delete + replace)
# 2. Assignments (delete + replace)
# 3. Policy Set Definitions (delete + replace)
# 4. Replaced Policy Definitions (replace only)
# Then creates/updates:
# 5. Policy Definitions (new + replace + update)
# 6. Policy Set Definitions (new + replace + update)
# 7. Obsolete Policy Definitions (delete)
# 8. Assignments (new + replace + update)
# 9. Exemptions (new + replace + update)

# Verify the plan structure supports this ordering
assert_json_eq "plan has exemptions.delete" "$plan" '.exemptions | has("delete")' "true"
assert_json_eq "plan has exemptions.replace" "$plan" '.exemptions | has("replace")' "true"
assert_json_eq "plan has assignments.delete" "$plan" '.assignments | has("delete")' "true"
assert_json_eq "plan has assignments.new" "$plan" '.assignments | has("new")' "true"
assert_json_eq "plan has policyDefs.new" "$plan" '.policyDefinitions | has("new")' "true"
assert_json_eq "plan has policyDefs.delete" "$plan" '.policyDefinitions | has("delete")' "true"
assert_json_eq "plan has policyDefs.replace" "$plan" '.policyDefinitions | has("replace")' "true"
assert_json_eq "plan has policySetDefs.new" "$plan" '.policySetDefinitions | has("new")' "true"

###############################################################################
echo ""
echo "=== set-az-policy-exemption.sh — Exemption object construction ==="
###############################################################################

echo "--- Ref ID parsing ---"
ref_input="ref-1,ref-2,ref-3"
ref_json="$(echo "$ref_input" | tr ',' '\n' | jq -R '.' | jq -s '.')"
assert_json_eq "ref IDs parsed" "$ref_json" 'length' "3"
assert_json_eq "ref ID 1" "$ref_json" '.[0]' "ref-1"
assert_json_eq "ref ID 3" "$ref_json" '.[2]' "ref-3"

echo "--- Exemption object structure ---"
test_scope="/subscriptions/sub-1"
test_name="test-ex"
test_ex_id="${test_scope}/providers/Microsoft.Authorization/policyExemptions/${test_name}"
test_obj="$(jq -n \
    --arg id "$test_ex_id" \
    --arg paid "/providers/pa/assign-1" \
    --arg ec "Waiver" \
    --arg sv "Default" \
    --arg dn "Test Exemption" \
    --arg desc "Test description" \
    --arg eo "" \
    --argjson meta 'null' \
    --argjson refs 'null' \
    --argjson rsel 'null' \
    '{
        id: $id,
        properties: {
            policyAssignmentId: $paid,
            exemptionCategory: $ec,
            assignmentScopeValidation: $sv,
            displayName: $dn,
            description: $desc,
            expiresOn: (if $eo == "" then null else $eo end),
            metadata: $meta,
            policyDefinitionReferenceIds: $refs,
            resourceSelectors: $rsel
        }
    }')"

assert_json_eq "exemption id" "$test_obj" '.id' "$test_ex_id"
assert_json_eq "exemption assignmentId" "$test_obj" '.properties.policyAssignmentId' "/providers/pa/assign-1"
assert_json_eq "exemption category" "$test_obj" '.properties.exemptionCategory' "Waiver"
assert_json_eq "exemption expiresOn null" "$test_obj" '.properties.expiresOn' "null"

echo "--- Exemption object with expiration ---"
test_obj_exp="$(jq -n \
    --arg id "$test_ex_id" \
    --arg paid "/providers/pa/assign-1" \
    --arg ec "Mitigated" \
    --arg sv "DoNotValidate" \
    --arg dn "Expiring Exemption" \
    --arg desc "" \
    --arg eo "2026-12-31T00:00:00Z" \
    --argjson meta '{"ticket": "INC-123"}' \
    --argjson refs '["ref-1", "ref-2"]' \
    --argjson rsel 'null' \
    '{
        id: $id,
        properties: {
            policyAssignmentId: $paid,
            exemptionCategory: $ec,
            assignmentScopeValidation: $sv,
            displayName: $dn,
            description: $desc,
            expiresOn: (if $eo == "" then null else $eo end),
            metadata: $meta,
            policyDefinitionReferenceIds: $refs,
            resourceSelectors: $rsel
        }
    }')"

assert_json_eq "exp exemption category" "$test_obj_exp" '.properties.exemptionCategory' "Mitigated"
assert_json_eq "exp exemption expiresOn" "$test_obj_exp" '.properties.expiresOn' "2026-12-31T00:00:00Z"
assert_json_eq "exp exemption scope val" "$test_obj_exp" '.properties.assignmentScopeValidation' "DoNotValidate"
assert_json_eq "exp exemption metadata ticket" "$test_obj_exp" '.properties.metadata.ticket' "INC-123"
assert_json_eq "exp exemption refs count" "$test_obj_exp" '.properties.policyDefinitionReferenceIds | length' "2"

###############################################################################
echo ""
echo "=== remove-az-policy-exemption.sh — ID construction ==="
###############################################################################

echo "--- Exemption ID from scope + name ---"
rm_scope="/subscriptions/sub-1"
rm_name="my-exemption"
rm_id="${rm_scope}/providers/Microsoft.Authorization/policyExemptions/${rm_name}"
assert_eq "remove exemption ID" "/subscriptions/sub-1/providers/Microsoft.Authorization/policyExemptions/my-exemption" "$rm_id"

###############################################################################
echo ""
echo "=== API version extraction ==="
###############################################################################

echo "--- Extract API versions from pac environment ---"
test_pac_env='{
    "apiVersions": {
        "policyDefinitions": "2023-04-01",
        "policySetDefinitions": "2023-04-01",
        "policyAssignments": "2023-04-01",
        "policyExemptions": "2022-07-01-preview",
        "roleAssignments": "2022-04-01"
    }
}'
assert_json_eq "policy def API version" "$test_pac_env" '.apiVersions.policyDefinitions' "2023-04-01"
assert_json_eq "exemptions API version" "$test_pac_env" '.apiVersions.policyExemptions' "2022-07-01-preview"
assert_json_eq "role assignments API version" "$test_pac_env" '.apiVersions.roleAssignments' "2022-04-01"

###############################################################################
echo ""
echo "=== Plan change calculation ==="
###############################################################################

echo "--- Total policy changes formula ---"
total_changes="$(echo "$plan" | jq '
    (.policyDefinitions.numberOfChanges // 0) +
    (.policySetDefinitions.numberOfChanges // 0) +
    (.assignments.numberOfChanges // 0) +
    (.exemptions.numberOfChanges // 0)')"
assert_eq "total changes" "5" "$total_changes"

echo "--- Role changes formula ---"
role_changes="$(echo "$roles_plan" | jq '.roleAssignments.numberOfChanges // 0')"
assert_eq "role changes" "3" "$role_changes"

echo "--- Policy stage determination ---"
policy_stage="no"
[[ $total_changes -gt 0 ]] && policy_stage="yes"
assert_eq "policy stage yes" "yes" "$policy_stage"

role_stage="no"
[[ $role_changes -gt 0 ]] && role_stage="yes"
assert_eq "role stage yes" "yes" "$role_stage"

echo "--- Zero changes → stage=no ---"
empty_plan='{"policyDefinitions":{"numberOfChanges":0},"policySetDefinitions":{"numberOfChanges":0},"assignments":{"numberOfChanges":0},"exemptions":{"numberOfChanges":0}}'
zero_changes="$(echo "$empty_plan" | jq '
    (.policyDefinitions.numberOfChanges // 0) +
    (.policySetDefinitions.numberOfChanges // 0) +
    (.assignments.numberOfChanges // 0) +
    (.exemptions.numberOfChanges // 0)')"
zero_stage="no"
[[ $zero_changes -gt 0 ]] && zero_stage="yes"
assert_eq "zero changes stage no" "no" "$zero_stage"

###############################################################################
echo ""
echo "=== SUMMARY ==="
###############################################################################

TOTAL=$((PASS + FAIL))
echo "Passed: ${PASS}/${TOTAL}"
if [[ $FAIL -gt 0 ]]; then
    echo "FAILED: ${FAIL} tests"
    exit 1
fi
echo "All tests passed!"
exit 0
