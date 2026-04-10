#!/usr/bin/env bash
# scripts/operations/export-policy-to-epac.sh — Convert policies from Azure Portal or ALZ to EPAC format
# Replaces: Scripts/Operations/Export-PolicyToEPAC.ps1
#
# Usage: ./scripts/operations/export-policy-to-epac.sh [options]
#   --policy-definition-id <id>         Azure policy definition ID
#   --policy-set-definition-id <id>     Azure policy set definition ID
#   --alz-policy-definition-id <id>     ALZ policy definition name
#   --alz-policy-set-definition-id <id> ALZ policy set definition name
#   --output-folder <path>              Output folder (default: Output)
#   --auto-create-parameters             Auto-create assignment parameters (default: true)
#   --no-auto-create-parameters          Disable auto-creating parameters
#   --use-builtin                        Use builtin references (default: true)
#   --no-use-builtin                     Use local definitions
#   --pac-selector <name>                PacSelector from global-settings
#   --overwrite-scope <scope>            Override scope in assignment
#   --overwrite-pac-selector <name>      Override PacSelector in assignment
#   --no-overwrite-output                Don't overwrite existing output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/epac.sh
source "${SCRIPT_DIR}/../../lib/epac.sh"

# ═════════════════════════════════════════════════════════════════════════════
# Internal helpers
# ═════════════════════════════════════════════════════════════════════════════

# Remove EPAC-internal metadata fields from a policy object
_clean_metadata() {
    local json="$1"
    echo "$json" | jq 'del(.pacOwnerId, .deployedBy, .createdBy, .createdOn, .updatedBy, .updatedOn)'
}

# Write a policy definition JSON file
_write_definition() {
    local name="$1" json="$2" folder="$3" schema="$4"
    mkdir -p "$folder"
    local out
    out="$(jq -n --arg s "$schema" --argjson d "$json" '{"\$schema": $s} + $d')"
    echo "$out" | jq '.' > "${folder}/${name}.jsonc"
    echo "Created definition: ${name}.jsonc" >&2
}

