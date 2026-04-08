#!/usr/bin/env bash
# tests/test_transforms.sh — Tests for WI-06 lib/transforms.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/epac.sh"
source "${SCRIPT_DIR}/../lib/transforms.sh"

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

assert_true() {
    local desc="$1" actual="$2"
    assert_eq "$desc" "true" "$actual"
}

assert_false() {
    local desc="$1" actual="$2"
    assert_eq "$desc" "false" "$actual"
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Module load check ==="
assert_eq "transforms loaded" "1" "${_EPAC_TRANSFORMS_LOADED}"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Function availability ==="
for fn in epac_effect_to_ordinal epac_ordinal_to_effect_display_name \
          epac_effect_to_csv_string epac_allowed_effects_to_csv_string \
          epac_effect_to_markdown_string epac_to_hashtable \
          epac_to_display_string epac_to_array epac_to_comparable_json \
          epac_flatten_for_csv epac_convert_policy_to_details \
          epac_convert_policy_set_to_details \
          epac_convert_policy_resources_to_details \
          epac_convert_details_to_flat_list \
          epac_convert_parameters_to_string; do
    assert_true "function $fn exists" "$(declare -F "$fn" &>/dev/null && echo true || echo false)"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_effect_to_ordinal ==="
assert_eq "Modify → 0" "0" "$(epac_effect_to_ordinal "Modify")"
assert_eq "modify → 0 (case)" "0" "$(epac_effect_to_ordinal "modify")"
assert_eq "Append → 1" "1" "$(epac_effect_to_ordinal "Append")"
assert_eq "DeployIfNotExists → 2" "2" "$(epac_effect_to_ordinal "DeployIfNotExists")"
assert_eq "DenyAction → 3" "3" "$(epac_effect_to_ordinal "DenyAction")"
assert_eq "Deny → 4" "4" "$(epac_effect_to_ordinal "Deny")"
assert_eq "Audit → 5" "5" "$(epac_effect_to_ordinal "Audit")"
assert_eq "Manual → 6" "6" "$(epac_effect_to_ordinal "Manual")"
assert_eq "AuditIfNotExists → 7" "7" "$(epac_effect_to_ordinal "AuditIfNotExists")"
assert_eq "Disabled → 8" "8" "$(epac_effect_to_ordinal "Disabled")"
assert_eq "Unknown → 98" "98" "$(epac_effect_to_ordinal "SomethingElse")"
assert_eq "Empty → 98" "98" "$(epac_effect_to_ordinal "")"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_ordinal_to_effect_display_name ==="
result="$(epac_ordinal_to_effect_display_name 0)"
display_name="$(echo "$result" | cut -f1)"
assert_eq "Ordinal 0 display" "Policy effects Modify, Append and DeployIfNotExists(DINE)" "$display_name"
result="$(epac_ordinal_to_effect_display_name 4)"
display_name="$(echo "$result" | cut -f1)"
assert_eq "Ordinal 4 display" "Policy effects Deny" "$display_name"
result="$(epac_ordinal_to_effect_display_name 8)"
display_name="$(echo "$result" | cut -f1)"
assert_eq "Ordinal 8 display" "Policy effects Disabled" "$display_name"
result="$(epac_ordinal_to_effect_display_name 99)"
display_name="$(echo "$result" | cut -f1)"
assert_eq "Ordinal 99 display" "Unknown" "$display_name"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_effect_to_csv_string ==="
assert_eq "Deny csv" "Deny" "$(epac_effect_to_csv_string "deny")"
assert_eq "Audit csv" "Audit" "$(epac_effect_to_csv_string "AUDIT")"
assert_eq "Modify csv" "Modify" "$(epac_effect_to_csv_string "modify")"
assert_eq "DeployIfNotExists csv" "DeployIfNotExists" "$(epac_effect_to_csv_string "deployifnotexists")"
assert_eq "Unknown csv" "Error" "$(epac_effect_to_csv_string "bogus")"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_effect_to_markdown_string ==="
result="$(epac_effect_to_markdown_string "Deny" '["Deny","Audit","Disabled"]')"
assert_eq "Markdown bold default" "**Deny**<br/>Audit<br/>Disabled" "$result"

result="$(epac_effect_to_markdown_string "Audit" '["Audit"]')"
assert_eq "Markdown single" "**Audit**" "$result"

result="$(epac_effect_to_markdown_string "" '[]')"
assert_eq "Markdown empty" "" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_to_hashtable ==="
assert_eq "Object passthrough" '{"a":1}' "$(epac_to_hashtable '{"a":1}' | jq -c '.')"
assert_eq "Null → {}" '{}' "$(epac_to_hashtable "null" | jq -c '.')"
assert_eq "Empty → {}" '{}' "$(epac_to_hashtable "" | jq -c '.')"
assert_eq "Array → {}" '{}' "$(epac_to_hashtable "[1,2]" | jq -c '.')"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_to_display_string ==="
assert_eq "Null display" '"null"' "$(epac_to_display_string "")"
assert_eq "JSON object display" '{"a":1}' "$(epac_to_display_string '{"a":1}')"
assert_eq "String display" '"hello"' "$(epac_to_display_string "hello")"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_to_array ==="
assert_eq "Array passthrough" '["a","b"]' "$(epac_to_array '["a","b"]' | jq -c '.')"
assert_eq "Wrap scalar" '[42]' "$(epac_to_array "42" | jq -c '.')"
assert_eq "Null with skip" '[]' "$(epac_to_array "null" "true")"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_to_comparable_json ==="
result="$(epac_to_comparable_json '{"b":2,"a":1}' true)"
assert_eq "Sorted keys compact" '{"a":1,"b":2}' "$result"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_flatten_for_csv ==="
input='[{"name":"test","tags":{"env":"prod"},"count":5}]'
result="$(epac_flatten_for_csv "$input")"
assert_json_eq "String kept" "$result" '.[0].name' 'test'
assert_json_eq "Number kept" "$result" '.[0].count' '5'
result_tags="$(echo "$result" | jq -r '.[0].tags')"
assert_eq "Object → JSON string" '{"env":"prod"}' "$result_tags"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_allowed_effects_to_csv_string ==="
result="$(epac_allowed_effects_to_csv_string "Deny" "true" '["Deny","Audit","Disabled"]' '[]' ',' ',')"
assert_eq "Parameterized allowed effects" "parameter,Deny,Audit,Disabled" "$result"

result="$(epac_allowed_effects_to_csv_string "Deny" "false" '[]' '["Deny","Audit","Disabled"]' ',' ',')"
assert_eq "Override allowed effects" "override,Deny,Audit,Disabled" "$result"

result="$(epac_allowed_effects_to_csv_string "Deny" "false" '[]' '[]' ',' ',')"
assert_eq "Default only effect" "default,Deny" "$result"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_convert_policy_to_details ==="

# Test 1: Fixed effect policy
fixed_policy='{
  "name": "deny-public-ip",
  "properties": {
    "displayName": "Deny Public IP",
    "description": "Denies creation of public IPs",
    "policyType": "Custom",
    "metadata": {"category": "Network", "version": "1.0.0"},
    "parameters": {},
    "policyRule": {
      "if": {"field": "type", "equals": "Microsoft.Network/publicIPAddresses"},
      "then": {"effect": "Deny"}
    }
  }
}'
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/deny-public-ip" "$fixed_policy")"
assert_json_eq "Fixed: displayName" "$result" '.displayName' 'Deny Public IP'
assert_json_eq "Fixed: effectValue" "$result" '.effectValue' 'Deny'
assert_json_eq "Fixed: effectDefault" "$result" '.effectDefault' 'Deny'
assert_json_eq "Fixed: effectReason" "$result" '.effectReason' 'Policy Fixed'
assert_json_eq "Fixed: category" "$result" '.category' 'Network'
assert_json_eq "Fixed: effectParameterName" "$result" '.effectParameterName' ''
assert_json_count "Fixed: effectAllowedValues length" "$result" '.effectAllowedValues' '1'

