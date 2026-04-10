#!/usr/bin/env bash
# tests/test_documentation.sh — Functional tests for WI-14 documentation generation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/epac.sh"

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
        echo "    in: ${haystack:0:200}..."
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

assert_json_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if jq -e --argjson a "$expected" --argjson b "$actual" -n '$a == $b' >/dev/null 2>&1; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

line_count() {
    wc -l < "$1" | tr -d ' '
}

# ═══════════════════════════════════════════════════════════════════════════════
# Test data: Build a realistic flat policy list and policy set details
# ═══════════════════════════════════════════════════════════════════════════════

FLAT_POLICY_LIST='{
    "pol-1": {
        "id": "/providers/Microsoft.Authorization/policyDefinitions/pol-1",
        "name": "pol-1",
        "referencePath": "",
        "displayName": "Require HTTPS",
        "description": "Ensures HTTPS is required",
        "policyType": "BuiltIn",
        "category": "Security",
        "effectDefault": "Deny",
        "effectValue": "Deny",
        "ordinal": 4,
        "isEffectParameterized": false,
        "effectAllowedValues": {"Deny": "Deny", "Disabled": "Disabled"},
        "effectAllowedOverrides": [],
        "parameters": {},
        "policySetList": {
            "MCSB": {
                "shortName": "MCSB",
                "id": "/providers/Microsoft.Authorization/policySetDefinitions/mcsb-v2",
                "name": "mcsb-v2",
                "displayName": "MCSB v2",
                "description": "Microsoft Cloud Security Benchmark v2",
                "policyType": "BuiltIn",
                "effectParameterName": "",
                "effectDefault": "Deny",
                "effectValue": "Deny",
                "effectAllowedValues": ["Deny", "Disabled"],
                "effectAllowedOverrides": [],
                "effectReason": "Policy Fixed",
                "isEffectParameterized": false,
                "parameters": {},
                "groupNames": ["Network-Security"]
            }
        },
        "groupNames": {"Network-Security": "Network-Security"},
        "groupNamesList": ["Network-Security"],
        "policySetEffectStrings": ["MCSB: Deny (Policy Fixed)"]
    },
    "pol-2": {
        "id": "/providers/Microsoft.Authorization/policyDefinitions/pol-2",
        "name": "pol-2",
        "referencePath": "",
        "displayName": "Enable Logging",
        "description": "Deploys logging if not exists",
        "policyType": "BuiltIn",
        "category": "Monitoring",
        "effectDefault": "DeployIfNotExists",
        "effectValue": "DeployIfNotExists",
        "ordinal": 2,
        "isEffectParameterized": true,
        "effectAllowedValues": {"DeployIfNotExists": "DeployIfNotExists", "Disabled": "Disabled"},
        "effectAllowedOverrides": [],
        "parameters": {
            "logAnalyticsWorkspace": {
                "isEffect": false,
                "value": "/sub/ws/1",
                "defaultValue": "/sub/ws/1",
                "definition": {"type": "String"},
                "multiUse": false,
                "policySets": ["MCSB v2"]
            }
        },
        "policySetList": {
            "MCSB": {
                "shortName": "MCSB",
                "id": "/providers/Microsoft.Authorization/policySetDefinitions/mcsb-v2",
                "name": "mcsb-v2",
                "displayName": "MCSB v2",
                "description": "Microsoft Cloud Security Benchmark v2",
                "policyType": "BuiltIn",
                "effectParameterName": "effect",
                "effectDefault": "DeployIfNotExists",
                "effectValue": "DeployIfNotExists",
                "effectAllowedValues": ["DeployIfNotExists", "Disabled"],
                "effectAllowedOverrides": [],
                "effectReason": "PolicySet Default",
                "isEffectParameterized": true,
                "parameters": {
                    "logAnalyticsWorkspace": {
                        "isEffect": false,
                        "value": "/sub/ws/1",
                        "defaultValue": "/sub/ws/1",
                        "definition": {"type": "String"},
                        "multiUse": false,
                        "policySets": ["MCSB v2"]
                    }
                },
                "groupNames": ["Logging-Auditing"]
            }
        },
        "groupNames": {"Logging-Auditing": "Logging-Auditing"},
        "groupNamesList": ["Logging-Auditing"],
        "policySetEffectStrings": ["MCSB: DeployIfNotExists (default: effect)"]
    },
    "pol-3": {
        "id": "/providers/Microsoft.Authorization/policyDefinitions/pol-3",
        "name": "pol-3",
        "referencePath": "",
        "displayName": "Manual Compliance Check",
        "description": "Manual policy for compliance",
        "policyType": "BuiltIn",
        "category": "General",
        "effectDefault": "Manual",
        "effectValue": "Manual",
        "ordinal": 6,
        "isEffectParameterized": false,
        "effectAllowedValues": {"Manual": "Manual"},
        "effectAllowedOverrides": [],
        "parameters": {},
        "policySetList": {},
        "groupNames": {},
        "groupNamesList": [],
        "policySetEffectStrings": []
    }
}'

