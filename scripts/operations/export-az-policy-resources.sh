#!/usr/bin/env bash
# scripts/operations/export-az-policy-resources.sh — Export Azure Policy resources
# Replaces: Scripts/Operations/Export-AzPolicyResources.ps1
#
# Modes:
#   export              — Export to EPAC format (default)
#   collectRawFile      — Collect raw JSON data per pacSelector
#   exportFromRawFiles  — Export from previously collected raw files
#   exportRawToPipeline — Output raw JSON to stdout
#   psrule              — Export for PSRule validation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/epac.sh
source "${SCRIPT_DIR}/../../lib/epac.sh"

# ═════════════════════════════════════════════════════════════════════════════
# Internal helper functions (defined before main logic)
# ═════════════════════════════════════════════════════════════════════════════

_add_ownership_row() {
    local pac_selector="$1" kind="$2" obj="$3" raw_meta="$4" id="$5"

    local owner
    owner="$(echo "$obj" | jq -r '.pacOwner // "thisPaC"')"
    if [[ "$owner" == "otherPaC" ]]; then
        local pid
        pid="$(echo "$raw_meta" | jq -r '.pacOwnerId // ""')"
        owner="otherPaC(pacOwnerId=${pid})"
    fi

    local principal_id="n/a" last_change="n/a"
    if [[ "$(echo "$raw_meta" | jq 'has("updatedBy")')" == "true" ]]; then
        principal_id="$(echo "$raw_meta" | jq -r '.updatedBy')"
        last_change="$(echo "$raw_meta" | jq -r 'if .updatedOn then .updatedOn else "n/a" end')"
    elif [[ "$(echo "$raw_meta" | jq 'has("createdBy")')" == "true" ]]; then
        principal_id="$(echo "$raw_meta" | jq -r '.createdBy')"
        last_change="$(echo "$raw_meta" | jq -r 'if .createdOn then .createdOn else "n/a" end')"
    else
        last_change="$(echo "$raw_meta" | jq -r 'if .createdOn then .createdOn else "n/a" end')"
    fi

    local category display_name
    category="$(echo "$raw_meta" | jq -r '.category // ""')"
    display_name="$(echo "$obj" | jq -r '.properties.displayName // .name // ""')"

    local row
    row="$(jq -n --arg ps "$pac_selector" --arg k "$kind" --arg o "$owner" \
        --arg p "$principal_id" --arg lc "$last_change" --arg c "$category" \
        --arg dn "$display_name" --arg id "$id" \
        '{pacSelector:$ps,kind:$k,owner:$o,principalId:$p,lastChange:$lc,category:$c,displayName:$dn,id:$id}')"
    local rows
    rows="$(cat "$_all_rows_file")"
    echo "$rows" | jq --argjson r "$row" '. += [$r]' > "$_all_rows_file"
}

_add_generic_ownership_row() {
    local pac_selector="$1" kind="$2" owner="$3" raw_meta="$4"
    local display_name="$5" name="$6" id="$7"

    [[ -z "$display_name" ]] && display_name="$name"

    local principal_id="n/a" last_change="n/a"
    if [[ "$(echo "$raw_meta" | jq 'has("updatedBy")')" == "true" ]]; then
        principal_id="$(echo "$raw_meta" | jq -r '.updatedBy')"
        last_change="$(echo "$raw_meta" | jq -r 'if .updatedOn then .updatedOn else "n/a" end')"
    elif [[ "$(echo "$raw_meta" | jq 'has("createdBy")')" == "true" ]]; then
        principal_id="$(echo "$raw_meta" | jq -r '.createdBy')"
        last_change="$(echo "$raw_meta" | jq -r 'if .createdOn then .createdOn else "n/a" end')"
    else
        last_change="$(echo "$raw_meta" | jq -r 'if .createdOn then .createdOn else "n/a" end')"
    fi
    local category
    category="$(echo "$raw_meta" | jq -r '.category // ""')"

    local row
    row="$(jq -n --arg ps "$pac_selector" --arg k "$kind" --arg o "$owner" \
        --arg p "$principal_id" --arg lc "$last_change" --arg c "$category" \
        --arg dn "$display_name" --arg id "$id" \
        '{pacSelector:$ps,kind:$k,owner:$o,principalId:$p,lastChange:$lc,category:$c,displayName:$dn,id:$id}')"
    local rows
    rows="$(cat "$_all_rows_file")"
    echo "$rows" | jq --argjson r "$row" '. += [$r]' > "$_all_rows_file"
}