# Fetch ALZ policies.json from GitHub and extract policy definitions
_fetch_alz_policies() {
    local github_headers=(-H "Accept: application/vnd.github.v3+json" -H "X-GitHub-Api-Version: 2022-11-28")
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        github_headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi

    local tag
    tag="$(curl -sS "${github_headers[@]}" \
        "https://api.github.com/repos/Azure/Enterprise-Scale/releases/latest" | jq -r '.tag_name')"

    local policy_url="https://raw.githubusercontent.com/Azure/Enterprise-Scale/${tag}/eslzArm/managementGroupTemplates/policyDefinitions/policies.json"
    local raw_content
    raw_content="$(curl -sS "${github_headers[@]}" "$policy_url")"

    # Extract policy definitions from ARM template variables (fxv* keys containing policyDefinitions)
    echo "$raw_content" | jq '
        [.variables | to_entries[] |
            select(.key | startswith("fxv")) |
            .value | fromjson |
            select(.Type == "Microsoft.Authorization/policyDefinitions") |
            select(.Properties.metadata.alzCloudEnvironments // [] | index("AzureCloud")) |
            {key: .Name, value: .Properties}
        ] | from_entries
    '
}

# Fetch ALZ initiatives.json
_fetch_alz_policy_sets() {
    local github_headers=(-H "Accept: application/vnd.github.v3+json" -H "X-GitHub-Api-Version: 2022-11-28")
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
        github_headers+=(-H "Authorization: Bearer $GITHUB_TOKEN")
    fi

    local tag
    tag="$(curl -sS "${github_headers[@]}" \
        "https://api.github.com/repos/Azure/Enterprise-Scale/releases/latest" | jq -r '.tag_name')"

    local set_url="https://raw.githubusercontent.com/Azure/Enterprise-Scale/${tag}/eslzArm/managementGroupTemplates/policyDefinitions/initiatives.json"
    local raw_content
    raw_content="$(curl -sS "${github_headers[@]}" "$set_url")"

    echo "$raw_content" | jq '
        [.variables | to_entries[] |
            select(.key | startswith("fxv")) |
            .value | fromjson |
            select(.Type | test("Microsoft.Authorization/policySetDefinitions")) |
            select(.Properties.metadata.alzCloudEnvironments // [] | index("AzureCloud")) |
            {key: .Name, value: .Properties}
        ] | from_entries
    '
}

# Build policy set definition array for EPAC format
_build_policy_set_defs_array() {
    local policy_defs_json="$1"  # JSON array of policyDefinition entries
    echo "$policy_defs_json" | jq '[
        .[] |
        {
            policyDefinitionReferenceId: (.policyDefinitionReferenceId // ""),
            policyDefinitionId: (.policyDefinitionId // .PolicyDefinitionId // ""),
            parameters: (.parameters // {})
        }
        + (if (.definitionVersion // "") != "" then {definitionVersion} else {} end)
        + (if (.groupNames // "" | type) == "array" and (.groupNames | length) > 0 then {groupNames} else {} end)
    ]'
}

# Create assignment file
_create_assignment() {
    local policy_name="$1" policy_type="$2" policy_display="$3" policy_desc="$4"
    local builtin_type="$5" policy_obj="$6"

    local def_entry='{}'
    if [[ "$policy_type" == "policyDefinitions" ]]; then
        if $_use_builtin && [[ "$builtin_type" == "BuiltIn" ]]; then
            def_entry="$(jq -n --arg id "/providers/Microsoft.Authorization/policyDefinitions/$policy_name" \
                '{policyId: $id}')"
        else
            def_entry="$(jq -n --arg n "$policy_name" '{policyName: $n}')"
        fi
    else
        if $_use_builtin && [[ "$builtin_type" == "BuiltIn" ]]; then
            def_entry="$(jq -n --arg id "/providers/Microsoft.Authorization/policySetDefinitions/$policy_name" \
                '{policySetId: $id}')"
        else
            def_entry="$(jq -n --arg n "$policy_name" '{policySetName: $n}')"
        fi
    fi

    local guid_suffix
    guid_suffix="$(epac_new_guid | cut -d'-' -f5)"

    # Build parameters from either policy_obj or az query
    local params='{}'
    if $_auto_create_parameters; then
        local param_source
        if $_use_builtin; then
            # Get parameters from Azure directly or from the policy object
            param_source="$(echo "$policy_obj" | jq '.properties.parameters // .parameters // {}')"
        else
            param_source="$(echo "$policy_obj" | jq '.properties.parameters // .parameters // {}')"
        fi
        params="$(echo "$param_source" | jq '
            [to_entries[] | {key: .key, value: (.value.defaultValue // "")}] | from_entries
        ')"
    fi

    # Determine scope
    local scope_selector="EPAC-Dev"
    local scope_value="/providers/Microsoft.Management/managementGroups/EPAC-Dev"

    if [[ -n "$_pac_selector" ]]; then
        scope_selector="$_pac_selector"
        # Try to read scope from global-settings
        if [[ -f "Definitions/global-settings.jsonc" ]]; then
            local gs_scope
            gs_scope="$(epac_parse_jsonc "Definitions/global-settings.jsonc" | jq -r \
                --arg ps "$_pac_selector" '.pacEnvironments[] | select(.pacSelector == $ps) | .deploymentRootScope // empty')"
            if [[ -n "$gs_scope" ]]; then
                scope_value="$gs_scope"
            fi
        fi
    fi
    if [[ -n "$_overwrite_pac_selector" && "$_overwrite_pac_selector" != "EPAC-Dev" ]]; then
        scope_selector="$_overwrite_pac_selector"
    fi
    if [[ -n "$_overwrite_scope" ]]; then
        scope_value="$_overwrite_scope"
    fi

    local assignment_json
    assignment_json="$(jq -n \
        --arg schema "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-assignment-schema.json" \
        --argjson de "$def_entry" \
        --arg guid "$guid_suffix" \
        --arg dn "$policy_display" \
        --arg desc "$policy_desc" \
        --arg sel "$scope_selector" \
        --arg sv "$scope_value" \
        --argjson params "$params" '{
            "\$schema": $schema,
            nodeName: "/Security/",
            definitionEntry: $de,
            children: [{
                nodeName: $sel,
                assignment: {
                    name: $guid,
                    displayName: $dn,
                    description: $desc
                },
                enforcementMode: "Default",
                parameters: $params,
                scope: {($sel): [$sv]}
            }]
        }')"

    mkdir -p "${_output_folder}/Export/policyAssignments"
    echo "$assignment_json" | jq '.' > "${_output_folder}/Export/policyAssignments/${policy_name}.jsonc"
    echo "Created assignment: ${policy_name}.jsonc" >&2
}

# ═════════════════════════════════════════════════════════════════════════════
# Parse arguments
# ═════════════════════════════════════════════════════════════════════════════

_policy_definition_id=""
_policy_set_definition_id=""
_alz_policy_definition_id=""
_alz_policy_set_definition_id=""
_output_folder="Output"
_auto_create_parameters=true
_use_builtin=true
_pac_selector=""
_overwrite_scope=""
_overwrite_pac_selector=""
_overwrite_output=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --policy-definition-id) _policy_definition_id="$2"; shift 2 ;;
        --policy-set-definition-id) _policy_set_definition_id="$2"; shift 2 ;;
        --alz-policy-definition-id) _alz_policy_definition_id="$2"; shift 2 ;;
        --alz-policy-set-definition-id) _alz_policy_set_definition_id="$2"; shift 2 ;;
        --output-folder) _output_folder="$2"; shift 2 ;;
        --auto-create-parameters) _auto_create_parameters=true; shift ;;
        --no-auto-create-parameters) _auto_create_parameters=false; shift ;;
        --use-builtin) _use_builtin=true; shift ;;
        --no-use-builtin) _use_builtin=false; shift ;;
        --pac-selector) _pac_selector="$2"; shift 2 ;;
        --overwrite-scope) _overwrite_scope="$2"; shift 2 ;;
        --overwrite-pac-selector) _overwrite_pac_selector="$2"; shift 2 ;;
        --no-overwrite-output) _overwrite_output=false; shift ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Must have exactly one input
