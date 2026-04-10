#!/usr/bin/env bash
# tests/test_exemptions_plans.sh — Tests for exemptions plan and deployment plan orchestrator
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source plan builders
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
# Helpers
###############################################################################

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

PAC_ENV='{
    "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/root",
    "pacOwnerId": "pac-owner-1",
    "deployedBy": "epac-test",
    "cloud": "AzureCloud",
    "tenantId": "tenant-1",
    "pacSelector": "dev",
    "desiredState": {"strategy": "full"},
    "policyDefinitionsScopes": ["/providers/Microsoft.Management/managementGroups/root"]
}'

# Test assignment: direct policy assignment
POLICY_DEF_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/test-policy"
POLICY_SET_DEF_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policySetDefinitions/test-policyset"

ASSIGNMENT_1_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyAssignments/test-assign-1"
ASSIGNMENT_2_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyAssignments/test-assign-2"

ALL_ASSIGNMENTS="$(jq -n \
    --arg a1 "$ASSIGNMENT_1_ID" --arg a2 "$ASSIGNMENT_2_ID" \
    --arg pd "$POLICY_DEF_ID" --arg psd "$POLICY_SET_DEF_ID" \
    '{
        ($a1): {
            id: $a1, name: "test-assign-1",
            properties: {
                displayName: "Test Assignment 1",
                policyDefinitionId: $pd,
                scope: "/providers/Microsoft.Management/managementGroups/root",
                notScopes: []
            }
        },
        ($a2): {
            id: $a2, name: "test-assign-2",
            properties: {
                displayName: "Test Assignment 2",
                policyDefinitionId: $psd,
                scope: "/providers/Microsoft.Management/managementGroups/root",
                notScopes: []
            }
        }
    }')"

COMBINED_DETAILS="$(jq -n \
    --arg pd "$POLICY_DEF_ID" --arg psd "$POLICY_SET_DEF_ID" \
    '{
        policies: {
            ($pd): {
                id: $pd, name: "test-policy", displayName: "Test Policy",
                isDeprecated: false, policyType: "Custom",
                category: "General", effectDefault: "Deny"
            }
        },
        policySets: {
            ($psd): {
                id: $psd, name: "test-policyset", displayName: "Test Policy Set",
                isDeprecated: false, policyType: "Custom",
                policyDefinitions: [
                    {id: $pd, policyDefinitionReferenceId: "ref-1", policyDefinitionId: $pd}
                ]
            }
        }
    }')"

ALL_DEFINITIONS="$(jq -n \
    --arg pd "$POLICY_DEF_ID" --arg psd "$POLICY_SET_DEF_ID" \
    '{
        policydefinitions: {
            ($pd): {id: $pd, name: "test-policy", properties: {displayName: "Test Policy"}}
        },
        policysetdefinitions: {
            ($psd): {id: $psd, name: "test-policyset", properties: {displayName: "Test Policy Set"}}
        }
    }')"

DEPLOYED_EXEMPTIONS_EMPTY='{"managed":{},"readOnly":{}}'
REPLACED_ASSIGNMENTS='{}'

###############################################################################
echo "=== _epac_get_calculated_assignments ==="
###############################################################################

echo "--- Direct policy assignment lookup ---"
result="$(_epac_get_calculated_assignments "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" 2>/dev/null)"
assert_json_eq "byAssignmentId has assign-1" "$result" \
    ".byAssignmentId[\"$ASSIGNMENT_1_ID\"] | length" "1"
assert_json_eq "assign-1 isPolicyAssignment=true" "$result" \
    ".byAssignmentId[\"$ASSIGNMENT_1_ID\"][0].isPolicyAssignment" "true"
assert_json_eq "byPolicyId has test-policy (direct)" "$result" \
    ".byPolicyId[\"$POLICY_DEF_ID\"] | map(select(.isPolicyAssignment == true)) | length" "1"