# Process resources for a single pacSelector (export/exportFromRawFiles mode)
_process_pac_resources() {
    local deployed="$1" pac_selector="$2" pac_env="$3"

    local include_auto="$_include_auto_assigned"
    local skip_exemptions=false
    [[ "$_exemption_files" == "none" ]] && skip_exemptions=true

    # ── Policy Definitions ──────────────────────────────────────────────
    epac_write_section "Processing Policy Definitions" "blue"
    local policy_defs
    policy_defs="$(echo "$deployed" | jq '.policydefinitions.ownedBy // {} | to_entries')"
    local pd_count
    pd_count="$(echo "$policy_defs" | jq 'length')"
    epac_write_status "Found $pd_count custom policy definitions" "success" 2

    echo "$policy_defs" | jq -c '.[]' | while IFS= read -r entry; do
        local pd_id pd_obj pd_props pd_name raw_meta
        pd_id="$(echo "$entry" | jq -r '.key')"
        pd_obj="$(echo "$entry" | jq '.value')"
        pd_props="$(echo "$pd_obj" | jq '.properties // {}')"
        pd_name="$(echo "$pd_obj" | jq -r '.name')"
        raw_meta="$(echo "$pd_props" | jq '.metadata // {}')"

        _add_ownership_row "$pac_selector" "PolicyDefinition" "$pd_obj" "$raw_meta" "$pd_id"

        local metadata
        metadata="$(epac_get_custom_metadata "$raw_meta" "pacOwnerId")"

        local definition
        definition="$(jq -n --arg n "$pd_name" --argjson p "$pd_props" --argjson m "$metadata" \
            '{name: $n, properties: ($p | .metadata = $m)}')"

        epac_out_policy_definition "$definition" "$_policy_defs_folder" \
            "$_policy_props_by_name_file" "$_invalid_chars" "$pd_id" "$_file_extension"
    done

    # Cache definition properties by key
    echo "$deployed" | jq -c '.policydefinitions.all // {} | to_entries[]' | while IFS= read -r entry; do
        local d_id d_parts d_key d_props existing
        d_id="$(echo "$entry" | jq -r '.key')"
        d_parts="$(epac_split_policy_resource_id "$d_id")"
        d_key="$(echo "$d_parts" | jq -r '.definitionKey')"
        d_props="$(echo "$entry" | jq '.value.properties')"
        existing="$(cat "$_def_props_by_key_file")"
        if [[ "$(echo "$existing" | jq --arg k "$d_key" 'has($k)')" == "false" ]]; then
            echo "$existing" | jq --arg k "$d_key" --argjson p "$d_props" '.[$k] = $p' > "$_def_props_by_key_file"
        fi
    done

    # ── Policy Set Definitions ──────────────────────────────────────────
    epac_write_section "Processing Policy Set Definitions" "blue"
    local policy_set_defs
    policy_set_defs="$(echo "$deployed" | jq '.policysetdefinitions.ownedBy // {} | to_entries')"
    local psd_count
    psd_count="$(echo "$policy_set_defs" | jq 'length')"
    epac_write_status "Found $psd_count custom policy set definitions" "success" 2

    echo "$policy_set_defs" | jq -c '.[]' | while IFS= read -r entry; do
        local psd_id psd_obj psd_props psd_name raw_meta
        psd_id="$(echo "$entry" | jq -r '.key')"
        psd_obj="$(echo "$entry" | jq '.value')"
        psd_props="$(echo "$psd_obj" | jq '.properties // {}')"
        psd_name="$(echo "$psd_obj" | jq -r '.name')"
        raw_meta="$(echo "$psd_props" | jq '.metadata // {}')"

        _add_ownership_row "$pac_selector" "PolicySetDefinition" "$psd_obj" "$raw_meta" "$psd_id"

        local metadata
        metadata="$(epac_get_custom_metadata "$raw_meta" "pacOwnerId")"

        # Adjust policyDefinitions for EPAC format
        local policy_defs_adjusted
        policy_defs_adjusted="$(echo "$psd_props" | jq '[
            (.policyDefinitions // [])[] |
            (. as $pd | $pd.policyDefinitionId | split("/")) as $parts |
            (if ($parts | length >= 4) and $parts[3] == "Microsoft.Authorization" and $parts[1] == "providers"
             then "builtin" else "custom" end) as $scope_type |
            if $scope_type == "builtin" then
                {policyDefinitionReferenceId, policyDefinitionId, parameters}
                + (if .definitionVersion then {definitionVersion} else {} end)
                + (if (.groupNames // [] | length) > 0 then {groupNames} else {} end)
            else
                {policyDefinitionReferenceId,
                 policyDefinitionName: (.policyDefinitionId | split("/") | last),
                 parameters}
                + (if .definitionVersion then {definitionVersion} else {} end)
                + (if (.groupNames // [] | length) > 0 then {groupNames} else {} end)
            end
        ]')"

        local definition
        definition="$(jq -n --arg n "$psd_name" --argjson p "$psd_props" --argjson m "$metadata" \
            --argjson pda "$policy_defs_adjusted" '{
                name: $n,
                properties: {
                    displayName: $p.displayName,
                    description: $p.description,
                    metadata: $m,
                    parameters: $p.parameters,
                    policyDefinitions: $pda,
                    policyDefinitionGroups: $p.policyDefinitionGroups
                }
            }')"

        epac_out_policy_definition "$definition" "$_policy_set_defs_folder" \
            "$_policy_set_props_by_name_file" "$_invalid_chars" "$psd_id" "$_file_extension"
    done

    # Cache policy set properties by key
    echo "$deployed" | jq -c '.policysetdefinitions.all // {} | to_entries[]' | while IFS= read -r entry; do
        local d_id d_parts d_key d_props existing
        d_id="$(echo "$entry" | jq -r '.key')"
        d_parts="$(epac_split_policy_resource_id "$d_id")"
        d_key="$(echo "$d_parts" | jq -r '.definitionKey')"
        d_props="$(echo "$entry" | jq '.value.properties')"
        existing="$(cat "$_def_props_by_key_file")"
        if [[ "$(echo "$existing" | jq --arg k "$d_key" 'has($k)')" == "false" ]]; then
            echo "$existing" | jq --arg k "$d_key" --argjson p "$d_props" '.[$k] = $p' > "$_def_props_by_key_file"
        fi
    done

    # ── Policy Assignments ──────────────────────────────────────────────
    epac_write_section "Collating Policy Assignments" "blue"
    local policy_assignments
    policy_assignments="$(echo "$deployed" | jq '.policyassignments.all // {}')"
    local pa_count
    pa_count="$(echo "$policy_assignments" | jq 'keys | length')"
    epac_write_status "Environment: $pac_selector" "info" 2
    epac_write_status "Found $pa_count policy assignments" "success" 2

    echo "$policy_assignments" | jq -c 'to_entries[]' | while IFS= read -r entry; do
        local pa_id pa_obj pa_props raw_meta
        pa_id="$(echo "$entry" | jq -r '.key')"
        pa_obj="$(echo "$entry" | jq '.value')"
        pa_props="$(echo "$pa_obj" | jq '.properties // {}')"
        raw_meta="$(echo "$pa_props" | jq '.metadata // {}')"

        local pac_owner
        pac_owner="$(echo "$pa_obj" | jq -r '.pacOwner // ""')"
        if [[ "$pac_owner" == "managedByDfcSecurityPolicies" || "$pac_owner" == "managedByDfcDefenderPlans" ]]; then
            if [[ "$include_auto" != "true" ]]; then
                continue
            fi
        fi

        local policy_def_id parts kind_str scope_type
        policy_def_id="$(echo "$pa_props" | jq -r '.policyDefinitionId')"
        parts="$(epac_split_policy_resource_id "$policy_def_id")"
        kind_str="$(echo "$parts" | jq -r 'if .kind == "policyDefinitions" then "Policy" else "PolicySet" end')"
        scope_type="$(echo "$parts" | jq -r 'if .scopeType == "builtin" then "Builtin" else "Custom" end')"

        local row_kind="Assignment(${kind_str}-${scope_type})"
        local row_owner="$pac_owner"
        if [[ "$pac_owner" == "otherPaC" ]]; then
            row_owner="otherPaC(pacOwnerId=$(echo "$raw_meta" | jq -r '.pacOwnerId // ""'))"
        fi

        _add_generic_ownership_row "$pac_selector" "$row_kind" "$row_owner" "$raw_meta" \
            "$(echo "$pa_props" | jq -r '.displayName // ""')" \
            "$(echo "$pa_obj" | jq -r '.name')" "$pa_id"

        local roles_json metadata pa_name def_key enforcement_mode display_name description definition_version
        roles_json="$(echo "$raw_meta" | jq '.roles // []')"
        metadata="$(epac_get_custom_metadata "$(echo "$pa_props" | jq '.metadata // {}')" "pacOwnerId,roles")"
        pa_name="$(echo "$pa_obj" | jq -r '.name')"
        def_key="$(echo "$parts" | jq -r '.definitionKey')"
        enforcement_mode="$(echo "$pa_props" | jq -r '.enforcementMode // "Default"')"
        display_name="$(echo "$pa_props" | jq -r '.displayName // ""')"
        [[ -z "$display_name" ]] && display_name="$pa_name"
        description="$(echo "$pa_props" | jq -r '.description // ""')"
        definition_version="$(echo "$pa_props" | jq '.definitionVersion // null')"

        local assignment_name_ex
        assignment_name_ex="$(jq -n --arg n "$pa_name" --arg dn "$display_name" --arg d "$description" \
            '{name:$n,displayName:$dn,description:$d}')"

        local scope
        scope="$(echo "$pa_obj" | jq -r '.resourceIdParts.scope // ""')"

        local global_not_scopes assignment_not_scopes not_scopes
        global_not_scopes="$(echo "$pac_env" | jq '.globalNotScopes // []')"
        assignment_not_scopes="$(echo "$pa_props" | jq '.notScopes // []')"
        not_scopes="$(epac_remove_global_not_scopes "$assignment_not_scopes" "$global_not_scopes")"

        local additional_role_assignments
        additional_role_assignments="$(echo "$roles_json" | jq --arg s "$scope" \
            '[.[] | select(.scope != $s) | {roleDefinitionId, scope}]')"

        local identity_entry="null"
        local identity_type location mi_location
        identity_type="$(echo "$pa_obj" | jq -r '.identity.type // ""')"
        location="$(echo "$pa_obj" | jq -r '.location // ""')"
        mi_location="$(echo "$pac_env" | jq -r '.managedIdentityLocation // ""')"
        [[ "$location" == "$mi_location" ]] && location=""

        if [[ "$identity_type" == "UserAssigned" ]]; then
            local user_ids user_id_count
            user_ids="$(echo "$pa_obj" | jq '.identity.userAssignedIdentities // {} | keys')"
            user_id_count="$(echo "$user_ids" | jq 'length')"
            if [[ $user_id_count -gt 1 ]]; then
                identity_entry="$(echo "$user_ids" | jq --arg l "$location" \
                    '[.[] | {userAssigned:., location:(if $l=="" then null else $l end)}]')"
            else
                identity_entry="$(echo "$user_ids" | jq --arg l "$location" \
                    '{userAssigned:.[0], location:(if $l=="" then null else $l end)}')"
            fi
        elif [[ "$identity_type" == "SystemAssigned" ]]; then
            identity_entry="$(jq -n --arg l "$location" \
                '{userAssigned:null, location:(if $l=="" then null else $l end)}')"
        fi

        local parameters overrides resource_selectors ncm
        parameters="$(echo "$pa_props" | jq '(.parameters // {}) | with_entries(.value = .value.value)')"
        overrides="$(echo "$pa_props" | jq '.overrides // null')"
        resource_selectors="$(echo "$pa_props" | jq '.resourceSelectors // null')"
        ncm="$(echo "$pa_props" | jq 'if (.nonComplianceMessages // [] | length) > 0 then
            [.nonComplianceMessages[] | if .policyDefinitionReferenceId then . else {message} end]
            else null end')"

        local props_list
        props_list="$(jq -n \
            --argjson anx "$assignment_name_ex" \
            --argjson md "$metadata" \
            --argjson p "$parameters" \
            --argjson ov "$overrides" \
            --argjson rs "$resource_selectors" \
            --arg em "$enforcement_mode" \
            --arg sc "$scope" \
            --argjson ns "$not_scopes" \
            --argjson ncm "$ncm" \
            --argjson ara "$additional_role_assignments" \
            --argjson ie "$identity_entry" \
            --argjson dv "$definition_version" '{
                assignmentNameEx:$anx, metadata:$md, parameters:$p,
                overrides:$ov, resourceSelectors:$rs, enforcementMode:$em,
                scopes:$sc, notScopes:$ns, nonComplianceMessages:$ncm,
                additionalRoleAssignments:$ara, identityEntry:$ie,
                definitionVersion:$dv
            }')"

        local def_file="${_assignments_by_def_dir}/${def_key}.json"
        if [[ ! -f "$def_file" ]]; then
            local def_props_by_key def_properties def_display
            def_props_by_key="$(cat "$_def_props_by_key_file")"
            def_properties="$(echo "$def_props_by_key" | jq --arg k "$def_key" '.[$k] // {}')"
            def_display="$(echo "$def_properties" | jq -r '.displayName // ""')"

            jq -n \
                --arg dk "$def_key" \
                --arg did "$(echo "$parts" | jq -r '.id')" \
                --arg dn "$(echo "$parts" | jq -r '.name')" \
                --arg ddn "$def_display" \
                --arg ds "$(echo "$parts" | jq -r '.scope')" \
                --arg dst "$(echo "$parts" | jq -r '.scopeType')" \
                --arg dkind "$(echo "$parts" | jq -r '.kind')" \
                --argjson ib "$(echo "$parts" | jq '.scopeType == "builtin"')" '{
                    children:[], clusters:{},
                    definitionEntry:{
                        definitionKey:$dk, id:$did, name:$dn,
                        displayName:$ddn, scope:$ds, scopeType:$dst,
                        kind:$dkind, isBuiltin:$ib
                    }
                }' > "$def_file"
        fi

        epac_set_export_node "$def_file" "$pac_selector" "$_property_names" "$props_list" 0
    done

    # ── Exemptions ──────────────────────────────────────────────────────
    if [[ "$skip_exemptions" != "true" ]]; then
        local policy_exemptions exemption_values
        policy_exemptions="$(echo "$deployed" | jq '.policyexemptions // {}')"
        exemption_values="$(echo "$policy_exemptions" | jq '[to_entries[].value | to_entries[].value]')"

        echo "$exemption_values" | jq -c '.[]' | while IFS= read -r exemption; do
            local ex_status ex_owner ex_meta ex_display ex_id ex_category
            ex_status="$(echo "$exemption" | jq -r '.status // ""')"
            ex_meta="$(echo "$exemption" | jq '.metadata // {}')"
            ex_owner="$(echo "$exemption" | jq -r '.pacOwner // ""')"
            if [[ "$ex_owner" == "otherPaC" ]]; then
                ex_owner="otherPaC(pacOwnerId=$(echo "$ex_meta" | jq -r '.pacOwnerId // ""'))"
            fi
            ex_display="$(echo "$exemption" | jq -r '.displayName // .name // ""')"
            ex_id="$(echo "$exemption" | jq -r '.id // ""')"
            ex_category="$(echo "$exemption" | jq -r '.exemptionCategory // ""')"

            local row
            row="$(jq -n --arg ps "$pac_selector" --arg k "Exemption($ex_status)" --arg o "$ex_owner" \
                --arg p "n/a" --arg lc "n/a" --arg c "$ex_category" --arg dn "$ex_display" --arg id "$ex_id" \
                '{pacSelector:$ps,kind:$k,owner:$o,principalId:$p,lastChange:$lc,category:$c,displayName:$dn,id:$id}')"
            local rows
            rows="$(cat "$_all_rows_file")"
            echo "$rows" | jq --argjson r "$row" '. += [$r]' > "$_all_rows_file"
        done

        local exemption_flags=""
        [[ "$_exemption_files" == "json" ]] && exemption_flags="--json"
        [[ "$_exemption_files" == "csv" ]] && exemption_flags="--csv"

        epac_out_policy_exemptions "$exemption_values" "$pac_env" \
            "$_policy_exemptions_folder" $exemption_flags \
            --file-extension "$_file_extension" --active-only
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# Main script logic
# ═════════════════════════════════════════════════════════════════════════════

# ─── Parse arguments ────────────────────────────────────────────────────────

_definitions_root_folder="${PAC_DEFINITIONS_FOLDER:-./Definitions}"
_output_folder="${PAC_OUTPUT_FOLDER:-./Outputs}"
_interactive=false
_include_child_scopes=false
_include_auto_assigned=false
_exemption_files="csv"
_file_extension="jsonc"
_mode="export"
_input_pac_selector="*"
_suppress_epac_output=false
_psrule_ignore_full_scope=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --definitions-root-folder) _definitions_root_folder="$2"; shift 2 ;;
        --output-folder) _output_folder="$2"; shift 2 ;;
        --interactive) _interactive=true; shift ;;
        --include-child-scopes) _include_child_scopes=true; shift ;;
        --include-auto-assigned) _include_auto_assigned=true; shift ;;
        --exemption-files) _exemption_files="$2"; shift 2 ;;
        --file-extension) _file_extension="$2"; shift 2 ;;
        --mode) _mode="$2"; shift 2 ;;
        --input-pac-selector) _input_pac_selector="$2"; shift 2 ;;
        --suppress-epac-output) _suppress_epac_output=true; shift ;;
        --psrule-ignore-full-scope) _psrule_ignore_full_scope=true; shift ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate
