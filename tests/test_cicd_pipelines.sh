#!/usr/bin/env bash
# tests/test_cicd_pipelines.sh — Tests for WI-19 CI/CD pipeline templates
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TESTS=0

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

assert_valid_yaml() {
    local desc="$1" path="$2"
    TESTS=$((TESTS + 1))
    # Basic YAML validation - check it's not empty and doesn't have obvious syntax errors
    if [[ -f "$path" ]] && [[ -s "$path" ]]; then
        # Check no tabs (YAML should use spaces)
        if grep -Pq '\t' "$path"; then
            echo "  FAIL: $desc (contains tabs)"
            FAIL=$((FAIL + 1))
        else
            echo "  PASS: $desc"
            PASS=$((PASS + 1))
        fi
    else
        echo "  FAIL: $desc (empty or missing)"
        FAIL=$((FAIL + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Azure DevOps templates existence ==="
# ═══════════════════════════════════════════════════════════════════════════════

ado_bash="${REPO_ROOT}/StarterKit/Pipelines/AzureDevOps/templates"
for tmpl in plan.yml deploy-policy.yml deploy-roles.yml documentation.yml remediate.yml plan-exemptions-only.yml; do
    assert_file_exists "ADO bash template: $tmpl" "${ado_bash}/${tmpl}"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== GitHub Actions templates existence ==="
# ═══════════════════════════════════════════════════════════════════════════════

gh_bash="${REPO_ROOT}/StarterKit/Pipelines/GitHubActions/templates"
for tmpl in plan.yml deploy-policy.yml deploy-roles.yml remediate.yml plan-exemptions-only.yml; do
    assert_file_exists "GH bash template: $tmpl" "${gh_bash}/${tmpl}"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== ALZ sync pipelines existence ==="
# ═══════════════════════════════════════════════════════════════════════════════

assert_file_exists "GH ALZ sync bash" "${REPO_ROOT}/StarterKit/Pipelines/GitHubActions/alz-sync.yaml"
assert_file_exists "ADO ALZ sync bash" "${REPO_ROOT}/StarterKit/Pipelines/AzureDevOps/alz-sync.yml"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== YAML validity ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in "${ado_bash}"/*.yml "${gh_bash}"/*.yml; do
    assert_valid_yaml "$(basename "$f") valid YAML" "$f"
done

assert_valid_yaml "GH ALZ sync YAML" "${REPO_ROOT}/StarterKit/Pipelines/GitHubActions/alz-sync.yaml"
assert_valid_yaml "ADO ALZ sync YAML" "${REPO_ROOT}/StarterKit/Pipelines/AzureDevOps/alz-sync.yml"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== ADO templates use AzureCLI@2 instead of AzurePowerShell@5 ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in "${ado_bash}"/*.yml; do
    content="$(cat "$f")"
    name="$(basename "$f")"
    assert_contains "ADO $name uses AzureCLI@2" "$content" "AzureCLI@2"
    assert_not_contains "ADO $name no AzurePowerShell" "$content" "AzurePowerShell"
    assert_contains "ADO $name scriptType bash" "$content" "scriptType: bash"
    assert_not_contains "ADO $name no Install-Module" "$content" "Install-Module"
    assert_not_contains "ADO $name no pwsh" "$content" "pwsh"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== ADO templates reference correct bash scripts ==="
# ═══════════════════════════════════════════════════════════════════════════════

assert_contains "ADO plan refs build-deployment-plans.sh" \
    "$(cat "${ado_bash}/plan.yml")" "scripts/deploy/build-deployment-plans.sh"
assert_contains "ADO deploy-policy refs deploy-policy-plan.sh" \
    "$(cat "${ado_bash}/deploy-policy.yml")" "scripts/deploy/deploy-policy-plan.sh"
assert_contains "ADO deploy-roles refs deploy-roles-plan.sh" \
    "$(cat "${ado_bash}/deploy-roles.yml")" "scripts/deploy/deploy-roles-plan.sh"
assert_contains "ADO documentation refs build-policy-documentation.sh" \
    "$(cat "${ado_bash}/documentation.yml")" "scripts/operations/build-policy-documentation.sh"
assert_contains "ADO remediate refs new-az-remediation-tasks.sh" \
    "$(cat "${ado_bash}/remediate.yml")" "scripts/operations/new-az-remediation-tasks.sh"
assert_contains "ADO plan-exemptions-only has --build-exemptions-only" \
    "$(cat "${ado_bash}/plan-exemptions-only.yml")" "--build-exemptions-only"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== ADO templates have correct parameters ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in "${ado_bash}"/*.yml; do
    content="$(cat "$f")"
    name="$(basename "$f")"
    assert_contains "ADO $name has serviceConnection param" "$content" "serviceConnection"
    assert_contains "ADO $name has pacEnvironmentSelector param" "$content" "pacEnvironmentSelector"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== ADO deploy templates have artifact download ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in deploy-policy.yml deploy-roles.yml; do
    content="$(cat "${ado_bash}/${f}")"
    assert_contains "ADO $f has download" "$content" "download: current"
    assert_contains "ADO $f has artifact" "$content" "artifact:"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== ADO plan templates have artifact publish ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in plan.yml plan-exemptions-only.yml; do
    content="$(cat "${ado_bash}/${f}")"
    assert_contains "ADO $f has publish" "$content" "publish:"
    assert_contains "ADO $f has condition" "$content" "condition:"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== GH Actions templates use azure/login not PowerShell ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in "${gh_bash}"/*.yml; do
    content="$(cat "$f")"
    name="$(basename "$f")"
    assert_contains "GH $name uses azure/login" "$content" "azure/login@v2"
    assert_not_contains "GH $name no Install-Module" "$content" "Install-Module"
    assert_not_contains "GH $name no Azure/powershell" "$content" "Azure/powershell"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== GH Actions templates reference correct bash scripts ==="
# ═══════════════════════════════════════════════════════════════════════════════

assert_contains "GH plan refs build-deployment-plans.sh" \
    "$(cat "${gh_bash}/plan.yml")" "scripts/deploy/build-deployment-plans.sh"
assert_contains "GH deploy-policy refs deploy-policy-plan.sh" \
    "$(cat "${gh_bash}/deploy-policy.yml")" "scripts/deploy/deploy-policy-plan.sh"
assert_contains "GH deploy-roles refs deploy-roles-plan.sh" \
    "$(cat "${gh_bash}/deploy-roles.yml")" "scripts/deploy/deploy-roles-plan.sh"
assert_contains "GH remediate refs new-az-remediation-tasks.sh" \
    "$(cat "${gh_bash}/remediate.yml")" "scripts/operations/new-az-remediation-tasks.sh"
assert_contains "GH plan-exemptions-only has --build-exemptions-only" \
    "$(cat "${gh_bash}/plan-exemptions-only.yml")" "--build-exemptions-only"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== GH Actions plan templates have workflow_call ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in plan.yml plan-exemptions-only.yml; do
    content="$(cat "${gh_bash}/${f}")"
    assert_contains "GH $f has workflow_call" "$content" "workflow_call"
    assert_contains "GH $f has outputs" "$content" "deployPolicyChanges"
    assert_contains "GH $f has upload-artifact" "$content" "upload-artifact"
    assert_contains "GH $f has detectPlan" "$content" "detectPlan"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== GH Actions deploy templates have download-artifact ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in deploy-policy.yml deploy-roles.yml; do
    content="$(cat "${gh_bash}/${f}")"
    assert_contains "GH $f has download-artifact" "$content" "download-artifact"
    assert_contains "GH $f has workflow_call" "$content" "workflow_call"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== GH Actions plan detect uses bash not pwsh ==="
# ═══════════════════════════════════════════════════════════════════════════════

plan_content="$(cat "${gh_bash}/plan.yml")"
assert_not_contains "GH plan detect no pwsh shell" "$plan_content" "shell: pwsh"
assert_contains "GH plan detect uses GITHUB_OUTPUT" "$plan_content" "GITHUB_OUTPUT"
assert_contains "GH plan detect uses bash syntax" "$plan_content" "[[ -d"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== ALZ sync workflows reference bash scripts ==="
# ═══════════════════════════════════════════════════════════════════════════════

gh_sync="$(cat "${REPO_ROOT}/StarterKit/Pipelines/GitHubActions/alz-sync.yaml")"
assert_contains "GH ALZ sync refs sync-alz-policy-from-library.sh" "$gh_sync" "scripts/caf/sync-alz-policy-from-library.sh"
assert_not_contains "GH ALZ sync no Install-Module" "$gh_sync" "Install-Module"
assert_contains "GH ALZ sync creates PR" "$gh_sync" "gh pr create"
assert_contains "GH ALZ sync has workflow_dispatch" "$gh_sync" "workflow_dispatch"

ado_sync="$(cat "${REPO_ROOT}/StarterKit/Pipelines/AzureDevOps/alz-sync.yml")"
assert_contains "ADO ALZ sync refs sync-alz-policy-from-library.sh" "$ado_sync" "scripts/caf/sync-alz-policy-from-library.sh"
assert_not_contains "ADO ALZ sync no Install-Module" "$ado_sync" "Install-Module"
assert_contains "ADO ALZ sync creates PR" "$ado_sync" "az repos pr create"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Referenced bash scripts exist ==="
# ═══════════════════════════════════════════════════════════════════════════════

for script in \
    scripts/deploy/build-deployment-plans.sh \
    scripts/deploy/deploy-policy-plan.sh \
    scripts/deploy/deploy-roles-plan.sh \
    scripts/operations/build-policy-documentation.sh \
    scripts/operations/new-az-remediation-tasks.sh \
    scripts/caf/sync-alz-policy-from-library.sh; do
    assert_file_exists "referenced script: $script" "${REPO_ROOT}/${script}"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== No PowerShell remnants in bash templates ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in "${ado_bash}"/*.yml "${gh_bash}"/*.yml \
    "${REPO_ROOT}/StarterKit/Pipelines/GitHubActions/alz-sync.yaml" \
    "${REPO_ROOT}/StarterKit/Pipelines/AzureDevOps/alz-sync.yml"; do
    content="$(cat "$f")"
    name="$(basename "$f")"
    assert_not_contains "$name no .ps1 references" "$content" ".ps1"
    assert_not_contains "$name no Build-DeploymentPlans cmdlet" "$content" "Build-DeploymentPlans "
    assert_not_contains "$name no Deploy-PolicyPlan cmdlet" "$content" "Deploy-PolicyPlan "
    assert_not_contains "$name no Deploy-RolesPlan cmdlet" "$content" "Deploy-RolesPlan "
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== SUMMARY ==="
echo "Tests: $TESTS | Passed: $PASS | Failed: $FAIL"

[[ $FAIL -eq 0 ]] || exit 1
