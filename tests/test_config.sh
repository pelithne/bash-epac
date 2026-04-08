#!/usr/bin/env bash
# tests/test_config.sh — Tests for WI-03 config.sh
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

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected to contain '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_get_custom_metadata ==="

meta='{"createdBy":"someone","createdOn":"2024-01-01","updatedBy":"else","updatedOn":"2024-02-01","lastSyncedToArgOn":"2024-03-01","keep":"me","also":"keep"}'
result="$(epac_get_custom_metadata "$meta")"
assert_json_eq "strips createdBy" "$result" '.createdBy // "gone"' "gone"
assert_json_eq "strips createdOn" "$result" '.createdOn // "gone"' "gone"
assert_json_eq "strips updatedBy" "$result" '.updatedBy // "gone"' "gone"
assert_json_eq "strips updatedOn" "$result" '.updatedOn // "gone"' "gone"
assert_json_eq "strips lastSyncedToArgOn" "$result" '.lastSyncedToArgOn // "gone"' "gone"
assert_json_eq "keeps keep" "$result" '.keep' "me"
assert_json_eq "keeps also" "$result" '.also' "keep"

meta2='{"createdBy":"x","custom1":"a","custom2":"b","keep":"yes"}'
result2="$(epac_get_custom_metadata "$meta2" "custom1,custom2")"
assert_json_eq "extra remove custom1" "$result2" '.custom1 // "gone"' "gone"
assert_json_eq "extra remove custom2" "$result2" '.custom2 // "gone"' "gone"
assert_json_eq "extra keep keep" "$result2" '.keep' "yes"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_get_deployment_plan ==="

tmp_plan="$(mktemp)"
echo '{"plan": "test", "count": 42}' > "$tmp_plan"
plan="$(epac_get_deployment_plan "$tmp_plan")"
assert_json_eq "reads plan field" "$plan" '.plan' "test"
assert_json_eq "reads plan count" "$plan" '.count' "42"
rm -f "$tmp_plan"

missing_plan="$(epac_get_deployment_plan "/nonexistent/file.json")"
assert_eq "missing file returns null" "null" "$missing_plan"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_add_selected_pac_array ==="

obj='{"dev": ["a","b"], "prod": ["c"], "*": ["z"]}'
arr="$(epac_add_selected_pac_array "$obj" "dev")"
assert_json_count "pac array dev count" "$arr" "." "3"  # a,b + z
assert_eq "pac array dev contains a" "true" "$(echo "$arr" | jq 'any(. == "a")')"
assert_eq "pac array dev contains z (wildcard)" "true" "$(echo "$arr" | jq 'any(. == "z")')"

arr_prod="$(epac_add_selected_pac_array "$obj" "prod")"
assert_json_count "pac array prod count" "$arr_prod" "." "2"  # c + z

arr_unknown="$(epac_add_selected_pac_array "$obj" "staging")"
assert_json_count "pac array unknown falls back to *" "$arr_unknown" "." "1"
assert_eq "pac array unknown has z" "true" "$(echo "$arr_unknown" | jq 'any(. == "z")')"

arr_existing="$(epac_add_selected_pac_array "$obj" "dev" '["existing"]')"
assert_json_count "pac array with existing" "$arr_existing" "." "4"  # existing + a,b + z

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_add_selected_pac_value ==="

val_obj='{"dev": "val-dev", "prod": "val-prod", "*": "val-default"}'
out='{"key1": "existing"}'

result="$(epac_add_selected_pac_value "$val_obj" "dev" "$out" "mykey")"
assert_json_eq "pac value dev" "$result" '.mykey' "val-dev"
assert_json_eq "pac value keeps existing" "$result" '.key1' "existing"

result_wild="$(epac_add_selected_pac_value "$val_obj" "staging" "$out" "mykey")"
assert_json_eq "pac value wildcard fallback" "$result_wild" '.mykey' "val-default"

no_wild='{"dev": "x"}'
result_no="$(epac_add_selected_pac_value "$no_wild" "staging" "$out" "mykey")"
assert_json_eq "pac value no match no wildcard" "$result_no" '.mykey // "absent"' "absent"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_get_selector_arrays ==="

sel='{"selectors": [{"in": ["a","b"], "notIn": ["x"]}, {"in": ["c"], "notIn": ["y","z"]}]}'
sa="$(epac_get_selector_arrays "$sel")"
assert_json_count "selector in count" "$sa" '.In' "3"
assert_json_count "selector notIn count" "$sa" '.NotIn' "3"
assert_eq "selector in has a" "true" "$(echo "$sa" | jq '.In | any(. == "a")')"
assert_eq "selector notIn has z" "true" "$(echo "$sa" | jq '.NotIn | any(. == "z")')"