assert_json_eq "byPolicyId entry is policy assignment" "$result" \
    ".byPolicyId[\"$POLICY_DEF_ID\"][0].isPolicyAssignment" "true"

echo "--- Policy set assignment lookup ---"
assert_json_eq "byAssignmentId has assign-2" "$result" \
    ".byAssignmentId[\"$ASSIGNMENT_2_ID\"] | length" "1"
assert_json_eq "assign-2 isPolicyAssignment=false" "$result" \
    ".byAssignmentId[\"$ASSIGNMENT_2_ID\"][0].isPolicyAssignment" "false"
assert_json_eq "assign-2 allowReferenceIdsInRow=true" "$result" \
    ".byAssignmentId[\"$ASSIGNMENT_2_ID\"][0].allowReferenceIdsInRow" "true"
assert_json_eq "byPolicySetId has test-policyset" "$result" \
    ".byPolicySetId[\"$POLICY_SET_DEF_ID\"] | length" "1"
# byPolicyId should have the policy definition referenced from the set
assert_json_eq "byPolicyId has policy from set (assign-2)" "$result" \
    ".byPolicyId[\"$POLICY_DEF_ID\"] | length" "2"

echo "--- Empty assignments ---"
result_empty="$(_epac_get_calculated_assignments "{}" "$COMBINED_DETAILS" 2>/dev/null)"
assert_json_eq "empty byAssignmentId" "$result_empty" '.byAssignmentId | length' "0"
assert_json_eq "empty byPolicySetId" "$result_empty" '.byPolicySetId | length' "0"
assert_json_eq "empty byPolicyId" "$result_empty" '.byPolicyId | length' "0"

###############################################################################
echo ""
echo "=== _epac_resolve_exemption_assignments ==="
###############################################################################

calc_assigns="$(_epac_get_calculated_assignments "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" 2>/dev/null)"
pd_scopes='["/providers/Microsoft.Management/managementGroups/root"]'
all_pd="$(echo "$ALL_DEFINITIONS" | jq '.policydefinitions')"
all_psd="$(echo "$ALL_DEFINITIONS" | jq '.policysetdefinitions')"

echo "--- Resolve by policyAssignmentId ---"
entry_by_id="$(jq -n --arg aid "$ASSIGNMENT_1_ID" '{policyAssignmentId: $aid}')"
resolved="$(_epac_resolve_exemption_assignments "$entry_by_id" "$calc_assigns" "$pd_scopes" "$all_pd" "$all_psd" 2>/dev/null)"
assert_json_eq "resolved by assignment ID length=1" "$resolved" 'length' "1"
assert_json_eq "resolved by assignment ID id" "$resolved" '.[0].id' "$ASSIGNMENT_1_ID"

echo "--- Resolve DoNotValidate ---"
entry_dnv="$(jq -n --arg aid "$ASSIGNMENT_1_ID" '{policyAssignmentId: $aid, assignmentScopeValidation: "DoNotValidate"}')"
resolved_dnv="$(_epac_resolve_exemption_assignments "$entry_dnv" "$calc_assigns" "$pd_scopes" "$all_pd" "$all_psd" 2>/dev/null)"
assert_json_eq "DoNotValidate gives synthetic result" "$resolved_dnv" 'length' "1"
assert_json_eq "DoNotValidate id matches" "$resolved_dnv" '.[0].id' "$ASSIGNMENT_1_ID"
assert_json_eq "DoNotValidate isPolicyAssignment" "$resolved_dnv" '.[0].isPolicyAssignment' "true"

echo "--- Resolve empty gives empty ---"
entry_empty='{"noRef": "true"}'
resolved_empty="$(_epac_resolve_exemption_assignments "$entry_empty" "$calc_assigns" "$pd_scopes" "$all_pd" "$all_psd" 2>/dev/null)"
assert_json_eq "no ref results in empty" "$resolved_empty" 'length' "0"

