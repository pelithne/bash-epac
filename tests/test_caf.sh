#!/usr/bin/env bash
# tests/test_caf.sh — Tests for WI-18 Cloud Adoption Framework integration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${REPO_ROOT}/lib/epac.sh"

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

for script in new-alz-policy-default-structure.sh sync-alz-policy-from-library.sh; do
    TESTS=$((TESTS + 1))
    if [[ -x "${REPO_ROOT}/scripts/caf/${script}" ]]; then
        echo "  PASS: $script is executable"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $script is not executable"
        FAIL=$((FAIL + 1))
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Help output ==="
# ═══════════════════════════════════════════════════════════════════════════════

for script in new-alz-policy-default-structure.sh sync-alz-policy-from-library.sh; do
    help_output="$(bash "${REPO_ROOT}/scripts/caf/${script}" --help 2>&1 || true)"
    assert_contains "${script} --help has Usage" "$help_output" "Usage:"
    assert_contains "${script} --help has definitions-root" "$help_output" "definitions-root"
    assert_contains "${script} --help has pac-selector" "$help_output" "pac-selector"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Required argument validation ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Missing required args should fail
rc=0
bash "${REPO_ROOT}/scripts/caf/new-alz-policy-default-structure.sh" 2>/dev/null || rc=$?
assert_rc "new-alz: fails without args" 1 "$rc"

rc=0
bash "${REPO_ROOT}/scripts/caf/new-alz-policy-default-structure.sh" --definitions-root /tmp 2>/dev/null || rc=$?
assert_rc "new-alz: fails without pac-selector" 1 "$rc"

rc=0
bash "${REPO_ROOT}/scripts/caf/sync-alz-policy-from-library.sh" 2>/dev/null || rc=$?
assert_rc "sync-alz: fails without args" 1 "$rc"

# Invalid type should fail
rc=0
bash "${REPO_ROOT}/scripts/caf/new-alz-policy-default-structure.sh" \
    --definitions-root /tmp --pac-selector test --type INVALID 2>/dev/null || rc=$?
assert_rc "new-alz: invalid type rejected" 1 "$rc"

rc=0
bash "${REPO_ROOT}/scripts/caf/sync-alz-policy-from-library.sh" \
    --definitions-root /tmp --pac-selector test --type BADTYPE 2>/dev/null || rc=$?
assert_rc "sync-alz: invalid type rejected" 1 "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== new-alz-policy-default-structure with mock library ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Create a minimal mock ALZ library
mock_lib="${TEST_TMP}/mock-alz-lib"
mkdir -p "${mock_lib}/platform/alz/architecture_definitions"
mkdir -p "${mock_lib}/platform/alz/policy_definitions/general"
mkdir -p "${mock_lib}/platform/alz/policy_assignments"

# Mock architecture definition
cat > "${mock_lib}/platform/alz/architecture_definitions/alz.alz_architecture_definition.json" << 'EOF'
{
    "management_groups": [
        {"id": "alz", "display_Name": "Root"},
        {"id": "platform", "display_Name": "Platform"},
        {"id": "landingzones", "display_Name": "Landing Zones"},
        {"id": "decommissioned", "display_Name": "Decommissioned"},
        {"id": "sandbox", "display_Name": "Sandbox"}
    ]
}
EOF

# Mock policy defaults
cat > "${mock_lib}/platform/alz/alz_policy_default_values.json" << 'EOF'
{
    "defaults": [
        {
            "default_name": "test_parameter",
            "description": "A test parameter",
            "policy_assignments": [
                {
                    "policy_assignment_name": "Test-Assignment",
                    "parameter_names": ["testParam"]
                }
            ]
        }
    ]
}
EOF

# Mock assignment file
cat > "${mock_lib}/platform/alz/policy_assignments/Test-Assignment.alz_policy_assignment.json" << 'EOF'
{
    "name": "Test-Assignment",
    "properties": {
        "displayName": "Test Assignment",
        "description": "A test assignment",
        "policyDefinitionId": "/providers/Microsoft.Authorization/policySetDefinitions/test-set",
        "parameters": {
            "testParam": {"value": "default-value"}
        },
        "nonComplianceMessages": [
            {"message": "Resources {enforcementMode} comply with this policy."}
        ]
    }
}
EOF

defs_root="${TEST_TMP}/Definitions"
mkdir -p "$defs_root"

bash "${REPO_ROOT}/scripts/caf/new-alz-policy-default-structure.sh" \
    --definitions-root "$defs_root" \
    --pac-selector "tenant01" \
    --type ALZ \
    --library-path "$mock_lib" 2>/dev/null

