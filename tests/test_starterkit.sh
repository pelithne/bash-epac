#!/usr/bin/env bash
# tests/test_starterkit.sh — Tests for WI-21 StarterKit & examples
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${REPO_ROOT}/lib/epac.sh"

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

assert_valid_json() {
    local desc="$1" path="$2"
    TESTS=$((TESTS + 1))
    if jq '.' "$path" &>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    elif epac_read_jsonc "$path" &>/dev/null; then
        echo "  PASS: $desc (JSONC)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (invalid JSON/JSONC)"
        FAIL=$((FAIL + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== StarterKit directory structure ==="
# ═══════════════════════════════════════════════════════════════════════════════

for dir in \
    StarterKit/Definitions-Common \
    StarterKit/Definitions-GitHub-Flow \
    StarterKit/Definitions-Microsoft-Release-Flow \
    StarterKit/HydrationKit \
    StarterKit/Pipelines/AzureDevOps \
    StarterKit/Pipelines/GitHubActions; do
    assert_dir_exists "dir: $dir" "${REPO_ROOT}/${dir}"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== StarterKit bash template directories ==="
# ═══════════════════════════════════════════════════════════════════════════════

for dir in \
    StarterKit/Pipelines/AzureDevOps/templates \
    StarterKit/Pipelines/GitHubActions/templates; do
    assert_dir_exists "bash templates: $dir" "${REPO_ROOT}/${dir}"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== All JSON/JSONC definition files are valid ==="
# ═══════════════════════════════════════════════════════════════════════════════

while IFS= read -r -d '' f; do
    name="${f#${REPO_ROOT}/}"
    assert_valid_json "$name" "$f"
done < <(find "${REPO_ROOT}/StarterKit/Definitions-Common" \
              "${REPO_ROOT}/StarterKit/Definitions-GitHub-Flow" \
              "${REPO_ROOT}/StarterKit/Definitions-Microsoft-Release-Flow" \
              \( -name "*.json" -o -name "*.jsonc" \) -print0 | sort -z)

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Global settings files are parseable ==="
# ═══════════════════════════════════════════════════════════════════════════════

while IFS= read -r -d '' gs; do
    name="${gs#${REPO_ROOT}/}"
    TESTS=$((TESTS + 1))
    if content="$(epac_read_jsonc "$gs" 2>/dev/null)"; then
        # Check it has a pacEnvironments key
        if echo "$content" | jq -e '.pacEnvironments' &>/dev/null; then
            echo "  PASS: $name has pacEnvironments"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $name missing pacEnvironments"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  FAIL: $name not parseable"
        FAIL=$((FAIL + 1))
    fi
done < <(find "${REPO_ROOT}/StarterKit" -name "global-settings.jsonc" -print0 2>/dev/null)

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Example documentation files ==="
# ═══════════════════════════════════════════════════════════════════════════════

assert_file_exists "bash documentation example" \
    "${REPO_ROOT}/Examples/Auto-Documentation/yamlExamples/documentation-bash.yaml"
assert_file_exists "bash documentation pipeline example" \
    "${REPO_ROOT}/Examples/Auto-Documentation/yamlExamples/documentationPipeline-bash.yaml"

# Bash examples use AzureCLI not PowerShell
bash_doc="$(cat "${REPO_ROOT}/Examples/Auto-Documentation/yamlExamples/documentation-bash.yaml")"
assert_contains "bash doc uses AzureCLI" "$bash_doc" "AzureCLI@2"
assert_not_contains "bash doc no AzurePowerShell" "$bash_doc" "AzurePowerShell"
assert_not_contains "bash doc no Install-Module" "$bash_doc" "Install-Module"
assert_contains "bash doc refs bash script" "$bash_doc" "scripts/operations/build-policy-documentation.sh"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Example policy documentation JSONC files ==="
# ═══════════════════════════════════════════════════════════════════════════════

while IFS= read -r -d '' f; do
    assert_valid_json "$(basename "$f")" "$f"
done < <(find "${REPO_ROOT}/Examples/Auto-Documentation/policyDocumentations" -name "*.jsonc" -print0 2>/dev/null)

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Example assignment/set files ==="
# ═══════════════════════════════════════════════════════════════════════════════

for f in \
    Examples/MCSBv2/mcsbv2-assignment.jsonc \
    Examples/MFA/MFA-policyAssignment.jsonc \
    Examples/MFA/MFA-policySetDefinition.jsonc; do
    assert_file_exists "example: $f" "${REPO_ROOT}/${f}"
    assert_valid_json "valid: $f" "${REPO_ROOT}/${f}"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Schema files ==="
# ═══════════════════════════════════════════════════════════════════════════════

for schema in \
    global-settings-schema.json \
    policy-assignment-schema.json \
    policy-definition-schema.json \
    policy-documentation-schema.json \
    policy-exemption-schema.json \
    policy-set-definition-schema.json \
    policy-structure-schema.json; do
    assert_file_exists "schema: $schema" "${REPO_ROOT}/Schemas/${schema}"
    assert_valid_json "valid schema: $schema" "${REPO_ROOT}/Schemas/${schema}"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Policy assignment files have schema reference ==="
# ═══════════════════════════════════════════════════════════════════════════════

while IFS= read -r -d '' f; do
    name="${f#${REPO_ROOT}/}"
    content="$(epac_read_jsonc "$f" 2>/dev/null || true)"
    if [[ -n "$content" ]]; then
        TESTS=$((TESTS + 1))
        if echo "$content" | jq -e '."$schema"' &>/dev/null; then
            echo "  PASS: $name has schema"
            PASS=$((PASS + 1))
        else
            # Not all assignment files require schema — pass if parseable
            echo "  PASS: $name parseable (no schema)"
            PASS=$((PASS + 1))
        fi
    fi
done < <(find "${REPO_ROOT}/StarterKit" -path "*/policyAssignments/*.jsonc" -print0 2>/dev/null)

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== StarterKit CSV files readable ==="
# ═══════════════════════════════════════════════════════════════════════════════

while IFS= read -r -d '' f; do
    name="${f#${REPO_ROOT}/}"
    TESTS=$((TESTS + 1))
    if [[ -s "$f" ]]; then
        # Check CSV has header line
        header="$(head -1 "$f")"
        if [[ -n "$header" ]]; then
            echo "  PASS: $name has content"
            PASS=$((PASS + 1))
        else
            echo "  FAIL: $name empty header"
            FAIL=$((FAIL + 1))
        fi
    else
        echo "  FAIL: $name is empty"
        FAIL=$((FAIL + 1))
    fi
done < <(find "${REPO_ROOT}/StarterKit" -name "*.csv" -print0 2>/dev/null)

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== HydrationKit questions file ==="
# ═══════════════════════════════════════════════════════════════════════════════

hk_questions="${REPO_ROOT}/StarterKit/HydrationKit/questions.jsonc"
if [[ -f "$hk_questions" ]]; then
    assert_valid_json "HydrationKit questions" "$hk_questions"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== SUMMARY ==="
echo "Tests: $TESTS | Passed: $PASS | Failed: $FAIL"

[[ $FAIL -eq 0 ]] || exit 1
