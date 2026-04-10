#!/usr/bin/env bash
# tests/test_exports.sh — Functional tests for WI-13 export operations
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
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
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

assert_false() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then
        echo "  FAIL: $desc (expected false)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

assert_json_eq() {
    local desc="$1" expected="$2" actual="$3"
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

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (doesn't contain '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (file not found: $path)"
        FAIL=$((FAIL + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_scrub_string ==="

result="$(epac_scrub_string "Hello World" "" 0)"
assert_eq "No changes with no options" "Hello World" "$result"

result="$(epac_scrub_string "  Hello  " "" 0 --trim)"
assert_eq "Trim whitespace" "Hello" "$result"

result="$(epac_scrub_string "Hello World" "" 0 --lower)"
assert_eq "Lower case" "hello world" "$result"

result="$(epac_scrub_string 'Hello:World[Test]' ':[]' 0)"
assert_eq "Remove invalid chars" "HelloWorldTest" "$result"

result="$(epac_scrub_string "Hello World" "" 5)"
assert_eq "Max length truncation" "Hello" "$result"

result="$(epac_scrub_string "Hello World" "" 0 --replace-spaces-with "-")"
assert_eq "Replace spaces with dash" "Hello-World" "$result"

result="$(epac_scrub_string "Hello  World" "" 0 --replace-spaces-with "-")"
assert_eq "Replace multiple spaces" "Hello--World" "$result"

result="$(epac_scrub_string '  My:Category  ' ':' 30 --trim --lower)"
assert_eq "Combined options" "mycategory" "$result"

result="$(epac_scrub_string 'Policy (Test) [v2]' '()[]' 0 --trim --lower --replace-spaces-with "-")"
assert_eq "Complex scrub" "policy-test-v2" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_get_definitions_full_path ==="

result="$(epac_get_definitions_full_path "/out/defs" "my-policy" "My Policy" ':[]' "jsonc" \
    --sub-folder "Security" --max-sub-folder 30 --max-filename 100)"
assert_eq "Basic path with subfolder" "/out/defs/Security/my-policy.jsonc" "$result"

result="$(epac_get_definitions_full_path "/out/defs" "my-policy" "My Policy" ':[]' "json")"
assert_eq "Path without subfolder" "/out/defs/my-policy.json" "$result"

result="$(epac_get_definitions_full_path "/out/defs" "abc" "Abc" ':[]' "jsonc" \
    --file-suffix "-policySet")"
assert_eq "Path with file suffix" "/out/defs/abc-policyset.jsonc" "$result"

# GUID name should use display name
result="$(epac_get_definitions_full_path "/out" "12345678-1234-1234-1234-123456789012" "My Display Name" ':[]' "jsonc" \
    --sub-folder "Cat")"
assert_contains "GUID replaced by display name" "$result" "my-display-name"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_remove_null_fields ==="

result="$(epac_remove_null_fields '{"a":1,"b":null,"c":"hello"}')"
assert_json_eq "Remove top-level nulls" '{"a":1,"c":"hello"}' "$result"

result="$(epac_remove_null_fields '{"a":{"b":null,"c":1}}')"
assert_json_eq "Remove nested nulls" '{"a":{"c":1}}' "$result"

result="$(epac_remove_null_fields '[{"a":null,"b":2},{"c":3}]')"
assert_json_eq "Remove nulls in array" '[{"b":2},{"c":3}]' "$result"

result="$(epac_remove_null_fields '{"a":1,"b":2}')"
assert_json_eq "No nulls unchanged" '{"a":1,"b":2}' "$result"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_remove_global_not_scopes ==="

result="$(epac_remove_global_not_scopes 'null' '[]')"
assert_eq "Null input returns null" "null" "$result"

result="$(epac_remove_global_not_scopes '[]' '[]')"
assert_eq "Empty array input returns null" "null" "$(echo "$result" | jq '.')"

result="$(epac_remove_global_not_scopes '["/sub/1","/sub/2"]' '[]')"
assert_json_eq "Empty global returns all" '["/sub/1","/sub/2"]' "$result"

result="$(epac_remove_global_not_scopes '["/sub/1","/sub/2","/sub/3"]' '["/sub/1","/sub/2"]')"
assert_json_eq "Filter exact matches" '["/sub/3"]' "$result"

result="$(epac_remove_global_not_scopes '["/sub/1"]' '["/sub/1"]')"
assert_eq "All filtered returns null" "null" "$(echo "$result" | jq '.')"

result="$(epac_remove_global_not_scopes '["/sub/1/child","/sub/2"]' '["/sub/1/*"]')"
assert_json_eq "Wildcard filter" '["/sub/2"]' "$result"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_new_export_node ==="

node_file="$(epac_new_export_node "tenant1" "parameters" '{"effect":"Audit"}')"
assert_file_exists "Creates temp file" "$node_file"
node_json="$(cat "$node_file")"
assert_json_eq "Simple property stored" '{"effect":"Audit"}' "$(echo "$node_json" | jq '.parameters')"
assert_json_eq "Empty children" '[]' "$(echo "$node_json" | jq '.children')"
rm -f "$node_file"

# scopes wrapped per-pacSelector
node_file="$(epac_new_export_node "prod" "scopes" "/providers/mg/root")"
node_json="$(cat "$node_file")"
assert_json_eq "Scopes wrapped" '{"prod":["/providers/mg/root"]}' "$(echo "$node_json" | jq '.scopes')"
rm -f "$node_file"

# notScopes wrapped per-pacSelector
node_file="$(epac_new_export_node "dev" "notScopes" '["/sub/excluded"]')"
node_json="$(cat "$node_file")"
assert_json_eq "notScopes wrapped" '{"dev":["/sub/excluded"]}' "$(echo "$node_json" | jq '.notScopes')"
rm -f "$node_file"

# identityEntry wrapped
node_file="$(epac_new_export_node "prod" "identityEntry" '{"userAssigned":null,"location":"eastus"}')"
node_json="$(cat "$node_file")"
assert_json_eq "identityEntry wrapped" '{"prod":{"userAssigned":null,"location":"eastus"}}' "$(echo "$node_json" | jq '.identityEntry')"
rm -f "$node_file"

# additionalRoleAssignments wrapped
node_file="$(epac_new_export_node "prod" "additionalRoleAssignments" '[{"roleDefinitionId":"abc","scope":"/sub/1"}]')"
node_json="$(cat "$node_file")"
expected='{"prod":[{"roleDefinitionId":"abc","scope":"/sub/1"}]}'
assert_json_eq "additionalRoleAssignments wrapped" "$expected" "$(echo "$node_json" | jq '.additionalRoleAssignments')"
rm -f "$node_file"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_merge_export_node_child ==="

# Setup parent
parent_file="$(mktemp)"
echo '{"children":[],"clusters":{}}' > "$parent_file"

# First child — new
child1="$(epac_merge_export_node_child "$parent_file" "tenant1" "enforcementMode" '"Default"')"
assert_file_exists "First child created" "$child1"
child1_json="$(cat "$child1")"
assert_eq "Child has property" '"Default"' "$(echo "$child1_json" | jq '.enforcementMode')"

# Second child same value — should match
child2="$(epac_merge_export_node_child "$parent_file" "tenant1" "enforcementMode" '"Default"')"
assert_eq "Matching child returned" "$child1" "$child2"

# Third child different value — new child
child3="$(epac_merge_export_node_child "$parent_file" "tenant1" "enforcementMode" '"DoNotEnforce"')"
if [[ "$child3" != "$child1" ]]; then
    echo "  PASS: Different value creates new child"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Different value should create new child"
    FAIL=$((FAIL + 1))
fi

parent_json="$(cat "$parent_file")"
assert_eq "Parent has 2 children" "2" "$(echo "$parent_json" | jq '.children | length')"

# Cleanup
rm -f "$child1" "$child3" "$parent_file"

# scopes merge behavior
parent_file="$(mktemp)"
echo '{"children":[],"clusters":{}}' > "$parent_file"

child_s1="$(epac_merge_export_node_child "$parent_file" "prod" "scopes" '"/mg/root"')"
child_s2="$(epac_merge_export_node_child "$parent_file" "dev" "scopes" '"/mg/dev"')"
assert_eq "Scopes always match (merge)" "$child_s1" "$child_s2"

child_json="$(cat "$child_s1")"
prod_scopes="$(echo "$child_json" | jq '.scopes.prod')"
dev_scopes="$(echo "$child_json" | jq '.scopes.dev')"
assert_json_eq "Prod scopes" '["/mg/root"]' "$prod_scopes"
assert_json_eq "Dev scopes" '["/mg/dev"]' "$dev_scopes"

rm -f "$child_s1" "$parent_file"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_set_export_node (tree building) ==="

parent_file="$(mktemp)"
echo '{"children":[],"clusters":{}}' > "$parent_file"

props='["enforcementMode","parameters","scopes"]'
prop_values='{"enforcementMode":"Default","parameters":{"effect":"Audit"},"scopes":"/mg/prod"}'

epac_set_export_node "$parent_file" "prod" "$props" "$prop_values" 0

parent_json="$(cat "$parent_file")"
child_count="$(echo "$parent_json" | jq '.children | length')"
assert_eq "Top level has 1 child" "1" "$child_count"

# Navigate tree: parent -> enforcementMode -> parameters -> scopes
c1_file="$(echo "$parent_json" | jq -r '.children[0]')"
c1_json="$(cat "$c1_file")"
assert_eq "First level: enforcementMode" '"Default"' "$(echo "$c1_json" | jq '.enforcementMode')"

c2_file="$(echo "$c1_json" | jq -r '.children[0]')"
c2_json="$(cat "$c2_file")"
assert_json_eq "Second level: parameters" '{"effect":"Audit"}' "$(echo "$c2_json" | jq '.parameters')"

c3_file="$(echo "$c2_json" | jq -r '.children[0]')"
c3_json="$(cat "$c3_file")"
assert_json_eq "Third level: scopes" '{"prod":["/mg/prod"]}' "$(echo "$c3_json" | jq '.scopes')"

# Add another assignment with same enforcement mode but different params
prop_values2='{"enforcementMode":"Default","parameters":{"effect":"Deny"},"scopes":"/mg/dev"}'
epac_set_export_node "$parent_file" "dev" "$props" "$prop_values2" 0

parent_json="$(cat "$parent_file")"
assert_eq "Still 1 top-level child (same enforcementMode)" "1" "$(echo "$parent_json" | jq '.children | length')"

c1_file="$(echo "$parent_json" | jq -r '.children[0]')"
c1_json="$(cat "$c1_file")"
assert_eq "enforcementMode child has 2 children (different params)" "2" "$(echo "$c1_json" | jq '.children | length')"

# Cleanup tree
epac_cleanup_export_nodes "$parent_file"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_export_assignment_node ==="

# Build a simple tree manually and export it
parent_file="$(mktemp)"
echo '{"children":[],"clusters":{}}' > "$parent_file"

props='["enforcementMode","scopes"]'
prop_values='{"enforcementMode":"DoNotEnforce","scopes":"/mg/prod"}'
epac_set_export_node "$parent_file" "prod" "$props" "$prop_values" 0

prop_values2='{"enforcementMode":"DoNotEnforce","scopes":"/mg/dev"}'
epac_set_export_node "$parent_file" "dev" "$props" "$prop_values2" 0

# Export from the first child (enforcementMode=DoNotEnforce node)
first_child="$(jq -r '.children[0]' "$parent_file")"
start_node='{"nodeName":"/root","definitionEntry":{"policyId":"test"}}'
result="$(epac_export_assignment_node "$first_child" "$start_node" "$props")"

assert_eq "Has enforcementMode" '"DoNotEnforce"' "$(echo "$result" | jq '.enforcementMode')"
# Should have scope with both prod and dev
assert_json_eq "Scope has prod" '["/mg/prod"]' "$(echo "$result" | jq '.scope.prod')"
assert_json_eq "Scope has dev" '["/mg/dev"]' "$(echo "$result" | jq '.scope.dev')"

epac_cleanup_export_nodes "$parent_file"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== _epac_add_assignment_property ==="

node='{"nodeName":"/root","definitionEntry":{"policyId":"test"}}'

# parameters
result="$(_epac_add_assignment_property "$node" "parameters" '{"effect":"Audit"}')"
assert_json_eq "Add parameters" '{"effect":"Audit"}' "$(echo "$result" | jq '.parameters')"

# enforcementMode (skip Default)
result="$(_epac_add_assignment_property "$node" "enforcementMode" '"Default"')"
has_em="$(echo "$result" | jq 'has("enforcementMode")')"
assert_eq "Skip Default enforcementMode" "false" "$has_em"

result="$(_epac_add_assignment_property "$node" "enforcementMode" '"DoNotEnforce"')"
assert_eq "Add DoNotEnforce" '"DoNotEnforce"' "$(echo "$result" | jq '.enforcementMode')"

# assignmentNameEx
result="$(_epac_add_assignment_property "$node" "assignmentNameEx" '{"name":"a1","displayName":"Assign 1","description":"desc"}')"
assert_eq "Assignment name" '"a1"' "$(echo "$result" | jq '.assignment.name')"
assert_eq "Assignment displayName" '"Assign 1"' "$(echo "$result" | jq '.assignment.displayName')"

# nonComplianceMessages at root
result="$(_epac_add_assignment_property "$node" "nonComplianceMessages" '[{"message":"Not compliant"}]')"
ncm="$(echo "$result" | jq '.definitionEntry.nonComplianceMessages')"
assert_json_eq "NCM on root goes to definitionEntry" '[{"message":"Not compliant"}]' "$ncm"

# nonComplianceMessages at non-root
child_node='{"nodeName":"/child-0"}'
result="$(_epac_add_assignment_property "$child_node" "nonComplianceMessages" '[{"message":"bad"}]')"
ncm="$(echo "$result" | jq '.nonComplianceMessages')"
assert_json_eq "NCM on child stays on node" '[{"message":"bad"}]' "$ncm"

# scopes
result="$(_epac_add_assignment_property "$node" "scopes" '{"prod":["/mg/root"]}')"
assert_json_eq "Scopes → scope" '{"prod":["/mg/root"]}' "$(echo "$result" | jq '.scope')"

# notScopes
result="$(_epac_add_assignment_property "$node" "notScopes" '{"prod":["/sub/excl"]}')"
assert_json_eq "notScopes property" '{"prod":["/sub/excl"]}' "$(echo "$result" | jq '.notScopes')"

# identityEntry
result="$(_epac_add_assignment_property "$node" "identityEntry" '{"prod":{"userAssigned":"/id/mi1","location":"eastus"}}')"
assert_eq "ManagedIdentityLocations" '"eastus"' "$(echo "$result" | jq '.managedIdentityLocations.prod')"
assert_eq "UserAssignedIdentity" '"/id/mi1"' "$(echo "$result" | jq '.userAssignedIdentity.prod')"

# definitionVersion
result="$(_epac_add_assignment_property "$node" "definitionVersion" '"1.0.0"')"
assert_eq "Definition version" '"1.0.0"' "$(echo "$result" | jq '.definitionVersion')"

# null values skipped
result="$(_epac_add_assignment_property "$node" "overrides" 'null')"
assert_eq "Null overrides skipped" "false" "$(echo "$result" | jq 'has("overrides")')"

result="$(_epac_add_assignment_property "$node" "resourceSelectors" 'null')"
assert_eq "Null resourceSelectors skipped" "false" "$(echo "$result" | jq 'has("resourceSelectors")')"

# empty parameters skipped
result="$(_epac_add_assignment_property "$node" "parameters" '{}')"
assert_eq "Empty parameters skipped" "false" "$(echo "$result" | jq 'has("parameters")')"

# empty metadata skipped
result="$(_epac_add_assignment_property "$node" "metadata" '{}')"
assert_eq "Empty metadata skipped" "false" "$(echo "$result" | jq 'has("metadata")')"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_out_policy_definition ==="

test_dir="$(mktemp -d)"
props_file="$(mktemp)"
echo '{}' > "$props_file"

def_json='{"name":"test-policy","properties":{"displayName":"Test Policy","description":"A test","metadata":{"category":"Security"},"parameters":{},"policyRule":{"if":{"field":"type","equals":"test"},"then":{"effect":"deny"}}}}'

epac_out_policy_definition "$def_json" "${test_dir}/policyDefinitions" "$props_file" ':[]' "test-id" "jsonc"

assert_file_exists "Definition file created" "${test_dir}/policyDefinitions/Security/test-policy.jsonc"

file_content="$(cat "${test_dir}/policyDefinitions/Security/test-policy.jsonc")"
schema="$(echo "$file_content" | jq -r '."$schema"')"
assert_contains "Has policy-definition schema" "$schema" "policy-definition-schema.json"

name="$(echo "$file_content" | jq -r '.name')"
assert_eq "Name preserved" "test-policy" "$name"

# Policy set definition uses different schema
psd_json='{"name":"test-set","properties":{"displayName":"Test Set","metadata":{"category":"Compliance"},"policyDefinitions":[{"id":"x"}]}}'
epac_out_policy_definition "$psd_json" "${test_dir}/policySetDefinitions" "$props_file" ':[]' "set-id" "jsonc"

assert_file_exists "PolicySet file created" "${test_dir}/policySetDefinitions/Compliance/test-set.jsonc"
set_content="$(cat "${test_dir}/policySetDefinitions/Compliance/test-set.jsonc")"
set_schema="$(echo "$set_content" | jq -r '."$schema"')"
assert_contains "Has policy-set-definition schema" "$set_schema" "policy-set-definition-schema.json"

# Duplicates quietly ignored
epac_out_policy_definition "$def_json" "${test_dir}/policyDefinitions" "$props_file" ':[]' "test-id-2" "jsonc"
props_seen="$(cat "$props_file")"
assert_eq "Properties tracked" "true" "$(echo "$props_seen" | jq 'has("test-policy")')"

rm -rf "$test_dir" "$props_file"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_out_policy_assignment_file ==="

test_dir="$(mktemp -d)"

# Build a simple per-definition tree
per_def_file="$(mktemp)"
jq -n '{
    children: [],
    clusters: {},
    definitionEntry: {
        definitionKey: "test-def",
        id: "/providers/Microsoft.Authorization/policyDefinitions/test-def",
        name: "test-def",
        displayName: "Test Definition",
        scope: "",
        scopeType: "builtin",
        kind: "policyDefinitions",
        isBuiltin: true
    },
    enforcementMode: "Default",
    scopes: {"prod": ["/mg/root"]},
    assignmentNameEx: {"name": "test-assign", "displayName": "Test Assign", "description": "desc"}
}' > "$per_def_file"

props='["enforcementMode","scopes","assignmentNameEx"]'
epac_out_policy_assignment_file "$per_def_file" "$props" "${test_dir}/assignments" ':[]' "jsonc"

# Find the created file
created_file="$(find "$test_dir" -name "*.jsonc" -type f | head -1)"
if [[ -n "$created_file" ]]; then
    echo "  PASS: Assignment file created"
    PASS=$((PASS + 1))
    
    content="$(cat "$created_file")"
    assert_eq "Has /root nodeName" '"/root"' "$(echo "$content" | jq '.nodeName')"
    assert_contains "Has assignment schema" "$(echo "$content" | jq -r '."$schema"')" "policy-assignment-schema.json"
    assert_eq "Has policyId for builtin" '"/providers/Microsoft.Authorization/policyDefinitions/test-def"' \
        "$(echo "$content" | jq '.definitionEntry.policyId')"
else
    echo "  FAIL: Assignment file not created"
    FAIL=$((FAIL + 1))
fi

rm -rf "$test_dir" "$per_def_file"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_write_ownership_csv ==="

test_dir="$(mktemp -d)"
csv_path="${test_dir}/ownership.csv"

rows='[
    {"pacSelector":"prod","kind":"PolicyDefinition","owner":"thisPaC","principalId":"user1","lastChange":"2024-01-01T00:00:00","category":"Security","displayName":"Test Policy","id":"/pol/1"},
    {"pacSelector":"dev","kind":"Assignment(Policy-Builtin)","owner":"otherPaC","principalId":"user2","lastChange":"n/a","category":"","displayName":"Test Assignment","id":"/assign/1"}
]'

epac_write_ownership_csv "$rows" "$csv_path"
assert_file_exists "CSV file created" "$csv_path"

line_count="$(wc -l < "$csv_path")"
assert_eq "CSV has 3 lines (header + 2 rows)" "3" "$line_count"

header="$(head -1 "$csv_path")"
assert_eq "CSV header correct" "pacSelector,kind,owner,principalId,lastChange,category,displayName,id" "$header"

assert_contains "First row has prod" "$(sed -n '2p' "$csv_path")" "prod"
assert_contains "Second row has dev" "$(sed -n '3p' "$csv_path")" "dev"

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_out_policy_exemptions (JSON) ==="

test_dir="$(mktemp -d)"
pac_env='{"pacSelector":"prod"}'

exemptions='[
    {"name":"ex1","displayName":"Exemption 1","description":"Test","exemptionCategory":"Waiver","expiresOn":"2025-12-31","status":"active","scope":"/sub/1","policyAssignmentId":"/assign/1","metadata":{"deployedBy":"EPAC","epacMetadata":{"source":"test"}}},
    {"name":"ex2","displayName":"Exemption 2","description":"Expired","exemptionCategory":"Mitigated","expiresOn":"2023-01-01","status":"expired","scope":"/sub/2","policyAssignmentId":"/assign/2","metadata":{}}
]'

epac_out_policy_exemptions "$exemptions" "$pac_env" "$test_dir" --json --file-extension jsonc --active-only

json_file="${test_dir}/prod/active-exemptions.jsonc"
assert_file_exists "Active exemptions JSON created" "$json_file"

if [[ -f "$json_file" ]]; then
    content="$(cat "$json_file")"
    ex_count="$(echo "$content" | jq '.exemptions | length')"
    assert_eq "Only active exemptions" "1" "$ex_count"
    assert_eq "Active exemption name" '"ex1"' "$(echo "$content" | jq '.exemptions[0].name')"
    assert_contains "Has exemption schema" "$(echo "$content" | jq -r '."$schema"')" "policy-exemption-schema.json"
fi

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_out_policy_exemptions (CSV) ==="

test_dir="$(mktemp -d)"
pac_env='{"pacSelector":"dev"}'

exemptions='[
    {"name":"ex1","displayName":"Ex 1","description":"Test","exemptionCategory":"Waiver","expiresOn":"2025-12-31","status":"active","scope":"/sub/1","policyAssignmentId":"/assign/1","metadata":{}},
    {"name":"ex2","displayName":"Ex 2","description":"","exemptionCategory":"Mitigated","expiresOn":"2024-06-15","status":"active-expiring-within-15-days","scope":"/sub/2","policyAssignmentId":"/assign/2","metadata":{}}
]'

epac_out_policy_exemptions "$exemptions" "$pac_env" "$test_dir" --csv --file-extension json --active-only

csv_file="${test_dir}/dev/active-exemptions.csv"
assert_file_exists "Active exemptions CSV created" "$csv_file"

if [[ -f "$csv_file" ]]; then
    line_count="$(wc -l < "$csv_file")"
    assert_eq "CSV has 3 lines" "3" "$line_count"
    assert_contains "Header has name" "$(head -1 "$csv_file")" "name"
fi

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_out_policy_exemptions (all exemptions) ==="

test_dir="$(mktemp -d)"
pac_env='{"pacSelector":"all"}'

exemptions='[
    {"name":"ex1","displayName":"Ex 1","description":"","exemptionCategory":"Waiver","expiresOn":"2025-12-31","status":"active","expiresInDays":365,"scope":"/sub/1","policyAssignmentId":"/a/1","metadata":{}},
    {"name":"ex2","displayName":"Ex 2","description":"","exemptionCategory":"Mitigated","expiresOn":"2023-01-01","status":"expired","expiresInDays":2147483647,"scope":"/sub/2","policyAssignmentId":"/a/2","metadata":{}}
]'

epac_out_policy_exemptions "$exemptions" "$pac_env" "$test_dir" --json --file-extension jsonc

json_file="${test_dir}/all/all-exemptions.jsonc"
assert_file_exists "All exemptions JSON created" "$json_file"

if [[ -f "$json_file" ]]; then
    content="$(cat "$json_file")"
    ex_count="$(echo "$content" | jq '.exemptions | length')"
    assert_eq "All exemptions included" "2" "$ex_count"
    # Check expiresInDays=max → "n/a"
    expires_str="$(echo "$content" | jq -r '.exemptions[1].expiresInDays')"
    assert_eq "Max expires becomes n/a" "n/a" "$expires_str"
fi

rm -rf "$test_dir"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Tree building integration test ==="

# Build a tree with 2 assignments under same definition but different pacSelectors
parent_file="$(mktemp)"
echo '{"children":[],"clusters":{}}' > "$parent_file"

props='["assignmentNameEx","parameters","enforcementMode","scopes"]'

# Assignment 1: prod
p1='{"assignmentNameEx":{"name":"a1","displayName":"Assign 1","description":"d1"},"parameters":{"effect":"Audit"},"enforcementMode":"Default","scopes":"/mg/prod"}'
epac_set_export_node "$parent_file" "prod" "$props" "$p1" 0

# Assignment 2: dev, same everything except scope
p2='{"assignmentNameEx":{"name":"a1","displayName":"Assign 1","description":"d1"},"parameters":{"effect":"Audit"},"enforcementMode":"Default","scopes":"/mg/dev"}'
epac_set_export_node "$parent_file" "dev" "$props" "$p2" 0

# They should collapse into same nodes since all properties match
parent_json="$(cat "$parent_file")"
assert_eq "Integration: 1 top child (same assignmentNameEx)" "1" "$(echo "$parent_json" | jq '.children | length')"

# Navigate down 3 levels to scopes
c1="$(jq -r '.children[0]' "$parent_file")"
c2="$(jq -r '.children[0]' "$c1")"
c3="$(jq -r '.children[0]' "$c2")"
c4="$(jq -r '.children[0]' "$c3")"

scopes_json="$(jq '.scopes' "$c4")"
assert_json_eq "Integration: prod scope" '["/mg/prod"]' "$(echo "$scopes_json" | jq '.prod')"
assert_json_eq "Integration: dev scope" '["/mg/dev"]' "$(echo "$scopes_json" | jq '.dev')"

# Now export the tree
start='{"nodeName":"/root","definitionEntry":{"policyName":"test"}}'
first_child="$(jq -r '.children[0]' "$parent_file")"
result="$(epac_export_assignment_node "$first_child" "$start" "$props")"

# assignment should be present
assert_eq "Export: assignment name" '"a1"' "$(echo "$result" | jq '.assignment.name')"
assert_eq "Export: assignment displayName" '"Assign 1"' "$(echo "$result" | jq '.assignment.displayName')"
assert_json_eq "Export: parameters" '{"effect":"Audit"}' "$(echo "$result" | jq '.parameters')"
# enforcementMode=Default should be omitted
assert_eq "Export: Default enforcementMode skipped" "false" "$(echo "$result" | jq 'has("enforcementMode")')"
# scope
assert_json_eq "Export: prod scope" '["/mg/prod"]' "$(echo "$result" | jq '.scope.prod')"
assert_json_eq "Export: dev scope" '["/mg/dev"]' "$(echo "$result" | jq '.scope.dev')"

epac_cleanup_export_nodes "$parent_file"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Multi-child tree test ==="

parent_file="$(mktemp)"
echo '{"children":[],"clusters":{}}' > "$parent_file"

props='["enforcementMode","parameters","scopes"]'

# Two assignments with different enforcement modes
p1='{"enforcementMode":"Default","parameters":{"effect":"Audit"},"scopes":"/mg/prod"}'
p2='{"enforcementMode":"DoNotEnforce","parameters":{"effect":"Deny"},"scopes":"/mg/dev"}'

epac_set_export_node "$parent_file" "prod" "$props" "$p1" 0
epac_set_export_node "$parent_file" "dev" "$props" "$p2" 0

parent_json="$(cat "$parent_file")"
assert_eq "Multi: 2 top children (different enforcementMode)" "2" "$(echo "$parent_json" | jq '.children | length')"

# Export 
start='{"nodeName":"/root","definitionEntry":{"policyName":"multi-test"}}'
result="$(epac_export_assignment_node "$parent_file" "$start" "$props")"

# Should have children array since there are 2 branches
has_children="$(echo "$result" | jq 'has("children")')"
assert_eq "Multi: has children array" "true" "$has_children"
child_count="$(echo "$result" | jq '.children | length')"
assert_eq "Multi: 2 children in output" "2" "$child_count"

epac_cleanup_export_nodes "$parent_file"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== epac_cleanup_export_nodes ==="

parent_file="$(mktemp)"
echo '{"children":[],"clusters":{}}' > "$parent_file"

props='["enforcementMode","scopes"]'
p1='{"enforcementMode":"Default","scopes":"/mg/prod"}'
epac_set_export_node "$parent_file" "prod" "$props" "$p1" 0

# Verify files exist
c1="$(jq -r '.children[0]' "$parent_file")"
c2="$(jq -r '.children[0]' "$c1")"
assert_file_exists "Pre-cleanup: child1 exists" "$c1"
assert_file_exists "Pre-cleanup: child2 exists" "$c2"

# Cleanup
epac_cleanup_export_nodes "$parent_file"

if [[ ! -f "$parent_file" && ! -f "$c1" && ! -f "$c2" ]]; then
    echo "  PASS: All temp files cleaned up"
    PASS=$((PASS + 1))
else
    echo "  FAIL: Some temp files remain"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "================================="
echo "Tests: $((PASS + FAIL)) | Passed: $PASS | Failed: $FAIL"
echo "================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