echo "--- Resolve by assignmentReferenceId (assignment path) ---"
entry_ref="$(jq -n --arg aid "$ASSIGNMENT_1_ID" '{assignmentReferenceId: $aid}')"
resolved_ref="$(_epac_resolve_exemption_assignments "$entry_ref" "$calc_assigns" "$pd_scopes" "$all_pd" "$all_psd" 2>/dev/null)"
assert_json_eq "ref by assignment path length=1" "$resolved_ref" 'length' "1"

###############################################################################
echo ""
echo "=== _epac_parse_csv_exemptions ==="
###############################################################################

echo "--- Parse simple CSV ---"
csv_file="${TEST_DIR}/test.csv"
cat > "$csv_file" << 'CSVEOF'
name,displayName,exemptionCategory,scope
ex-1,Exemption 1,Waiver,/subscriptions/sub1
ex-2,Exemption 2,Mitigated,/subscriptions/sub2
CSVEOF
csv_result="$(_epac_parse_csv_exemptions "$csv_file")"
assert_json_eq "CSV 2 entries" "$csv_result" 'length' "2"
assert_json_eq "CSV first name" "$csv_result" '.[0].name' "ex-1"
assert_json_eq "CSV first displayName" "$csv_result" '.[0].displayName' "Exemption 1"
assert_json_eq "CSV first category" "$csv_result" '.[0].exemptionCategory' "Waiver"
assert_json_eq "CSV second name" "$csv_result" '.[1].name' "ex-2"
assert_json_eq "CSV second category" "$csv_result" '.[1].exemptionCategory' "Mitigated"

echo "--- Parse empty CSV (header only) ---"
csv_empty="${TEST_DIR}/empty.csv"
echo "name,displayName,exemptionCategory,scope" > "$csv_empty"
csv_empty_result="$(_epac_parse_csv_exemptions "$csv_empty")"
assert_json_eq "empty CSV 0 entries" "$csv_empty_result" 'length' "0"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — New exemptions ==="
###############################################################################

echo "--- New exemption from JSON file ---"
exemption_dir="${TEST_DIR}/exemptions-new"
mkdir -p "$exemption_dir"
cat > "${exemption_dir}/test-exemption.jsonc" << JSONEOF
{
    "exemptions": [
        {
            "name": "test-ex-1",
            "displayName": "Test Exemption 1",
            "exemptionCategory": "Waiver",
            "description": "Test description",
            "policyAssignmentId": "${ASSIGNMENT_1_ID}",
            "scope": "/providers/Microsoft.Management/managementGroups/root"
        }
    ]
}
JSONEOF

plan="$(epac_build_exemptions_plan \
    "$exemption_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

assert_json_eq "1 new exemption" "$plan" '.exemptions.new | length' "1"
assert_json_eq "0 updates" "$plan" '.exemptions.update | length' "0"
assert_json_eq "0 replaces" "$plan" '.exemptions.replace | length' "0"
assert_json_eq "0 deletes" "$plan" '.exemptions.delete | length' "0"
assert_json_eq "0 unchanged" "$plan" '.exemptions.numberUnchanged' "0"
assert_json_eq "1 total change" "$plan" '.exemptions.numberOfChanges' "1"

# Verify exemption content
first_key="$(echo "$plan" | jq -r '.exemptions.new | keys[0]')"
assert_json_eq "new exemption name" "$plan" ".exemptions.new[\"$first_key\"].name" "test-ex-1"
assert_json_eq "new exemption displayName" "$plan" ".exemptions.new[\"$first_key\"].displayName" "Test Exemption 1"
assert_json_eq "new exemption category" "$plan" ".exemptions.new[\"$first_key\"].exemptionCategory" "Waiver"
assert_json_eq "new exemption has pacOwnerId" "$plan" ".exemptions.new[\"$first_key\"].metadata.pacOwnerId" "pac-owner-1"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Unchanged ==="
###############################################################################