case "$_mode" in
    export|collectRawFile|exportFromRawFiles|exportRawToPipeline|psrule) ;;
    *) epac_log_error "Invalid mode: $_mode"; exit 1 ;;
esac
case "$_exemption_files" in
    none|csv|json) ;;
    *) epac_log_error "Invalid exemption-files: $_exemption_files"; exit 1 ;;
esac
case "$_file_extension" in
    json|jsonc) ;;
    *) epac_log_error "Invalid file-extension: $_file_extension"; exit 1 ;;
esac

# ─── Initialize ─────────────────────────────────────────────────────────────

_global_settings="$(epac_get_global_settings "$_definitions_root_folder" "$_output_folder")"
_output_folder="$(echo "$_global_settings" | jq -r '.outputFolder')"
_export_folder="${_output_folder}/export"
_raw_folder="${_export_folder}/RawDefinitions"
_definitions_folder="${_export_folder}/Definitions"
_policy_defs_folder="${_definitions_folder}/policyDefinitions"
_policy_set_defs_folder="${_definitions_folder}/policySetDefinitions"
_policy_assignments_folder="${_definitions_folder}/policyAssignments"
_policy_exemptions_folder="${_definitions_folder}/policyExemptions"
_ownership_csv_path="${_export_folder}/policy-ownership.csv"
_invalid_chars='/\\:*?"<>|[]()$'