POLICY_SET_DETAILS='{
    "/providers/Microsoft.Authorization/policySetDefinitions/mcsb-v2": {
        "displayName": "MCSB v2",
        "description": "Microsoft Cloud Security Benchmark v2",
        "policyType": "BuiltIn",
        "category": "Security Center"
    }
}'

ITEM_LIST='[
    {"shortName": "MCSB", "itemId": "/providers/Microsoft.Authorization/policySetDefinitions/mcsb-v2", "policySetId": "/providers/Microsoft.Authorization/policySetDefinitions/mcsb-v2"}
]'

ENV_COLUMNS='["default"]'

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_out_documentation_for_policy_sets ==="

test_dir="$(mktemp -d)"

epac_out_documentation_for_policy_sets \
    --output-path "$test_dir" \
    --doc-spec '{"fileNameStem":"test-ps","title":"Test Policy Sets","markdownIncludeComplianceGroupNames":true}' \
    --item-list "$ITEM_LIST" \
    --env-columns-csv "$ENV_COLUMNS" \
    --policy-set-details "$POLICY_SET_DETAILS" \
    --flat-policy-list "$FLAT_POLICY_LIST" 2>/dev/null

# Check markdown
assert_file_exists "Markdown file created" "$test_dir/test-ps.md"

md_content="$(cat "$test_dir/test-ps.md")"
assert_contains "MD has title" "$md_content" "# Test Policy Sets"
assert_contains "MD has policy set list section" "$md_content" "Policy Set (Initiative) List"
assert_contains "MD has MCSB shortName" "$md_content" "## MCSB"
assert_contains "MD has display name" "$md_content" "MCSB v2"
assert_contains "MD has effects section" "$md_content" "Policy Effects"
assert_contains "MD has Require HTTPS" "$md_content" "**Require HTTPS**"
assert_contains "MD has Enable Logging" "$md_content" "**Enable Logging**"
assert_not_contains "MD excludes Manual by default" "$md_content" "Manual Compliance Check"
assert_contains "MD has compliance column" "$md_content" "Compliance"
assert_contains "MD has group name" "$md_content" "Network-Security"
assert_contains "MD has parameters section" "$md_content" "Policy Parameters by Policy"
assert_contains "MD has parameter value" "$md_content" "logAnalyticsWorkspace"

# Check CSV
assert_file_exists "CSV file created" "$test_dir/test-ps.csv"

csv_content="$(cat "$test_dir/test-ps.csv")"
assert_contains "CSV has header" "$csv_content" "name"
assert_contains "CSV has header effect col" "$csv_content" "defaultEffect"
assert_contains "CSV has pol-1" "$csv_content" "pol-1"
assert_contains "CSV has pol-2" "$csv_content" "pol-2"

# Check compliance CSV
assert_file_exists "Compliance CSV created" "$test_dir/test-ps-compliance.csv"