echo "--- Exemption already deployed, no changes ---"
deployed_ex_id="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyExemptions/test-ex-1"
deployed_exemptions="$(jq -n \
    --arg id "$deployed_ex_id" --arg paid "$ASSIGNMENT_1_ID" \
    '{
        managed: {
            ($id): {
                id: $id, name: "test-ex-1",
                properties: {
                    displayName: "Test Exemption 1",
                    description: "Test description",
                    exemptionCategory: "Waiver",
                    policyAssignmentId: $paid,
                    assignmentScopeValidation: "Default",
                    metadata: {"pacOwnerId": "pac-owner-1", "deployedBy": "epac-test"},
                    policyDefinitionReferenceIds: null,
                    resourceSelectors: null,
                    expiresOn: ""
                }
            }
        },
        readOnly: {}
    }')"

plan_unchanged="$(epac_build_exemptions_plan \
    "$exemption_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$deployed_exemptions" "false" "false" 2>/dev/null)"

assert_json_eq "0 new" "$plan_unchanged" '.exemptions.new | length' "0"
assert_json_eq "0 updates" "$plan_unchanged" '.exemptions.update | length' "0"
assert_json_eq "0 replaces" "$plan_unchanged" '.exemptions.replace | length' "0"
assert_json_eq "0 deletes" "$plan_unchanged" '.exemptions.delete | length' "0"
assert_json_eq "1 unchanged" "$plan_unchanged" '.exemptions.numberUnchanged' "1"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Update ==="
###############################################################################

echo "--- Update when displayName changes ---"
deployed_update="$(jq -n \
    --arg id "$deployed_ex_id" --arg paid "$ASSIGNMENT_1_ID" \
    '{
        managed: {
            ($id): {
                id: $id, name: "test-ex-1",
                properties: {
                    displayName: "Old Name",
                    description: "Test description",
                    exemptionCategory: "Waiver",
                    policyAssignmentId: $paid,
                    assignmentScopeValidation: "Default",
                    metadata: {"pacOwnerId": "pac-owner-1", "deployedBy": "epac-test"},
                    policyDefinitionReferenceIds: null,
                    resourceSelectors: null,
                    expiresOn: ""
                }
            }
        },
        readOnly: {}
    }')"

plan_update="$(epac_build_exemptions_plan \
    "$exemption_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$deployed_update" "false" "false" 2>/dev/null)"

assert_json_eq "0 new" "$plan_update" '.exemptions.new | length' "0"
assert_json_eq "1 update" "$plan_update" '.exemptions.update | length' "1"
assert_json_eq "0 replaces" "$plan_update" '.exemptions.replace | length' "0"
assert_json_eq "0 deletes" "$plan_update" '.exemptions.delete | length' "0"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Replace ==="
###############################################################################

echo "--- Replace when assignment was replaced ---"
plan_replace="$(epac_build_exemptions_plan \
    "$exemption_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" \
    "$(jq -n --arg id "$ASSIGNMENT_1_ID" '{($id): true}')" \
    "$deployed_exemptions" "false" "false" 2>/dev/null)"

assert_json_eq "0 new" "$plan_replace" '.exemptions.new | length' "0"
assert_json_eq "0 updates" "$plan_replace" '.exemptions.update | length' "0"
assert_json_eq "1 replace" "$plan_replace" '.exemptions.replace | length' "1"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Delete ==="
###############################################################################

echo "--- Delete exemptions not in definition files ---"
extra_deployed_id="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyExemptions/orphaned-ex"
deployed_with_extra="$(jq -n \
    --arg id "$deployed_ex_id" --arg eid "$extra_deployed_id" --arg paid "$ASSIGNMENT_1_ID" \
    '{
        managed: {
            ($id): {
                id: $id, name: "test-ex-1",
                displayName: "Test Exemption 1",
                properties: {
                    displayName: "Test Exemption 1",
                    description: "Test description",
                    exemptionCategory: "Waiver",
                    policyAssignmentId: $paid,
                    assignmentScopeValidation: "Default",
                    metadata: {"pacOwnerId": "pac-owner-1", "deployedBy": "epac-test"},
                    policyDefinitionReferenceIds: null,
                    resourceSelectors: null,
                    expiresOn: ""
                }
            },
            ($eid): {
                id: $eid, name: "orphaned-ex",
                displayName: "Orphaned Exemption",
                properties: {
                    displayName: "Orphaned Exemption",
                    exemptionCategory: "Waiver",
                    metadata: {"pacOwnerId": "pac-owner-1"}
                }
            }
        },
        readOnly: {}
    }')"