empty_sel='{"selectors": []}'
sa2="$(epac_get_selector_arrays "$empty_sel")"
assert_json_count "empty selector in" "$sa2" '.In' "0"
assert_json_count "empty selector notIn" "$sa2" '.NotIn' "0"

no_sel='{}'
sa3="$(epac_get_selector_arrays "$no_sel")"
assert_json_count "no selectors in" "$sa3" '.In' "0"
assert_json_count "no selectors notIn" "$sa3" '.NotIn' "0"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== scope helpers ==="

assert_eq "validate sub scope" "0" "$(_epac_validate_scope "/subscriptions/00000000-0000-0000-0000-000000000000" && echo 0 || echo 1)"
assert_eq "validate mg scope" "0" "$(_epac_validate_scope "/providers/Microsoft.Management/managementGroups/my-mg" && echo 0 || echo 1)"
assert_eq "invalid scope" "1" "$(_epac_validate_scope "/invalid/path" && echo 0 || echo 1)"

assert_eq "classify sub" "subscription" "$(_epac_classify_scope "/subscriptions/00000000-0000-0000-0000-000000000000")"
assert_eq "classify rg" "resourceGroup" "$(_epac_classify_scope "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/my-rg")"
assert_eq "classify mg" "managementGroup" "$(_epac_classify_scope "/providers/Microsoft.Management/managementGroups/my-mg")"
assert_eq "classify unknown" "unknown" "$(_epac_classify_scope "/bogus/thing")"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_get_global_settings (valid) ==="

