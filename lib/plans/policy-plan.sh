#!/usr/bin/env bash
# lib/plans/policy-plan.sh — Policy definition plan building
# Replaces: Build-PolicyPlan.ps1
# Reads policy definition files, compares with deployed definitions,
# produces new/update/replace/delete plan.

[[ -n "${_EPAC_POLICY_PLAN_LOADED:-}" ]] && return 0
readonly _EPAC_POLICY_PLAN_LOADED=1

_EPAC_PLAN_DIR="${BASH_SOURCE[0]%/*}"
source "${_EPAC_PLAN_DIR}/../core.sh"
source "${_EPAC_PLAN_DIR}/../json.sh"
source "${_EPAC_PLAN_DIR}/../utils.sh"
source "${_EPAC_PLAN_DIR}/../output.sh"
source "${_EPAC_PLAN_DIR}/../validators.sh"

###############################################################################
# Build policy definition plan
###############################################################################
# Arguments:
#   $1 - definitions_root_folder: path to policy definition JSONC/JSON files
#   $2 - pac_environment: JSON pac environment
#   $3 - deployed_definitions: JSON { managed: {id: def}, readOnly: {id: def} }
#   $4 - all_definitions: JSON { policydefinitions: {id: def} }
#   $5 - replace_definitions: JSON { id: def }
#   $6 - policy_role_ids: JSON { policyId: [roleDefId ...] }
#   $7 - detailed_output: "true"|"false"
#
# Outputs JSON to stdout:
# {
#   definitions: { new:{}, update:{}, replace:{}, delete:{},
#                  numberUnchanged:N, numberOfChanges:N },
#   allDefinitions: { policydefinitions: {...} },
#   replaceDefinitions: {...},
#   policyRoleIds: {...}
# }