plan_delete="$(epac_build_exemptions_plan \
    "$exemption_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$deployed_with_extra" "false" "false" 2>/dev/null)"

assert_json_eq "0 new" "$plan_delete" '.exemptions.new | length' "0"
assert_json_eq "1 delete" "$plan_delete" '.exemptions.delete | length' "1"
assert_json_eq "1 unchanged" "$plan_delete" '.exemptions.numberUnchanged' "1"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Missing folder ==="
###############################################################################

echo "--- Missing folder gives empty plan ---"
plan_missing="$(epac_build_exemptions_plan \
    "${TEST_DIR}/no-such-folder" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

assert_json_eq "0 changes" "$plan_missing" '.exemptions.numberOfChanges' "0"
assert_json_eq "0 new" "$plan_missing" '.exemptions.new | length' "0"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Empty folder ==="
###############################################################################

echo "--- Empty folder gives empty plan ---"
empty_dir="${TEST_DIR}/empty-exemptions"
mkdir -p "$empty_dir"
plan_empty="$(epac_build_exemptions_plan \
    "$empty_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

assert_json_eq "0 changes" "$plan_empty" '.exemptions.numberOfChanges' "0"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Validation errors ==="
###############################################################################

echo "--- Missing required fields ---"
bad_dir="${TEST_DIR}/bad-exemptions"
mkdir -p "$bad_dir"
cat > "${bad_dir}/bad.json" << 'JSONEOF'
{
    "exemptions": [
        {"displayName": "No Name", "exemptionCategory": "Waiver", "scope": "/sub"},
        {"name": "no-display", "exemptionCategory": "Waiver", "scope": "/sub"},
        {"name": "no-cat", "displayName": "No Cat", "scope": "/sub"},
        {"name": "bad-cat", "displayName": "Bad Cat", "exemptionCategory": "Invalid", "scope": "/sub"},
        {"name": "no-scope", "displayName": "No Scope", "exemptionCategory": "Waiver"}
    ]
}
JSONEOF

plan_bad="$(epac_build_exemptions_plan \
    "$bad_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

# All 5 entries should be skipped, no new exemptions
assert_json_eq "0 new from bad entries" "$plan_bad" '.exemptions.new | length' "0"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Multiple scopes ==="
###############################################################################

echo "--- Multiple scopes create multiple exemptions ---"
multi_scope_dir="${TEST_DIR}/multi-scope"
mkdir -p "$multi_scope_dir"
cat > "${multi_scope_dir}/multi.jsonc" << JSONEOF
{
    "exemptions": [
        {
            "name": "multi-scope-ex",
            "displayName": "Multi Scope Exemption",
            "exemptionCategory": "Mitigated",
            "description": "Test multi",
            "policyAssignmentId": "${ASSIGNMENT_1_ID}",
            "scopes": [
                "/providers/Microsoft.Management/managementGroups/root/subscriptions/sub1",
                "/providers/Microsoft.Management/managementGroups/root/subscriptions/sub2"
            ]
        }
    ]
}
JSONEOF

plan_multi="$(epac_build_exemptions_plan \
    "$multi_scope_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

assert_json_eq "2 new exemptions from 2 scopes" "$plan_multi" '.exemptions.new | length' "2"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Duplicate detection ==="
###############################################################################