# Create temporary definitions structure with valid global-settings.jsonc
TMPDIR_GS="$(mktemp -d)"
mkdir -p "${TMPDIR_GS}/Definitions"
cat > "${TMPDIR_GS}/Definitions/global-settings.jsonc" << 'JSONC'
{
    // This is the pac owner id
    "pacOwnerId": "test-owner-id-12345",
    "pacEnvironments": [
        {
            "pacSelector": "dev",
            "cloud": "AzureCloud",
            "tenantId": "00000000-1111-2222-3333-444444444444",
            "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/dev-mg",
            "managedIdentityLocation": "eastus",
            "desiredState": {
                "strategy": "full",
                "keepDfcSecurityAssignments": false
            },
            "globalNotScopes": [
                "/subscriptions/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            ]
        },
        {
            "pacSelector": "prod",
            "cloud": "AzureCloud",
            "tenantId": "55555555-6666-7777-8888-999999999999",
            "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/prod-mg",
            "managedIdentityLocation": "westus2",
            "desiredState": {
                "strategy": "ownedOnly",
                "keepDfcSecurityAssignments": true,
                "excludedScopes": [
                    "/subscriptions/11111111-2222-3333-4444-555555555555"
                ],
                "excludedPolicyDefinitions": ["def1", "def2"]
            }
        }
    ]
}
JSONC

gs="$(epac_get_global_settings "${TMPDIR_GS}/Definitions" "${TMPDIR_GS}/Output" "${TMPDIR_GS}/Input" 2>/dev/null)"
assert_json_eq "gs telemetryEnabled" "$gs" '.telemetryEnabled' "true"
assert_json_eq "gs definitionsRootFolder" "$gs" '.definitionsRootFolder' "${TMPDIR_GS}/Definitions"
assert_json_count "gs pacEnvironmentSelectors count" "$gs" '.pacEnvironmentSelectors' "2"
assert_json_eq "gs selector 0" "$gs" '.pacEnvironmentSelectors[0]' "dev"
assert_json_eq "gs selector 1" "$gs" '.pacEnvironmentSelectors[1]' "prod"

# Dev environment
assert_json_eq "gs dev pacOwnerId" "$gs" '.pacEnvironments.dev.pacOwnerId' "test-owner-id-12345"
assert_json_eq "gs dev cloud" "$gs" '.pacEnvironments.dev.cloud' "AzureCloud"
assert_json_eq "gs dev tenantId" "$gs" '.pacEnvironments.dev.tenantId' "00000000-1111-2222-3333-444444444444"
assert_json_eq "gs dev deploymentRootScope" "$gs" '.pacEnvironments.dev.deploymentRootScope' "/providers/Microsoft.Management/managementGroups/dev-mg"
assert_json_eq "gs dev managedIdentityLocation" "$gs" '.pacEnvironments.dev.managedIdentityLocation' "eastus"
assert_json_eq "gs dev strategy" "$gs" '.pacEnvironments.dev.desiredState.strategy' "full"
assert_json_eq "gs dev keepDfcSecurityAssignments" "$gs" '.pacEnvironments.dev.desiredState.keepDfcSecurityAssignments' "false"
assert_json_eq "gs dev keepDfcPlanAssignments" "$gs" '.pacEnvironments.dev.desiredState.keepDfcPlanAssignments' "true"
assert_json_count "gs dev globalNotScopes" "$gs" '.pacEnvironments.dev.globalNotScopes' "1"
assert_json_count "gs dev globalNotScopesSubscriptions" "$gs" '.pacEnvironments.dev.globalNotScopesSubscriptions' "1"
assert_json_eq "gs dev deployedBy" "$gs" '.pacEnvironments.dev.deployedBy' "epac/test-owner-id-12345/dev"

# Prod environment
assert_json_eq "gs prod strategy" "$gs" '.pacEnvironments.prod.desiredState.strategy' "ownedOnly"
assert_json_eq "gs prod keepDfcSecurityAssignments" "$gs" '.pacEnvironments.prod.desiredState.keepDfcSecurityAssignments' "true"
assert_json_count "gs prod excludedPolicyDefinitions" "$gs" '.pacEnvironments.prod.desiredState.excludedPolicyDefinitions' "2"
assert_json_count "gs prod excludedScopes" "$gs" '.pacEnvironments.prod.desiredState.excludedScopes' "1"

rm -rf "$TMPDIR_GS"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_get_global_settings (telemetry opt-out) ==="

TMPDIR_TO="$(mktemp -d)"
mkdir -p "${TMPDIR_TO}/Definitions"
cat > "${TMPDIR_TO}/Definitions/global-settings.jsonc" << 'JSONC'
{
    "pacOwnerId": "owner-x",
    "telemetryOptOut": true,
    "pacEnvironments": [
        {
            "pacSelector": "test",
            "cloud": "AzureCloud",
            "tenantId": "00000000-0000-0000-0000-000000000000",
            "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/test",
            "managedIdentityLocation": "eastus",
            "desiredState": {
                "strategy": "full",
                "keepDfcSecurityAssignments": false
            }
        }
    ]
}
JSONC

gs_to="$(epac_get_global_settings "${TMPDIR_TO}/Definitions" "${TMPDIR_TO}/Output" "${TMPDIR_TO}/Input" 2>/dev/null)"
assert_json_eq "gs telemetry opt-out" "$gs_to" '.telemetryEnabled' "false"
rm -rf "$TMPDIR_TO"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_get_global_settings (validation errors) ==="

# Missing pacOwnerId
TMPDIR_ERR="$(mktemp -d)"
mkdir -p "${TMPDIR_ERR}/Definitions"
cat > "${TMPDIR_ERR}/Definitions/global-settings.jsonc" << 'JSONC'
{
    "pacEnvironments": [
        {
            "pacSelector": "bad",
            "cloud": "AzureCloud",
            "tenantId": "00000000-0000-0000-0000-000000000000",
            "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/test",
            "managedIdentityLocation": "eastus",
            "desiredState": {
                "strategy": "full",
                "keepDfcSecurityAssignments": false
            }
        }
    ]
}
JSONC

if bash -c "source '${SCRIPT_DIR}/../lib/epac.sh'; epac_get_global_settings '${TMPDIR_ERR}/Definitions' '${TMPDIR_ERR}/Output' '${TMPDIR_ERR}/Input'" 2>/dev/null; then
    echo "  FAIL: missing pacOwnerId should fail"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: missing pacOwnerId fails validation"
    PASS=$((PASS + 1))
fi
rm -rf "$TMPDIR_ERR"

# Missing strategy
TMPDIR_ERR2="$(mktemp -d)"
mkdir -p "${TMPDIR_ERR2}/Definitions"
cat > "${TMPDIR_ERR2}/Definitions/global-settings.jsonc" << 'JSONC'
{
    "pacOwnerId": "owner1",
    "pacEnvironments": [
        {
            "pacSelector": "env1",
            "cloud": "AzureCloud",
            "tenantId": "00000000-0000-0000-0000-000000000000",
            "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/test",
            "managedIdentityLocation": "eastus",
            "desiredState": {
                "keepDfcSecurityAssignments": false
            }
        }
    ]
}
JSONC

if bash -c "source '${SCRIPT_DIR}/../lib/epac.sh'; epac_get_global_settings '${TMPDIR_ERR2}/Definitions' '${TMPDIR_ERR2}/Output' '${TMPDIR_ERR2}/Input'" 2>/dev/null; then
    echo "  FAIL: missing strategy should fail"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: missing strategy fails validation"
    PASS=$((PASS + 1))
fi
rm -rf "$TMPDIR_ERR2"

# Deprecated globalNotScopes at top level
TMPDIR_ERR3="$(mktemp -d)"
mkdir -p "${TMPDIR_ERR3}/Definitions"
cat > "${TMPDIR_ERR3}/Definitions/global-settings.jsonc" << 'JSONC'
{
    "pacOwnerId": "owner2",
    "globalNotScopes": ["/subscriptions/abc"],
    "pacEnvironments": [
        {
            "pacSelector": "e1",
            "cloud": "AzureCloud",
            "tenantId": "00000000-0000-0000-0000-000000000000",
            "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/test",
            "managedIdentityLocation": "eastus",
            "desiredState": {
                "strategy": "full",
                "keepDfcSecurityAssignments": false
            }
        }
    ]
}
JSONC

if bash -c "source '${SCRIPT_DIR}/../lib/epac.sh'; epac_get_global_settings '${TMPDIR_ERR3}/Definitions' '${TMPDIR_ERR3}/Output' '${TMPDIR_ERR3}/Input'" 2>/dev/null; then
    echo "  FAIL: deprecated globalNotScopes should fail"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: deprecated globalNotScopes fails validation"
    PASS=$((PASS + 1))
fi
rm -rf "$TMPDIR_ERR3"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_get_global_settings (custom deployedBy) ==="

TMPDIR_DB="$(mktemp -d)"
mkdir -p "${TMPDIR_DB}/Definitions"
cat > "${TMPDIR_DB}/Definitions/global-settings.jsonc" << 'JSONC'
{
    "pacOwnerId": "owner-db",
    "pacEnvironments": [
        {
            "pacSelector": "custom",
            "cloud": "AzureCloud",
            "tenantId": "00000000-0000-0000-0000-000000000000",
            "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/test",
            "managedIdentityLocation": "eastus",
            "deployedBy": "my-custom-deployer",
            "desiredState": {
                "strategy": "full",
                "keepDfcSecurityAssignments": false
            }
        }
    ]
}
JSONC

gs_db="$(epac_get_global_settings "${TMPDIR_DB}/Definitions" "${TMPDIR_DB}/Output" "${TMPDIR_DB}/Input" 2>/dev/null)"
assert_json_eq "gs custom deployedBy" "$gs_db" '.pacEnvironments.custom.deployedBy' "my-custom-deployer"
rm -rf "$TMPDIR_DB"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_get_global_settings (globalNotScopes classification) ==="

TMPDIR_SC="$(mktemp -d)"
mkdir -p "${TMPDIR_SC}/Definitions"
cat > "${TMPDIR_SC}/Definitions/global-settings.jsonc" << 'JSONC'
{
    "pacOwnerId": "owner-sc",
    "pacEnvironments": [
        {
            "pacSelector": "scoped",
            "cloud": "AzureCloud",
            "tenantId": "00000000-0000-0000-0000-000000000000",
            "deploymentRootScope": "/providers/Microsoft.Management/managementGroups/test",
            "managedIdentityLocation": "eastus",
            "globalNotScopes": [
                "/subscriptions/11111111-1111-1111-1111-111111111111",
                "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg1",
                "/providers/Microsoft.Management/managementGroups/excluded-mg"
            ],
            "desiredState": {
                "strategy": "full",
                "keepDfcSecurityAssignments": false
            }
        }
    ]
}
JSONC

gs_sc="$(epac_get_global_settings "${TMPDIR_SC}/Definitions" "${TMPDIR_SC}/Output" "${TMPDIR_SC}/Input" 2>/dev/null)"
assert_json_count "gs scoped globalNotScopes" "$gs_sc" '.pacEnvironments.scoped.globalNotScopes' "3"
assert_json_count "gs scoped globalNotScopesSubscriptions" "$gs_sc" '.pacEnvironments.scoped.globalNotScopesSubscriptions' "1"
assert_json_count "gs scoped globalNotScopesResourceGroups" "$gs_sc" '.pacEnvironments.scoped.globalNotScopesResourceGroups' "1"
assert_json_count "gs scoped globalNotScopesManagementGroups" "$gs_sc" '.pacEnvironments.scoped.globalNotScopesManagementGroups' "1"
rm -rf "$TMPDIR_SC"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "─────────────────────────────────────────"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "─────────────────────────────────────────"
exit "$FAIL"
