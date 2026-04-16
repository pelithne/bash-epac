#!/usr/bin/env bash
# tests/test_scaffolding.sh — Tests for WI-16 scaffolding & new resource creation scripts
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
        echo "    in: ${haystack:0:200}"
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

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Script executability ==="
for script in \
    new-epac-global-settings.sh \
    new-epac-policy-definition.sh \
    new-epac-policy-assignment-definition.sh \
    new-pipelines-from-starter-kit.sh \
    convert-markdown-github-alerts.sh; do

    path="${REPO_ROOT}/scripts/operations/${script}"
    TESTS=$((TESTS + 1))
    if [[ -x "$path" ]]; then
        echo "  PASS: $script is executable"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $script is not executable"
        FAIL=$((FAIL + 1))
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Script --help exits cleanly ==="
for script in \
    new-epac-global-settings.sh \
    new-epac-policy-definition.sh \
    new-epac-policy-assignment-definition.sh \
    new-pipelines-from-starter-kit.sh \
    convert-markdown-github-alerts.sh; do

    path="${REPO_ROOT}/scripts/operations/${script}"
    rc=0
    output="$(bash "$path" --help 2>&1)" || rc=$?
    assert_rc "$script --help exits 0" 0 "$rc"
    assert_contains "$script --help has Usage" "$output" "Usage"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Argument validation ==="

rc=0
bash "${REPO_ROOT}/scripts/operations/new-epac-global-settings.sh" 2>&1 || rc=$?
assert_eq "global-settings no args exits 1" "1" "$rc"

rc=0
bash "${REPO_ROOT}/scripts/operations/new-epac-policy-definition.sh" 2>&1 || rc=$?
assert_eq "policy-definition no args exits 1" "1" "$rc"

rc=0
bash "${REPO_ROOT}/scripts/operations/new-epac-policy-assignment-definition.sh" 2>&1 || rc=$?
assert_eq "policy-assignment no args exits 1" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Global settings: scope validation ==="

rc=0
bash "${REPO_ROOT}/scripts/operations/new-epac-global-settings.sh" \
    --location "eastus" --tenant-id "00000000-0000-0000-0000-000000000000" \
    --definitions-root-folder "$TEST_TMP" \
    --deployment-root-scope "/invalid/scope" 2>&1 || rc=$?
assert_eq "Invalid scope format exits 1" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Global settings: folder validation ==="

rc=0
bash "${REPO_ROOT}/scripts/operations/new-epac-global-settings.sh" \
    --location "eastus" --tenant-id "00000000-0000-0000-0000-000000000000" \
    --definitions-root-folder "/nonexistent/path" \
    --deployment-root-scope "/providers/Microsoft.Management/managementGroups/mg1" 2>&1 || rc=$?
assert_eq "Missing folder exits 1" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Global settings: JSON structure ==="

# Test the jq template directly (can't call az account list-locations offline)
pac_owner_id="test-guid-1234"
location="eastus"
tenant_id="00000000-0000-0000-0000-000000000000"
scope="/providers/Microsoft.Management/managementGroups/mg1"

gs_json="$(jq -n \
    --arg schema "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/global-settings-schema.json" \
    --arg owner_id "$pac_owner_id" \
    --arg location "$location" \
    --arg tenant "$tenant_id" \
    --arg scope "$scope" \
    '{
        "$schema": $schema,
        pacOwnerId: $owner_id,
        managedIdentityLocations: { "*": $location },
        pacEnvironments: [{
            pacSelector: "quick-start",
            cloud: "AzureCloud",
            tenantId: $tenant,
            deploymentRootScope: $scope
        }]
    }')"

schema_val="$(echo "$gs_json" | jq -r '.["$schema"]')"
assert_contains "JSON has schema" "$schema_val" "global-settings-schema.json"

owner_val="$(echo "$gs_json" | jq -r '.pacOwnerId')"
assert_eq "JSON has pacOwnerId" "test-guid-1234" "$owner_val"

loc_val="$(echo "$gs_json" | jq -r '.managedIdentityLocations["*"]')"
assert_eq "JSON has location" "eastus" "$loc_val"

env_count="$(echo "$gs_json" | jq '.pacEnvironments | length')"
assert_eq "JSON has 1 pacEnvironment" "1" "$env_count"

selector="$(echo "$gs_json" | jq -r '.pacEnvironments[0].pacSelector')"
assert_eq "JSON pacSelector" "quick-start" "$selector"