epac_build_policy_plan() {
    local definitions_root_folder="$1"
    local pac_environment="$2"
    local deployed_definitions="$3"
    local all_definitions="$4"
    local replace_definitions="$5"
    local policy_role_ids="$6"
    local detailed_output="${7:-false}"

    local deployment_root_scope
    deployment_root_scope="$(echo "$pac_environment" | jq -r '.deploymentRootScope')"
    local pac_owner_id
    pac_owner_id="$(echo "$pac_environment" | jq -r '.pacOwnerId')"
    local deployed_by
    deployed_by="$(echo "$pac_environment" | jq -r '.deployedBy // empty')"
    local strategy
    strategy="$(echo "$pac_environment" | jq -r '.desiredState.strategy // "full"')"

    # Clone managed definitions as delete candidates
    local delete_candidates
    delete_candidates="$(echo "$deployed_definitions" | jq '.managed // {}')"

    local definitions_new="{}"
    local definitions_update="{}"
    local definitions_replace="{}"
    local definitions_delete="{}"
    local definitions_unchanged=0
    local definitions_ignored=0
    local duplicate_tracking="{}"

    # Get excluded files list
    local excluded_files
    excluded_files="$(echo "$pac_environment" | jq '.desiredState.excludedPolicyDefinitionFiles // []')"

    # Collect all JSON/JSONC files
    if [[ ! -d "$definitions_root_folder" ]]; then
        epac_write_status "Policy definitions folder not found: ${definitions_root_folder}" "warning" 2 >&2
        _epac_emit_policy_plan_result "$definitions_new" "$definitions_update" "$definitions_replace" \
            "$definitions_delete" "$definitions_unchanged" "$all_definitions" "$replace_definitions" "$policy_role_ids"
        return 0
    fi

    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$definitions_root_folder" -type f \( -name '*.json' -o -name '*.jsonc' \) -print0 2>/dev/null | sort -z)

    local file_count=${#files[@]}
    epac_write_status "Processing ${file_count} policy definition files" "info" 2 >&2

    for file in "${files[@]}"; do
        local filename
        filename="$(basename "$file")"

        # Check exclusions
        local is_excluded
        is_excluded="$(echo "$excluded_files" | jq --arg f "$filename" 'map(select(. == $f)) | length > 0')"
        if [[ "$is_excluded" == "true" ]]; then
            epac_write_status "Excluded: ${filename}" "skip" 4 >&2
            definitions_ignored=$((definitions_ignored + 1))
            continue
        fi

        # Parse the definition file
        local definition_object
        if ! definition_object="$(epac_read_jsonc "$file")"; then
            epac_log_error "Failed to parse: ${file}"
            continue
        fi

        # Extract properties (handle both .properties wrapper and direct)
        local def_props
        def_props="$(echo "$definition_object" | jq 'if .properties then .properties else . end')"

        local name
        name="$(echo "$definition_object" | jq -r '.name // empty')"
        local display_name
        display_name="$(echo "$def_props" | jq -r '.displayName // empty')"
        local description
        description="$(echo "$def_props" | jq -r '.description // empty')"
        local metadata
        metadata="$(echo "$def_props" | jq '.metadata // {}')"
        local mode
        mode="$(echo "$def_props" | jq -r '.mode // "All"')"
        local version
        version="$(echo "$def_props" | jq -r '.version // empty')"
        local parameters
        parameters="$(echo "$def_props" | jq '.parameters // null')"
        local policy_rule
        policy_rule="$(echo "$def_props" | jq '.policyRule // null')"

        # Set pacOwnerId in metadata
        metadata="$(echo "$metadata" | jq --arg pid "$pac_owner_id" '.pacOwnerId = $pid')"

        # Check epacCloudEnvironments filter
        local cloud_envs
        cloud_envs="$(echo "$metadata" | jq '.epacCloudEnvironments // null')"
        if [[ "$cloud_envs" != "null" ]]; then
            local pac_cloud
            pac_cloud="$(echo "$pac_environment" | jq -r '.cloud // "AzureCloud"')"
            local cloud_match
            cloud_match="$(echo "$cloud_envs" | jq --arg c "$pac_cloud" 'map(select(ascii_downcase == ($c | ascii_downcase))) | length > 0')"
            if [[ "$cloud_match" != "true" ]]; then
                definitions_ignored=$((definitions_ignored + 1))
                continue
            fi
        fi

        # Set deployedBy if not already in metadata
        if [[ -n "$deployed_by" ]]; then
            metadata="$(echo "$metadata" | jq --arg db "$deployed_by" 'if has("deployedBy") then . else .deployedBy = $db end')"
        fi

        # Validations
        if [[ -z "$name" ]]; then
            epac_log_error "Policy from file '${file}' requires a name"
            continue
        fi

        if ! epac_confirm_valid_policy_resource_name "$name"; then
            epac_log_error "Policy '${name}' has invalid characters in name"
            continue
        fi

        if [[ -z "$display_name" && "$mode" != "Microsoft.Network.Data" ]]; then
            epac_log_error "Policy '${name}' requires a displayName"
            continue
        fi

        if [[ "$policy_rule" == "null" ]]; then
            epac_log_error "Policy '${name}' requires a policyRule"
            continue
        fi

        local id="${deployment_root_scope}/providers/Microsoft.Authorization/policyDefinitions/${name}"

        # Duplicate check
        local is_dup
        is_dup="$(echo "$duplicate_tracking" | jq --arg id "$id" 'has($id)')"
        if [[ "$is_dup" == "true" ]]; then
            epac_log_error "Duplicate policy definition: ${name} (from ${file})"
            continue
        fi
        duplicate_tracking="$(echo "$duplicate_tracking" | jq --arg id "$id" --arg f "$file" '.[$id] = $f')"

        # Extract role definition IDs
        local role_ids
        role_ids="$(echo "$policy_rule" | jq '.then.details // null | if type == "object" then .roleDefinitionIds // null else null end')"
        if [[ "$role_ids" != "null" ]]; then
            policy_role_ids="$(echo "$policy_role_ids" | jq --arg id "$id" --argjson r "$role_ids" '.[$id] = $r')"
        fi

        # Build definition object
        local definition
        definition="$(jq -n \
            --arg id "$id" \
            --arg name "$name" \
            --arg sid "$deployment_root_scope" \
            --arg dn "$display_name" \
            --arg desc "$description" \
            --arg mode "$mode" \
            --arg ver "$version" \
            --argjson meta "$metadata" \
            --argjson params "$parameters" \
            --argjson rule "$policy_rule" \
            '{
                id: $id, name: $name, scopeId: $sid,
                displayName: $dn, description: $desc,
                mode: $mode, version: $ver,
                metadata: $meta, parameters: $params,
                policyRule: $rule
            }')"

        # Add to allDefinitions
        all_definitions="$(echo "$all_definitions" | jq --arg id "$id" --argjson d "$definition" '.policydefinitions[$id] = $d')"

        # Compare with deployed
        local deployed_def
        deployed_def="$(echo "$delete_candidates" | jq --arg id "$id" '.[$id] // null')"

        if [[ "$deployed_def" != "null" ]]; then
            # Remove from delete candidates
            delete_candidates="$(echo "$delete_candidates" | jq --arg id "$id" 'del(.[$id])')"

            # Get deployed properties
            local deployed_props
            deployed_props="$(echo "$deployed_def" | jq 'if .properties then .properties else . end')"

            # Compare fields
            local dn_match desc_match mode_match
            local deployed_dn deployed_desc deployed_mode
            deployed_dn="$(echo "$deployed_props" | jq -r '.displayName // empty')"
            deployed_desc="$(echo "$deployed_props" | jq -r '.description // empty')"
            deployed_mode="$(echo "$deployed_props" | jq -r '.mode // "All"')"

            [[ "$deployed_dn" == "$display_name" ]] && dn_match="true" || dn_match="false"
            [[ "$deployed_desc" == "$description" ]] && desc_match="true" || desc_match="false"
            [[ "$deployed_mode" == "$mode" ]] && mode_match="true" || mode_match="false"

            # Metadata match
            local deployed_metadata
            deployed_metadata="$(echo "$deployed_props" | jq '.metadata // {}')"
            local meta_result
            meta_result="$(epac_confirm_metadata_matches "$deployed_metadata" "$metadata")"
            local meta_match change_pac_owner
            meta_match="$(echo "$meta_result" | jq -r '.match')"
            change_pac_owner="$(echo "$meta_result" | jq -r '.changePacOwnerId')"

            # Parameters match
            local param_result
            param_result="$(epac_confirm_parameters_definition_match \
                "$(echo "$deployed_props" | jq '.parameters // null')" \
                "$parameters")"
            local param_match param_incompatible
            param_match="$(echo "$param_result" | jq -r '.match')"
            param_incompatible="$(echo "$param_result" | jq -r '.incompatible')"

            # Policy rule match
            local rule_match
            if epac_deep_equal "$(echo "$deployed_props" | jq '.policyRule // null')" "$policy_rule"; then
                rule_match="true"
            else
                rule_match="false"
            fi

            if [[ "$dn_match" == "true" && "$desc_match" == "true" && "$mode_match" == "true" && \
                  "$meta_match" == "true" && "$change_pac_owner" == "false" && \
                  "$param_match" == "true" && "$rule_match" == "true" ]]; then
                definitions_unchanged=$((definitions_unchanged + 1))
            else
                # Build changes string
                local changes=()
                [[ "$param_incompatible" == "true" ]] && changes+=("param-incompat")
                [[ "$dn_match" != "true" ]] && changes+=("display")
                [[ "$desc_match" != "true" ]] && changes+=("description")
                [[ "$mode_match" != "true" ]] && changes+=("mode")
                [[ "$change_pac_owner" == "true" ]] && changes+=("owner")
                [[ "$meta_match" != "true" ]] && changes+=("metadata")
                [[ "$param_match" != "true" && "$param_incompatible" != "true" ]] && changes+=("param")
                [[ "$rule_match" != "true" ]] && changes+=("rule")
                local changes_str
                changes_str="$(IFS=','; echo "${changes[*]}")"

                if [[ "$param_incompatible" == "true" ]]; then
                    epac_write_status "Replace (${changes_str}): ${display_name}" "replace" 4 >&2
                    definitions_replace="$(echo "$definitions_replace" | jq --arg id "$id" --argjson d "$definition" '.[$id] = $d')"
                    replace_definitions="$(echo "$replace_definitions" | jq --arg id "$id" --argjson d "$definition" '.[$id] = $d')"
                else
                    epac_write_status "Update (${changes_str}): ${display_name}" "update" 4 >&2
                    definitions_update="$(echo "$definitions_update" | jq --arg id "$id" --argjson d "$definition" '.[$id] = $d')"
                fi
            fi
        else
            # New definition
            epac_write_status "New: ${display_name}" "new" 4 >&2
            definitions_new="$(echo "$definitions_new" | jq --arg id "$id" --argjson d "$definition" '.[$id] = $d')"
        fi
    done

    # Process delete candidates
    local del_ids
    del_ids="$(echo "$delete_candidates" | jq -r 'keys[]' 2>/dev/null)" || del_ids=""
    for del_id in $del_ids; do
        local del_def
        del_def="$(echo "$delete_candidates" | jq --arg id "$del_id" '.[$id]')"
        local del_props
        del_props="$(echo "$del_def" | jq 'if .properties then .properties else . end')"
        local del_dn
        del_dn="$(echo "$del_props" | jq -r '.displayName // empty')"
        local del_pac_owner
        del_pac_owner="$(echo "$del_def" | jq -r '.pacOwner // "unknownOwner"')"

        if epac_confirm_delete_for_strategy "$del_pac_owner" "$strategy"; then
            epac_write_status "Delete: ${del_dn}" "delete" 4 >&2
            local del_scope
            del_scope="$(echo "$del_def" | jq -r '.scope // empty')"
            [[ -z "$del_scope" ]] && del_scope="$deployment_root_scope"
            local del_name
            del_name="$(echo "$del_def" | jq -r '.name // empty')"

            local del_entry
            del_entry="$(jq -n --arg id "$del_id" --arg n "$del_name" --arg s "$del_scope" --arg dn "$del_dn" \
                '{id: $id, name: $n, scopeId: $s, displayName: $dn}')"
            definitions_delete="$(echo "$definitions_delete" | jq --arg id "$del_id" --argjson d "$del_entry" '.[$id] = $d')"

            # Remove from allDefinitions
            all_definitions="$(echo "$all_definitions" | jq --arg id "$del_id" 'del(.policydefinitions[$id])')"
        fi
    done

    _epac_emit_policy_plan_result "$definitions_new" "$definitions_update" "$definitions_replace" \
        "$definitions_delete" "$definitions_unchanged" "$all_definitions" "$replace_definitions" "$policy_role_ids"
}

