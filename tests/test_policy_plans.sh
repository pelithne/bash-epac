#!/usr/bin/env bash
# tests/test_policy_plans.sh — Tests for policy plan and policy set plan building
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

# Create a temp directory for test definition files
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

write_policy_file() {
    local dir="$1" name="$2" content="$3"
    mkdir -p "$dir"
    echo "$content" > "${dir}/${name}"
}

# Standard pac environment
PAC_ENV='{
    "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/root",
    "pacOwnerId": "pac-owner-1",
    "deployedBy": "epac-test",
    "cloud": "AzureCloud",
    "policyDefinitionsScopes": ["/providers/Microsoft.Management/managementGroups/root"],
    "desiredState": {
        "strategy": "full",
        "excludedPolicyDefinitionFiles": [],
        "excludedPolicySetDefinitionFiles": []
    }
}'

EMPTY_DEPLOYED='{"managed": {}, "readOnly": {}}'
EMPTY_ALL_DEFS='{"policydefinitions": {}, "policysetdefinitions": {}}'
EMPTY_REPLACE='{}'
EMPTY_ROLES='{}'

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Function availability ==="

assert_eq "epac_build_policy_plan available" "function" "$(type -t epac_build_policy_plan 2>/dev/null || echo missing)"
assert_eq "epac_build_policy_set_plan available" "function" "$(type -t epac_build_policy_set_plan 2>/dev/null || echo missing)"
assert_eq "epac_build_policy_set_definition_ids available" "function" "$(type -t epac_build_policy_set_definition_ids 2>/dev/null || echo missing)"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Empty definitions folder ==="

result="$(epac_build_policy_plan "/nonexistent" "$PAC_ENV" "$EMPTY_DEPLOYED" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "empty: no new" "$result" '.definitions.new | length' "0"
assert_json_eq "empty: no updates" "$result" '.definitions.update | length' "0"
assert_json_eq "empty: no changes" "$result" '.definitions.numberOfChanges' "0"
assert_json_eq "empty: no unchanged" "$result" '.definitions.numberUnchanged' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== New policy definition ==="

NEW_DIR="${TEST_DIR}/new_policy"
write_policy_file "$NEW_DIR" "test-policy.jsonc" '{
    "name": "test-deny-policy",
    "properties": {
        "displayName": "Test Deny Policy",
        "description": "A test deny policy",
        "mode": "All",
        "metadata": { "category": "Test" },
        "parameters": {
            "effect": {
                "type": "String",
                "defaultValue": "Deny",
                "allowedValues": ["Deny", "Disabled"]
            }
        },
        "policyRule": {
            "if": { "field": "type", "equals": "Microsoft.Compute/virtualMachines" },
            "then": { "effect": "[parameters(\"effect\")]" }
        }
    }
}'

result="$(epac_build_policy_plan "$NEW_DIR" "$PAC_ENV" "$EMPTY_DEPLOYED" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "new: 1 new def" "$result" '.definitions.new | length' "1"
assert_json_eq "new: numberOfChanges=1" "$result" '.definitions.numberOfChanges' "1"
assert_json_eq "new: numberUnchanged=0" "$result" '.definitions.numberUnchanged' "0"

NEW_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/test-deny-policy"
assert_json_eq "new: correct name" "$result" ".definitions.new[\"${NEW_ID}\"].name" "test-deny-policy"
assert_json_eq "new: correct displayName" "$result" ".definitions.new[\"${NEW_ID}\"].displayName" "Test Deny Policy"
assert_json_eq "new: pacOwnerId set" "$result" ".definitions.new[\"${NEW_ID}\"].metadata.pacOwnerId" "pac-owner-1"
assert_json_eq "new: deployedBy set" "$result" ".definitions.new[\"${NEW_ID}\"].metadata.deployedBy" "epac-test"
assert_json_eq "new: in allDefinitions" "$result" ".allDefinitions.policydefinitions[\"${NEW_ID}\"].name" "test-deny-policy"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Role definitions extraction ==="

