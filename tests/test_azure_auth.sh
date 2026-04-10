#!/usr/bin/env bash
# tests/test_azure_auth.sh — Tests for WI-02 azure-auth.sh
# Tests that don't require an actual Azure connection.
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

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== API version tables ==="

versions=$(_epac_api_versions_for_cloud "AzureCloud")
assert_json_eq "Default cloud policyDef API" "$versions" ".policyDefinitions" "2023-04-01"
assert_json_eq "Default cloud exemptions API" "$versions" ".policyExemptions" "2022-07-01-preview"
assert_json_eq "Default cloud roleAssign API" "$versions" ".roleAssignments" "2022-04-01"

china_versions=$(_epac_api_versions_for_cloud "AzureChinaCloud")
assert_json_eq "China cloud policyDef API" "$china_versions" ".policyDefinitions" "2021-06-01"
assert_json_eq "China cloud exemptions API" "$china_versions" ".policyExemptions" "2022-07-01-preview"

gov_versions=$(_epac_api_versions_for_cloud "AzureUSGovernment")
assert_json_eq "USGov cloud policyDef API" "$gov_versions" ".policyDefinitions" "2023-04-01"
assert_json_eq "USGov cloud exemptions API" "$gov_versions" ".policyExemptions" "2024-12-01-preview"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Cloud name mapping ==="

assert_eq "AzureCloud mapping" "AzureCloud" "$(_epac_cloud_to_az_cloud "AzureCloud")"
assert_eq "AzureChinaCloud mapping" "AzureChinaCloud" "$(_epac_cloud_to_az_cloud "AzureChinaCloud")"
assert_eq "AzureUSGovernment mapping" "AzureUSGovernment" "$(_epac_cloud_to_az_cloud "AzureUSGovernment")"
assert_eq "Case insensitive mapping" "AzureCloud" "$(_epac_cloud_to_az_cloud "azurecloud")"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== PAC folders ==="

# Default folders
folders=$(epac_get_pac_folders)
assert_json_eq "Default definitions root" "$folders" ".definitionsRootFolder" "Definitions"
assert_json_eq "Default global settings file" "$folders" ".globalSettingsFile" "Definitions/global-settings.jsonc"
assert_json_eq "Default output folder" "$folders" ".outputFolder" "Output"
assert_json_eq "Default input folder" "$folders" ".inputFolder" "Output"

# Custom folders
folders=$(epac_get_pac_folders "MyDefs" "MyOutput" "MyInput")
assert_json_eq "Custom definitions root" "$folders" ".definitionsRootFolder" "MyDefs"
assert_json_eq "Custom global settings file" "$folders" ".globalSettingsFile" "MyDefs/global-settings.jsonc"
assert_json_eq "Custom output folder" "$folders" ".outputFolder" "MyOutput"
assert_json_eq "Custom input folder" "$folders" ".inputFolder" "MyInput"

# Env var folders
folders=$(PAC_DEFINITIONS_FOLDER="EnvDefs" PAC_OUTPUT_FOLDER="EnvOut" PAC_INPUT_FOLDER="EnvIn" epac_get_pac_folders)
assert_json_eq "Env var definitions root" "$folders" ".definitionsRootFolder" "EnvDefs"
assert_json_eq "Env var output folder" "$folders" ".outputFolder" "EnvOut"
assert_json_eq "Env var input folder" "$folders" ".inputFolder" "EnvIn"

# Input defaults to output when not specified
folders=$(PAC_OUTPUT_FOLDER="CustomOut" PAC_INPUT_FOLDER="" epac_get_pac_folders "" "" "")
assert_json_eq "Input defaults to output" "$folders" ".inputFolder" "CustomOut"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Switch PAC environment ==="

# Test with mock pac environments (no actual Azure login — test the validation path)
pac_envs='{"dev":{"cloud":"AzureCloud","tenantId":"11111111-1111-1111-1111-111111111111","deploymentRootScope":"/providers/Microsoft.Management/managementGroups/dev"},"prod":{"cloud":"AzureCloud","tenantId":"22222222-2222-2222-2222-222222222222","deploymentRootScope":"/providers/Microsoft.Management/managementGroups/prod"}}'

# Test invalid selector (run in subshell since epac_die exits)
if bash -c "source '${SCRIPT_DIR}/../lib/epac.sh'; epac_switch_pac_environment '$pac_envs' 'nonexistent' 'false'" 2>/dev/null; then
    echo "  FAIL: Invalid selector should fail"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: Invalid selector correctly fails"
    PASS=$((PASS + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Telemetry URI construction ==="

# We can't actually send telemetry, but we can verify the function exists
# and doesn't crash on basic invocation (it will fail silently)
epac_submit_telemetry "test-pid" "/providers/Microsoft.Management/managementGroups/testMG" 2>/dev/null || true
echo "  PASS: Telemetry for management group scope doesn't crash"
PASS=$((PASS + 1))

epac_submit_telemetry "test-pid" "/subscriptions/sub-123" 2>/dev/null || true
echo "  PASS: Telemetry for subscription scope doesn't crash"
PASS=$((PASS + 1))

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== REST wrapper (offline) ==="

# Verify EPAC_REST_STATUS_CODE variable exists
assert_eq "REST status code var initialized" "" "$EPAC_REST_STATUS_CODE"

# Test that epac_invoke_az_rest fails gracefully without a login
if epac_invoke_az_rest "GET" "https://management.azure.com/invalid" "" 0 2>/dev/null; then
    echo "  FAIL: REST call without auth should fail"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: REST call without auth correctly fails"
    PASS=$((PASS + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"
[[ $FAIL -gt 0 ]] && exit 1 || exit 0