# Verify output
structure_file="${defs_root}/policyStructures/alz.policy_default_structure.tenant01.jsonc"
assert_file_exists "structure file created" "$structure_file"

structure="$(cat "$structure_file")"
assert_json_field "has schema" "$structure" '."$schema"' \
    "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-structure-schema.json"
assert_json_field "has enforcementMode" "$structure" '.enforcementMode' "Default"

# Check MG mappings
assert_json_field "alz MG mapped" "$structure" '.managementGroupNameMappings.alz.management_group_function' "Root"
assert_json_field "platform MG mapped" "$structure" '.managementGroupNameMappings.platform.management_group_function' "Platform"
assert_json_field "landingzones MG mapped" "$structure" '.managementGroupNameMappings.landingzones.management_group_function' "Landing Zones"
assert_json_field "alz MG value" "$structure" '.managementGroupNameMappings.alz.value' \
    "/providers/Microsoft.Management/managementGroups/alz"
assert_json_field "5 MG mappings" "$structure" '.managementGroupNameMappings | keys | length' "5"

# Check default parameter values
assert_contains "has test_parameter" "$structure" "test_parameter"
assert_json_field "test_parameter description" "$structure" \
    '.defaultParameterValues.test_parameter[0].description' "A test parameter"
assert_json_field "test_parameter value" "$structure" \
    '.defaultParameterValues.test_parameter[0].parameters.value' "default-value"
assert_json_field "test_parameter param_name" "$structure" \
    '.defaultParameterValues.test_parameter[0].parameters.parameter_name' "testParam"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== new-alz with different types ==="
# ═══════════════════════════════════════════════════════════════════════════════

for test_type in FSI AMBA SLZ; do
    type_lower="$(echo "$test_type" | tr '[:upper:]' '[:lower:]')"
    mock_type_lib="${TEST_TMP}/mock-${type_lower}-lib"
    mkdir -p "${mock_type_lib}/platform/${type_lower}/architecture_definitions"

    cat > "${mock_type_lib}/platform/${type_lower}/architecture_definitions/${type_lower}.alz_architecture_definition.json" << TYPEEOF
{
    "management_groups": [
        {"id": "${type_lower}", "display_Name": "${test_type} Root"}
    ]
}
TYPEEOF

    cat > "${mock_type_lib}/platform/${type_lower}/alz_policy_default_values.json" << 'TYPEEOF'
{"defaults": []}
TYPEEOF

    type_defs="${TEST_TMP}/Defs_${test_type}"
    mkdir -p "$type_defs"

    bash "${REPO_ROOT}/scripts/caf/new-alz-policy-default-structure.sh" \
        --definitions-root "$type_defs" \
        --pac-selector "test" \
        --type "$test_type" \
        --library-path "$mock_type_lib" 2>/dev/null

    sf="${type_defs}/policyStructures/${type_lower}.policy_default_structure.test.jsonc"
    assert_file_exists "${test_type} structure file" "$sf"

    sc="$(cat "$sf")"
    assert_json_field "${test_type} MG mapped" "$sc" \
        ".managementGroupNameMappings.${type_lower}.management_group_function" "${test_type} Root"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== sync-alz-policy-from-library with mock library ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Set up definitions with structure file from previous test
sync_defs="${TEST_TMP}/SyncDefs"
mkdir -p "${sync_defs}/policyStructures"
cp "$structure_file" "${sync_defs}/policyStructures/"

# Create mock archetype definitions
mkdir -p "${mock_lib}/platform/alz/archetype_definitions"
cat > "${mock_lib}/platform/alz/archetype_definitions/root.json" << 'EOF'
{
    "name": "root",
    "policy_assignments": ["Test-Assignment"]
}
EOF

rc=0
bash "${REPO_ROOT}/scripts/caf/sync-alz-policy-from-library.sh" \
    --definitions-root "$sync_defs" \
    --pac-selector "tenant01" \
    --type ALZ \
    --library-path "$mock_lib" 2>/dev/null || rc=$?
assert_rc "sync completed without error" 0 "$rc"

# Check assignments were created
assign_dir="${sync_defs}/policyAssignments/ALZ/tenant01"
TESTS=$((TESTS + 1))
if [[ -d "$assign_dir" ]]; then
    assign_count="$(find "$assign_dir" -name "*.jsonc" -type f 2>/dev/null | wc -l)"
    if [[ "$assign_count" -ge 1 ]]; then
        echo "  PASS: created $assign_count assignment file(s)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: no assignment files in $assign_dir"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  FAIL: assignment directory not created: $assign_dir"
    FAIL=$((FAIL + 1))