_property_names='["assignmentNameEx","metadata","parameters","overrides","resourceSelectors","enforcementMode","scopes","notScopes","nonComplianceMessages","additionalRoleAssignments","identityEntry","definitionVersion"]'

# Tracking state files
_policy_props_by_name_file="$(mktemp)"
echo '{}' > "$_policy_props_by_name_file"
_policy_set_props_by_name_file="$(mktemp)"
echo '{}' > "$_policy_set_props_by_name_file"
_def_props_by_key_file="$(mktemp)"
echo '{}' > "$_def_props_by_key_file"
_assignments_by_def_dir="$(mktemp -d)"
_all_rows_file="$(mktemp)"
echo '[]' > "$_all_rows_file"

_cleanup_export() {
    rm -f "$_policy_props_by_name_file" "$_policy_set_props_by_name_file" \
          "$_def_props_by_key_file" "$_all_rows_file"
    rm -rf "$_assignments_by_def_dir"
}
trap _cleanup_export EXIT

# ─── Mode-specific init ────────────────────────────────────────────────────

if [[ "$_mode" == "export" || "$_mode" == "exportFromRawFiles" ]]; then
    if [[ -d "$_definitions_folder" ]]; then
        if $_interactive; then
            echo "About to delete: $_definitions_folder"
            read -rp "Continue? [y/N] " _confirm
            if [[ "${_confirm,,}" != "y" ]]; then
                echo "Aborted."
                exit 0
            fi
        fi
        rm -rf "$_definitions_folder"
    fi
    epac_write_section "Exporting Policy Resources" "blue"
    epac_write_status "WARNING: Assumes policies/policy sets with same name have same properties across scopes" "warning" 2
    epac_write_status "Ignores auto-assigned DfC assignments unless --include-auto-assigned" "warning" 2