echo "--- Duplicate exemption IDs cause error ---"
dup_dir="${TEST_DIR}/dup-exemptions"
mkdir -p "$dup_dir"
cat > "${dup_dir}/dup1.jsonc" << JSONEOF
{
    "exemptions": [
        {
            "name": "dup-ex",
            "displayName": "Dup 1",
            "exemptionCategory": "Waiver",
            "policyAssignmentId": "${ASSIGNMENT_1_ID}",
            "scope": "/providers/Microsoft.Management/managementGroups/root"
        },
        {
            "name": "dup-ex",
            "displayName": "Dup 2",
            "exemptionCategory": "Waiver",
            "policyAssignmentId": "${ASSIGNMENT_1_ID}",
            "scope": "/providers/Microsoft.Management/managementGroups/root"
        }
    ]
}
JSONEOF

plan_dup="$(epac_build_exemptions_plan \
    "$dup_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

# First is new, second is duplicate (skipped)
assert_json_eq "1 new (second is dup)" "$plan_dup" '.exemptions.new | length' "1"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Expiration ==="
###############################################################################

echo "--- Expired exemption counted ---"
exp_dir="${TEST_DIR}/expired-exemptions"
mkdir -p "$exp_dir"
yesterday="$(date -d 'yesterday' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -v-1d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '2020-01-01T00:00:00Z')"
cat > "${exp_dir}/expired.jsonc" << JSONEOF
{
    "exemptions": [
        {
            "name": "expired-ex",
            "displayName": "Expired Exemption",
            "exemptionCategory": "Waiver",
            "policyAssignmentId": "${ASSIGNMENT_1_ID}",
            "scope": "/providers/Microsoft.Management/managementGroups/root",
            "expiresOn": "${yesterday}"
        }
    ]
}
JSONEOF

plan_exp="$(epac_build_exemptions_plan \
    "$exp_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

assert_json_eq "1 new, expired" "$plan_exp" '.exemptions.new | length' "1"
assert_json_eq "1 expired count" "$plan_exp" '.exemptions.numberOfExpired' "1"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — CSV input ==="
###############################################################################

echo "--- CSV exemption file ---"
csv_dir="${TEST_DIR}/csv-exemptions"
mkdir -p "$csv_dir"
cat > "${csv_dir}/exemptions.csv" << CSVEOF
name,displayName,exemptionCategory,scope,policyAssignmentId
csv-ex-1,CSV Exemption 1,Waiver,/providers/Microsoft.Management/managementGroups/root,${ASSIGNMENT_1_ID}
CSVEOF

plan_csv="$(epac_build_exemptions_plan \
    "$csv_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

assert_json_eq "1 new from CSV" "$plan_csv" '.exemptions.new | length' "1"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Metadata merging ==="
###############################################################################

echo "--- Custom metadata with pacOwnerId ---"
meta_dir="${TEST_DIR}/meta-exemptions"
mkdir -p "$meta_dir"
cat > "${meta_dir}/meta.jsonc" << JSONEOF
{
    "exemptions": [
        {
            "name": "meta-ex",
            "displayName": "Meta Exemption",
            "exemptionCategory": "Waiver",
            "policyAssignmentId": "${ASSIGNMENT_1_ID}",
            "scope": "/providers/Microsoft.Management/managementGroups/root",
            "metadata": {
                "customKey": "customValue",
                "ticket": "JIRA-123"
            }
        }
    ]
}
JSONEOF

plan_meta="$(epac_build_exemptions_plan \
    "$meta_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

first_meta_key="$(echo "$plan_meta" | jq -r '.exemptions.new | keys[0]')"
assert_json_eq "metadata has pacOwnerId" "$plan_meta" ".exemptions.new[\"$first_meta_key\"].metadata.pacOwnerId" "pac-owner-1"
assert_json_eq "metadata has customKey" "$plan_meta" ".exemptions.new[\"$first_meta_key\"].metadata.customKey" "customValue"
assert_json_eq "metadata has ticket" "$plan_meta" ".exemptions.new[\"$first_meta_key\"].metadata.ticket" "JIRA-123"
assert_json_eq "metadata has deployedBy" "$plan_meta" ".exemptions.new[\"$first_meta_key\"].metadata.deployedBy" "epac-test"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Category update ==="
###############################################################################

