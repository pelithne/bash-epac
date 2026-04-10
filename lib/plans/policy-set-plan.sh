#!/usr/bin/env bash
# lib/plans/policy-set-plan.sh — Policy set (initiative) definition plan building
# Replaces: Build-PolicySetPlan.ps1, Build-PolicySetPolicyDefinitionIds.ps1
# Reads policy set definition files, resolves member policy IDs,
# imports groups, compares with deployed definitions, produces plan.

[[ -n "${_EPAC_POLICY_SET_PLAN_LOADED:-}" ]] && return 0
readonly _EPAC_POLICY_SET_PLAN_LOADED=1

_EPAC_PLAN_DIR="${BASH_SOURCE[0]%/*}"
source "${_EPAC_PLAN_DIR}/../core.sh"
source "${_EPAC_PLAN_DIR}/../json.sh"
source "${_EPAC_PLAN_DIR}/../utils.sh"
source "${_EPAC_PLAN_DIR}/../output.sh"
source "${_EPAC_PLAN_DIR}/../validators.sh"

###############################################################################
# Build policy set definition IDs
###############################################################################
# Resolves each policyDefinition entry's ID, collects role IDs and group names.
# Arguments:
#   $1 - display_name: for error messages
#   $2 - policy_definitions: JSON array of policy definition entries
#   $3 - policy_definitions_scopes: JSON array of scope IDs
#   $4 - all_policy_definitions: JSON { id: def } of all known policies
#   $5 - policy_role_ids: JSON { policyId: [roleDefId ...] }
#
# Outputs JSON:
# { valid: bool, policyDefinitions: [...], roleIds: {...}, usedGroups: {...} }

epac_build_policy_set_definition_ids() {
    local display_name="$1"
    local policy_definitions="$2"
    local policy_definitions_scopes="$3"
    local all_policy_definitions="$4"
    local policy_role_ids="$5"

    local valid="true"
    local final_defs="[]"
    local role_ids_in_set="{}"
    local used_groups="{}"

    local count
    count="$(echo "$policy_definitions" | jq 'length')"
    local i=0
    while [[ $i -lt $count ]]; do
        local entry
        entry="$(echo "$policy_definitions" | jq --argjson i "$i" '.[$i]')"

        local policy_id
        policy_id="$(echo "$entry" | jq -r '.policyDefinitionId // empty')"
        local policy_name
        policy_name="$(echo "$entry" | jq -r '.policyDefinitionName // empty')"
        local ref_id
        ref_id="$(echo "$entry" | jq -r '.policyDefinitionReferenceId // empty')"

        # Validate policyDefinitionReferenceId
        if [[ -z "$ref_id" ]]; then
            valid="false"
            epac_log_error "${display_name}: policyDefinitions entry missing policyDefinitionReferenceId"
            i=$((i + 1))
            continue
        fi

        # Validate exactly one of policyDefinitionId or policyDefinitionName
        if [[ -z "$policy_id" && -z "$policy_name" ]]; then
            valid="false"
            epac_log_error "${display_name}: policyDefinitions entry has neither policyDefinitionId nor policyDefinitionName"
            i=$((i + 1))
            continue
        fi
        if [[ -n "$policy_id" && -n "$policy_name" ]]; then
            valid="false"
            epac_log_error "${display_name}: policyDefinitions entry may only have EITHER policyDefinitionId OR policyDefinitionName"
            i=$((i + 1))
            continue
        fi

        # Resolve ID
        local resolved_id=""
        if [[ -n "$policy_id" ]]; then
            resolved_id="$(epac_confirm_policy_definition_used_exists "$policy_id" "" "$policy_definitions_scopes" "$all_policy_definitions")"
        else
            resolved_id="$(epac_confirm_policy_definition_used_exists "" "$policy_name" "$policy_definitions_scopes" "$all_policy_definitions")"
        fi

        if [[ -z "$resolved_id" || "$resolved_id" == "null" ]]; then
            valid="false"
            epac_log_error "${display_name}: policy '${policy_id}${policy_name}' not found"
            i=$((i + 1))
            continue
        fi

        # Collect role IDs from resolved policy
        local member_roles
        member_roles="$(echo "$policy_role_ids" | jq --arg id "$resolved_id" '.[$id] // null')"
        if [[ "$member_roles" != "null" ]]; then
            local rj=0
            local rcount
            rcount="$(echo "$member_roles" | jq 'length')"
            while [[ $rj -lt $rcount ]]; do
                local rid
                rid="$(echo "$member_roles" | jq -r --argjson j "$rj" '.[$j]')"
                role_ids_in_set="$(echo "$role_ids_in_set" | jq --arg r "$rid" '.[$r] = "added"')"
                rj=$((rj + 1))
            done
        fi

        # Collect used group names
        local group_names
        group_names="$(echo "$entry" | jq '.groupNames // null')"
        if [[ "$group_names" != "null" ]]; then
            local gn_count
            gn_count="$(echo "$group_names" | jq 'length')"
            local gi=0
            while [[ $gi -lt $gn_count ]]; do
                local gn
                gn="$(echo "$group_names" | jq -r --argjson i "$gi" '.[$i]')"
                used_groups="$(echo "$used_groups" | jq --arg g "$gn" '.[$g] = $g')"
                gi=$((gi + 1))
            done
        fi

        # Build final policy entry
        local final_entry
        final_entry="$(jq -n --arg ref "$ref_id" --arg pid "$resolved_id" \
            '{policyDefinitionReferenceId: $ref, policyDefinitionId: $pid}')"

        # Add optional fields
        local entry_params
        entry_params="$(echo "$entry" | jq '.parameters // null')"
        if [[ "$entry_params" != "null" ]]; then
            final_entry="$(echo "$final_entry" | jq --argjson p "$entry_params" '.parameters = $p')"
        fi
        if [[ "$group_names" != "null" ]]; then
            final_entry="$(echo "$final_entry" | jq --argjson g "$group_names" '.groupNames = $g')"
        fi
        local def_version
        def_version="$(echo "$entry" | jq -r '.definitionVersion // empty')"
        if [[ -n "$def_version" ]]; then
            final_entry="$(echo "$final_entry" | jq --arg v "$def_version" '.definitionVersion = $v')"
        fi

        final_defs="$(echo "$final_defs" | jq --argjson e "$final_entry" '. + [$e]')"
        i=$((i + 1))
    done

    jq -n --argjson v "$valid" --argjson pd "$final_defs" \
        --argjson ri "$role_ids_in_set" --argjson ug "$used_groups" \
        '{valid: $v, policyDefinitions: $pd, roleIds: $ri, usedGroups: $ug}'
}