comp_csv="$(cat "$test_dir/test-ps-compliance.csv")"
assert_contains "Compliance CSV header" "$comp_csv" "groupName"
assert_contains "Compliance has group" "$comp_csv" "Network-Security"

# Check JSONC
assert_file_exists "JSONC file created" "$test_dir/test-ps.jsonc"

jsonc_content="$(cat "$test_dir/test-ps.jsonc")"
assert_contains "JSONC has parameters" "$jsonc_content" '"parameters"'
assert_contains "JSONC has MCSB comment" "$jsonc_content" "MCSB v2"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set docs: include manual ==="

test_dir="$(mktemp -d)"

epac_out_documentation_for_policy_sets \
    --output-path "$test_dir" \
    --doc-spec '{"fileNameStem":"test-manual","title":"With Manual"}' \
    --item-list "$ITEM_LIST" \
    --env-columns-csv "$ENV_COLUMNS" \
    --policy-set-details "$POLICY_SET_DETAILS" \
    --flat-policy-list "$FLAT_POLICY_LIST" \
    --include-manual 2>/dev/null

md_content="$(cat "$test_dir/test-manual.md")"
assert_contains "Manual policy included" "$md_content" "Manual Compliance Check"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set docs: ADO Wiki format ==="

test_dir="$(mktemp -d)"

epac_out_documentation_for_policy_sets \
    --output-path "$test_dir" \
    --doc-spec '{"fileNameStem":"test-ado","title":"ADO Test","markdownAdoWiki":true}' \
    --item-list "$ITEM_LIST" \
    --env-columns-csv "$ENV_COLUMNS" \
    --policy-set-details "$POLICY_SET_DETAILS" \
    --flat-policy-list "$FLAT_POLICY_LIST" 2>/dev/null

md_content="$(cat "$test_dir/test-ado.md")"
assert_contains "ADO Wiki has TOC" "$md_content" "[[_TOC_]]"
assert_not_contains "ADO no # title" "$md_content" "# ADO Test"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set docs: no HTML mode ==="

test_dir="$(mktemp -d)"

epac_out_documentation_for_policy_sets \
    --output-path "$test_dir" \
    --doc-spec '{"fileNameStem":"test-nohtml","title":"No HTML","markdownNoEmbeddedHtml":true}' \
    --item-list "$ITEM_LIST" \
    --env-columns-csv "$ENV_COLUMNS" \
    --policy-set-details "$POLICY_SET_DETAILS" \
    --flat-policy-list "$FLAT_POLICY_LIST" 2>/dev/null

md_content="$(cat "$test_dir/test-nohtml.md")"
assert_not_contains "No HTML: no <br/>" "$md_content" "<br/>"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set docs: suppress parameters ==="

test_dir="$(mktemp -d)"

epac_out_documentation_for_policy_sets \
    --output-path "$test_dir" \
    --doc-spec '{"fileNameStem":"test-noparam","title":"No Params","markdownSuppressParameterSection":true}' \
    --item-list "$ITEM_LIST" \
    --env-columns-csv "$ENV_COLUMNS" \
    --policy-set-details "$POLICY_SET_DETAILS" \
    --flat-policy-list "$FLAT_POLICY_LIST" 2>/dev/null

md_content="$(cat "$test_dir/test-noparam.md")"
assert_not_contains "Parameters suppressed" "$md_content" "Policy Parameters by Policy"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_out_documentation_for_assignments ==="