# Test 2: Parameterized effect policy
param_policy='{
  "name": "audit-sql-tde",
  "properties": {
    "displayName": "Audit SQL TDE",
    "description": "Audit transparent data encryption",
    "policyType": "BuiltIn",
    "metadata": {"category": "SQL", "version": "2.0.0"},
    "parameters": {
      "effect": {
        "type": "String",
        "defaultValue": "AuditIfNotExists",
        "allowedValues": ["AuditIfNotExists", "Disabled"]
      }
    },
    "policyRule": {
      "if": {"field": "type", "equals": "Microsoft.Sql/servers"},
      "then": {
        "effect": "[parameters('"'"'effect'"'"')]",
        "details": {
          "type": "Microsoft.Sql/servers/transparentDataEncryption",
          "existenceCondition": {"field": "status", "equals": "Enabled"}
        }
      }
    }
  }
}'
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/audit-sql-tde" "$param_policy")"
assert_json_eq "Param: effectValue" "$result" '.effectValue' 'AuditIfNotExists'
assert_json_eq "Param: effectDefault" "$result" '.effectDefault' 'AuditIfNotExists'
assert_json_eq "Param: effectReason" "$result" '.effectReason' 'Policy Default'
assert_json_eq "Param: effectParameterName" "$result" '.effectParameterName' 'effect'
assert_json_count "Param: effectAllowedValues" "$result" '.effectAllowedValues' '2'
assert_json_count "Param: effectAllowedOverrides" "$result" '.effectAllowedOverrides' '2'