ROLE_DIR="${TEST_DIR}/role_policy"
write_policy_file "$ROLE_DIR" "dine-policy.jsonc" '{
    "name": "dine-test-policy",
    "properties": {
        "displayName": "DINE Test Policy",
        "description": "A test DINE policy",
        "mode": "All",
        "policyRule": {
            "if": { "field": "type", "equals": "Microsoft.Compute/virtualMachines" },
            "then": {
                "effect": "DeployIfNotExists",
                "details": {
                    "type": "Microsoft.Compute/virtualMachines/extensions",
                    "roleDefinitionIds": [
                        "/providers/Microsoft.Authorization/roleDefinitions/role-1",
                        "/providers/Microsoft.Authorization/roleDefinitions/role-2"
                    ]
                }
            }
        }
    }
}'

result="$(epac_build_policy_plan "$ROLE_DIR" "$PAC_ENV" "$EMPTY_DEPLOYED" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
DINE_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/dine-test-policy"
assert_json_eq "role: 2 role IDs" "$result" ".policyRoleIds[\"${DINE_ID}\"] | length" "2"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Unchanged policy definition ==="

UNCHANGED_DIR="${TEST_DIR}/unchanged_policy"
write_policy_file "$UNCHANGED_DIR" "unchanged.json" '{
    "name": "existing-policy",
    "properties": {
        "displayName": "Existing Policy",
        "description": "An existing policy",
        "mode": "All",
        "metadata": { "category": "Test", "pacOwnerId": "pac-owner-1", "deployedBy": "epac-test" },
        "parameters": null,
        "policyRule": {
            "if": { "field": "type", "equals": "Microsoft.Storage/storageAccounts" },
            "then": { "effect": "Audit" }
        }
    }
}'

UC_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/existing-policy"
DEPLOYED_WITH_EXISTING="{\"managed\": {\"${UC_ID}\": {\"name\": \"existing-policy\", \"properties\": {\"displayName\": \"Existing Policy\", \"description\": \"An existing policy\", \"mode\": \"All\", \"metadata\": {\"category\": \"Test\", \"pacOwnerId\": \"pac-owner-1\", \"deployedBy\": \"epac-test\"}, \"parameters\": null, \"policyRule\": {\"if\": {\"field\": \"type\", \"equals\": \"Microsoft.Storage/storageAccounts\"}, \"then\": {\"effect\": \"Audit\"}}}}}, \"readOnly\": {}}"

result="$(epac_build_policy_plan "$UNCHANGED_DIR" "$PAC_ENV" "$DEPLOYED_WITH_EXISTING" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "unchanged: 0 new" "$result" '.definitions.new | length' "0"
assert_json_eq "unchanged: 0 update" "$result" '.definitions.update | length' "0"
assert_json_eq "unchanged: 0 replace" "$result" '.definitions.replace | length' "0"
assert_json_eq "unchanged: 0 delete" "$result" '.definitions.delete | length' "0"
assert_json_eq "unchanged: 1 unchanged" "$result" '.definitions.numberUnchanged' "1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Updated policy definition (description change) ==="

UPDATE_DIR="${TEST_DIR}/update_policy"
write_policy_file "$UPDATE_DIR" "update.json" '{
    "name": "existing-policy",
    "properties": {
        "displayName": "Existing Policy",
        "description": "UPDATED description",
        "mode": "All",
        "metadata": { "category": "Test", "pacOwnerId": "pac-owner-1", "deployedBy": "epac-test" },
        "parameters": null,
        "policyRule": {
            "if": { "field": "type", "equals": "Microsoft.Storage/storageAccounts" },
            "then": { "effect": "Audit" }
        }
    }
}'

result="$(epac_build_policy_plan "$UPDATE_DIR" "$PAC_ENV" "$DEPLOYED_WITH_EXISTING" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "update: 1 update" "$result" '.definitions.update | length' "1"
assert_json_eq "update: 0 new" "$result" '.definitions.new | length' "0"
assert_json_eq "update: numberOfChanges=1" "$result" '.definitions.numberOfChanges' "1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Replace policy (incompatible param change) ==="