###############################################################################
# Build policy set definition plan
###############################################################################
# Arguments: same shape as epac_build_policy_plan
#   $1 - definitions_root_folder
#   $2 - pac_environment: JSON
#   $3 - deployed_definitions: JSON { managed:{}, readOnly:{} }
#   $4 - all_definitions: JSON { policydefinitions:{}, policysetdefinitions:{} }
#   $5 - replace_definitions: JSON { id: def }
#   $6 - policy_role_ids: JSON { policyId: [roleDefId] }
#   $7 - detailed_output: "true"|"false"
#
# Outputs JSON (same shape as policy plan result, but for sets)

epac_build_policy_set_plan() {
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
    local policy_defs_scopes
    policy_defs_scopes="$(echo "$pac_environment" | jq '.policyDefinitionsScopes // []')"

    local delete_candidates
    delete_candidates="$(echo "$deployed_definitions" | jq '.managed // {}')"

    local defs_new="{}"
    local defs_update="{}"
    local defs_replace="{}"
    local defs_delete="{}"
    local defs_unchanged=0
    local defs_ignored=0
    local duplicate_tracking="{}"

    local excluded_files
    excluded_files="$(echo "$pac_environment" | jq '.desiredState.excludedPolicySetDefinitionFiles // []')"

    if [[ ! -d "$definitions_root_folder" ]]; then
        epac_write_status "Policy set definitions folder not found: ${definitions_root_folder}" "warning" 2 >&2
        _epac_emit_policy_set_plan_result "$defs_new" "$defs_update" "$defs_replace" "$defs_delete" \
            "$defs_unchanged" "$all_definitions" "$replace_definitions" "$policy_role_ids"
        return 0
    fi

    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$definitions_root_folder" -type f \( -name '*.json' -o -name '*.jsonc' \) -print0 2>/dev/null | sort -z)

    local file_count=${#files[@]}
    epac_write_status "Processing ${file_count} policy set definition files" "info" 2 >&2

    for file in "${files[@]}"; do
        local filename
        filename="$(basename "$file")"

        # Check exclusions
        local is_excluded
        is_excluded="$(echo "$excluded_files" | jq --arg f "$filename" 'map(select(. == $f)) | length > 0')"
        if [[ "$is_excluded" == "true" ]]; then
            epac_write_status "Excluded: ${filename}" "skip" 4 >&2
            defs_ignored=$((defs_ignored + 1))
            continue
        fi

        # Parse
        local definition_object
        if ! definition_object="$(epac_read_jsonc "$file")"; then
            epac_log_error "Failed to parse: ${file}"
            continue
        fi

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
        local version
        version="$(echo "$def_props" | jq -r '.version // empty')"
        local parameters
        parameters="$(echo "$def_props" | jq '.parameters // null')"
        local policy_definitions
        policy_definitions="$(echo "$def_props" | jq '.policyDefinitions // null')"
        local policy_definition_groups
        policy_definition_groups="$(echo "$def_props" | jq '.policyDefinitionGroups // null')"
        local import_groups
        import_groups="$(echo "$def_props" | jq '.importPolicyDefinitionGroups // null')"

        # Set pacOwnerId
        metadata="$(echo "$metadata" | jq --arg pid "$pac_owner_id" '.pacOwnerId = $pid')"

        # Cloud filter
        local cloud_envs
        cloud_envs="$(echo "$metadata" | jq '.epacCloudEnvironments // null')"
        if [[ "$cloud_envs" != "null" ]]; then
            local pac_cloud
            pac_cloud="$(echo "$pac_environment" | jq -r '.cloud // "AzureCloud"')"
            local cloud_match
            cloud_match="$(echo "$cloud_envs" | jq --arg c "$pac_cloud" 'map(select(ascii_downcase == ($c | ascii_downcase))) | length > 0')"
            if [[ "$cloud_match" != "true" ]]; then
                defs_ignored=$((defs_ignored + 1))
                continue
            fi
        fi

        # Set deployedBy
        if [[ -n "$deployed_by" ]]; then
            metadata="$(echo "$metadata" | jq --arg db "$deployed_by" 'if has("deployedBy") then . else .deployedBy = $db end')"
        fi

        # Validations
        if [[ -z "$name" ]]; then
            epac_log_error "Policy set from file '${file}' requires a name"
            continue
        fi
        if ! epac_confirm_valid_policy_resource_name "$name"; then
            epac_log_error "Policy set '${name}' has invalid characters in name"
            continue
        fi
        if [[ -z "$display_name" ]]; then
            epac_log_error "Policy set '${name}' requires a displayName"
            continue
        fi
        if [[ "$policy_definitions" == "null" ]]; then
            epac_log_error "Policy set '${name}' requires policyDefinitions array"
            continue
        fi
        local pd_type
        pd_type="$(echo "$policy_definitions" | jq -r 'type')"
        if [[ "$pd_type" != "array" ]]; then
            epac_log_error "Policy set '${name}': policyDefinitions must be an array"
            continue
        fi
        local pd_len
        pd_len="$(echo "$policy_definitions" | jq 'length')"
        if [[ "$pd_len" -eq 0 ]]; then
            epac_log_error "Policy set '${name}': policyDefinitions array is empty"
            continue
        fi

        local id="${deployment_root_scope}/providers/Microsoft.Authorization/policySetDefinitions/${name}"

        # Duplicate check
        local is_dup
        is_dup="$(echo "$duplicate_tracking" | jq --arg id "$id" 'has($id)')"
        if [[ "$is_dup" == "true" ]]; then
            epac_log_error "Duplicate policy set definition: ${name} (from ${file})"
            continue
        fi
        duplicate_tracking="$(echo "$duplicate_tracking" | jq --arg id "$id" --arg f "$file" '.[$id] = $f')"

        # Resolve policy definition IDs
        local all_policy_defs
        all_policy_defs="$(echo "$all_definitions" | jq '.policydefinitions // {}')"
        local id_result
        id_result="$(epac_build_policy_set_definition_ids "$display_name" "$policy_definitions" \
            "$policy_defs_scopes" "$all_policy_defs" "$policy_role_ids")"

        local valid_defs
        valid_defs="$(echo "$id_result" | jq -r '.valid')"
        local policy_defs_final
        policy_defs_final="$(echo "$id_result" | jq '.policyDefinitions')"
        local role_ids_in_set
        role_ids_in_set="$(echo "$id_result" | jq '.roleIds')"
        local used_groups
        used_groups="$(echo "$id_result" | jq '.usedGroups')"

        if [[ "$valid_defs" != "true" ]]; then
            continue
        fi

        # Add set-level role IDs
        local set_role_count
        set_role_count="$(echo "$role_ids_in_set" | jq 'length')"
        if [[ $set_role_count -gt 0 ]]; then
            local role_keys
            role_keys="$(echo "$role_ids_in_set" | jq -r 'keys[]')"
            local role_arr="[]"
            for rk in $role_keys; do
                role_arr="$(echo "$role_arr" | jq --arg r "$rk" '. + [$r]')"
            done
            policy_role_ids="$(echo "$policy_role_ids" | jq --arg id "$id" --argjson r "$role_arr" '.[$id] = $r')"
        fi

        # Process policy definition groups
        local groups_table="{}"
        if [[ "$policy_definition_groups" != "null" ]]; then
            local g_count
            g_count="$(echo "$policy_definition_groups" | jq 'length')"
            local gi=0
            while [[ $gi -lt $g_count ]]; do
                local grp
                grp="$(echo "$policy_definition_groups" | jq --argjson i "$gi" '.[$i]')"
                local grp_name
                grp_name="$(echo "$grp" | jq -r '.name')"
                groups_table="$(echo "$groups_table" | jq --arg n "$grp_name" --argjson g "$grp" '.[$n] = $g')"
                gi=$((gi + 1))
            done

            # Validate all used groups are defined
            local missing_group_names
            missing_group_names="$(jq -n --argjson ug "$used_groups" --argjson gt "$groups_table" \
                '[$ug | keys[] | select(. as $k | $gt | has($k) | not)]')"
            local missing_count
            missing_count="$(echo "$missing_group_names" | jq 'length')"
            if [[ $missing_count -gt 0 ]]; then
                local missing_str
                missing_str="$(echo "$missing_group_names" | jq -r 'join(", ")')"
                epac_log_error "Policy set '${name}': PolicyDefinitionGroups not found: ${missing_str}"
                continue
            fi
        fi

        # Import groups from built-in policy sets
        if [[ "$import_groups" != "null" ]]; then
            local imp_count
            imp_count="$(echo "$import_groups" | jq 'length')"
            local ii=0
            local remaining_groups
            remaining_groups="$(echo "$used_groups" | jq 'length')"

            while [[ $ii -lt $imp_count && $remaining_groups -gt 0 ]]; do
                local import_set_id
                import_set_id="$(echo "$import_groups" | jq -r --argjson i "$ii" '.[$i]')"

                # Ensure full ID
                if [[ "$import_set_id" != /providers/* ]]; then
                    import_set_id="/providers/Microsoft.Authorization/policySetDefinitions/${import_set_id}"
                fi

                local imported_set
                imported_set="$(echo "$deployed_definitions" | jq --arg id "$import_set_id" '.readOnly[$id] // null')"
                if [[ "$imported_set" == "null" ]]; then
                    epac_log_error "Policy set '${name}': import set '${import_set_id}' not found in read-only definitions"
                    ii=$((ii + 1))
                    continue
                fi

                local imported_groups
                imported_groups="$(echo "$imported_set" | jq '.properties.policyDefinitionGroups // []')"
                local ig_count
                ig_count="$(echo "$imported_groups" | jq 'length')"

                if [[ $ig_count -eq 0 ]]; then
                    epac_log_error "Policy set '${name}': import set '${import_set_id}' has no PolicyDefinitionGroups"
                    ii=$((ii + 1))
                    continue
                fi

                local ij=0
                while [[ $ij -lt $ig_count ]]; do
                    local imp_group
                    imp_group="$(echo "$imported_groups" | jq --argjson j "$ij" '.[$j]')"
                    local imp_gn
                    imp_gn="$(echo "$imp_group" | jq -r '.name')"

                    local is_used
                    is_used="$(echo "$used_groups" | jq --arg g "$imp_gn" 'has($g)')"
                    if [[ "$is_used" == "true" ]]; then
                        used_groups="$(echo "$used_groups" | jq --arg g "$imp_gn" 'del(.[$g])')"
                        groups_table="$(echo "$groups_table" | jq --arg n "$imp_gn" --argjson g "$imp_group" '.[$n] = $g')"

                        local gt_count
                        gt_count="$(echo "$groups_table" | jq 'length')"
                        if [[ $gt_count -ge 1000 ]]; then
                            remaining_groups="$(echo "$used_groups" | jq 'length')"
                            if [[ $remaining_groups -gt 0 ]]; then
                                epac_log_warning "Too many PolicyDefinitionGroups (1000+) — ignoring remaining imports" >&2
                            fi
                            break 2  # break out of both loops
                        fi
                    fi
                    ij=$((ij + 1))
                done

                remaining_groups="$(echo "$used_groups" | jq 'length')"
                ii=$((ii + 1))
            done
        fi

        # Finalize groups array (sorted by name)
        local groups_final="null"
        local gt_count
        gt_count="$(echo "$groups_table" | jq 'length')"
        if [[ $gt_count -gt 0 ]]; then
            groups_final="$(echo "$groups_table" | jq '[.[] | .] | sort_by(.name)')"
        fi

        # Build definition object
        local definition
        definition="$(jq -n \
            --arg id "$id" \
            --arg name "$name" \
            --arg sid "$deployment_root_scope" \
            --arg dn "$display_name" \
            --arg desc "$description" \
            --arg ver "$version" \
            --argjson meta "$metadata" \
            --argjson params "$parameters" \
            --argjson pd "$policy_defs_final" \
            --argjson pdg "$groups_final" \
            '{
                id: $id, name: $name, scopeId: $sid,
                displayName: $dn, description: $desc,
                version: $ver, metadata: $meta,
                parameters: $params,
                policyDefinitions: $pd,
                policyDefinitionGroups: $pdg
            }')"

        # Add to allDefinitions
        all_definitions="$(echo "$all_definitions" | jq --arg id "$id" --argjson d "$definition" '.policysetdefinitions[$id] = $d')"

        # Compare with deployed
        local deployed_def
        deployed_def="$(echo "$delete_candidates" | jq --arg id "$id" '.[$id] // null')"

        if [[ "$deployed_def" != "null" ]]; then
            delete_candidates="$(echo "$delete_candidates" | jq --arg id "$id" 'del(.[$id])')"

            local deployed_props
            deployed_props="$(echo "$deployed_def" | jq 'if .properties then .properties else . end')"

            # Compare fields
            local dn_match desc_match
            local deployed_dn deployed_desc
            deployed_dn="$(echo "$deployed_props" | jq -r '.displayName // empty')"
            deployed_desc="$(echo "$deployed_props" | jq -r '.description // empty')"
            [[ "$deployed_dn" == "$display_name" ]] && dn_match="true" || dn_match="false"
            [[ "$deployed_desc" == "$description" ]] && desc_match="true" || desc_match="false"

            # Metadata
            local deployed_metadata
            deployed_metadata="$(echo "$deployed_props" | jq '.metadata // {}')"
            local meta_result
            meta_result="$(epac_confirm_metadata_matches "$deployed_metadata" "$metadata")"
            local meta_match change_pac_owner
            meta_match="$(echo "$meta_result" | jq -r '.match')"
            change_pac_owner="$(echo "$meta_result" | jq -r '.changePacOwnerId')"

            # Parameters
            local param_result
            param_result="$(epac_confirm_parameters_definition_match \
                "$(echo "$deployed_props" | jq '.parameters // null')" \
                "$parameters")"
            local param_match param_incompatible
            param_match="$(echo "$param_result" | jq -r '.match')"
            param_incompatible="$(echo "$param_result" | jq -r '.incompatible')"

            # Policy definitions in set (ordered comparison)
            local pd_match
            if epac_confirm_policy_definitions_in_set_match \
                "$(echo "$deployed_props" | jq '.policyDefinitions // null')" \
                "$policy_defs_final" \
                "$(echo "$all_definitions" | jq '.policydefinitions // {}')"; then
                pd_match="true"
            else
                pd_match="false"
            fi

            # Policy definition groups
            local pdg_match
            if epac_deep_equal "$(echo "$deployed_props" | jq '.policyDefinitionGroups // null')" "$groups_final"; then
                pdg_match="true"
            else
                pdg_match="false"
            fi
            local deleted_groups="false"
            if [[ "$pdg_match" == "false" ]]; then
                if [[ "$groups_final" == "null" ]] || [[ "$(echo "$groups_final" | jq 'length')" -eq 0 ]]; then
                    deleted_groups="true"
                fi
            fi

            # Check if set contains replaced policies
            local contains_replaced="false"
            local pdi=0
            local pd_final_count
            pd_final_count="$(echo "$policy_defs_final" | jq 'length')"
            while [[ $pdi -lt $pd_final_count ]]; do
                local member_id
                member_id="$(echo "$policy_defs_final" | jq -r --argjson i "$pdi" '.[$i].policyDefinitionId')"
                local is_replaced
                is_replaced="$(echo "$replace_definitions" | jq --arg id "$member_id" 'has($id)')"
                if [[ "$is_replaced" == "true" ]]; then
                    contains_replaced="true"
                    break
                fi
                pdi=$((pdi + 1))
            done

            if [[ "$contains_replaced" == "false" && "$dn_match" == "true" && "$desc_match" == "true" && \
                  "$meta_match" == "true" && "$change_pac_owner" == "false" && \
                  "$param_match" == "true" && "$pd_match" == "true" && "$pdg_match" == "true" ]]; then
                defs_unchanged=$((defs_unchanged + 1))
            else
                # Build changes string
                local changes=()
                [[ "$param_incompatible" == "true" ]] && changes+=("paramIncompat")
                [[ "$contains_replaced" == "true" ]] && changes+=("replacedPolicy")
                [[ "$dn_match" != "true" ]] && changes+=("displayName")
                [[ "$desc_match" != "true" ]] && changes+=("description")
                [[ "$change_pac_owner" == "true" ]] && changes+=("owner")
                [[ "$meta_match" != "true" ]] && changes+=("metadata")
                [[ "$param_match" != "true" && "$param_incompatible" != "true" ]] && changes+=("param")
                [[ "$pd_match" != "true" ]] && changes+=("policies")
                if [[ "$pdg_match" != "true" ]]; then
                    [[ "$deleted_groups" == "true" ]] && changes+=("groupsDeleted") || changes+=("groups")
                fi
                local changes_str
                changes_str="$(IFS=','; echo "${changes[*]}")"

                if [[ "$param_incompatible" == "true" || "$contains_replaced" == "true" ]]; then
                    epac_write_status "Replace (${changes_str}): ${display_name}" "replace" 4 >&2
                    defs_replace="$(echo "$defs_replace" | jq --arg id "$id" --argjson d "$definition" '.[$id] = $d')"
                    replace_definitions="$(echo "$replace_definitions" | jq --arg id "$id" --argjson d "$definition" '.[$id] = $d')"
                else
                    epac_write_status "Update (${changes_str}): ${display_name}" "update" 4 >&2
                    defs_update="$(echo "$defs_update" | jq --arg id "$id" --argjson d "$definition" '.[$id] = $d')"
                fi
            fi
        else
            # New definition
            epac_write_status "New: ${display_name}" "new" 4 >&2
            defs_new="$(echo "$defs_new" | jq --arg id "$id" --argjson d "$definition" '.[$id] = $d')"
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
            defs_delete="$(echo "$defs_delete" | jq --arg id "$del_id" --argjson d "$del_entry" '.[$id] = $d')"

            all_definitions="$(echo "$all_definitions" | jq --arg id "$del_id" 'del(.policysetdefinitions[$id])')"
        fi
    done

    _epac_emit_policy_set_plan_result "$defs_new" "$defs_update" "$defs_replace" "$defs_delete" \
        "$defs_unchanged" "$all_definitions" "$replace_definitions" "$policy_role_ids"
}

# ─── Helper: emit plan result JSON ──────────────────────────────────────────

_epac_emit_policy_set_plan_result() {
    local d_new="$1" d_update="$2" d_replace="$3" d_delete="$4"
    local unchanged="$5" all_defs="$6" replace_defs="$7" role_ids="$8"

    local num_changes
    num_changes="$(jq -n --argjson n "$d_new" --argjson u "$d_update" --argjson r "$d_replace" --argjson d "$d_delete" \
        '($n | length) + ($u | length) + ($r | length) + ($d | length)')"

    jq -n \
        --argjson dn "$d_new" \
        --argjson du "$d_update" \
        --argjson dr "$d_replace" \
        --argjson dd "$d_delete" \
        --argjson nc "$num_changes" \
        --argjson nu "$unchanged" \
        --argjson ad "$all_defs" \
        --argjson rd "$replace_defs" \
        --argjson ri "$role_ids" \
        '{
            definitions: {
                new: $dn, update: $du, replace: $dr, delete: $dd,
                numberOfChanges: $nc, numberUnchanged: $nu
            },
            allDefinitions: $ad,
            replaceDefinitions: $rd,
            policyRoleIds: $ri
        }'
}