fi

# Find and verify assignment content
assign_file="$(find "$assign_dir" -name "Test-Assignment.jsonc" -type f 2>/dev/null | head -1)"
if [[ -n "$assign_file" ]]; then
    ac="$(cat "$assign_file")"
    assert_json_field "assignment schema" "$ac" '."$schema"' \
        "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-assignment-schema.json"
    assert_json_field "assignment name" "$ac" '.assignment.name' "Test-Assignment"
    assert_json_field "assignment displayName" "$ac" '.assignment.displayName' "Test Assignment"
    assert_json_field "assignment enforcementMode" "$ac" '.enforcementMode' "Default"
    assert_json_field "assignment scope has pac" "$ac" '.scope | keys[0]' "tenant01"

    # Check scope value points to alz MG (root archetype → alz scope)
    scope_val="$(echo "$ac" | jq -r '.scope.tenant01[0]')"
    assert_contains "scope has MG provider" "$scope_val" "/providers/Microsoft.Management/managementGroups/"

    # Check parameters were populated
    assert_json_field "parameter testParam" "$ac" '.parameters.testParam' "default-value"

    # Check non-compliance message
    assert_json_field "non-compliance message" "$ac" '.nonComplianceMessages[0].message' \
        "Resources must comply with this policy."
else
    TESTS=$((TESTS + 6))
    echo "  FAIL: Test-Assignment.jsonc not found"
    FAIL=$((FAIL + 6))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== sync-alz: policy definition creation ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Add a mock policy definition to the library
mkdir -p "${mock_lib}/platform/alz/policy_definitions/Security"
cat > "${mock_lib}/platform/alz/policy_definitions/Security/test-policy.json" << 'EOF'
{
    "name": "test-policy-def",
    "properties": {
        "displayName": "Test Policy",
        "description": "A test policy definition",
        "metadata": {"category": "Security"},
        "policyType": "Custom",
        "mode": "All",
        "parameters": {},
        "policyRule": {
            "if": {"field": "type", "equals": "Microsoft.Compute/virtualMachines"},
            "then": {"effect": "audit"}
        }
    }
}
EOF

# Add a mock policy set definition
mkdir -p "${mock_lib}/platform/alz/policy_set_definitions"
cat > "${mock_lib}/platform/alz/policy_set_definitions/test-set-def.json" << 'EOF'
{
    "name": "test-policy-set",
    "properties": {
        "displayName": "Test Policy Set",
        "description": "A test set",
        "metadata": {"category": "Security"},
        "policyType": "Custom",
        "parameters": {},
        "policyDefinitions": [
            {
                "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/builtin-1",
                "policyDefinitionReferenceId": "ref-1",
                "parameters": {},
                "groupNames": ["group1"]
            },
            {
                "policyDefinitionId": "/providers/Microsoft.Management/managementGroups/alz/providers/Microsoft.Authorization/policyDefinitions/custom-1",
                "policyDefinitionReferenceId": "ref-2",
                "parameters": {},
                "groupNames": ["group1"]
            }
        ],
        "policyDefinitionGroups": [
            {"name": "group1", "displayName": "Group 1"}
        ]
    }
}
EOF

sync_defs2="${TEST_TMP}/SyncDefs2"
mkdir -p "${sync_defs2}/policyStructures"
cp "$structure_file" "${sync_defs2}/policyStructures/"

rc=0
bash "${REPO_ROOT}/scripts/caf/sync-alz-policy-from-library.sh" \
    --definitions-root "$sync_defs2" \
    --pac-selector "tenant01" \
    --type ALZ \
    --library-path "$mock_lib" 2>/dev/null || rc=$?
assert_rc "sync2 completed without error" 0 "$rc"

# Check policy definition was created
pd_dir="${sync_defs2}/policyDefinitions/ALZ/Security"
assert_dir_exists "policy def category dir" "$pd_dir"

pd_files="$(find "$pd_dir" -name "*.json" -type f 2>/dev/null)"
TESTS=$((TESTS + 1))
if [[ -n "$pd_files" ]]; then
    echo "  PASS: policy definition file(s) created in Security category"
    PASS=$((PASS + 1))

    pd_content="$(cat "$(echo "$pd_files" | head -1)")"
    assert_json_field "policy def has schema" "$pd_content" '."$schema"' \
        "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-definition-schema.json"
    assert_json_field "policy def name" "$pd_content" '.name' "test-policy-def"
    assert_contains "policy def has policyRule" "$pd_content" "policyRule"