REPLACE_DIR="${TEST_DIR}/replace_policy"
write_policy_file "$REPLACE_DIR" "replace.json" '{
    "name": "existing-policy",
    "properties": {
        "displayName": "Existing Policy",
        "description": "An existing policy",
        "mode": "All",
        "metadata": { "category": "Test", "pacOwnerId": "pac-owner-1", "deployedBy": "epac-test" },
        "parameters": {
            "newParam": { "type": "String" }
        },
        "policyRule": {
            "if": { "field": "type", "equals": "Microsoft.Storage/storageAccounts" },
            "then": { "effect": "Audit" }
        }
    }
}'

# Deployed has no parameters, new adds a parameter without defaultValue → incompatible
DEPLOYED_NO_PARAMS="{\"managed\": {\"${UC_ID}\": {\"name\": \"existing-policy\", \"properties\": {\"displayName\": \"Existing Policy\", \"description\": \"An existing policy\", \"mode\": \"All\", \"metadata\": {\"category\": \"Test\", \"pacOwnerId\": \"pac-owner-1\", \"deployedBy\": \"epac-test\"}, \"parameters\": {}, \"policyRule\": {\"if\": {\"field\": \"type\", \"equals\": \"Microsoft.Storage/storageAccounts\"}, \"then\": {\"effect\": \"Audit\"}}}}}, \"readOnly\": {}}"

result="$(epac_build_policy_plan "$REPLACE_DIR" "$PAC_ENV" "$DEPLOYED_NO_PARAMS" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "replace: 1 replace" "$result" '.definitions.replace | length' "1"
assert_json_eq "replace: in replaceDefinitions" "$result" ".replaceDefinitions[\"${UC_ID}\"].name" "existing-policy"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Delete policy (strategy=full, unknownOwner) ==="

DELETE_DIR="${TEST_DIR}/delete_empty"
mkdir -p "$DELETE_DIR"
# Touch a dummy — but the deployed definition has a policy not in our files
DEL_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/orphaned-policy"
DEPLOYED_ORPHAN="{\"managed\": {\"${DEL_ID}\": {\"name\": \"orphaned-policy\", \"pacOwner\": \"unknownOwner\", \"properties\": {\"displayName\": \"Orphaned Policy\"}}}, \"readOnly\": {}}"

result="$(epac_build_policy_plan "$DELETE_DIR" "$PAC_ENV" "$DEPLOYED_ORPHAN" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "delete: 1 delete" "$result" '.definitions.delete | length' "1"
assert_json_eq "delete: numberOfChanges=1" "$result" '.definitions.numberOfChanges' "1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Skip delete (strategy=full, otherPaC) ==="

DEPLOYED_OTHERPAC="{\"managed\": {\"${DEL_ID}\": {\"name\": \"orphaned-policy\", \"pacOwner\": \"otherPaC\", \"properties\": {\"displayName\": \"Other PAC Policy\"}}}, \"readOnly\": {}}"

result="$(epac_build_policy_plan "$DELETE_DIR" "$PAC_ENV" "$DEPLOYED_OTHERPAC" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "skip delete: 0 delete" "$result" '.definitions.delete | length' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Excluded file ==="

EXCL_DIR="${TEST_DIR}/excl_policy"
write_policy_file "$EXCL_DIR" "excluded.json" '{
    "name": "excluded-policy",
    "properties": {
        "displayName": "Excluded",
        "policyRule": { "if": {}, "then": {"effect": "Deny"} }
    }
}'

PAC_ENV_EXCL="$(echo "$PAC_ENV" | jq '.desiredState.excludedPolicyDefinitionFiles = ["excluded.json"]')"
result="$(epac_build_policy_plan "$EXCL_DIR" "$PAC_ENV_EXCL" "$EMPTY_DEPLOYED" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "excluded: 0 new" "$result" '.definitions.new | length' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Validation: missing name ==="