echo "--- Update when exemptionCategory changes ---"
cat_deployed="$(jq -n \
    --arg id "$deployed_ex_id" --arg paid "$ASSIGNMENT_1_ID" \
    '{
        managed: {
            ($id): {
                id: $id, name: "test-ex-1",
                properties: {
                    displayName: "Test Exemption 1",
                    description: "Test description",
                    exemptionCategory: "Mitigated",
                    policyAssignmentId: $paid,
                    assignmentScopeValidation: "Default",
                    metadata: {"pacOwnerId": "pac-owner-1", "deployedBy": "epac-test"},
                    policyDefinitionReferenceIds: null,
                    resourceSelectors: null,
                    expiresOn: ""
                }
            }
        },
        readOnly: {}
    }')"

plan_cat="$(epac_build_exemptions_plan \
    "$exemption_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$cat_deployed" "false" "false" 2>/dev/null)"

assert_json_eq "1 update (category change)" "$plan_cat" '.exemptions.update | length' "1"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Replace on mismatched assignment ==="
###############################################################################

echo "--- Replace when deployed assignment differs ---"
diff_assign_deployed="$(jq -n \
    --arg id "$deployed_ex_id" --arg paid "/some/other/assignment" \
    '{
        managed: {
            ($id): {
                id: $id, name: "test-ex-1",
                properties: {
                    displayName: "Test Exemption 1",
                    description: "Test description",
                    exemptionCategory: "Waiver",
                    policyAssignmentId: $paid,
                    assignmentScopeValidation: "Default",
                    metadata: {"pacOwnerId": "pac-owner-1", "deployedBy": "epac-test"},
                    policyDefinitionReferenceIds: null,
                    resourceSelectors: null,
                    expiresOn: ""
                }
            }
        },
        readOnly: {}
    }')"

plan_diff_assign="$(epac_build_exemptions_plan \
    "$exemption_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$diff_assign_deployed" "false" "false" 2>/dev/null)"

assert_json_eq "1 replace (different assignment)" "$plan_diff_assign" '.exemptions.replace | length' "1"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Scope postfix ==="
###############################################################################

echo "--- Scope postfix in scope string ---"
postfix_dir="${TEST_DIR}/postfix-exemptions"
mkdir -p "$postfix_dir"
cat > "${postfix_dir}/postfix.jsonc" << JSONEOF
{
    "exemptions": [
        {
            "name": "postfix-ex",
            "displayName": "Postfix Exemption",
            "exemptionCategory": "Waiver",
            "policyAssignmentId": "${ASSIGNMENT_1_ID}",
            "scopes": [
                "prod:/providers/Microsoft.Management/managementGroups/root/subscriptions/sub1",
                "dev:/providers/Microsoft.Management/managementGroups/root/subscriptions/sub2"
            ]
        }
    ]
}
JSONEOF

plan_postfix="$(epac_build_exemptions_plan \
    "$postfix_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

assert_json_eq "2 new from postfix scopes" "$plan_postfix" '.exemptions.new | length' "2"
# Check that display names have postfix
first_postfix_key="$(echo "$plan_postfix" | jq -r '.exemptions.new | keys[0]')"
second_postfix_key="$(echo "$plan_postfix" | jq -r '.exemptions.new | keys[1]')"
dn1="$(echo "$plan_postfix" | jq -r ".exemptions.new[\"$first_postfix_key\"].displayName")"
dn2="$(echo "$plan_postfix" | jq -r ".exemptions.new[\"$second_postfix_key\"].displayName")"
# Check one of them contains "dev" or "prod" in display name
# Check that display names contain postfix strings
has_postfix_1="false"
[[ "$dn1" == *" - dev"* || "$dn1" == *" - prod"* ]] && has_postfix_1="true"
assert_eq "postfix in displayName 1" "true" "$has_postfix_1"
has_postfix_2="false"
[[ "$dn2" == *" - dev"* || "$dn2" == *" - prod"* ]] && has_postfix_2="true"
assert_eq "postfix in displayName 2" "true" "$has_postfix_2"