else
    echo "  FAIL: no policy definition files created"
    FAIL=$((FAIL + 1))
fi

# Check policy set definition was created
psd_dir="${sync_defs2}/policySetDefinitions/ALZ/Security"
assert_dir_exists "policy set def category dir" "$psd_dir"

psd_files="$(find "$psd_dir" -name "*.json" -type f 2>/dev/null)"
TESTS=$((TESTS + 1))
if [[ -n "$psd_files" ]]; then
    echo "  PASS: policy set definition file(s) created"
    PASS=$((PASS + 1))

    psd_content="$(cat "$(echo "$psd_files" | head -1)")"
    assert_json_field "set def has schema" "$psd_content" '."$schema"' \
        "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-set-definition-schema.json"
    assert_json_field "set def name" "$psd_content" '.name' "test-policy-set"

    # Check that MG-based policyDefId was converted to policyDefinitionName
    TESTS=$((TESTS + 1))
    if echo "$psd_content" | jq -e '.properties.policyDefinitions[] | select(.policyDefinitionName == "custom-1")' &>/dev/null; then
        echo "  PASS: custom policy uses policyDefinitionName"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: custom policy should use policyDefinitionName"
        FAIL=$((FAIL + 1))
    fi

    # Check that builtin keeps policyDefinitionId
    TESTS=$((TESTS + 1))
    if echo "$psd_content" | jq -e '.properties.policyDefinitions[] | select(.policyDefinitionId)' &>/dev/null; then
        echo "  PASS: builtin policy keeps policyDefinitionId"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: builtin policy should keep policyDefinitionId"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  FAIL: no policy set definition files created"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== sync-alz: assignment cleanup ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Create a pre-existing assignment that should be cleaned up
sync_defs3="${TEST_TMP}/SyncDefs3"
mkdir -p "${sync_defs3}/policyStructures"
cp "$structure_file" "${sync_defs3}/policyStructures/"
mkdir -p "${sync_defs3}/policyAssignments/ALZ/tenant01/Root"
cat > "${sync_defs3}/policyAssignments/ALZ/tenant01/Root/Old-Assignment.jsonc" << 'EOF'
{"assignment": {"name": "Old-Assignment"}}
EOF

rc=0
bash "${REPO_ROOT}/scripts/caf/sync-alz-policy-from-library.sh" \
    --definitions-root "$sync_defs3" \
    --pac-selector "tenant01" \
    --type ALZ \
    --library-path "$mock_lib" 2>/dev/null || rc=$?
assert_rc "sync3 cleanup completed" 0 "$rc"

# Old assignment should have been removed
TESTS=$((TESTS + 1))
if [[ ! -f "${sync_defs3}/policyAssignments/ALZ/tenant01/Root/Old-Assignment.jsonc" ]]; then
    echo "  PASS: old assignment removed during sync"
    PASS=$((PASS + 1))
else
    echo "  FAIL: old assignment should have been cleaned up"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== sync-alz: --sync-assignments-only ==="
# ═══════════════════════════════════════════════════════════════════════════════

sync_defs4="${TEST_TMP}/SyncDefs4"
mkdir -p "${sync_defs4}/policyStructures"
cp "$structure_file" "${sync_defs4}/policyStructures/"

rc=0
bash "${REPO_ROOT}/scripts/caf/sync-alz-policy-from-library.sh" \
    --definitions-root "$sync_defs4" \
    --pac-selector "tenant01" \
    --type ALZ \
    --library-path "$mock_lib" \
    --sync-assignments-only 2>/dev/null || rc=$?
assert_rc "sync4 assignments-only completed" 0 "$rc"

# Should NOT have policy definitions
TESTS=$((TESTS + 1))
if [[ ! -d "${sync_defs4}/policyDefinitions" ]]; then
    echo "  PASS: no policy definitions created with --sync-assignments-only"
    PASS=$((PASS + 1))
else
    pd_count="$(find "${sync_defs4}/policyDefinitions" -name "*.json" 2>/dev/null | wc -l)"
    if [[ "$pd_count" -eq 0 ]]; then
        echo "  PASS: no policy definitions created with --sync-assignments-only"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: policy definitions should not be created with --sync-assignments-only"
        FAIL=$((FAIL + 1))
    fi
fi

