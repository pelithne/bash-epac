#!/usr/bin/env bash
# tests/test_documentation.sh — Tests for WI-22 Documentation & README updates
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

assert_no_match() {
    local desc="$1" file="$2" pattern="$3"
    TESTS=$((TESTS + 1))
    if grep -qiE "$pattern" "$file" 2>/dev/null; then
        local count
        count=$(grep -ciE "$pattern" "$file" 2>/dev/null || true)
        echo "  FAIL: $desc ($count matches of '$pattern')"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

assert_match() {
    local desc="$1" file="$2" pattern="$3"
    TESTS=$((TESTS + 1))
    if grep -qiE "$pattern" "$file" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (no match for '$pattern')"
        FAIL=$((FAIL + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Documentation files exist ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in \
    index.md \
    ci-cd-overview.md \
    ci-cd-ado-pipelines.md \
    ci-cd-github-actions.md \
    ci-cd-app-registrations.md \
    ci-cd-branching-flows.md \
    debugging.md \
    start-implementing.md \
    start-changes.md \
    start-extracting-policy-resources.md \
    start-forking-github-repo.md \
    start-hydration-kit.md \
    manual-configuration.md \
    guidance-exemptions.md \
    guidance-lighthouse.md \
    guidance-remediation.md \
    guidance-scope-exclusions.md \
    integrating-with-alz-library.md \
    integrating-with-alz-overview.md \
    operational-scripts.md \
    operational-scripts-reference.md \
    operational-scripts-documenting-policy.md \
    policy-assignments.md \
    policy-assignments-csv-parameters.md \
    policy-definitions.md \
    policy-exemptions.md \
    policy-set-definitions.md \
    settings-desired-state.md \
    settings-dfc-assignments.md \
    settings-global-setting-file.md \
    settings-output-themes.md; do
    assert_file_exists "$f" "${REPO_ROOT}/Docs/$f"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== No PowerShell cmdlet references in docs ==="
# ═══════════════════════════════════════════════════════════════════════════════

# Check key docs for PS cmdlet names (excluding legacy sections and code comments)
PS_CMDLETS="Build-DeploymentPlans|Deploy-PolicyPlan|Deploy-RolesPlan|Build-PolicyDocumentation|New-AzRemediationTasks|Export-AzPolicyResources|New-PipelinesFromStarterKit|Connect-AzAccount|Install-Module|Export-NonComplianceReports|Set-AzPolicyExemptionEpac"

for f in \
    index.md \
    ci-cd-overview.md \
    debugging.md \
    start-implementing.md \
    manual-configuration.md \
    operational-scripts.md \
    operational-scripts-reference.md \
    start-hydration-kit.md \
    start-extracting-policy-resources.md \
    integrating-with-alz-library.md; do
    assert_no_match "no PS cmdlets: $f" "${REPO_ROOT}/Docs/$f" "$PS_CMDLETS"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== No .ps1 file extensions in key docs ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in \
    index.md \
    ci-cd-overview.md \
    debugging.md \
    start-implementing.md \
    manual-configuration.md \
    operational-scripts.md \
    operational-scripts-reference.md; do
    assert_no_match "no .ps1 refs: $f" "${REPO_ROOT}/Docs/$f" '\.ps1'
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== No \$env: PowerShell environment variable syntax ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in \
    ci-cd-overview.md \
    settings-global-setting-file.md \
    start-implementing.md \
    manual-configuration.md; do
    assert_no_match "no \$env: syntax: $f" "${REPO_ROOT}/Docs/$f" '\$env:'
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Bash script references present in key docs ==="
# ═══════════════════════════════════════════════════════════════════════════════

assert_match "index.md refs bash scripts" "${REPO_ROOT}/Docs/index.md" "build-deployment-plans\.sh"
assert_match "index.md refs deploy scripts" "${REPO_ROOT}/Docs/index.md" "deploy-policy-plan\.sh"
assert_match "ci-cd-overview refs epac-plan" "${REPO_ROOT}/Docs/ci-cd-overview.md" "epac-plan"
assert_match "ci-cd-overview refs deploy script" "${REPO_ROOT}/Docs/ci-cd-overview.md" "deploy-policy-plan\.sh"
assert_match "debugging.md refs bash dep tree" "${REPO_ROOT}/Docs/debugging.md" "epac_build_policy_plan"
assert_match "start-implementing refs bash" "${REPO_ROOT}/Docs/start-implementing.md" "Bash 5\.1"
assert_match "start-implementing refs jq" "${REPO_ROOT}/Docs/start-implementing.md" "jq 1\.6"
assert_match "start-implementing refs az cli" "${REPO_ROOT}/Docs/start-implementing.md" "Azure CLI"
assert_match "ops-reference refs bash" "${REPO_ROOT}/Docs/operational-scripts-reference.md" "build-policy-documentation\.sh"
assert_match "ops-reference uses --flags" "${REPO_ROOT}/Docs/operational-scripts-reference.md" "definitions-root-folder"
assert_match "manual-config uses bash cmds" "${REPO_ROOT}/Docs/manual-configuration.md" "build-deployment-plans\.sh"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== README.md updated ==="
# ═══════════════════════════════════════════════════════════════════════════════

assert_match "README mentions bash" "${REPO_ROOT}/README.md" "Bash"
assert_match "README mentions jq" "${REPO_ROOT}/README.md" "jq"
assert_match "README mentions Azure CLI" "${REPO_ROOT}/README.md" "Azure CLI"
assert_no_match "README no PS gallery" "${REPO_ROOT}/README.md" "powershellgallery"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== mkdocs.yml exists ==="
# ═══════════════════════════════════════════════════════════════════════════════

assert_file_exists "mkdocs.yml" "${REPO_ROOT}/mkdocs.yml"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== SUMMARY ==="
echo "Tests: $TESTS | Passed: $PASS | Failed: $FAIL"

[[ $FAIL -eq 0 ]] || exit 1