cloud="$(echo "$gs_json" | jq -r '.pacEnvironments[0].cloud')"
assert_eq "JSON cloud" "AzureCloud" "$cloud"

tenant_out="$(echo "$gs_json" | jq -r '.pacEnvironments[0].tenantId')"
assert_eq "JSON tenantId" "$tenant_id" "$tenant_out"

scope_out="$(echo "$gs_json" | jq -r '.pacEnvironments[0].deploymentRootScope')"
assert_eq "JSON scope" "$scope" "$scope_out"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy definition: EPAC format (policy) ==="

# Simulate az CLI output for a policy definition
mock_pd='{
    "name": "Deny-SQL-Public",
    "displayName": "Deny SQL Public Access",
    "mode": "All",
    "description": "Denies public access to SQL",
    "metadata": {"version": "1.0.0", "category": "SQL"},
    "parameters": {"effect": {"type": "String", "defaultValue": "Deny"}},
    "policyRule": {"if": {"field": "type", "equals": "Microsoft.Sql"}, "then": {"effect": "[parameters('"'"'effect'"'"')]"}}
}'

epac_pd="$(echo "$mock_pd" | jq '{
    name: .name,
    properties: {
        displayName: .displayName,
        mode: .mode,
        description: .description,
        metadata: { version: .metadata.version, category: .metadata.category },
        parameters: .parameters,
        policyRule: .policyRule
    }
}')"

pd_name="$(echo "$epac_pd" | jq -r '.name')"
assert_eq "PD name" "Deny-SQL-Public" "$pd_name"

pd_display="$(echo "$epac_pd" | jq -r '.properties.displayName')"
assert_eq "PD displayName" "Deny SQL Public Access" "$pd_display"

pd_mode="$(echo "$epac_pd" | jq -r '.properties.mode')"
assert_eq "PD mode" "All" "$pd_mode"

pd_version="$(echo "$epac_pd" | jq -r '.properties.metadata.version')"
assert_eq "PD metadata version" "1.0.0" "$pd_version"

pd_category="$(echo "$epac_pd" | jq -r '.properties.metadata.category')"
assert_eq "PD metadata category" "SQL" "$pd_category"

pd_params="$(echo "$epac_pd" | jq '.properties.parameters | length')"
assert_eq "PD has 1 param" "1" "$pd_params"

pd_rule="$(echo "$epac_pd" | jq '.properties.policyRule | has("if")')"
assert_eq "PD has policyRule.if" "true" "$pd_rule"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy definition: EPAC format (policy set) ==="

mock_psd='{
    "name": "MCSB-v2",
    "displayName": "MCSB v2",
    "description": "Microsoft Cloud Security Benchmark",
    "metadata": {"version": "2.0.0", "category": "Security"},
    "policyDefinitionGroups": [{"name": "NS-1", "displayName": "NS-1"}],
    "parameters": {},
    "policyDefinitions": [
        {"policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/Deny-SQL-Public", "parameters": {}},
        {"policyDefinitionId": "/providers/Microsoft.Management/managementGroups/mg1/providers/Microsoft.Authorization/policyDefinitions/Audit-VM", "parameters": {}}
    ]
}'

epac_psd="$(echo "$mock_psd" | jq '{
    name: .name,
    properties: {
        displayName: .displayName,
        description: .description,
        metadata: { version: .metadata.version, category: .metadata.category },
        policyDefinitionGroups: .policyDefinitionGroups,
        parameters: .parameters,
        policyDefinitions: [.policyDefinitions[] | {
            policyDefinitionName: (.policyDefinitionId | split("/") | last)
        } + (del(.policyDefinitionId))]
    }
}')"

psd_name="$(echo "$epac_psd" | jq -r '.name')"
assert_eq "PSD name" "MCSB-v2" "$psd_name"

psd_pd_count="$(echo "$epac_psd" | jq '.properties.policyDefinitions | length')"
assert_eq "PSD has 2 policy definitions" "2" "$psd_pd_count"

# Verify policyDefinitionName extracted from ID
psd_pd1_name="$(echo "$epac_psd" | jq -r '.properties.policyDefinitions[0].policyDefinitionName')"
assert_eq "PSD pd[0] name" "Deny-SQL-Public" "$psd_pd1_name"

psd_pd2_name="$(echo "$epac_psd" | jq -r '.properties.policyDefinitions[1].policyDefinitionName')"
assert_eq "PSD pd[1] name" "Audit-VM" "$psd_pd2_name"