# Test 3: Policy with no default value
nodefault_policy='{
  "name": "require-tag",
  "properties": {
    "displayName": "Require Tag",
    "description": "Requires a tag",
    "policyType": "Custom",
    "metadata": {"category": "Tags", "version": "1.0.0"},
    "parameters": {
      "effect": {
        "type": "String",
        "allowedValues": ["Deny", "Audit", "Disabled"]
      }
    },
    "policyRule": {
      "if": {"field": "tags", "exists": "false"},
      "then": {"effect": "[parameters('"'"'effect'"'"')]"}
    }
  }
}'
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/require-tag" "$nodefault_policy")"
assert_json_eq "NoDefault: effectReason" "$result" '.effectReason' 'Policy No Default'
assert_json_count "NoDefault: effectAllowedValues" "$result" '.effectAllowedValues' '3'

# Test 4: DINE policy anatomy detection
dine_policy='{
  "name": "deploy-diag",
  "properties": {
    "displayName": "Deploy Diagnostics",
    "description": "Deploy diagnostic settings",
    "policyType": "Custom",
    "metadata": {"category": "Monitoring", "version": "1.0.0"},
    "parameters": {},
    "policyRule": {
      "if": {"field": "type", "equals": "Microsoft.Compute/virtualMachines"},
      "then": {
        "effect": "DeployIfNotExists",
        "details": {
          "existenceCondition": {"field": "status", "equals": "Enabled"},
          "deployment": {"properties": {"mode": "incremental"}}
        }
      }
    }
  }
}'
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/deploy-diag" "$dine_policy")"
assert_json_eq "DINE: effectValue" "$result" '.effectValue' 'DeployIfNotExists'
assert_json_eq "DINE: effectReason" "$result" '.effectReason' 'Policy Fixed'
# DINE anatomy: existenceCondition + deployment → [Disabled, AuditIfNotExists, DeployIfNotExists]
override_count="$(echo "$result" | jq '.effectAllowedOverrides | length')"
assert_eq "DINE: override count = 3" "3" "$override_count"

# Test 5: DenyAction anatomy detection
denyaction_policy='{
  "name": "deny-action-delete",
  "properties": {
    "displayName": "Deny Action Delete",
    "description": "Deny delete action",
    "policyType": "Custom",
    "metadata": {"category": "General", "version": "1.0.0"},
    "parameters": {},
    "policyRule": {
      "if": {"field": "type", "equals": "Microsoft.Resources/subscriptions"},
      "then": {
        "effect": "DenyAction",
        "details": {
          "actionNames": ["delete"]
        }
      }
    }
  }
}'
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/deny-action-delete" "$denyaction_policy")"
assert_json_eq "DenyAction: override[0]" "$result" '.effectAllowedOverrides[0]' 'Disabled'
assert_json_eq "DenyAction: override[1]" "$result" '.effectAllowedOverrides[1]' 'DenyAction'