# Should still have assignments
assign_count="$(find "${sync_defs4}/policyAssignments" -name "*.jsonc" -type f 2>/dev/null | wc -l)"
TESTS=$((TESTS + 1))
if [[ "$assign_count" -ge 1 ]]; then
    echo "  PASS: assignments still created with --sync-assignments-only"
    PASS=$((PASS + 1))
else
    echo "  FAIL: assignments should be created with --sync-assignments-only"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== sync-alz: enforcementMode override ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Create structure with override
sync_defs5="${TEST_TMP}/SyncDefs5"
mkdir -p "${sync_defs5}/policyStructures"

# Modify structure to include override
override_structure="$(cat "$structure_file" | jq '.overrides = {
    "enforcementMode": [
        {"policy_assignment_name": "Test-Assignment", "value": "DoNotEnforce"}
    ],
    "archetypes": {"ignore": [], "custom": []},
    "parameters": {}
}')"
echo "$override_structure" > "${sync_defs5}/policyStructures/alz.policy_default_structure.tenant01.jsonc"

rc=0
bash "${REPO_ROOT}/scripts/caf/sync-alz-policy-from-library.sh" \
    --definitions-root "$sync_defs5" \
    --pac-selector "tenant01" \
    --type ALZ \
    --library-path "$mock_lib" \
    --enable-overrides 2>/dev/null || rc=$?
assert_rc "sync5 overrides completed" 0 "$rc"

override_file="$(find "${sync_defs5}/policyAssignments" -name "Test-Assignment.jsonc" -type f 2>/dev/null | head -1)"
if [[ -n "$override_file" ]]; then
    override_content="$(cat "$override_file")"
    assert_json_field "enforcement override applied" "$override_content" '.enforcementMode' "DoNotEnforce"
else
    TESTS=$((TESTS + 1))
    echo "  FAIL: Test-Assignment.jsonc not found for override test"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== sync-alz: missing structure file ==="
# ═══════════════════════════════════════════════════════════════════════════════

sync_defs_empty="${TEST_TMP}/EmptyDefs"
mkdir -p "${sync_defs_empty}/policyStructures"

rc=0
bash "${REPO_ROOT}/scripts/caf/sync-alz-policy-from-library.sh" \
    --definitions-root "$sync_defs_empty" \
    --pac-selector "tenant01" \
    --type ALZ \
    --library-path "$mock_lib" 2>/dev/null || rc=$?
assert_rc "sync fails without structure file" 1 "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_log_success exists ==="
# ═══════════════════════════════════════════════════════════════════════════════

TESTS=$((TESTS + 1))
if declare -f epac_log_success &>/dev/null; then
    echo "  PASS: epac_log_success function exists"
    PASS=$((PASS + 1))
else
    echo "  FAIL: epac_log_success function not found"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== [[ to [ template fix ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Add a policy def with [[ in it to test the fix
pd_bracket_dir="${mock_lib}/platform/alz/policy_definitions/Test"
mkdir -p "$pd_bracket_dir"
cat > "${pd_bracket_dir}/bracket-test.json" << 'EOF'
{
    "name": "bracket-test",
    "properties": {
        "displayName": "Bracket Test",
        "metadata": {"category": "Test"},
        "policyRule": {
            "if": {"field": "[[resourceGroup().name]", "equals": "test"},
            "then": {"effect": "audit"}
        }
    }
}
EOF

sync_defs6="${TEST_TMP}/SyncDefs6"
mkdir -p "${sync_defs6}/policyStructures"
cp "$structure_file" "${sync_defs6}/policyStructures/"

rc=0
bash "${REPO_ROOT}/scripts/caf/sync-alz-policy-from-library.sh" \
    --definitions-root "$sync_defs6" \
    --pac-selector "tenant01" \
    --type ALZ \
    --library-path "$mock_lib" 2>/dev/null || rc=$?
assert_rc "sync6 bracket fix completed" 0 "$rc"

bracket_file="$(find "${sync_defs6}/policyDefinitions" -name "bracket-test.json" -type f 2>/dev/null | head -1)"
if [[ -n "$bracket_file" ]]; then
    bracket_content="$(cat "$bracket_file")"
    assert_not_contains "no [[ in output" "$bracket_content" "[["
    assert_contains "has [ in output" "$bracket_content" "[resourceGroup"
else
    TESTS=$((TESTS + 2))
    echo "  FAIL: bracket-test.json not created"
    FAIL=$((FAIL + 2))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== SUMMARY ==="
echo "Tests: $TESTS | Passed: $PASS | Failed: $FAIL"

[[ $FAIL -eq 0 ]] || exit 1