# Verify policyDefinitionId removed
psd_has_id="$(echo "$epac_psd" | jq '.properties.policyDefinitions[0] | has("policyDefinitionId")')"
assert_eq "PSD pd[0] no policyDefinitionId" "false" "$psd_has_id"

psd_groups="$(echo "$epac_psd" | jq '.properties.policyDefinitionGroups | length')"
assert_eq "PSD has groups" "1" "$psd_groups"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment definition: EPAC format (policy) ==="

mock_assign='{
    "name": "Deny-SQL-Assign",
    "displayName": "Deny SQL Assignment",
    "description": "Assignment for Deny SQL",
    "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/Deny-SQL-Public",
    "parameters": {"effect": {"value": "Deny"}, "allowedLocations": {"value": ["eastus","westus"]}}
}'

epac_assign="$(echo "$mock_assign" | jq --arg defKey "policyName" '{
    assignment: {
        name: .name,
        displayName: .displayName,
        description: .description
    },
    definitionEntry: {
        ($defKey): (.policyDefinitionId | split("/") | last)
    },
    parameters: (
        if .parameters != null and (.parameters | length) > 0 then
            .parameters | to_entries | map({key: .key, value: .value.value}) | from_entries
        else
            {}
        end
    )
}')"

assign_name="$(echo "$epac_assign" | jq -r '.assignment.name')"
assert_eq "Assign name" "Deny-SQL-Assign" "$assign_name"

assign_display="$(echo "$epac_assign" | jq -r '.assignment.displayName')"
assert_eq "Assign displayName" "Deny SQL Assignment" "$assign_display"

assign_policy_name="$(echo "$epac_assign" | jq -r '.definitionEntry.policyName')"
assert_eq "Assign policyName" "Deny-SQL-Public" "$assign_policy_name"

assign_effect="$(echo "$epac_assign" | jq -r '.parameters.effect')"
assert_eq "Assign param effect" "Deny" "$assign_effect"

assign_locations="$(echo "$epac_assign" | jq '.parameters.allowedLocations | length')"
assert_eq "Assign param locations count" "2" "$assign_locations"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment definition: EPAC format (policy set) ==="

mock_set_assign='{
    "name": "MCSB-Assign",
    "displayName": "MCSB Assignment",
    "description": "Assignment for MCSB",
    "policyDefinitionId": "/providers/Microsoft.Authorization/policySetDefinitions/MCSB-v2",
    "parameters": {}
}'

epac_set_assign="$(echo "$mock_set_assign" | jq --arg defKey "policySetName" '{
    assignment: {
        name: .name,
        displayName: .displayName,
        description: .description
    },
    definitionEntry: {
        ($defKey): (.policyDefinitionId | split("/") | last)
    },
    parameters: (
        if .parameters != null and (.parameters | length) > 0 then
            .parameters | to_entries | map({key: .key, value: .value.value}) | from_entries
        else
            {}
        end
    )
}')"

set_assign_key="$(echo "$epac_set_assign" | jq -r '.definitionEntry | keys[0]')"
assert_eq "Set assign uses policySetName" "policySetName" "$set_assign_key"

set_assign_val="$(echo "$epac_set_assign" | jq -r '.definitionEntry.policySetName')"
assert_eq "Set assign policySetName" "MCSB-v2" "$set_assign_val"

set_assign_params="$(echo "$epac_set_assign" | jq '.parameters | length')"
assert_eq "Set assign empty params" "0" "$set_assign_params"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Pipelines: starter kit validation ==="

# Test with nonexistent starter kit folder
rc=0
bash "${REPO_ROOT}/scripts/operations/new-pipelines-from-starter-kit.sh" \
    --starter-kit-folder "/nonexistent" 2>&1 || rc=$?
assert_eq "Missing starter kit exits 1" "1" "$rc"

# Test invalid pipeline type
rc=0
bash "${REPO_ROOT}/scripts/operations/new-pipelines-from-starter-kit.sh" \
    --pipeline-type Invalid 2>&1 || rc=$?
assert_eq "Invalid pipeline type exits 1" "1" "$rc"

# Test invalid branching flow
rc=0
bash "${REPO_ROOT}/scripts/operations/new-pipelines-from-starter-kit.sh" \
    --branching-flow Invalid 2>&1 || rc=$?
assert_eq "Invalid branching flow exits 1" "1" "$rc"

# ════════════════════════════════════════════════════════════════════════════════
echo "=== Pipelines: actual copy (GitHubActions/Release) ==="