# ─── Helper: emit plan result JSON ──────────────────────────────────────────

_epac_emit_policy_plan_result() {
    local d_new="$1" d_update="$2" d_replace="$3" d_delete="$4"
    local unchanged="$5" all_defs="$6" replace_defs="$7" role_ids="$8"

    local num_changes
    num_changes="$(jq -n --argjson n "$d_new" --argjson u "$d_update" --argjson r "$d_replace" --argjson d "$d_delete" \
        '($n | length) + ($u | length) + ($r | length) + ($d | length)')"

    # Use temp files to avoid "Argument list too long" for large JSON
    local _tmp_ad _tmp_rd _tmp_ri
    _tmp_ad="$(mktemp)" ; _tmp_rd="$(mktemp)" ; _tmp_ri="$(mktemp)"
    echo "$all_defs" > "$_tmp_ad"
    echo "$replace_defs" > "$_tmp_rd"
    echo "$role_ids" > "$_tmp_ri"

    jq -n \
        --argjson dn "$d_new" \
        --argjson du "$d_update" \
        --argjson dr "$d_replace" \
        --argjson dd "$d_delete" \
        --argjson nc "$num_changes" \
        --argjson nu "$unchanged" \
        --slurpfile ad "$_tmp_ad" \
        --slurpfile rd "$_tmp_rd" \
        --slurpfile ri "$_tmp_ri" \
        '{
            definitions: {
                new: $dn, update: $du, replace: $dr, delete: $dd,
                numberOfChanges: $nc, numberUnchanged: $nu
            },
            allDefinitions: $ad[0],
            replaceDefinitions: $rd[0],
            policyRoleIds: $ri[0]
        }'
    rm -f "$_tmp_ad" "$_tmp_rd" "$_tmp_ri"
}