# Build assignments by environment
ASSIGNMENTS_BY_ENV='{
    "Production": {
        "flatPolicyList": {
            "pol-a": {
                "name": "audit-storage",
                "referencePath": "",
                "displayName": "Audit Storage",
                "description": "Audit storage accounts",
                "policyType": "BuiltIn",
                "category": "Storage",
                "effectDefault": "Audit",
                "effectValue": "Audit",
                "ordinal": 5,
                "isEffectParameterized": true,
                "effectAllowedValues": {"Audit": "Audit", "Disabled": "Disabled"},
                "effectAllowedOverrides": [],
                "parameters": {
                    "storageType": {
                        "isEffect": false,
                        "value": "BlobStorage",
                        "defaultValue": "BlobStorage",
                        "multiUse": false,
                        "policySets": ["Storage"]
                    }
                },
                "policySetList": {},
                "groupNames": {},
                "groupNamesList": [],
                "policySetEffectStrings": []
            }
        },
        "itemList": [{"shortName": "storage-audit", "assignmentId": "/sub/1/a/storage-audit", "itemId": "/sub/1/a/storage-audit"}],
        "assignmentsDetails": {
            "/sub/1/a/storage-audit": {
                "displayName": "Storage Audit Assignment",
                "policySetId": "/providers/Microsoft.Authorization/policySetDefinitions/storage-set",
                "policyType": "BuiltIn",
                "category": "Storage",
                "description": "Audits storage accounts",
                "assignment": {"properties": {"displayName": "Storage Audit Assignment"}}
            }
        },
        "scopes": ["/subscriptions/sub-1"]
    },
    "Development": {
        "flatPolicyList": {
            "pol-a": {
                "name": "audit-storage",
                "referencePath": "",
                "displayName": "Audit Storage",
                "description": "Audit storage accounts",
                "policyType": "BuiltIn",
                "category": "Storage",
                "effectDefault": "Audit",
                "effectValue": "Disabled",
                "ordinal": 8,
                "isEffectParameterized": true,
                "effectAllowedValues": {"Audit": "Audit", "Disabled": "Disabled"},
                "effectAllowedOverrides": [],
                "parameters": {},
                "policySetList": {},
                "groupNames": {},
                "groupNamesList": [],
                "policySetEffectStrings": []
            }
        },
        "itemList": [{"shortName": "storage-audit", "assignmentId": "/sub/2/a/storage-audit", "itemId": "/sub/2/a/storage-audit"}],
        "assignmentsDetails": {
            "/sub/2/a/storage-audit": {
                "displayName": "Storage Audit Assignment Dev",
                "policySetId": "/providers/Microsoft.Authorization/policySetDefinitions/storage-set",
                "policyType": "BuiltIn",
                "category": "Storage",
                "description": "Audits storage in dev",
                "assignment": {"properties": {"displayName": "Storage Audit Assignment Dev"}}
            }
        },
        "scopes": ["/subscriptions/sub-2"]
    }
}'

test_dir="$(mktemp -d)"
services_dir="${test_dir}/services"
mkdir -p "$services_dir"

epac_out_documentation_for_assignments \
    --output-path "$test_dir" \
    --output-path-services "$services_dir" \
    --doc-spec '{"fileNameStem":"test-assign","title":"Assignment Docs","environmentCategories":["Production","Development"]}' \
    --assignments-by-env "$ASSIGNMENTS_BY_ENV" 2>/dev/null

# Check markdown
assert_file_exists "Assignment MD created" "$test_dir/test-assign.md"

md_content="$(cat "$test_dir/test-assign.md")"
assert_contains "Assignment title" "$md_content" "# Assignment Docs"
assert_contains "Has Production env" "$md_content" "Environment Category \`Production\`"
assert_contains "Has Development env" "$md_content" "Environment Category \`Development\`"
assert_contains "Has scopes" "$md_content" "/subscriptions/sub-1"
assert_contains "Has assignment details" "$md_content" "Storage Audit Assignment"
assert_contains "Has policy effects table" "$md_content" "Policy Effects by Policy"
assert_contains "Has Audit Storage policy" "$md_content" "**Audit Storage**"
assert_contains "Has Production column" "$md_content" " Production |"
assert_contains "Has Development column" "$md_content" " Development |"
assert_contains "Has params section" "$md_content" "Policy Parameters by Policy"

# Check CSV
assert_file_exists "Assignment CSV created" "$test_dir/test-assign.csv"