dest="${TEST_TMP}/gh-release"
bash "${REPO_ROOT}/scripts/operations/new-pipelines-from-starter-kit.sh" \
    --starter-kit-folder "${REPO_ROOT}/StarterKit" \
    --pipelines-folder "$dest" \
    --pipeline-type GitHubActions \
    --branching-flow Release \
    --suppress-confirm 2>&1

# Check that workflow files were copied
ga_release_files="$(ls "$dest"/*.yml 2>/dev/null | wc -l | tr -d ' ')"
TESTS=$((TESTS + 1))
if [[ "$ga_release_files" -gt 0 ]]; then
    echo "  PASS: GitHubActions/Release: $ga_release_files yml files copied"
    PASS=$((PASS + 1))
else
    echo "  FAIL: GitHubActions/Release: no yml files copied"
    FAIL=$((FAIL + 1))
fi

# Check template files (for GitHubActions, templates go to same folder)
ga_template_count="$(ls "$dest"/*.yml 2>/dev/null | grep -c -E 'plan|deploy|remediate' || true)"
TESTS=$((TESTS + 1))
if [[ "$ga_template_count" -gt 0 ]]; then
    echo "  PASS: GitHubActions templates copied ($ga_template_count template files)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: GitHubActions templates not copied"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Pipelines: actual copy (AzureDevOps/GitHub) ==="

dest2="${TEST_TMP}/ado-github"
bash "${REPO_ROOT}/scripts/operations/new-pipelines-from-starter-kit.sh" \
    --starter-kit-folder "${REPO_ROOT}/StarterKit" \
    --pipelines-folder "$dest2" \
    --pipeline-type AzureDevOps \
    --branching-flow GitHub \
    --suppress-confirm 2>&1

# Verify pipeline files
ado_pipeline_files="$(ls "$dest2"/*.yml 2>/dev/null | wc -l | tr -d ' ')"
TESTS=$((TESTS + 1))
if [[ "$ado_pipeline_files" -gt 0 ]]; then
    echo "  PASS: AzureDevOps/GitHub: $ado_pipeline_files yml files copied"
    PASS=$((PASS + 1))
else
    echo "  FAIL: AzureDevOps/GitHub: no yml files copied"
    FAIL=$((FAIL + 1))
fi

# Verify templates subfolder
ado_template_files="$(ls "$dest2/templates"/*.yml 2>/dev/null | wc -l | tr -d ' ')"
TESTS=$((TESTS + 1))
if [[ "$ado_template_files" -gt 0 ]]; then
    echo "  PASS: AzureDevOps templates in subfolder ($ado_template_files files)"
    PASS=$((PASS + 1))
else
    echo "  FAIL: AzureDevOps templates not in subfolder"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Markdown conversion: GitHub → MkDocs ==="

md_input="${TEST_TMP}/md-input"
md_output="${TEST_TMP}/md-output"
mkdir -p "$md_input/sub"

cat > "$md_input/test1.md" << 'MDEOF'
# Title

Some text before.

> [!NOTE]
> This is a note.

Some text between.

> [!WARNING]
> This is a warning.

> [!CAUTION]
> Watch out!
MDEOF

cat > "$md_input/sub/nested.md" << 'MDEOF'
> [!TIP]
> A helpful tip.

> [!IMPORTANT]
> Do this now.
MDEOF

bash "${REPO_ROOT}/scripts/operations/convert-markdown-github-alerts.sh" \
    --input-folder "$md_input" \
    --output-folder "$md_output" 2>&1

assert_file_exists "Output test1.md exists" "$md_output/test1.md"
assert_file_exists "Output sub/nested.md exists" "$md_output/sub/nested.md"

# Verify conversions
test1_content="$(cat "$md_output/test1.md")"
assert_contains "Has !!! note" "$test1_content" '!!! note'
assert_contains "Has !!! warning" "$test1_content" '!!! warning'
assert_contains "Has !!! danger" "$test1_content" '!!! danger "Caution"'
assert_contains "Has indented note content" "$test1_content" '    This is a note.'
assert_contains "Has indented warning content" "$test1_content" '    This is a warning.'
assert_contains "Preserves title" "$test1_content" '# Title'
assert_contains "Preserves text" "$test1_content" 'Some text before.'

nested_content="$(cat "$md_output/sub/nested.md")"
assert_contains "Nested has !!! tip" "$nested_content" '!!! tip'
assert_contains "Nested has !!! tip Important" "$nested_content" '!!! tip "Important"'

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Markdown conversion: MkDocs → GitHub ==="