NONAME_DIR="${TEST_DIR}/noname"
write_policy_file "$NONAME_DIR" "noname.json" '{
    "properties": {
        "displayName": "No Name",
        "policyRule": { "if": {}, "then": {"effect": "Deny"} }
    }
}'
result="$(epac_build_policy_plan "$NONAME_DIR" "$PAC_ENV" "$EMPTY_DEPLOYED" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "noname: 0 new" "$result" '.definitions.new | length' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Cloud environment filter ==="

CLOUD_DIR="${TEST_DIR}/cloud_policy"
write_policy_file "$CLOUD_DIR" "gov-only.json" '{
    "name": "gov-policy",
    "properties": {
        "displayName": "Gov Only",
        "metadata": { "epacCloudEnvironments": ["AzureUSGovernment"] },
        "policyRule": { "if": {}, "then": {"effect": "Deny"} }
    }
}'

result="$(epac_build_policy_plan "$CLOUD_DIR" "$PAC_ENV" "$EMPTY_DEPLOYED" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "cloud filter: 0 new (wrong cloud)" "$result" '.definitions.new | length' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Multiple files ==="

MULTI_DIR="${TEST_DIR}/multi_policy"
write_policy_file "$MULTI_DIR" "policy1.json" '{
    "name": "multi-1",
    "properties": {
        "displayName": "Multi 1",
        "policyRule": { "if": {}, "then": {"effect": "Audit"} }
    }
}'
write_policy_file "$MULTI_DIR" "policy2.json" '{
    "name": "multi-2",
    "properties": {
        "displayName": "Multi 2",
        "policyRule": { "if": {}, "then": {"effect": "Deny"} }
    }
}'

result="$(epac_build_policy_plan "$MULTI_DIR" "$PAC_ENV" "$EMPTY_DEPLOYED" "$EMPTY_ALL_DEFS" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "multi: 2 new" "$result" '.definitions.new | length' "2"
assert_json_eq "multi: numberOfChanges=2" "$result" '.definitions.numberOfChanges' "2"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_build_policy_set_definition_ids ==="

ALL_DEFS_WITH_POLICY='{
    "/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy": {
        "id": "/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy",
        "name": "my-policy"
    }
}'
SCOPES='["/providers/Microsoft.Management/managementGroups/root"]'

PD_ENTRIES='[
    {
        "policyDefinitionReferenceId": "ref1",
        "policyDefinitionId": "/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy",
        "groupNames": ["grp1", "grp2"]
    }
]'

id_result="$(epac_build_policy_set_definition_ids "Test Set" "$PD_ENTRIES" "$SCOPES" "$ALL_DEFS_WITH_POLICY" "$EMPTY_ROLES")"
assert_json_eq "set-ids: valid" "$id_result" '.valid' "true"
assert_json_eq "set-ids: 1 entry" "$id_result" '.policyDefinitions | length' "1"
assert_json_eq "set-ids: correct refId" "$id_result" '.policyDefinitions[0].policyDefinitionReferenceId' "ref1"
assert_json_eq "set-ids: grp1 used" "$id_result" '.usedGroups.grp1' "grp1"
assert_json_eq "set-ids: grp2 used" "$id_result" '.usedGroups.grp2' "grp2"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set ID resolution by name ==="

PD_BY_NAME='[{"policyDefinitionReferenceId": "ref-byname", "policyDefinitionName": "my-policy"}]'
id_result="$(epac_build_policy_set_definition_ids "Test Set" "$PD_BY_NAME" "$SCOPES" "$ALL_DEFS_WITH_POLICY" "$EMPTY_ROLES")"
assert_json_eq "by-name: valid" "$id_result" '.valid' "true"
assert_json_eq "by-name: resolved ID" "$id_result" '.policyDefinitions[0].policyDefinitionId' \
    "/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set ID missing refId ==="