###############################################################################
echo ""
echo "=== epac_build_exemptions_plan — Root array format ==="
###############################################################################

echo "--- JSON file with root array ---"
arr_dir="${TEST_DIR}/array-exemptions"
mkdir -p "$arr_dir"
cat > "${arr_dir}/array.json" << JSONEOF
[
    {
        "name": "arr-ex-1",
        "displayName": "Array Exemption",
        "exemptionCategory": "Waiver",
        "policyAssignmentId": "${ASSIGNMENT_1_ID}",
        "scope": "/providers/Microsoft.Management/managementGroups/root"
    }
]
JSONEOF

plan_arr="$(epac_build_exemptions_plan \
    "$arr_dir" "$PAC_ENV" "{}" "$ALL_DEFINITIONS" \
    "$ALL_ASSIGNMENTS" "$COMBINED_DETAILS" "$REPLACED_ASSIGNMENTS" \
    "$DEPLOYED_EXEMPTIONS_EMPTY" "false" "false" 2>/dev/null)"

assert_json_eq "1 new from array format" "$plan_arr" '.exemptions.new | length' "1"

###############################################################################
echo ""
echo "=== _epac_emit_exemptions_plan_result ==="
###############################################################################

echo "--- Result structure ---"
emit_result="$(_epac_emit_exemptions_plan_result '{"a": 1}' '{"b": 2, "c": 3}' '{}' '{"d": 4}' 5 2 1)"
assert_json_eq "emit new count" "$emit_result" '.exemptions.new | length' "1"
assert_json_eq "emit update count" "$emit_result" '.exemptions.update | length' "2"
assert_json_eq "emit replace count" "$emit_result" '.exemptions.replace | length' "0"
assert_json_eq "emit delete count" "$emit_result" '.exemptions.delete | length' "1"
assert_json_eq "emit unchanged" "$emit_result" '.exemptions.numberUnchanged' "5"
assert_json_eq "emit orphans" "$emit_result" '.exemptions.numberOfOrphans' "2"
assert_json_eq "emit expired" "$emit_result" '.exemptions.numberOfExpired' "1"
assert_json_eq "emit total changes" "$emit_result" '.exemptions.numberOfChanges' "4"

###############################################################################
echo ""
echo "=== build-deployment-plans.sh — Script structure ==="
###############################################################################

echo "--- Script exists and is executable ---"
assert_true "build-deployment-plans.sh exists" test -f "${SCRIPT_DIR}/../scripts/deploy/build-deployment-plans.sh"
assert_true "build-deployment-plans.sh is executable" test -x "${SCRIPT_DIR}/../scripts/deploy/build-deployment-plans.sh"

echo "--- Script has usage help ---"
help_output="$(bash "${SCRIPT_DIR}/../scripts/deploy/build-deployment-plans.sh" --help 2>&1 || true)"
_check_help() { echo "$help_output" | grep -q "$1"; }
assert_true "help mentions pac-environment" _check_help 'pac-environment'
assert_true "help mentions output-folder" _check_help 'output-folder'
assert_true "help mentions devops-type" _check_help 'devops-type'
assert_true "help mentions build-exemptions-only" _check_help 'build-exemptions-only'
assert_true "help mentions skip-exemptions" _check_help 'skip-exemptions'

echo "--- Conflict detection ---"
conflict_output="$(bash "${SCRIPT_DIR}/../scripts/deploy/build-deployment-plans.sh" \
    --build-exemptions-only --skip-exemptions 2>&1 || true)"
_check_conflict() { echo "$conflict_output" | grep -q 'cannot be used together'; }
assert_true "conflict error" _check_conflict

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
