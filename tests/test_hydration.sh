#!/usr/bin/env bash
# tests/test_hydration.sh — Tests for WI-17 Hydration Kit
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${REPO_ROOT}/lib/hydration/hydration-core.sh"
source "${REPO_ROOT}/lib/hydration/hydration-mg.sh"
source "${REPO_ROOT}/lib/hydration/hydration-definitions.sh"
source "${REPO_ROOT}/lib/hydration/hydration-tests.sh"

PASS=0
FAIL=0
TESTS=0
TEST_TMP=""

setup() {
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    [[ -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

trap teardown EXIT
setup

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TESTS=$((TESTS + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (doesn't contain '$needle')"
        echo "    in: ${haystack:0:300}"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TESTS=$((TESTS + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (should not contain '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    TESTS=$((TESTS + 1))
    if [[ -f "$path" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (file not found: $path)"
        FAIL=$((FAIL + 1))
    fi
}

assert_dir_exists() {
    local desc="$1" path="$2"
    TESTS=$((TESTS + 1))
    if [[ -d "$path" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (dir not found: $path)"
        FAIL=$((FAIL + 1))
    fi
}

assert_rc() {
    local desc="$1" expected="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if [[ "$expected" -eq "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (rc=$actual, expected=$expected)"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_field() {
    local desc="$1" json="$2" field="$3" expected="$4"
    local actual
    actual="$(echo "$json" | jq -r "$field" 2>/dev/null || echo "ERROR")"
    assert_eq "$desc" "$expected" "$actual"
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Script executability ==="
# ═══════════════════════════════════════════════════════════════════════════════
for script in \
    install-hydration-epac.sh \
    new-hydration-caf3-hierarchy.sh \
    copy-hydration-mg-hierarchy.sh \
    remove-hydration-mg-recursive.sh \
    new-hydration-definitions-folder.sh \
    new-hydration-global-settings.sh \
    new-hydration-assignment-pac-selector.sh \
    update-hydration-assignment-destination.sh \
    new-filtered-exception-file.sh \
    update-hydration-definition-folder-structure.sh \
    new-hydration-policy-documentation-source.sh \
    build-hydration-deployment-plans.sh \
    test-hydration-connection.sh \
    test-hydration-path.sh \
    test-hydration-rbac.sh \
    test-hydration-mg-name.sh; do
    TESTS=$((TESTS + 1))
    if [[ -x "${REPO_ROOT}/scripts/hydration/${script}" ]]; then
        echo "  PASS: $script is executable"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $script is not executable"
        FAIL=$((FAIL + 1))
    fi
done

for lib in hydration-core.sh hydration-mg.sh hydration-definitions.sh hydration-tests.sh; do
    TESTS=$((TESTS + 1))
    if [[ -x "${REPO_ROOT}/lib/hydration/${lib}" ]]; then
        echo "  PASS: lib/$lib is executable"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: lib/$lib is not executable"
        FAIL=$((FAIL + 1))
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_terminal_width ==="
# ═══════════════════════════════════════════════════════════════════════════════
w="$(hydration_terminal_width)"
TESTS=$((TESTS + 1))
if [[ "$w" -ge 80 ]]; then
    echo "  PASS: terminal_width >= 80 ($w)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: terminal_width < 80 ($w)"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_validate_mg_name ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Valid names
for name in "mygroup" "my-group" "my_group" "my.group" "MG123" "a" "Platform-01" "Test_Group.v2"; do
    rc=0
    hydration_validate_mg_name "$name" >/dev/null 2>&1 || rc=$?
    assert_rc "valid name '$name'" 0 "$rc"
done

# Invalid: empty
rc=0
hydration_validate_mg_name "" >/dev/null 2>&1 || rc=$?
assert_rc "empty name rejected" 1 "$rc"

# Invalid: too long (91 chars)
long_name="$(printf '%91s' '' | tr ' ' 'a')"
rc=0
hydration_validate_mg_name "$long_name" >/dev/null 2>&1 || rc=$?
assert_rc "91-char name rejected" 1 "$rc"

# Invalid: special characters
for name in "my group" "my/group" "my@group" "my!group" "has space" "name+plus"; do
    rc=0
    hydration_validate_mg_name "$name" >/dev/null 2>&1 || rc=$?
    assert_rc "invalid name '$name' rejected" 1 "$rc"
done

# Exactly 90 chars is valid
name90="$(printf '%90s' '' | tr ' ' 'x')"
rc=0
hydration_validate_mg_name "$name90" >/dev/null 2>&1 || rc=$?
assert_rc "90-char name accepted" 0 "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_log ==="
# ═══════════════════════════════════════════════════════════════════════════════

log_file="${TEST_TMP}/test.log"

# Log creates file and header
hydration_log newStage "Test Stage" "$log_file" --silent
assert_file_exists "log file created" "$log_file"
content="$(cat "$log_file")"
assert_contains "log has header" "$content" "EPAC Hydration Kit Log File"
assert_contains "log has stage entry" "$content" "Stage Initiated: Test Stage"

# newStage entry format
assert_contains "newStage format" "$content" "Stage Initiated:"

# commandStart entry
hydration_log commandStart "test-cmd" "$log_file" --silent
content="$(cat "$log_file")"
assert_contains "commandStart format" "$content" "Command Run: test-cmd"

# testResult entry
hydration_log testResult "path -- Passed" "$log_file" --silent
content="$(cat "$log_file")"
assert_contains "testResult format" "$content" "Test Result Data: path -- Passed"

# answerRequested entry
hydration_log answerRequested "What is your name?" "$log_file" --silent
content="$(cat "$log_file")"
assert_contains "answerRequested format" "$content" "Requesting response to: What is your name?"

# answerSetProvided entry
hydration_log answerSetProvided "name=test" "$log_file" --silent
content="$(cat "$log_file")"
assert_contains "answerSetProvided format" "$content" "Response(s) Provided: name=test"

# Timestamp format check
assert_contains "has timestamp" "$content" " -- "

# Log with UTC
utc_log="${TEST_TMP}/utc.log"
hydration_log newStage "UTC Test" "$utc_log" --utc --silent
utc_content="$(cat "$utc_log")"
assert_contains "UTC log has entry" "$utc_content" "Stage Initiated: UTC Test"

# Non-silent mode produces stdout
visible="$(hydration_log newStage "Visible Stage" "${TEST_TMP}/vis.log")"
assert_contains "visible output" "$visible" "Stage Initiated: Visible Stage"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_separator ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Top separator
output="$(hydration_separator "Header Test" "Top" 80)"
assert_contains "Top has large row" "$output" "========"
assert_contains "Top has text" "$output" "Header Test"

# Middle separator
output="$(hydration_separator "Middle Test" "Middle" 80)"
assert_contains "Middle has small rows" "$output" "--------"
assert_contains "Middle has text" "$output" "Middle Test"

# Bottom separator
output="$(hydration_separator "Footer Test" "Bottom" 80)"
assert_contains "Bottom has large row" "$output" "========"
assert_contains "Bottom has text" "$output" "Footer Test"

# Custom width
output="$(hydration_separator "Custom" "Top" 40)"
assert_contains "custom width has text" "$output" "Custom"

# Custom characters
output="$(hydration_separator "Stars" "Top" 80 "*" "~")"
assert_contains "custom large char" "$output" "****"
assert_contains "custom small char" "$output" "~"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_save_answers / hydration_load_answers ==="
# ═══════════════════════════════════════════════════════════════════════════════

answer_file="${TEST_TMP}/answers.json"
test_answers='{"name":"test","value":42}'

hydration_save_answers "$answer_file" "$test_answers"
assert_file_exists "answer file created" "$answer_file"

loaded="$(hydration_load_answers "$answer_file")"
assert_json_field "loaded name" "$loaded" ".name" "test"
assert_json_field "loaded value" "$loaded" ".value" "42"

# Load from non-existent file returns empty object
missing="$(hydration_load_answers "${TEST_TMP}/nonexistent.json")"
assert_eq "missing file returns {}" "{}" "$missing"

# Nested answer structure
nested_answers='{"config":{"tenant":"abc","root":"MyRoot"},"choices":["a","b"]}'
hydration_save_answers "${TEST_TMP}/nested.json" "$nested_answers"
loaded_nested="$(hydration_load_answers "${TEST_TMP}/nested.json")"
assert_json_field "nested tenant" "$loaded_nested" ".config.tenant" "abc"
assert_json_field "nested choices count" "$loaded_nested" '.choices | length' "2"

# Save creates parent directories
deep_answer="${TEST_TMP}/deep/nested/dir/answers.json"
hydration_save_answers "$deep_answer" '{"deep":true}'
assert_file_exists "deep answer file" "$deep_answer"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_create_definitions_folder ==="
# ═══════════════════════════════════════════════════════════════════════════════

defs_dir="${TEST_TMP}/TestDefs"
hydration_create_definitions_folder "$defs_dir"

assert_dir_exists "definitions root" "$defs_dir"
assert_dir_exists "policyAssignments" "${defs_dir}/policyAssignments"
assert_dir_exists "policySetDefinitions" "${defs_dir}/policySetDefinitions"
assert_dir_exists "policyDefinitions" "${defs_dir}/policyDefinitions"
assert_dir_exists "policyDocumentations" "${defs_dir}/policyDocumentations"
assert_file_exists "global-settings stub" "${defs_dir}/global-settings.jsonc"

# Verify stub content
gs_stub="$(cat "${defs_dir}/global-settings.jsonc")"
assert_contains "has schema" "$gs_stub" 'global-settings-schema.json'

# Re-running should not fail (idempotent)
hydration_create_definitions_folder "$defs_dir"
assert_dir_exists "still exists after re-run" "$defs_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_create_global_settings ==="
# ═══════════════════════════════════════════════════════════════════════════════

gs_defs="${TEST_TMP}/GSDefs"
mkdir -p "$gs_defs"

gs_log="${TEST_TMP}/gs.log"
gs_result="$(hydration_create_global_settings \
    --pac-owner-id "11111111-2222-3333-4444-555555555555" \
    --mi-location "eastus" \
    --main-pac-selector "tenant01" \
    --epac-pac-selector "epac-dev" \
    --cloud "AzureCloud" \
    --tenant-id "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" \
    --main-root "MyRoot" \
    --epac-root "epac-MyRoot" \
    --strategy "full" \
    --definitions-root "$gs_defs" \
    --log-file "$gs_log")"

assert_file_exists "global-settings.jsonc created" "${gs_defs}/global-settings.jsonc"
gs_content="$(cat "${gs_defs}/global-settings.jsonc")"

assert_json_field "schema present" "$gs_content" '."$schema"' \
    "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/global-settings-schema.json"
assert_json_field "pacOwnerId" "$gs_content" '.pacOwnerId' "11111111-2222-3333-4444-555555555555"
assert_json_field "main pacSelector" "$gs_content" '.pacEnvironments[0].pacSelector' "tenant01"
assert_json_field "epac pacSelector" "$gs_content" '.pacEnvironments[1].pacSelector' "epac-dev"
assert_json_field "cloud" "$gs_content" '.pacEnvironments[0].cloud' "AzureCloud"
assert_json_field "tenantId" "$gs_content" '.pacEnvironments[0].tenantId' "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
assert_json_field "main deploymentRootScope" "$gs_content" '.pacEnvironments[0].deploymentRootScope' \
    "/providers/Microsoft.Management/managementGroups/MyRoot"
assert_json_field "epac deploymentRootScope" "$gs_content" '.pacEnvironments[1].deploymentRootScope' \
    "/providers/Microsoft.Management/managementGroups/epac-MyRoot"
assert_json_field "strategy" "$gs_content" '.pacEnvironments[0].desiredState.strategy' "full"
assert_json_field "keepDfcSecurityAssignments default false" "$gs_content" '.pacEnvironments[0].desiredState.keepDfcSecurityAssignments' "false"
assert_json_field "MI location" "$gs_content" '.pacEnvironments[0].managedIdentityLocation' "eastus"
assert_json_field "two pac environments" "$gs_content" '.pacEnvironments | length' "2"

# Global settings with keep-dfc flag
gs_defs2="${TEST_TMP}/GSDefs2"
mkdir -p "$gs_defs2"
hydration_create_global_settings \
    --pac-owner-id "test" \
    --mi-location "westus" \
    --main-pac-selector "main" \
    --epac-pac-selector "dev" \
    --cloud "AzureUSGovernment" \
    --tenant-id "test-tenant" \
    --main-root "Root" \
    --epac-root "DevRoot" \
    --strategy "ownedOnly" \
    --definitions-root "$gs_defs2" \
    --keep-dfc >/dev/null

gs2="$(cat "${gs_defs2}/global-settings.jsonc")"
assert_json_field "keepDfc true" "$gs2" '.pacEnvironments[0].desiredState.keepDfcSecurityAssignments' "true"
assert_json_field "strategy ownedOnly" "$gs2" '.pacEnvironments[0].desiredState.strategy' "ownedOnly"
assert_json_field "gov cloud" "$gs2" '.pacEnvironments[0].cloud' "AzureUSGovernment"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_update_assignment_scope ==="
# ═══════════════════════════════════════════════════════════════════════════════

scope_file="${TEST_TMP}/scope-test.json"
cat > "$scope_file" << 'EOF'
{
    "nodeName": "test-assignment",
    "scope": {
        "tenant01": [
            "/providers/Microsoft.Management/managementGroups/OldMG"
        ]
    }
}
EOF

hydration_update_assignment_scope "$scope_file" "OldMG" "NewMG"
updated="$(cat "$scope_file")"
assert_contains "old MG replaced" "$updated" "NewMG"
assert_not_contains "old MG gone" "$updated" "OldMG"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_filter_exemptions ==="
# ═══════════════════════════════════════════════════════════════════════════════

filter_defs="${TEST_TMP}/FilterDefs"
mkdir -p "${filter_defs}/policyAssignments"

# Create test assignment files
cat > "${filter_defs}/policyAssignments/assign1.json" << 'EOF'
{"assignment": {"name": "myAssignment1"}}
EOF
cat > "${filter_defs}/policyAssignments/assign2.json" << 'EOF'
{"assignment": {"name": "myAssignment2"}}
EOF

# Create CSV with mixed exemptions
exemptions_csv="${TEST_TMP}/exemptions.csv"
cat > "$exemptions_csv" << 'EOF'
name,policyAssignmentId,description
exempt1,/providers/Microsoft.Authorization/policyAssignments/myAssignment1,relevant
exempt2,/providers/Microsoft.Authorization/policyAssignments/unknownAssignment,not relevant
exempt3,/providers/Microsoft.Authorization/policyAssignments/myAssignment2,also relevant
EOF

filter_output="${TEST_TMP}/FilterOutput"
hydration_filter_exemptions "$exemptions_csv" "$filter_output" "$filter_defs"

assert_file_exists "filtered CSV created" "${filter_output}/filtered-exemptions.csv"
filtered="$(cat "${filter_output}/filtered-exemptions.csv")"
assert_contains "header preserved" "$filtered" "name,policyAssignmentId,description"
assert_contains "relevant exempt1 kept" "$filtered" "myAssignment1"
assert_contains "relevant exempt3 kept" "$filtered" "myAssignment2"
assert_not_contains "unknown assignment excluded" "$filtered" "unknownAssignment"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_test_path ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Test existing path
existing_path="${TEST_TMP}/existing"
mkdir -p "$existing_path"
result="$(hydration_test_path "$existing_path")"
assert_eq "existing path passes" "Passed" "$result"

# Test creatable path
new_path="${TEST_TMP}/new-dir/sub"
result="$(hydration_test_path "$new_path")"
assert_eq "creatable path passes" "Passed" "$result"
assert_dir_exists "created by test" "$new_path"

# Test path with logging
log_path="${TEST_TMP}/path-test.log"
hydration_test_path "$existing_path" "$log_path" >/dev/null
assert_file_exists "path test log created" "$log_path"
log_content="$(cat "$log_path")"
assert_contains "path test logged" "$log_content" "Passed"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_test_git ==="
# ═══════════════════════════════════════════════════════════════════════════════

result="$(hydration_test_git)"
assert_eq "git is available" "Passed" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== hydration_reorganize_definitions ==="
# ═══════════════════════════════════════════════════════════════════════════════

reorg_defs="${TEST_TMP}/ReorgDefs"
mkdir -p "${reorg_defs}/policyAssignments"

# Create test assignment files at root level
cat > "${reorg_defs}/policyAssignments/security-assign.json" << 'EOF'
{"assignment": {"name": "security-assign"}}
EOF
cat > "${reorg_defs}/policyAssignments/platform-assign.json" << 'EOF'
{"assignment": {"name": "platform-assign"}}
EOF

folder_order='{"Security": ["security-assign"], "Platform": ["platform-assign"]}'
hydration_reorganize_definitions "$reorg_defs" "$folder_order"

assert_dir_exists "Security folder" "${reorg_defs}/policyAssignments/Security"
assert_dir_exists "Platform folder" "${reorg_defs}/policyAssignments/Platform"

# Check if files were moved (they should be in subfolders now)
TESTS=$((TESTS + 1))
if [[ -f "${reorg_defs}/policyAssignments/Security/security-assign.json" ]] || \
   [[ -f "${reorg_defs}/policyAssignments/Security/security-assign.jsonc" ]]; then
    echo "  PASS: security file moved to Security folder"
    PASS=$((PASS + 1))
else
    echo "  FAIL: security file not in Security folder"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Script help output ==="
# ═══════════════════════════════════════════════════════════════════════════════

for script in \
    new-hydration-caf3-hierarchy.sh \
    copy-hydration-mg-hierarchy.sh \
    remove-hydration-mg-recursive.sh \
    new-hydration-definitions-folder.sh \
    new-hydration-assignment-pac-selector.sh \
    new-filtered-exception-file.sh \
    update-hydration-definition-folder-structure.sh \
    test-hydration-path.sh \
    test-hydration-connection.sh \
    test-hydration-rbac.sh \
    test-hydration-mg-name.sh; do
    help_output="$(bash "${REPO_ROOT}/scripts/hydration/${script}" --help 2>&1 || true)"
    assert_contains "${script} --help has Usage" "$help_output" "Usage:"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== test-hydration-mg-name.sh validation ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Valid name via script
rc=0
bash "${REPO_ROOT}/scripts/hydration/test-hydration-mg-name.sh" --name "valid-name" >/dev/null 2>&1 || rc=$?
assert_rc "script: valid name" 0 "$rc"

# Invalid name via script (space)
rc=0
bash "${REPO_ROOT}/scripts/hydration/test-hydration-mg-name.sh" --name "invalid name" >/dev/null 2>&1 || rc=$?
assert_rc "script: invalid name" 1 "$rc"

# Multiple names
rc=0
output="$(bash "${REPO_ROOT}/scripts/hydration/test-hydration-mg-name.sh" --name "ok" --name "also-ok" 2>&1)" || rc=$?
assert_rc "script: two valid names" 0 "$rc"
assert_contains "reports first" "$output" "'ok': valid"
assert_contains "reports second" "$output" "'also-ok': valid"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== new-hydration-definitions-folder.sh ==="
# ═══════════════════════════════════════════════════════════════════════════════

script_defs="${TEST_TMP}/ScriptDefs"
bash "${REPO_ROOT}/scripts/hydration/new-hydration-definitions-folder.sh" --path "$script_defs"
assert_dir_exists "script creates root" "$script_defs"
assert_dir_exists "script creates policyAssignments" "${script_defs}/policyAssignments"
assert_dir_exists "script creates policyDefinitions" "${script_defs}/policyDefinitions"
assert_file_exists "script creates global-settings" "${script_defs}/global-settings.jsonc"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== test-hydration-path.sh ==="
# ═══════════════════════════════════════════════════════════════════════════════

path_test_dir="${TEST_TMP}/pathtest"
mkdir -p "$path_test_dir"

rc=0
output="$(bash "${REPO_ROOT}/scripts/hydration/test-hydration-path.sh" --path "$path_test_dir" 2>&1)" || rc=$?
assert_rc "existing path script succeeds" 0 "$rc"
assert_contains "path script shows OK" "$output" "OK"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== new-hydration-policy-documentation-source.sh ==="
# ═══════════════════════════════════════════════════════════════════════════════

doc_defs="${TEST_TMP}/DocDefs"
doc_output="${TEST_TMP}/DocOutput"
mkdir -p "${doc_defs}/policyAssignments"

# Create test assignment with policySetDefinition reference
cat > "${doc_defs}/policyAssignments/test-assign.json" << 'EOF'
{
    "assignment": {"name": "test-monitoring", "displayName": "Test Monitoring"},
    "policyDefinitionId": "/providers/Microsoft.Authorization/policySetDefinitions/monitoring-set"
}
EOF

bash "${REPO_ROOT}/scripts/hydration/new-hydration-policy-documentation-source.sh" \
    --pac-selector "tenant01" \
    --definitions "$doc_defs" \
    --output "$doc_output" \
    --report-title "Test Report" \
    --file-name-stem "TestTenant" \
    --max-parameter-length 50 \
    --include-compliance-groups \
    --no-embedded-html \
    --add-toc

date_dir="$(date '+%Y-%m-%d')"
doc_file="${doc_output}/${date_dir}/policyDocumentations/TestTenant.jsonc"
assert_file_exists "documentation file created" "$doc_file"

doc_content="$(cat "$doc_file")"
assert_json_field "doc schema" "$doc_content" '."$schema"' \
    "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-documentation-schema.json"
assert_json_field "doc pacEnvironment" "$doc_content" '.documentAssignments.documentAllAssignments[0].pacEnvironment' "tenant01"
assert_json_field "doc title" "$doc_content" '.documentAssignments.documentationSpecifications[0].title' "Test Report"
assert_json_field "doc stem" "$doc_content" '.documentAssignments.documentationSpecifications[0].fileNameStem' "TestTenant"
assert_json_field "doc maxParameterLength" "$doc_content" '.documentAssignments.documentationSpecifications[0].markdownMaxParameterLength' "50"
assert_json_field "doc complianceGroups" "$doc_content" '.documentAssignments.documentationSpecifications[0].markdownIncludeComplianceGroupNames' "true"
assert_json_field "doc noHtml" "$doc_content" '.documentAssignments.documentationSpecifications[0].markdownNoEmbeddedHtml' "true"
assert_json_field "doc toc" "$doc_content" '.documentAssignments.documentationSpecifications[0].markdownAddToc' "true"
assert_json_field "doc policySet pacEnv" "$doc_content" '.documentPolicySets[0].pacEnvironment' "tenant01"

# Check policySet was found from assignment scan
ps_count="$(echo "$doc_content" | jq '.documentPolicySets[0].policySets | length')"
TESTS=$((TESTS + 1))
if [[ "$ps_count" -ge 1 ]]; then
    echo "  PASS: found $ps_count policySet(s) from assignment scan"
    PASS=$((PASS + 1))
else
    echo "  FAIL: no policySets found (expected >= 1)"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== update-hydration-assignment-destination.sh ==="
# ═══════════════════════════════════════════════════════════════════════════════

dest_file="${TEST_TMP}/dest-test.json"
cat > "$dest_file" << 'EOF'
{
    "nodeName": "test-node",
    "scope": {
        "myPac": [
            "/providers/Microsoft.Management/managementGroups/OriginalMG"
        ]
    }
}
EOF

output="$(bash "${REPO_ROOT}/scripts/hydration/update-hydration-assignment-destination.sh" \
    --pac-selector "myPac" \
    --file "$dest_file" \
    --old-mg "OriginalMG" \
    --new-mg "ReplacedMG" \
    --suppress-file 2>&1)"
assert_contains "output has new MG" "$output" "ReplacedMG"
assert_not_contains "output no old MG" "$output" "OriginalMG"

# Test with prefix/suffix
dest_file2="${TEST_TMP}/dest-test2.json"
cat > "$dest_file2" << 'EOF'
{
    "nodeName": "test-node2",
    "scope": {
        "tenant01": [
            "/providers/Microsoft.Management/managementGroups/Platform"
        ]
    }
}
EOF

output2="$(bash "${REPO_ROOT}/scripts/hydration/update-hydration-assignment-destination.sh" \
    --pac-selector "tenant01" \
    --file "$dest_file2" \
    --old-mg "Platform" \
    --new-prefix "epac-" \
    --new-suffix "-dev" \
    --suppress-file 2>&1)"
assert_contains "prefix+suffix applied" "$output2" "epac-Platform-dev"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== install-hydration-epac.sh --help ==="
# ═══════════════════════════════════════════════════════════════════════════════

help_out="$(bash "${REPO_ROOT}/scripts/hydration/install-hydration-epac.sh" --help 2>&1 || true)"
assert_contains "wizard help has Usage" "$help_out" "Usage:"
assert_contains "wizard help has tenant-intermediate-root" "$help_out" "tenant-intermediate-root"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Required argument validation ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Scripts that require arguments should fail gracefully
for script_args in \
    "new-hydration-caf3-hierarchy.sh" \
    "copy-hydration-mg-hierarchy.sh" \
    "new-hydration-assignment-pac-selector.sh" \
    "new-filtered-exception-file.sh" \
    "update-hydration-definition-folder-structure.sh" \
    "test-hydration-rbac.sh"; do
    rc=0
    bash "${REPO_ROOT}/scripts/hydration/${script_args}" 2>/dev/null || rc=$?
    assert_rc "${script_args} fails without args" 1 "$rc"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Library guard variables ==="
# ═══════════════════════════════════════════════════════════════════════════════

assert_eq "core guard set" "1" "${_EPAC_HYDRATION_CORE_LOADED:-}"
assert_eq "mg guard set" "1" "${_EPAC_HYDRATION_MG_LOADED:-}"
assert_eq "defs guard set" "1" "${_EPAC_HYDRATION_DEFS_LOADED:-}"
assert_eq "tests guard set" "1" "${_EPAC_HYDRATION_TESTS_LOADED:-}"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== SUMMARY ==="
echo "  Total:  $TESTS"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

[[ $FAIL -eq 0 ]] || exit 1