else
    epac_write_section "Collecting Policy Resources (Raw)" "blue"
fi

# ─── Retrieve & process policy resources ────────────────────────────────────

_pac_selectors="$(echo "$_global_settings" | jq -r '.pacEnvironmentSelectors[]')"

if [[ "$_mode" != "exportFromRawFiles" ]]; then
    while IFS= read -r _pac_selector; do
        [[ -z "$_pac_selector" ]] && continue
        if [[ "$_input_pac_selector" != "*" && "$_pac_selector" != "$_input_pac_selector" ]]; then
            continue
        fi

        epac_write_section "Processing: $_pac_selector" "blue"

        local_pac_env="$(echo "$_global_settings" | jq --arg ps "$_pac_selector" '.pacEnvironments[$ps]')"
        epac_select_pac_environment "$local_pac_env"

        local_scope_table="$(epac_build_scope_table "$local_pac_env" "$_include_child_scopes")"
        local_deployed="$(epac_get_az_policy_resources "$local_pac_env" "$local_scope_table" "export")"

        case "$_mode" in
            collectRawFile)
                mkdir -p "$_raw_folder"
                local_raw_file="${_raw_folder}/${_pac_selector}.json"
                echo "$local_deployed" | jq '.' > "$local_raw_file"
                epac_write_status "Wrote raw file: $local_raw_file" "success" 2
                ;;
            exportRawToPipeline)
                echo "$local_deployed"
                ;;
            psrule)
                local_assignments="$(echo "$local_deployed" | jq '.policyassignments.all // {}')"
                local_psrule_file="${_export_folder}/psrule-${_pac_selector}.json"
                mkdir -p "$_export_folder"

                if $_psrule_ignore_full_scope; then
                    echo "$local_assignments" | jq '[to_entries[] | .value]' > "$local_psrule_file"
                else
                    local_root_scope="$(echo "$local_pac_env" | jq -r '.deploymentRootScope')"
                    echo "$local_assignments" | jq --arg rs "$local_root_scope" '[
                        to_entries[] | .value |
                        select(.properties.scope == $rs or
                               (.properties.scope | startswith($rs + "/")))
                    ]' > "$local_psrule_file"
                fi
                epac_write_status "Wrote PSRule file: $local_psrule_file" "success" 2
                ;;
            export)
                _process_pac_resources "$local_deployed" "$_pac_selector" "$local_pac_env"
                ;;
        esac
    done <<< "$_pac_selectors"