# Test 6: Manual anatomy detection
manual_policy='{
  "name": "manual-attestation",
  "properties": {
    "displayName": "Manual Attestation",
    "description": "Requires manual attestation",
    "policyType": "Custom",
    "metadata": {"category": "General", "version": "1.0.0"},
    "parameters": {},
    "policyRule": {
      "if": {"field": "type", "equals": "Microsoft.Resources/subscriptions"},
      "then": {
        "effect": "Manual",
        "details": {
          "defaultState": "Unknown"
        }
      }
    }
  }
}'
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/manual-attestation" "$manual_policy")"
assert_json_eq "Manual: override[0]" "$result" '.effectAllowedOverrides[0]' 'Disabled'
assert_json_eq "Manual: override[1]" "$result" '.effectAllowedOverrides[1]' 'Manual'

# Test 7: Modify anatomy detection
modify_policy='{
  "name": "modify-tags",
  "properties": {
    "displayName": "Modify Tags",
    "description": "Add tags",
    "policyType": "Custom",
    "metadata": {"category": "Tags", "version": "1.0.0"},
    "parameters": {},
    "policyRule": {
      "if": {"field": "type", "equals": "Microsoft.Network/networkSecurityGroups"},
      "then": {
        "effect": "Modify",
        "details": {
          "operations": [
            {"operation": "addOrReplace", "field": "tags.environment", "value": "dev"}
          ]
        }
      }
    }
  }
}'
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/modify-tags" "$modify_policy")"
assert_json_eq "Modify: override[0]" "$result" '.effectAllowedOverrides[0]' 'Disabled'
assert_json_eq "Modify: override[1]" "$result" '.effectAllowedOverrides[1]' 'Audit'
assert_json_eq "Modify: override[2]" "$result" '.effectAllowedOverrides[2]' 'Modify'

# Test 8: Deprecated policy detection
deprecated_policy='{
  "name": "deprecated-policy",
  "properties": {
    "displayName": "Old Policy",
    "description": "This is deprecated",
    "policyType": "BuiltIn",
    "metadata": {"category": "General", "version": "1.0.0-deprecated"},
    "parameters": {},
    "policyRule": {
      "if": {"field": "type", "equals": "Microsoft.Compute/virtualMachines"},
      "then": {"effect": "Audit"}
    }
  }
}'
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/deprecated" "$deprecated_policy")"
assert_json_eq "Deprecated: isDeprecated" "$result" '.isDeprecated' 'true'

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_convert_policy_set_to_details ==="

# Build policy details first
fixed_detail="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/deny-public-ip" "$fixed_policy")"
param_detail="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/audit-sql-tde" "$param_policy")"

policy_details="$(jq -n \
    --argjson fd "$fixed_detail" \
    --argjson pd "$param_detail" \
    '{"/providers/Microsoft.Authorization/policyDefinitions/deny-public-ip": $fd, "/providers/Microsoft.Authorization/policyDefinitions/audit-sql-tde": $pd}')"

# Test: Policy set with parameter pass-through
policy_set='{
  "name": "security-initiative",
  "properties": {
    "displayName": "Security Initiative",
    "description": "Security baseline",
    "policyType": "Custom",
    "metadata": {"category": "Security"},
    "parameters": {
      "sqlTdeEffect": {
        "type": "String",
        "defaultValue": "Disabled",
        "allowedValues": ["AuditIfNotExists", "Disabled"]
      }
    },
    "policyDefinitions": [
      {
        "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/deny-public-ip",
        "policyDefinitionReferenceId": "deny-pip-ref",
        "parameters": {},
        "groupNames": ["network-security"]
      },
      {
        "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/audit-sql-tde",
        "policyDefinitionReferenceId": "audit-tde-ref",
        "parameters": {
          "effect": {"value": "[parameters('"'"'sqlTdeEffect'"'"')]"}
        },
        "groupNames": ["data-security"]
      }
    ]
  }
}'

result="$(epac_convert_policy_set_to_details "/providers/Microsoft.Authorization/policySetDefinitions/security-initiative" "$policy_set" "$policy_details")"
assert_json_eq "PSSet: displayName" "$result" '.displayName' 'Security Initiative'
assert_json_eq "PSSet: category" "$result" '.category' 'Security'
assert_json_count "PSSet: policyDefinitions count" "$result" '.policyDefinitions' '2'

# First policy (fixed): effect should remain Policy Fixed
assert_json_eq "PSSet: fixed policy effectReason" "$result" '.policyDefinitions[0].effectReason' 'Policy Fixed'
assert_json_eq "PSSet: fixed policy effectValue" "$result" '.policyDefinitions[0].effectValue' 'Deny'