csv_content="$(cat "$test_dir/test-assign.csv")"
assert_contains "CSV has Production effect col" "$csv_content" "ProductionEffect"
assert_contains "CSV has Development effect col" "$csv_content" "DevelopmentEffect"
assert_contains "CSV has audit-storage" "$csv_content" "audit-storage"

# Check per-category sub-pages
assert_file_exists "Storage sub-page" "$services_dir/Storage.md"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment docs: deduplication ==="

# Test that duplicate entries (same referencePath + displayName) get merged
DEDUP_FLAT='{
    "pol-x-env1": {
        "name": "custom-pol",
        "referencePath": "set1/ref1",
        "displayName": "Custom Policy",
        "description": "Test dedup",
        "policyType": "Custom",
        "category": "Custom",
        "effectDefault": "Audit",
        "effectValue": "Audit",
        "ordinal": 5,
        "isEffectParameterized": false,
        "effectAllowedValues": {},
        "effectAllowedOverrides": [],
        "parameters": {},
        "policySetList": {},
        "groupNames": [],
        "groupNamesList": [],
        "policySetEffectStrings": [],
        "isReferencePathMatch": false,
        "environmentList": {"Production": {"environmentCategory": "Production", "effectValue": "Audit", "parameters": {}}}
    },
    "pol-x-env2": {
        "name": "custom-pol",
        "referencePath": "set1/ref1",
        "displayName": "Custom Policy",
        "description": "Test dedup",
        "policyType": "Custom",
        "category": "Custom",
        "effectDefault": "Deny",
        "effectValue": "Deny",
        "ordinal": 4,
        "isEffectParameterized": false,
        "effectAllowedValues": {},
        "effectAllowedOverrides": [],
        "parameters": {},
        "policySetList": {},
        "groupNames": [],
        "groupNamesList": [],
        "policySetEffectStrings": [],
        "isReferencePathMatch": false,
        "environmentList": {"Development": {"environmentCategory": "Development", "effectValue": "Deny", "parameters": {}}}
    }
}'

result="$(_epac_deduplicate_flat_list "$DEDUP_FLAT")"
first_match="$(echo "$result" | jq -r '.["pol-x-env1"].isReferencePathMatch')"
second_match="$(echo "$result" | jq -r '.["pol-x-env2"].isReferencePathMatch')"
# One of them should be marked as a match
if [[ "$first_match" == "true" || "$second_match" == "true" ]]; then
    echo "  PASS: One entry marked as reference path match"
    PASS=$((PASS + 1)); TESTS=$((TESTS + 1))