fi

# ─── exportFromRawFiles: read raw data ─────────────────────────────────────

if [[ "$_mode" == "exportFromRawFiles" ]]; then
    if [[ ! -d "$_raw_folder" ]]; then
        epac_log_error "Raw folder not found: $_raw_folder"
        exit 1
    fi
    for _raw_file in "$_raw_folder"/*.json; do
        [[ -f "$_raw_file" ]] || continue
        _pac_selector="$(basename "$_raw_file" .json)"
        local_pac_env="$(echo "$_global_settings" | jq --arg ps "$_pac_selector" '.pacEnvironments[$ps]')"
        local_deployed="$(cat "$_raw_file")"
        epac_write_section "Processing raw file: $_pac_selector" "blue"
        _process_pac_resources "$local_deployed" "$_pac_selector" "$local_pac_env"
    done
fi

# ─── Post-processing: optimize trees & write files ─────────────────────────

if [[ "$_mode" == "export" || "$_mode" == "exportFromRawFiles" ]]; then
    epac_write_section "Optimizing Policy Assignment Trees" "yellow"
    for _def_file in "$_assignments_by_def_dir"/*.json; do
        [[ -f "$_def_file" ]] || continue
        local_children="$(jq -r '.children // [] | .[]' "$_def_file")"
        while IFS= read -r _child_file; do
            [[ -z "$_child_file" || ! -f "$_child_file" ]] && continue
            epac_set_export_node_ancestors "$_child_file" "$_property_names" 0
        done <<< "$local_children"
    done

    epac_write_section "Creating Policy Assignment Files" "green"
    for _def_file in "$_assignments_by_def_dir"/*.json; do
        [[ -f "$_def_file" ]] || continue
        epac_out_policy_assignment_file "$_def_file" "$_property_names" \
            "$_policy_assignments_folder" "$_invalid_chars" "$_file_extension"
    done

    epac_write_section "Creating Ownership CSV File" "green"
    epac_write_ownership_csv "$(cat "$_all_rows_file")" "$_ownership_csv_path"
    epac_write_status "Wrote: $_ownership_csv_path" "success" 2
fi

epac_write_section "Export Complete" "green"