_input_count=0
[[ -n "$_policy_definition_id" ]] && ((_input_count++))
[[ -n "$_policy_set_definition_id" ]] && ((_input_count++))
[[ -n "$_alz_policy_definition_id" ]] && ((_input_count++))
[[ -n "$_alz_policy_set_definition_id" ]] && ((_input_count++))

if [[ $_input_count -eq 0 ]]; then
    epac_log_error "Must specify one of: --policy-definition-id, --policy-set-definition-id, --alz-policy-definition-id, --alz-policy-set-definition-id"
    exit 1
fi
if [[ $_input_count -gt 1 ]]; then
    epac_log_error "Only one input parameter allowed"
    exit 1
fi

# Overwrite output
if $_overwrite_output && [[ -d "${_output_folder}/Export" ]]; then
    rm -rf "${_output_folder}/Export"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Process based on input type
# ═════════════════════════════════════════════════════════════════════════════

_policy_name=""
_policy_type=""
_policy_display=""
_policy_desc=""
_builtin_type=""
_policy_obj='{}'

_pd_schema="https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-definition-schema.json"
_psd_schema="https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-set-definition-schema.json"

if [[ -n "$_policy_definition_id" ]]; then
    # ── Azure Portal Policy Definition ──────────────────────────────────
    if [[ "$_policy_definition_id" != */providers/* ]]; then
        epac_log_error "Policy Definition ID doesn't match expected format: /providers/Microsoft.Authorization/policyDefinitions/<id>"
        exit 1
    fi

    _policy_name="${_policy_definition_id##*/}"
    _policy_type="policyDefinitions"

    local_response="$(az policy definition show --name "$_policy_name" -o json 2>/dev/null)" || \
    local_response="$(az policy definition show --name "$_policy_definition_id" -o json 2>/dev/null)" || {
        epac_log_error "Policy Definition ID '$_policy_definition_id' Not Found!"
        exit 1
    }

    _policy_display="$(echo "$local_response" | jq -r '.displayName // ""')"
    _policy_desc="$(echo "$local_response" | jq -r '.description // ""')"
    _builtin_type="$(echo "$local_response" | jq -r '.policyType // ""')"
    _policy_obj="$local_response"

    # Clean metadata and write definition (unless builtin + useBuiltin)
    local_metadata="$(_clean_metadata "$(echo "$local_response" | jq '.metadata // {}')")"
    local_def="$(jq -n --arg n "$_policy_name" --argjson r "$local_response" --argjson m "$local_metadata" '{
        name: $n,
        properties: {
            displayName: $r.displayName,
            policyType: $r.policyType,
            mode: $r.mode,
            description: $r.description,
            metadata: $m,
            parameters: $r.parameters,
            policyRule: $r.policyRule
        }
    }')"

    if ! ($_use_builtin && [[ "$_builtin_type" == "BuiltIn" ]]); then
        _write_definition "$_policy_name" "$local_def" "${_output_folder}/Export/policyDefinitions" "$_pd_schema"
    fi