# Second policy (parameterized → policy set surfaced): effect should come from policy set
assert_json_eq "PSSet: param policy effectReason" "$result" '.policyDefinitions[1].effectReason' 'PolicySet Default'
assert_json_eq "PSSet: param policy effectValue" "$result" '.policyDefinitions[1].effectValue' 'Disabled'
assert_json_eq "PSSet: param policy effectDefault" "$result" '.policyDefinitions[1].effectDefault' 'Disabled'

# Group names
assert_json_eq "PSSet: policy 0 groupNames" "$result" '.policyDefinitions[0].groupNames[0]' 'network-security'
assert_json_eq "PSSet: policy 1 groupNames" "$result" '.policyDefinitions[1].groupNames[0]' 'data-security'

# Test: Policy set with hard-coded effect override
policy_set_fixed='{
  "name": "fixed-override-set",
  "properties": {
    "displayName": "Fixed Override Set",
    "description": "Overrides effect to a fixed value",
    "policyType": "Custom",
    "metadata": {"category": "General"},
    "parameters": {},
    "policyDefinitions": [
      {
        "policyDefinitionId": "/providers/Microsoft.Authorization/policyDefinitions/audit-sql-tde",
        "policyDefinitionReferenceId": "fixed-tde-ref",
        "parameters": {
          "effect": {"value": "AuditIfNotExists"}
        },
        "groupNames": []
      }
    ]
  }
}'
result="$(epac_convert_policy_set_to_details "/providers/Microsoft.Authorization/policySetDefinitions/fixed-override-set" "$policy_set_fixed" "$policy_details")"
assert_json_eq "PSSetFixed: effectReason" "$result" '.policyDefinitions[0].effectReason' 'PolicySet Fixed'
assert_json_eq "PSSetFixed: effectValue" "$result" '.policyDefinitions[0].effectValue' 'AuditIfNotExists'

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_convert_policy_resources_to_details ==="

# Small-scale test with two policies
all_policies="$(jq -n \
    --argjson fp "$fixed_policy" \
    --argjson pp "$param_policy" \
    '{"/providers/Microsoft.Authorization/policyDefinitions/deny-public-ip": $fp, "/providers/Microsoft.Authorization/policyDefinitions/audit-sql-tde": $pp}')"

all_policy_sets="$(jq -n \
    --argjson ps "$policy_set" \
    '{"/providers/Microsoft.Authorization/policySetDefinitions/security-initiative": $ps}')"

result="$(epac_convert_policy_resources_to_details "$all_policies" "$all_policy_sets" 2>/dev/null)"
assert_json_count "Resources: policies count" "$result" '.policies | keys' '2'
assert_json_count "Resources: policySets count" "$result" '.policySets | keys' '1'

# Verify individual policy details are correct
assert_json_eq "Resources: policy has details" "$result" '.policies["/providers/Microsoft.Authorization/policyDefinitions/deny-public-ip"].effectReason' 'Policy Fixed'
assert_json_eq "Resources: param policy details" "$result" '.policies["/providers/Microsoft.Authorization/policyDefinitions/audit-sql-tde"].effectReason' 'Policy Default'

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_convert_details_to_flat_list ==="

# Build a policy set detail first
ps_detail="$(epac_convert_policy_set_to_details "/providers/Microsoft.Authorization/policySetDefinitions/security-initiative" "$policy_set" "$policy_details")"
ps_details_obj="$(jq -n --argjson d "$ps_detail" '{"/providers/Microsoft.Authorization/policySetDefinitions/security-initiative": $d}')"

item_list='[{"shortName": "SecurityBaseline", "itemId": "/providers/Microsoft.Authorization/policySetDefinitions/security-initiative"}]'

result="$(epac_convert_details_to_flat_list "$item_list" "$ps_details_obj")"
key_count="$(echo "$result" | jq 'keys | length')"
assert_eq "FlatList: has entries" "true" "$( [[ $key_count -gt 0 ]] && echo true || echo false )"