else
    echo "  FAIL: No entry marked as duplicate"
    FAIL=$((FAIL + 1)); TESTS=$((TESTS + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy set CSV column structure ==="

test_dir="$(mktemp -d)"

# Multiple environment columns
epac_out_documentation_for_policy_sets \
    --output-path "$test_dir" \
    --doc-spec '{"fileNameStem":"test-multi-env","title":"Multi Env"}' \
    --item-list "$ITEM_LIST" \
    --env-columns-csv '["prod","dev"]' \
    --policy-set-details "$POLICY_SET_DETAILS" \
    --flat-policy-list "$FLAT_POLICY_LIST" 2>/dev/null

csv_content="$(cat "$test_dir/test-multi-env.csv")"
assert_contains "CSV has prodEffect" "$csv_content" "prodEffect"
assert_contains "CSV has devEffect" "$csv_content" "devEffect"
assert_contains "CSV has prodParameters" "$csv_content" "prodParameters"
assert_contains "CSV has devParameters" "$csv_content" "devParameters"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== JSONC parameters file structure ==="

test_dir="$(mktemp -d)"

epac_out_documentation_for_policy_sets \
    --output-path "$test_dir" \
    --doc-spec '{"fileNameStem":"test-jsonc","title":"JSONC Test"}' \
    --item-list "$ITEM_LIST" \
    --env-columns-csv "$ENV_COLUMNS" \
    --policy-set-details "$POLICY_SET_DETAILS" \
    --flat-policy-list "$FLAT_POLICY_LIST" 2>/dev/null

jsonc_content="$(cat "$test_dir/test-jsonc.jsonc")"
assert_contains "JSONC opens with brace" "$jsonc_content" "{"
assert_contains "JSONC has parameters key" "$jsonc_content" '"parameters"'
assert_contains "JSONC has category comment" "$jsonc_content" "Monitoring -- Enable Logging"
assert_contains "JSONC has divider line" "$jsonc_content" "---"
assert_contains "JSONC closes properly" "$jsonc_content" "}"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment docs: with TOC ==="

test_dir="$(mktemp -d)"
services_dir="${test_dir}/services"
mkdir -p "$services_dir"

epac_out_documentation_for_assignments \
    --output-path "$test_dir" \
    --output-path-services "$services_dir" \
    --doc-spec '{"fileNameStem":"test-toc","title":"TOC Test","environmentCategories":["Production"],"markdownAddToc":true}' \
    --assignments-by-env "$ASSIGNMENTS_BY_ENV" 2>/dev/null

md_content="$(cat "$test_dir/test-toc.md")"
assert_contains "Has TOC" "$md_content" "[[_TOC_]]"
assert_contains "Has # title" "$md_content" "# TOC Test"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Assignment docs: single env ==="

test_dir="$(mktemp -d)"
services_dir="${test_dir}/services"
mkdir -p "$services_dir"

epac_out_documentation_for_assignments \
    --output-path "$test_dir" \
    --output-path-services "$services_dir" \
    --doc-spec '{"fileNameStem":"test-single","title":"Single Env","environmentCategories":["Production"]}' \
    --assignments-by-env "$ASSIGNMENTS_BY_ENV" 2>/dev/null

md_content="$(cat "$test_dir/test-single.md")"
assert_contains "Has Production" "$md_content" "Production"
assert_not_contains "No Development column" "$md_content" " Development |"

csv_content="$(cat "$test_dir/test-single.csv")"
assert_contains "CSV has ProductionEffect" "$csv_content" "ProductionEffect"
assert_not_contains "CSV no DevelopmentEffect" "$csv_content" "DevelopmentEffect"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_generate_policy_set_csv standalone ==="

test_dir="$(mktemp -d)"

sorted_keys="$(echo "$FLAT_POLICY_LIST" | jq -r '
    [to_entries[] | {key: .key, cat: .value.category, dn: .value.displayName}]
    | sort_by(.cat, .dn) | .[].key
')"

_epac_generate_policy_set_csv "$test_dir" "standalone-csv" \
    "$FLAT_POLICY_LIST" '["env1"]' "$sorted_keys" "false" 2>/dev/null

assert_file_exists "Standalone CSV created" "$test_dir/standalone-csv.csv"
csv_content="$(cat "$test_dir/standalone-csv.csv")"
# Should have 3 lines: header + 2 policies (Manual excluded)
lc="$(line_count "$test_dir/standalone-csv.csv")"
assert_eq "CSV has 3 lines (header + 2 data rows)" "3" "$lc"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Compliance CSV standalone ==="

test_dir="$(mktemp -d)"

_epac_generate_compliance_csv "$test_dir" "comp-test" \
    "$FLAT_POLICY_LIST" "$sorted_keys" "false" 2>/dev/null

assert_file_exists "Compliance CSV standalone" "$test_dir/comp-test-compliance.csv"
comp_content="$(cat "$test_dir/comp-test-compliance.csv")"
assert_contains "Compliance has header" "$comp_content" "groupName"
assert_contains "Compliance has Network-Security" "$comp_content" "Network-Security"
assert_contains "Compliance has Logging-Auditing" "$comp_content" "Logging-Auditing"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "================================="
echo "Tests: $TESTS | Passed: $PASS | Failed: $FAIL"
echo "================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