elif [[ -n "$_policy_set_definition_id" ]]; then
    # ── Azure Portal Policy Set Definition ──────────────────────────────
    if [[ "$_policy_set_definition_id" != */providers/* ]]; then
        epac_log_error "Policy Set Definition ID doesn't match expected format"
        exit 1
    fi

    _policy_name="${_policy_set_definition_id##*/}"
    _policy_type="policySetDefinitions"

    local_response="$(az policy set-definition show --name "$_policy_name" -o json 2>/dev/null)" || \
    local_response="$(az policy set-definition show --name "$_policy_set_definition_id" -o json 2>/dev/null)" || {
        epac_log_error "Policy Set Definition '$_policy_set_definition_id' Not Found!"
        exit 1
    }

    _policy_display="$(echo "$local_response" | jq -r '.displayName // ""')"
    _policy_desc="$(echo "$local_response" | jq -r '.description // ""')"
    _builtin_type="$(echo "$local_response" | jq -r '.policyType // ""')"
    _policy_obj="$local_response"

    local_metadata="$(_clean_metadata "$(echo "$local_response" | jq '.metadata // {}')")"
    local_pd_array="$(_build_policy_set_defs_array "$(echo "$local_response" | jq '.policyDefinitions // []')")"

    local_def="$(jq -n --arg n "$_policy_name" --argjson r "$local_response" --argjson m "$local_metadata" \
        --argjson pda "$local_pd_array" '{
        name: $n,
        properties: {
            displayName: $r.displayName,
            policyType: $r.policyType,
            description: $r.description,
            metadata: $m,
            parameters: $r.parameters,
            policyDefinitions: $pda,
            policyDefinitionGroups: $r.policyDefinitionGroups
        }
    }' | jq 'if .properties.policyDefinitionGroups == null then del(.properties.policyDefinitionGroups) else . end')"

    if ! ($_use_builtin && [[ "$_builtin_type" == "BuiltIn" ]]); then
        _write_definition "$_policy_name" "$local_def" "${_output_folder}/Export/policySetDefinitions" "$_psd_schema"
    fi

    # Export individual policies within the set
    local_policy_ids="$(echo "$local_response" | jq -r '.policyDefinitions[].policyDefinitionId')"
    while IFS= read -r _pid; do
        [[ -z "$_pid" ]] && continue
        local_short="${_pid##*/}"
        # Skip builtins if using builtin
        if $_use_builtin; then
            local_is_builtin
            local_is_builtin="$(az policy definition show --name "$local_short" -o json 2>/dev/null | jq -r '.policyType // ""')"
            if [[ "$local_is_builtin" == "BuiltIn" ]]; then
                continue
            fi
        fi
        local_pr="$(az policy definition show --name "$local_short" -o json 2>/dev/null)" || continue
        local_pm="$(_clean_metadata "$(echo "$local_pr" | jq '.metadata // {}')")"
        local_pd="$(jq -n --arg n "$local_short" --argjson r "$local_pr" --argjson m "$local_pm" '{
            name: $n,
            properties: {
                displayName: $r.displayName,
                policyType: $r.policyType,
                mode: $r.mode,
                description: $r.description,
                metadata: $m,
                parameters: $r.parameters,
                policyRule: $r.policyRule
            }
        }')"
        _write_definition "$local_short" "$local_pd" "${_output_folder}/Export/policyDefinitions" "$_pd_schema"
    done <<< "$local_policy_ids"

elif [[ -n "$_alz_policy_definition_id" ]]; then
    # ── ALZ Policy Definition ───────────────────────────────────────────
    _policy_name="$_alz_policy_definition_id"
    _policy_type="policyDefinitions"

    local_alz_hash
    local_alz_hash="$(_fetch_alz_policies)"

    local_response="$(echo "$local_alz_hash" | jq --arg n "$_policy_name" '.[$n] // null')"
    if [[ "$local_response" == "null" ]]; then
        epac_log_error "ALZ Policy Definition ID '$_alz_policy_definition_id' Not Found!"
        exit 1
    fi

    _policy_display="$(echo "$local_response" | jq -r '.displayName // ""')"
    _policy_desc="$(echo "$local_response" | jq -r '.description // ""')"
    _builtin_type="$(echo "$local_response" | jq -r '.policyType // "Custom"')"
    _policy_obj="$(jq -n --argjson p "$local_response" '{properties: $p}')"

    local_def="$(jq -n --arg n "$_policy_name" --argjson p "$local_response" '{
        name: $n,
        properties: {
            displayName: $p.displayName,
            policyType: $p.policyType,
            mode: $p.mode,
            description: $p.description,
            metadata: $p.metadata,
            parameters: $p.parameters,
            policyRule: $p.policyRule
        }
    }')"
    # Fix ALZ ARM template [[ → [
    local_json
    local_json="$(echo "$local_def" | jq '.' | sed 's/\[\[/[/g')"
    local_def="$local_json"

    if ! ($_use_builtin && [[ "$_builtin_type" == "BuiltIn" ]]); then
        _write_definition "$_policy_name" "$local_def" "${_output_folder}/Export/policyDefinitions" "$_pd_schema"
    fi