PD_NO_REF='[{"policyDefinitionId": "/some/id"}]'
id_result="$(epac_build_policy_set_definition_ids "Test Set" "$PD_NO_REF" "$SCOPES" "$ALL_DEFS_WITH_POLICY" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "no-ref: invalid" "$id_result" '.valid' "false"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set ID both id and name ==="

PD_BOTH='[{"policyDefinitionReferenceId": "ref1", "policyDefinitionId": "/some/id", "policyDefinitionName": "some-name"}]'
id_result="$(epac_build_policy_set_definition_ids "Test Set" "$PD_BOTH" "$SCOPES" "$ALL_DEFS_WITH_POLICY" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "both-id-name: invalid" "$id_result" '.valid' "false"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set ID not found ==="

PD_NOTFOUND='[{"policyDefinitionReferenceId": "ref1", "policyDefinitionId": "/nonexistent/id"}]'
id_result="$(epac_build_policy_set_definition_ids "Test Set" "$PD_NOTFOUND" "$SCOPES" "$ALL_DEFS_WITH_POLICY" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "not-found: invalid" "$id_result" '.valid' "false"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Role IDs collected from member policies ==="

ROLES_WITH_POLICY="{
    \"/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy\": [\"/providers/Microsoft.Authorization/roleDefinitions/contributor\"]
}"

id_result="$(epac_build_policy_set_definition_ids "Test Set" "$PD_ENTRIES" "$SCOPES" "$ALL_DEFS_WITH_POLICY" "$ROLES_WITH_POLICY")"
assert_json_eq "role-collect: contributor found" "$id_result" '.roleIds["/providers/Microsoft.Authorization/roleDefinitions/contributor"]' "added"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== New policy set definition ==="

SET_DIR="${TEST_DIR}/new_set"
write_policy_file "$SET_DIR" "test-set.jsonc" '{
    "name": "test-initiative",
    "properties": {
        "displayName": "Test Initiative",
        "description": "A test initiative",
        "metadata": { "category": "Test" },
        "parameters": {},
        "policyDefinitions": [
            {
                "policyDefinitionReferenceId": "ref1",
                "policyDefinitionId": "/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy"
            }
        ]
    }
}'

ALL_WITH_POLICY='{"policydefinitions": {"/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy": {"id": "/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy", "name": "my-policy"}}, "policysetdefinitions": {}}'

result="$(epac_build_policy_set_plan "$SET_DIR" "$PAC_ENV" "$EMPTY_DEPLOYED" "$ALL_WITH_POLICY" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "new set: 1 new" "$result" '.definitions.new | length' "1"
SET_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policySetDefinitions/test-initiative"
assert_json_eq "new set: correct name" "$result" ".definitions.new[\"${SET_ID}\"].name" "test-initiative"
assert_json_eq "new set: in allDefinitions" "$result" ".allDefinitions.policysetdefinitions[\"${SET_ID}\"].name" "test-initiative"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Unchanged policy set ==="

DEPLOYED_WITH_SET="{\"managed\": {\"${SET_ID}\": {\"name\": \"test-initiative\", \"properties\": {\"displayName\": \"Test Initiative\", \"description\": \"A test initiative\", \"metadata\": {\"category\": \"Test\", \"pacOwnerId\": \"pac-owner-1\", \"deployedBy\": \"epac-test\"}, \"parameters\": {}, \"policyDefinitions\": [{\"policyDefinitionReferenceId\": \"ref1\", \"policyDefinitionId\": \"/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy\"}], \"policyDefinitionGroups\": null}}}, \"readOnly\": {}}"

result="$(epac_build_policy_set_plan "$SET_DIR" "$PAC_ENV" "$DEPLOYED_WITH_SET" "$ALL_WITH_POLICY" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "unchanged set: 0 new" "$result" '.definitions.new | length' "0"
assert_json_eq "unchanged set: 0 update" "$result" '.definitions.update | length' "0"
assert_json_eq "unchanged set: 1 unchanged" "$result" '.definitions.numberUnchanged' "1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Updated policy set (description change) ==="