# Check one of the flat entries
deny_key="/providers/Microsoft.Authorization/policyDefinitions/deny-public-ip"
has_deny="$(echo "$result" | jq --arg k "$deny_key" 'has($k)')"
assert_true "FlatList: has deny-public-ip entry" "$has_deny"

if [[ "$has_deny" == "true" ]]; then
    deny_effect="$(echo "$result" | jq -r --arg k "$deny_key" '.[$k].effectDefault')"
    assert_eq "FlatList: deny effectDefault" "Deny" "$deny_effect"
    deny_cat="$(echo "$result" | jq -r --arg k "$deny_key" '.[$k].category')"
    assert_eq "FlatList: deny category" "Network" "$deny_cat"
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_convert_parameters_to_string ==="

params='{"effect": {"isEffect": true, "multiUse": false, "value": "Audit", "defaultValue": "Audit", "definition": {"type": "String"}}, "location": {"isEffect": false, "multiUse": false, "value": "eastus", "defaultValue": "eastus", "definition": {"type": "String"}}}'

csv_val_result="$(epac_convert_parameters_to_string "$params" "csvValues")"
assert_eq "CSV Values: non-empty" "true" "$( [[ -n "$csv_val_result" ]] && echo true || echo false )"

csv_def_result="$(epac_convert_parameters_to_string "$params" "csvDefinitions")"
assert_eq "CSV Definitions: non-empty" "true" "$( [[ -n "$csv_def_result" ]] && echo true || echo false )"

empty_result="$(epac_convert_parameters_to_string "{}" "csvValues")"
assert_eq "Empty params → empty string" "" "$empty_result"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_convert_policy_to_details: parameter definitions ==="
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/audit-sql-tde" "$param_policy")"
has_effect_param="$(echo "$result" | jq '.parameters | has("effect")')"
assert_true "Param defs: has 'effect' key" "$has_effect_param"
is_effect_flag="$(echo "$result" | jq '.parameters.effect.isEffect')"
assert_true "Param defs: effect isEffect=true" "$is_effect_flag"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== epac_convert_policy_to_details: Append anatomy ==="
append_policy='{
  "name": "append-https",
  "properties": {
    "displayName": "Append HTTPS",
    "description": "Append HTTPS requirement",
    "policyType": "Custom",
    "metadata": {"category": "Network", "version": "1.0.0"},
    "parameters": {},
    "policyRule": {
      "if": {"field": "type", "equals": "Microsoft.Web/sites"},
      "then": {
        "effect": "Append",
        "details": [
          {"field": "Microsoft.Web/sites/httpsOnly", "value": true}
        ]
      }
    }
  }
}'
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/append-https" "$append_policy")"
assert_json_eq "Append: override[0]" "$result" '.effectAllowedOverrides[0]' 'Disabled'
assert_json_eq "Append: override[1]" "$result" '.effectAllowedOverrides[1]' 'Audit'
assert_json_eq "Append: override[2]" "$result" '.effectAllowedOverrides[2]' 'Deny'
assert_json_eq "Append: override[3]" "$result" '.effectAllowedOverrides[3]' 'Append'

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== AINE anatomy detection ==="
aine_policy='{
  "name": "aine-test",
  "properties": {
    "displayName": "AINE Test",
    "description": "Tests AuditIfNotExists detection",
    "policyType": "Custom",
    "metadata": {"category": "Security", "version": "1.0.0"},
    "parameters": {},
    "policyRule": {
      "if": {"field": "type", "equals": "Microsoft.Compute/virtualMachines"},
      "then": {
        "effect": "AuditIfNotExists",
        "details": {
          "type": "Microsoft.Security/assessments",
          "existenceCondition": {"field": "status.code", "in": ["Healthy"]}
        }
      }
    }
  }
}'
result="$(epac_convert_policy_to_details "/providers/Microsoft.Authorization/policyDefinitions/aine-test" "$aine_policy")"
assert_json_eq "AINE: override[0]" "$result" '.effectAllowedOverrides[0]' 'Disabled'
assert_json_eq "AINE: override[1]" "$result" '.effectAllowedOverrides[1]' 'AuditIfNotExists'
override_count="$(echo "$result" | jq '.effectAllowedOverrides | length')"
assert_eq "AINE: override count = 2" "2" "$override_count"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed (total: $((PASS + FAIL)))"
echo "════════════════════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]] || exit 1