elif [[ -n "$_alz_policy_set_definition_id" ]]; then
    # ── ALZ Policy Set Definition ───────────────────────────────────────
    _policy_name="$_alz_policy_set_definition_id"
    _policy_type="policySetDefinitions"

    local_alz_hash
    local_alz_hash="$(_fetch_alz_policies)"
    local_alz_set_hash
    local_alz_set_hash="$(_fetch_alz_policy_sets)"

    local_response="$(echo "$local_alz_set_hash" | jq --arg n "$_policy_name" '.[$n] // null')"
    if [[ "$local_response" == "null" ]]; then
        epac_log_error "ALZ Policy Set Definition ID '$_alz_policy_set_definition_id' Not Found!"
        exit 1
    fi

    _policy_display="$(echo "$local_response" | jq -r '.displayName // ""')"
    _policy_desc="$(echo "$local_response" | jq -r '.description // ""')"
    _builtin_type="$(echo "$local_response" | jq -r '.policyType // "Custom"')"
    _policy_obj="$(jq -n --argjson p "$local_response" '{properties: $p}')"

    local_pd_array="$(_build_policy_set_defs_array "$(echo "$local_response" | jq '.policyDefinitions // []')")"

    local_def="$(jq -n --arg n "$_policy_name" --argjson p "$local_response" --argjson pda "$local_pd_array" '{
        name: $n,
        properties: {
            displayName: $p.displayName,
            policyType: $p.policyType,
            description: $p.description,
            metadata: $p.metadata,
            parameters: $p.parameters,
            policyDefinitions: $pda,
            policyDefinitionGroups: $p.policyDefinitionGroups
        }
    }' | jq 'if .properties.policyDefinitionGroups == null then del(.properties.policyDefinitionGroups) else . end')"
    local_json
    local_json="$(echo "$local_def" | jq '.' | sed 's/\[\[/[/g')"
    local_def="$local_json"

    if ! ($_use_builtin && [[ "$_builtin_type" == "BuiltIn" ]]); then
        _write_definition "$_policy_name" "$local_def" "${_output_folder}/Export/policySetDefinitions" "$_psd_schema"
    fi

    # Export individual ALZ policies within the set
    local_policy_ids="$(echo "$local_response" | jq -r '.policyDefinitions[].policyDefinitionId // .policyDefinitions[].PolicyDefinitionId')"
    while IFS= read -r _pid; do
        [[ -z "$_pid" ]] && continue
        local_short="${_pid##*/}"

        # Check if builtin via az CLI
        if $_use_builtin; then
            local_check="$(az policy definition show --name "$local_short" -o json 2>/dev/null | jq -r '.policyType // ""' 2>/dev/null)"
            if [[ "$local_check" == "BuiltIn" ]]; then
                continue
            fi
        fi

        # Try ALZ hash first, then Azure
        local_pd_response="$(echo "$local_alz_hash" | jq --arg n "$local_short" '.[$n] // null')"
        if [[ "$local_pd_response" == "null" ]]; then
            local_pd_response="$(echo "$local_alz_hash" | jq --arg n "$_pid" '.[$n] // null')"
        fi

        if [[ "$local_pd_response" != "null" ]]; then
            local_pd_def="$(jq -n --arg n "$local_short" --argjson p "$local_pd_response" '{
                name: $n,
                properties: {
                    displayName: $p.displayName,
                    policyType: $p.policyType,
                    mode: $p.mode,
                    description: $p.description,
                    metadata: $p.metadata,
                    parameters: $p.parameters,
                    policyRule: $p.policyRule
                }
            }')"
            local_pd_json
            local_pd_json="$(echo "$local_pd_def" | jq '.' | sed 's/\[\[/[/g')"
            _write_definition "$local_short" "$local_pd_json" "${_output_folder}/Export/policyDefinitions" "$_pd_schema"
        fi
    done <<< "$local_policy_ids"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Create assignment file
# ═════════════════════════════════════════════════════════════════════════════

if [[ -n "$_policy_name" ]]; then
    _create_assignment "$_policy_name" "$_policy_type" "$_policy_display" "$_policy_desc" \
        "$_builtin_type" "$_policy_obj"
fi

echo "" >&2
echo "Export complete." >&2