UPDATE_SET_DIR="${TEST_DIR}/update_set"
write_policy_file "$UPDATE_SET_DIR" "test-set.jsonc" '{
    "name": "test-initiative",
    "properties": {
        "displayName": "Test Initiative",
        "description": "UPDATED description for initiative",
        "metadata": { "category": "Test" },
        "parameters": {},
        "policyDefinitions": [
            {
                "policyDefinitionReferenceId": "ref1",
                "policyDefinitionId": "/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy"
            }
        ]
    }
}'

result="$(epac_build_policy_set_plan "$UPDATE_SET_DIR" "$PAC_ENV" "$DEPLOYED_WITH_SET" "$ALL_WITH_POLICY" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "update set: 1 update" "$result" '.definitions.update | length' "1"
assert_json_eq "update set: numberOfChanges=1" "$result" '.definitions.numberOfChanges' "1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Replace policy set (contains replaced policy) ==="

REPLACE_DEFS="{\"$( echo '/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy' )\": {\"name\": \"my-policy\"}}"

result="$(epac_build_policy_set_plan "$SET_DIR" "$PAC_ENV" "$DEPLOYED_WITH_SET" "$ALL_WITH_POLICY" "$REPLACE_DEFS" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "replace set: 1 replace" "$result" '.definitions.replace | length' "1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Delete policy set ==="

DEL_SET_DIR="${TEST_DIR}/delete_set_empty"
mkdir -p "$DEL_SET_DIR"

DEL_SET_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policySetDefinitions/orphaned-set"
DEPLOYED_ORPHAN_SET="{\"managed\": {\"${DEL_SET_ID}\": {\"name\": \"orphaned-set\", \"pacOwner\": \"thisPaC\", \"properties\": {\"displayName\": \"Orphaned Set\"}}}, \"readOnly\": {}}"

result="$(epac_build_policy_set_plan "$DEL_SET_DIR" "$PAC_ENV" "$DEPLOYED_ORPHAN_SET" "$ALL_WITH_POLICY" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "delete set: 1 delete" "$result" '.definitions.delete | length' "1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set with groups ==="

GROUP_SET_DIR="${TEST_DIR}/group_set"
write_policy_file "$GROUP_SET_DIR" "grouped-set.jsonc" '{
    "name": "grouped-initiative",
    "properties": {
        "displayName": "Grouped Initiative",
        "policyDefinitions": [
            {
                "policyDefinitionReferenceId": "ref1",
                "policyDefinitionId": "/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policyDefinitions/my-policy",
                "groupNames": ["network"]
            }
        ],
        "policyDefinitionGroups": [
            { "name": "network", "displayName": "Network Controls" }
        ]
    }
}'

result="$(epac_build_policy_set_plan "$GROUP_SET_DIR" "$PAC_ENV" "$EMPTY_DEPLOYED" "$ALL_WITH_POLICY" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
GRP_ID="/providers/Microsoft.Management/managementGroups/root/providers/Microsoft.Authorization/policySetDefinitions/grouped-initiative"
assert_json_eq "groups: 1 new" "$result" '.definitions.new | length' "1"
assert_json_eq "groups: group in output" "$result" ".definitions.new[\"${GRP_ID}\"].policyDefinitionGroups[0].name" "network"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set missing policyDefinitions ==="

NODEF_DIR="${TEST_DIR}/no_pd_set"
write_policy_file "$NODEF_DIR" "no-pd.json" '{
    "name": "no-pd-set",
    "properties": {
        "displayName": "No PDs"
    }
}'

result="$(epac_build_policy_set_plan "$NODEF_DIR" "$PAC_ENV" "$EMPTY_DEPLOYED" "$ALL_WITH_POLICY" "$EMPTY_REPLACE" "$EMPTY_ROLES" 2>/dev/null)"
assert_json_eq "no-pd: 0 new" "$result" '.definitions.new | length' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "================================================================="
echo "  RESULTS: ${PASS} passed, ${FAIL} failed"
echo "================================================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