mkdocs_input="${TEST_TMP}/mkdocs-input"
mkdocs_output="${TEST_TMP}/mkdocs-output"
mkdir -p "$mkdocs_input"

cat > "$mkdocs_input/test2.md" << 'MDEOF'
# Title

!!! note

    This is a note.

!!! warning

    Watch out for this.

!!! tip

    A helpful tip.
MDEOF

bash "${REPO_ROOT}/scripts/operations/convert-markdown-github-alerts.sh" \
    --input-folder "$mkdocs_input" \
    --output-folder "$mkdocs_output" \
    --to-github-alerts 2>&1

assert_file_exists "Output test2.md exists" "$mkdocs_output/test2.md"

test2_content="$(cat "$mkdocs_output/test2.md")"
assert_contains "Has > [!NOTE]" "$test2_content" '> [!NOTE]'
assert_contains "Has > [!WARNING]" "$test2_content" '> [!WARNING]'
assert_contains "Has > [!TIP]" "$test2_content" '> [!TIP]'
assert_contains "Has unindented note content" "$test2_content" '> This is a note.'
assert_contains "Has unindented warning content" "$test2_content" '> Watch out for this.'
assert_contains "Preserves title" "$test2_content" '# Title'

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Markdown conversion: all MkDocs types ==="

types_input="${TEST_TMP}/types-input"
types_output="${TEST_TMP}/types-output"
mkdir -p "$types_input"

# Test all MkDocs admonition types
cat > "$types_input/all-types.md" << 'MDEOF'
!!! note

    Note text.

!!! abstract

    Abstract text.

!!! info

    Info text.

!!! success

    Success text.

!!! question

    Question text.

!!! example

    Example text.

!!! tip

    Tip text.

!!! tip "Important"

    Important text.

!!! warning

    Warning text.

!!! danger "Caution"

    Caution text.

!!! danger

    Danger text.

!!! failure

    Failure text.

!!! bug

    Bug text.
MDEOF

bash "${REPO_ROOT}/scripts/operations/convert-markdown-github-alerts.sh" \
    --input-folder "$types_input" \
    --output-folder "$types_output" \
    --to-github-alerts 2>&1

types_content="$(cat "$types_output/all-types.md")"

# Count occurrences of each GitHub alert type
note_count="$(echo "$types_content" | grep -c '> \[!NOTE\]' || true)"
assert_eq "6 types map to NOTE" "6" "$note_count"

tip_count="$(echo "$types_content" | grep -c '> \[!TIP\]' || true)"
assert_eq "1 type maps to TIP" "1" "$tip_count"

important_count="$(echo "$types_content" | grep -c '> \[!IMPORTANT\]' || true)"
assert_eq "1 type maps to IMPORTANT" "1" "$important_count"

warning_count="$(echo "$types_content" | grep -c '> \[!WARNING\]' || true)"
assert_eq "1 type maps to WARNING" "1" "$warning_count"

caution_count="$(echo "$types_content" | grep -c '> \[!CAUTION\]' || true)"
assert_eq "4 types map to CAUTION" "4" "$caution_count"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Markdown conversion: round-trip ==="

# GitHub → MkDocs → GitHub should produce same output
roundtrip_mid="${TEST_TMP}/roundtrip-mid"
roundtrip_out="${TEST_TMP}/roundtrip-out"

# First: GitHub → MkDocs
bash "${REPO_ROOT}/scripts/operations/convert-markdown-github-alerts.sh" \
    --input-folder "$md_input" \
    --output-folder "$roundtrip_mid" 2>&1

# Then: MkDocs → GitHub
bash "${REPO_ROOT}/scripts/operations/convert-markdown-github-alerts.sh" \
    --input-folder "$roundtrip_mid" \
    --output-folder "$roundtrip_out" \
    --to-github-alerts 2>&1

# Compare original and round-tripped
diff_result="$(diff "$md_input/test1.md" "$roundtrip_out/test1.md" 2>&1 || true)"
assert_eq "Round-trip produces same output" "" "$diff_result"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Markdown conversion: input folder validation ==="

rc=0
bash "${REPO_ROOT}/scripts/operations/convert-markdown-github-alerts.sh" \
    --input-folder "/nonexistent" 2>&1 || rc=$?
assert_eq "Missing input folder exits 1" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "================================="
echo "Tests: $TESTS | Passed: $PASS | Failed: $FAIL"
echo "================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
