#!/usr/bin/env bash
# lib/plans/assignment-plan.sh — Assignment plan building
# Replaces: Build-AssignmentPlan.ps1, Build-AssignmentDefinitionNode.ps1,
#           Build-AssignmentDefinitionEntry.ps1, Build-AssignmentDefinitionAtLeaf.ps1,
#           Build-AssignmentParameterObject.ps1, Build-AssignmentIdentityChanges.ps1,
#           Merge-AssignmentParametersEx.ps1

[[ -n "${_EPAC_ASSIGNMENT_PLAN_LOADED:-}" ]] && return 0
readonly _EPAC_ASSIGNMENT_PLAN_LOADED=1

_EPAC_APLAN_DIR="${BASH_SOURCE[0]%/*}"
source "${_EPAC_APLAN_DIR}/../core.sh"
source "${_EPAC_APLAN_DIR}/../json.sh"
source "${_EPAC_APLAN_DIR}/../utils.sh"
source "${_EPAC_APLAN_DIR}/../output.sh"
source "${_EPAC_APLAN_DIR}/../validators.sh"
source "${_EPAC_APLAN_DIR}/../transforms.sh"
source "${_EPAC_APLAN_DIR}/../azure-resources.sh"

###############################################################################
# Helper: Add pac-selected value
###############################################################################
# Extracts an environment-specific value from a node property.
# The property can be either a direct value or an object keyed by pacSelector.
# Arguments:
#   $1 - property_value: JSON value (scalar/array/object or pac-keyed object)
#   $2 - pac_selector: environment selector string
# Outputs: the selected value, or "null" if not found

_epac_add_selected_pac_value() {
    local property_value="$1"
    local pac_selector="$2"

    if epac_is_null_or_empty "$property_value"; then
        echo "null"
        return 0
    fi

    local val_type
    val_type="$(echo "$property_value" | jq -r 'type')"

    if [[ "$val_type" != "object" ]]; then
        # Direct value (string, number, array, boolean)
        echo "$property_value"
        return 0
    fi

    # Check if it's a pac-selector keyed object
    local has_selector
    has_selector="$(echo "$property_value" | jq --arg sel "$pac_selector" 'has($sel)')"
    if [[ "$has_selector" == "true" ]]; then
        echo "$property_value" | jq --arg sel "$pac_selector" '.[$sel]'
        return 0
    fi

    # Check for wildcard
    local has_star
    has_star="$(echo "$property_value" | jq 'has("*")')"
    if [[ "$has_star" == "true" ]]; then
        echo "$property_value" | jq '.["*"]'
        return 0
    fi

    # Treat as direct object value (not pac-selector keyed)
    echo "$property_value"
}

###############################################################################
# Helper: Add pac-selected array
###############################################################################
# Extracts environment-specific array values and appends to existing list.
# Arguments:
#   $1 - existing_list: JSON array
#   $2 - property_value: JSON value (array or pac-keyed object with arrays)
#   $3 - pac_selector: environment selector string
# Outputs: merged JSON array

_epac_add_selected_pac_array() {
    local existing_list="$1"
    local property_value="$2"
    local pac_selector="$3"

    if epac_is_null_or_empty "$property_value"; then
        echo "$existing_list"
        return 0
    fi

    local val_type
    val_type="$(echo "$property_value" | jq -r 'type')"

    local selected="null"
    if [[ "$val_type" == "array" ]]; then
        selected="$property_value"
    elif [[ "$val_type" == "object" ]]; then
        local has_sel
        has_sel="$(echo "$property_value" | jq --arg sel "$pac_selector" 'has($sel)')"
        if [[ "$has_sel" == "true" ]]; then
            selected="$(echo "$property_value" | jq --arg sel "$pac_selector" '.[$sel]')"
        else
            local has_star
            has_star="$(echo "$property_value" | jq 'has("*")')"
            if [[ "$has_star" == "true" ]]; then
                selected="$(echo "$property_value" | jq '.["*"]')"
            fi
        fi
    fi

    if [[ "$selected" == "null" ]] || epac_is_null_or_empty "$selected"; then
        echo "$existing_list"
        return 0
    fi

    # Ensure selected is an array
    local sel_type
    sel_type="$(echo "$selected" | jq -r 'type')"
    if [[ "$sel_type" != "array" ]]; then
        selected="$(echo "$selected" | jq '[.]')"
    fi

    jq -n --argjson a "$existing_list" --argjson b "$selected" '$a + $b'
}

###############################################################################
# Build assignment definition entry
###############################################################################
# Validates and normalizes a definitionEntry or definitionEntryList item.
# Returns JSON: { valid, id, isPolicySet, displayName, nonComplianceMessages,
#                 policyName, policyId, policySetName, policySetId, append }

_epac_build_assignment_definition_entry() {
    local entry_obj="$1"
    local policy_definitions_scopes="$2"
    local node_name="$3"

    # Large data read from $EPAC_TMP_DIR
    local all_policy_definitions all_policy_set_definitions
    all_policy_definitions="$(cat "$EPAC_TMP_DIR/all_policy_defs.json")"
    all_policy_set_definitions="$(cat "$EPAC_TMP_DIR/all_policy_set_defs.json")"

    # Count identifiers present
    local policy_name policy_id policy_set_name policy_set_id initiative_name initiative_id
    policy_name="$(echo "$entry_obj" | jq -r '.policyName // empty')"
    policy_id="$(echo "$entry_obj" | jq -r '.policyId // empty')"
    policy_set_name="$(echo "$entry_obj" | jq -r '.policySetName // empty')"
    policy_set_id="$(echo "$entry_obj" | jq -r '.policySetId // empty')"
    initiative_name="$(echo "$entry_obj" | jq -r '.initiativeName // empty')"
    initiative_id="$(echo "$entry_obj" | jq -r '.initiativeId // empty')"

    # initiativeName/initiativeId are aliases for policySetName/policySetId
    [[ -n "$initiative_name" && -z "$policy_set_name" ]] && policy_set_name="$initiative_name"
    [[ -n "$initiative_id" && -z "$policy_set_id" ]] && policy_set_id="$initiative_id"

    local id_count=0
    [[ -n "$policy_name" ]] && id_count=$((id_count + 1))
    [[ -n "$policy_id" ]] && id_count=$((id_count + 1))
    [[ -n "$policy_set_name" ]] && id_count=$((id_count + 1))
    [[ -n "$policy_set_id" ]] && id_count=$((id_count + 1))

    if [[ $id_count -ne 1 ]]; then
        epac_log_error "Node ${node_name}: exactly one of policyName, policyId, policySetName, policySetId required (found ${id_count})" >&2
        jq -n '{valid: false}'
        return 0
    fi

    local is_policy_set="false"
    local resolved_id=""
    local display_name
    display_name="$(echo "$entry_obj" | jq -r '.displayName // empty')"

    if [[ -n "$policy_name" || -n "$policy_id" ]]; then
        # Policy definition
        if resolved_id="$(epac_confirm_policy_definition_used_exists "$policy_id" "$policy_name" "$policy_definitions_scopes" "$all_policy_definitions")"; then
            is_policy_set="false"
        else
            jq -n '{valid: false}'
            return 0
        fi
    else
        # Policy set definition
        if resolved_id="$(epac_confirm_policy_set_definition_used_exists "$policy_set_id" "$policy_set_name" "$policy_definitions_scopes" "$all_policy_set_definitions")"; then
            is_policy_set="true"
        else
            jq -n '{valid: false}'
            return 0
        fi
    fi

    local append
    append="$(echo "$entry_obj" | jq '.append // false')"

    jq -n \
        --arg id "$resolved_id" \
        --argjson isPolicySet "$is_policy_set" \
        --arg dn "$display_name" \
        --argjson append "$append" \
        --arg pn "$policy_name" \
        --arg pid "$policy_id" \
        --arg psn "$policy_set_name" \
        --arg psid "$policy_set_id" \
        '{
            valid: true,
            id: $id,
            isPolicySet: $isPolicySet,
            displayName: $dn,
            append: $append,
            policyName: $pn,
            policyId: $pid,
            policySetName: $psn,
            policySetId: $psid
        }'
}

###############################################################################
# Build assignment parameter object
###############################################################################
# Filters assignment parameters to only those in the policy definition.
# Omits parameters where value equals the default.
# Arguments:
#   $1 - assignment_parameters: JSON object of parameter values
#   $2 - parameters_in_definition: JSON object of parameter definitions
# Outputs: JSON object of filtered parameters

_epac_build_assignment_parameter_object() {
    local assignment_parameters="$1"
    local parameters_in_definition="$2"

    if epac_is_null_or_empty "$parameters_in_definition" || epac_is_null_or_empty "$assignment_parameters"; then
        echo "{}"
        return 0
    fi

    jq -n --argjson ap "$assignment_parameters" --argjson pd "$parameters_in_definition" '
        reduce ($pd | keys[]) as $pname (
            {};
            if ($ap | has($pname)) then
                ($ap[$pname]) as $val |
                ($pd[$pname].defaultValue // null) as $dv |
                if $dv == null then
                    .[$pname] = $val
                elif ($dv == $val) then
                    .
                else
                    .[$pname] = $val
                end
            else
                .
            end
        )
    '
}

###############################################################################
# Build assignment identity changes
###############################################################################
# Compares existing vs desired identity, calculates role assignment changes.
# Arguments:
#   $1 - existing: deployed assignment JSON (or "null")
#   $2 - assignment: desired assignment JSON (or "null")
#   $3 - replaced_assignment: "true"|"false"
#   $4 - deployed_role_assignments_by_principal: JSON { principalId: [roles...] }
#   $5 - scope_table: JSON { scope: {...} }
# Outputs: JSON with replaced, requiresRoleChanges, numberOfChanges, etc.

_epac_build_assignment_identity_changes() {
    local existing="$1"
    local assignment="$2"
    local replaced_assignment="$3"
    local deployed_role_assignments_by_principal="$4"

    local has_existing_identity="false"
    local identity_required="false"
    local existing_identity_type="None"
    local existing_principal_id=""
    local existing_user_assigned_identity=""
    local existing_location=""
    local existing_role_assignments="[]"
    local defined_identity_type="None"
    local defined_user_assigned_identity=""
    local defined_location="global"
    local required_role_assignments="[]"

    # Extract existing identity
    if [[ "$existing" != "null" ]]; then
        local ex_identity
        ex_identity="$(echo "$existing" | jq '.identity // null')"
        local ex_type
        ex_type="$(echo "$ex_identity" | jq -r '.type // "None"')"
        if [[ "$ex_identity" != "null" && "$ex_type" != "None" ]]; then
            has_existing_identity="true"
            existing_identity_type="$ex_type"
            existing_location="$(echo "$existing" | jq -r '.location // "global"')"
            if [[ "$ex_type" == "UserAssigned" ]]; then
                existing_user_assigned_identity="$(echo "$ex_identity" | jq -r '.userAssignedIdentities | keys[0] // empty')"
                existing_principal_id="$(echo "$ex_identity" | jq -r --arg k "$existing_user_assigned_identity" '.userAssignedIdentities[$k].principalId // empty')"
            else
                existing_principal_id="$(echo "$ex_identity" | jq -r '.principalId // empty')"
            fi
            if [[ -n "$existing_principal_id" ]]; then
                local has_roles
                has_roles="$(echo "$deployed_role_assignments_by_principal" | jq --arg pid "$existing_principal_id" 'has($pid)')"
                if [[ "$has_roles" == "true" ]]; then
                    existing_role_assignments="$(echo "$deployed_role_assignments_by_principal" | jq --arg pid "$existing_principal_id" '.[$pid]')"
                fi
            fi
        fi
    fi

    # Extract desired identity
    if [[ "$assignment" != "null" ]]; then
        local ident_required
        ident_required="$(echo "$assignment" | jq -r '.identityRequired // false')"
        if [[ "$ident_required" == "true" ]]; then
            identity_required="true"
            local def_identity
            def_identity="$(echo "$assignment" | jq '.identity // null')"
            if [[ "$def_identity" != "null" ]]; then
                defined_identity_type="$(echo "$def_identity" | jq -r '.type // "None"')"
                if [[ "$defined_identity_type" == "UserAssigned" ]]; then
                    defined_user_assigned_identity="$(echo "$def_identity" | jq -r '.userAssignedIdentities | keys[0] // empty')"
                fi
            fi
            defined_location="$(echo "$assignment" | jq -r '.managedIdentityLocation // "global"')"
            required_role_assignments="$(echo "$assignment" | jq '.requiredRoleAssignments // []')"
        fi
    fi

    # Detect changes
    local replaced="$replaced_assignment"
    local is_new_or_deleted="false"
    local is_user_assigned="false"
    local changed_identity_strings="[]"
    local added_list="[]"
    local updated_list="[]"
    local removed_list="[]"

    if [[ "$has_existing_identity" == "true" || "$identity_required" == "true" ]]; then
        if [[ "$existing" != "null" && "$assignment" != "null" ]]; then
            # Update scenario
            if [[ "$has_existing_identity" != "$identity_required" ]]; then
                # XOR: identity added or removed
                if [[ "$has_existing_identity" == "true" ]]; then
                    changed_identity_strings="$(echo "$changed_identity_strings" | jq '. + ["removedIdentity"]')"
                else
                    changed_identity_strings="$(echo "$changed_identity_strings" | jq '. + ["addedIdentity"]')"
                fi
                replaced="true"
            else
                # Both have identity
                if [[ "$existing_location" != "$defined_location" ]]; then
                    changed_identity_strings="$(echo "$changed_identity_strings" | jq --arg s "identityLocation ${existing_location}->${defined_location}" '. + [$s]')"
                    replaced="true"
                fi
                if [[ "$existing_identity_type" != "$defined_identity_type" ]]; then
                    changed_identity_strings="$(echo "$changed_identity_strings" | jq --arg s "identityType ${existing_identity_type}->${defined_identity_type}" '. + [$s]')"
                    replaced="true"
                elif [[ "$existing_identity_type" == "UserAssigned" && "$existing_user_assigned_identity" != "$defined_user_assigned_identity" ]]; then
                    changed_identity_strings="$(echo "$changed_identity_strings" | jq '. + ["changed userAssignedIdentity"]')"
                    replaced="true"
                fi
            fi
        else
            is_new_or_deleted="true"
        fi

        if [[ "$replaced" == "true" || "$is_new_or_deleted" == "true" ]]; then
            # Remove existing roles (unless UserAssigned)
            if [[ "$has_existing_identity" == "true" ]]; then
                local ex_role_count
                ex_role_count="$(echo "$existing_role_assignments" | jq 'length')"
                if [[ $ex_role_count -gt 0 ]]; then
                    if [[ "$existing_identity_type" != "UserAssigned" ]]; then
                        removed_list="$existing_role_assignments"
                    else
                        is_user_assigned="true"
                    fi
                fi
            fi
            # Add required roles (unless UserAssigned)
            if [[ "$identity_required" == "true" ]]; then
                if [[ "$defined_identity_type" != "UserAssigned" ]]; then
                    local req_count
                    req_count="$(echo "$required_role_assignments" | jq 'length')"
                    local ri=0
                    while [[ $ri -lt $req_count ]]; do
                        local req_role
                        req_role="$(echo "$required_role_assignments" | jq --argjson i "$ri" '.[$i]')"
                        local added_entry
                        added_entry="$(jq -n --argjson rr "$req_role" --argjson a "$assignment" '{
                            assignmentId: $a.id,
                            assignmentDisplayName: ($a.displayName // ""),
                            roleDisplayName: ($rr.roleDisplayName // "Unknown"),
                            scope: $rr.scope,
                            properties: {
                                roleDefinitionId: $rr.roleDefinitionId,
                                principalId: null,
                                principalType: "ServicePrincipal",
                                description: ($rr.description // ""),
                                crossTenant: ($rr.crossTenant // false)
                            }
                        }')"
                        added_list="$(echo "$added_list" | jq --argjson e "$added_entry" '. + [$e]')"
                        ri=$((ri + 1))
                    done
                else
                    is_user_assigned="true"
                fi
            fi
        else
            # Update scenario: compare existing vs required roles
            if [[ "$existing_identity_type" != "UserAssigned" ]]; then
                # Find added/updated roles
                local req_count
                req_count="$(echo "$required_role_assignments" | jq 'length')"
                local ri=0
                while [[ $ri -lt $req_count ]]; do
                    local req_role
                    req_role="$(echo "$required_role_assignments" | jq --argjson i "$ri" '.[$i]')"
                    local req_scope req_role_def_id req_description
                    req_scope="$(echo "$req_role" | jq -r '.scope')"
                    req_role_def_id="$(echo "$req_role" | jq -r '.roleDefinitionId')"
                    req_description="$(echo "$req_role" | jq -r '.description // ""')"

                    # Search for match in existing
                    local match_result
                    match_result="$(echo "$existing_role_assignments" | jq --arg s "$req_scope" --arg r "$req_role_def_id" '
                        [.[] | select(.scope == $s and .roleDefinitionId == $r)] | first // null
                    ')"

                    local added_entry
                    added_entry="$(jq -n --argjson rr "$req_role" --argjson a "$assignment" '{
                        assignmentId: $a.id,
                        assignmentDisplayName: ($a.displayName // ""),
                        roleDisplayName: ($rr.roleDisplayName // "Unknown"),
                        scope: $rr.scope,
                        properties: {
                            roleDefinitionId: $rr.roleDefinitionId,
                            principalId: null,
                            principalType: "ServicePrincipal",
                            description: ($rr.description // ""),
                            crossTenant: ($rr.crossTenant // false)
                        }
                    }')"

                    if [[ "$match_result" != "null" ]]; then
                        # Check description change
                        local deployed_desc
                        deployed_desc="$(echo "$match_result" | jq -r '.description // ""')"
                        if [[ -n "$deployed_desc" && "$deployed_desc" != "$req_description" ]]; then
                            added_entry="$(echo "$added_entry" | jq --argjson m "$match_result" '.id = $m.id | .properties.principalId = $m.principalId')"
                            updated_list="$(echo "$updated_list" | jq --argjson e "$added_entry" '. + [$e]')"
                        fi
                    else
                        # New role assignment
                        added_list="$(echo "$added_list" | jq --argjson e "$added_entry" '. + [$e]')"
                    fi
                    ri=$((ri + 1))
                done

                # Find removed roles
                local ex_count
                ex_count="$(echo "$existing_role_assignments" | jq 'length')"
                local ei=0
                while [[ $ei -lt $ex_count ]]; do
                    local deployed_role
                    deployed_role="$(echo "$existing_role_assignments" | jq --argjson i "$ei" '.[$i]')"
                    local dep_scope dep_role_def_id
                    dep_scope="$(echo "$deployed_role" | jq -r '.scope')"
                    dep_role_def_id="$(echo "$deployed_role" | jq -r '.roleDefinitionId')"

                    local still_needed
                    still_needed="$(echo "$required_role_assignments" | jq --arg s "$dep_scope" --arg r "$dep_role_def_id" '
                        [.[] | select(.scope == $s and .roleDefinitionId == $r)] | length > 0
                    ')"
                    if [[ "$still_needed" != "true" ]]; then
                        removed_list="$(echo "$removed_list" | jq --argjson e "$deployed_role" '. + [$e]')"
                    fi
                    ei=$((ei + 1))
                done
            else
                is_user_assigned="true"
            fi
        fi
    fi

    # Calculate changes
    local number_of_changes=0
    local added_count removed_count updated_count
    added_count="$(echo "$added_list" | jq 'length')"
    updated_count="$(echo "$updated_list" | jq 'length')"
    removed_count="$(echo "$removed_list" | jq 'length')"
    number_of_changes=$((added_count + updated_count + removed_count))

    if [[ $added_count -gt 0 ]]; then
        changed_identity_strings="$(echo "$changed_identity_strings" | jq '. + ["addedRoleAssignments"]')"
    fi
    if [[ $updated_count -gt 0 ]]; then
        changed_identity_strings="$(echo "$changed_identity_strings" | jq '. + ["updatedRoleAssignments"]')"
    fi
    if [[ $removed_count -gt 0 ]]; then
        changed_identity_strings="$(echo "$changed_identity_strings" | jq '. + ["removedRoleAssignments"]')"
    fi

    jq -n \
        --argjson replaced "$replaced" \
        --argjson requiresRoleChanges "$(echo "$number_of_changes" | jq '. > 0')" \
        --argjson numberOfChanges "$number_of_changes" \
        --argjson changedIdentityStrings "$changed_identity_strings" \
        --argjson isUserAssigned "$is_user_assigned" \
        --argjson added "$added_list" \
        --argjson updated "$updated_list" \
        --argjson removed "$removed_list" \
        '{
            replaced: $replaced,
            requiresRoleChanges: $requiresRoleChanges,
            numberOfChanges: $numberOfChanges,
            changedIdentityStrings: $changedIdentityStrings,
            isUserAssigned: $isUserAssigned,
            added: $added,
            updated: $updated,
            removed: $removed
        }'
}

###############################################################################
# Merge assignment parameters from CSV
###############################################################################
# Processes CSV parameter rows into parameters and overrides.
# Arguments:
#   $1 - node_name
#   $2 - policy_set_id
#   $3 - base_assignment: JSON assignment object (modified fields returned)
#   $4 - parameter_instructions: JSON { csvParameterArray, effectColumn, parametersColumn, nonComplianceMessageColumn }
#   $5 - flat_policy_list: JSON flat list
#   $6 - combined_policy_details: JSON details
#   $7 - effect_processed_for_policy: JSON { flatPolicyEntryKey: true }
# Outputs JSON: { hasErrors, parameters, overrides, nonComplianceMessages, effectProcessed }

_epac_merge_assignment_parameters_ex() {
    local node_name="$1"
    local policy_set_id="$2"
    local base_assignment="$3"
    local parameter_instructions="$4"
    local flat_policy_list="$5"
    local effect_processed="$6"

    # Large data read from $EPAC_TMP_DIR
    local combined_policy_details
    combined_policy_details="$(cat "$EPAC_TMP_DIR/combined_policy_details.json")"

    local csv_array
    csv_array="$(echo "$parameter_instructions" | jq '.csvParameterArray // []')"
    local effect_column
    effect_column="$(echo "$parameter_instructions" | jq -r '.effectColumn // "effect"')"
    local parameters_column
    parameters_column="$(echo "$parameter_instructions" | jq -r '.parametersColumn // "parameters"')"
    local non_compliance_msg_column
    non_compliance_msg_column="$(echo "$parameter_instructions" | jq -r '.nonComplianceMessageColumn // empty')"

    local parameters
    parameters="$(echo "$base_assignment" | jq '.parameters // {}')"
    local non_compliance_messages
    non_compliance_messages="$(echo "$base_assignment" | jq '.nonComplianceMessages // []')"
    local has_errors="false"
    local overrides_by_effect="{}"

    # Merge parameters from CSV
    local csv_count
    csv_count="$(echo "$csv_array" | jq 'length')"
    local row_number=0
    local ri=0
    while [[ $ri -lt $csv_count ]]; do
        local row
        row="$(echo "$csv_array" | jq --argjson i "$ri" '.[$i]')"
        row_number=$((row_number + 1))

        local flat_key
        flat_key="$(echo "$row" | jq -r '.flatPolicyEntryKey // empty')"
        if [[ -z "$flat_key" ]]; then
            ri=$((ri + 1))
            continue
        fi

        # Merge parameters column
        local params_cell
        params_cell="$(echo "$row" | jq -r --arg col "$parameters_column" '.[$col] // empty')"
        if [[ -n "$params_cell" ]]; then
            local added_params
            if added_params="$(echo "$params_cell" | jq '.' 2>/dev/null)"; then
                parameters="$(jq -n --argjson p "$parameters" --argjson ap "$added_params" '
                    reduce ($ap | keys[]) as $k ($p; if has($k) then . else .[$k] = $ap[$k] end)
                ')"
            fi
        fi

        local name
        name="$(echo "$row" | jq -r '.name // empty')"
        local flat_entry
        flat_entry="$(echo "$flat_policy_list" | jq --arg k "$flat_key" '.[$k] // null')"
        local policy_id
        policy_id="$(echo "$row" | jq -r '.policyId // empty')"

        if [[ "$flat_entry" == "null" || -z "$name" || -z "$policy_id" ]]; then
            ri=$((ri + 1))
            continue
        fi

        # Check if this policy is in the current policy set
        local policy_set_list
        policy_set_list="$(echo "$flat_entry" | jq '.policySetList // {}')"
        local in_this_set
        in_this_set="$(echo "$policy_set_list" | jq --arg psid "$policy_set_id" 'has($psid)')"
        if [[ "$in_this_set" != "true" ]]; then
            ri=$((ri + 1))
            continue
        fi

        local per_policy_set
        per_policy_set="$(echo "$policy_set_list" | jq --arg psid "$policy_set_id" '.[$psid]')"

        # Get effect info
        local effect_parameter_name
        effect_parameter_name="$(echo "$per_policy_set" | jq -r '.effectParameterName // empty')"
        local effect_default
        effect_default="$(echo "$per_policy_set" | jq -r '.effectDefault // "Disabled"')"
        local effect_allowed_values
        effect_allowed_values="$(echo "$per_policy_set" | jq '.effectAllowedValues // []')"
        local effect_allowed_overrides
        effect_allowed_overrides="$(echo "$per_policy_set" | jq '.effectAllowedOverrides // []')"
        local is_effect_parameterized
        is_effect_parameterized="$(echo "$per_policy_set" | jq -r '.isEffectParameterized // false')"
        local policy_def_ref_id
        policy_def_ref_id="$(echo "$per_policy_set" | jq -r '.policyDefinitionReferenceId // empty')"

        # Get requested effect
        local requested_effect
        requested_effect="$(echo "$row" | jq -r --arg col "$effect_column" '.[$col] // empty')"
        local planned_effect="$requested_effect"

        # Deduplication: if already processed, adjust effect
        local is_processed
        is_processed="$(echo "$effect_processed" | jq --arg k "$flat_key" 'has($k)')"
        if [[ "$is_processed" == "true" ]]; then
            case "$requested_effect" in
                Append|Modify|Deny) planned_effect="Audit" ;;
                DeployIfNotExists) planned_effect="AuditIfNotExists" ;;
                DenyAction) planned_effect="Disabled" ;;
            esac
        else
            effect_processed="$(echo "$effect_processed" | jq --arg k "$flat_key" '.[$k] = true')"
        fi

        if [[ "$planned_effect" != "$effect_default" && -n "$planned_effect" ]]; then
            local use_overrides="false"
            local confirmed_effect=""

            if [[ "$is_effect_parameterized" == "true" ]]; then
                # Try parameter first
                confirmed_effect="$(epac_confirm_effect_is_allowed "$planned_effect" "$effect_allowed_values")"
                if [[ -z "$confirmed_effect" ]]; then
                    use_overrides="true"
                    confirmed_effect="$(epac_confirm_effect_is_allowed "$planned_effect" "$effect_allowed_overrides")"
                    if [[ -z "$confirmed_effect" && "$requested_effect" != "$planned_effect" ]]; then
                        use_overrides="false"
                        confirmed_effect="$(epac_confirm_effect_is_allowed "$requested_effect" "$effect_allowed_values")"
                        if [[ -z "$confirmed_effect" ]]; then
                            use_overrides="true"
                            confirmed_effect="$(epac_confirm_effect_is_allowed "$requested_effect" "$effect_allowed_overrides")"
                        fi
                    fi
                fi
            else
                use_overrides="true"
                confirmed_effect="$(epac_confirm_effect_is_allowed "$planned_effect" "$effect_allowed_overrides")"
                if [[ -z "$confirmed_effect" ]]; then
                    confirmed_effect="$(epac_confirm_effect_is_allowed "$requested_effect" "$effect_allowed_overrides")"
                fi
            fi

            if [[ -z "$confirmed_effect" ]]; then
                epac_log_error "Node ${node_name}: CSV row ${row_number} for Policy '${name}': effect '${planned_effect}' not allowed" >&2
                has_errors="true"
                ri=$((ri + 1))
                continue
            elif [[ "$confirmed_effect" != "$effect_default" ]]; then
                if [[ "$use_overrides" == "true" ]]; then
                    overrides_by_effect="$(echo "$overrides_by_effect" | jq --arg e "$confirmed_effect" --arg pid "$policy_def_ref_id" '
                        if has($e) then .[$e] += [$pid] else .[$e] = [$pid] end
                    ')"
                else
                    parameters="$(echo "$parameters" | jq --arg pn "$effect_parameter_name" --arg v "$confirmed_effect" '.[$pn] = $v')"
                fi
            fi
        fi

        # Non-compliance messages from CSV
        if [[ -n "$non_compliance_msg_column" ]]; then
            local ncm
            ncm="$(echo "$row" | jq -r --arg col "$non_compliance_msg_column" '.[$col] // empty')"
            if [[ -n "$ncm" ]]; then
                non_compliance_messages="$(echo "$non_compliance_messages" | jq --arg msg "$ncm" --arg pdrid "$policy_def_ref_id" '. + [{message: $msg, policyDefinitionReferenceId: $pdrid}]')"
            fi
        fi

        ri=$((ri + 1))
    done

    # Build overrides from grouped effects (chunk at 50)
    local final_overrides="[]"
    local effects_count
    effects_count="$(echo "$overrides_by_effect" | jq 'length')"
    if [[ $effects_count -gt 0 ]]; then
        final_overrides="$(echo "$overrides_by_effect" | jq '
            [to_entries[] | .key as $effect | .value as $ids |
                range(0; (($ids | length) + 49) / 50 | floor) as $chunk |
                {
                    kind: "policyEffect",
                    value: $effect,
                    selectors: [{
                        kind: "policyDefinitionReferenceId",
                        in: $ids[$chunk * 50 : ($chunk + 1) * 50]
                    }]
                }
            ]
        ')"

        local override_count
        override_count="$(echo "$final_overrides" | jq 'length')"
        if [[ $override_count -gt 10 ]]; then
            epac_log_error "Node ${node_name}: CSV causes too many overrides (${override_count}, max 10)" >&2
            has_errors="true"
        fi
    fi

    jq -n \
        --argjson hasErrors "$has_errors" \
        --argjson params "$parameters" \
        --argjson overrides "$final_overrides" \
        --argjson ncm "$non_compliance_messages" \
        --argjson ep "$effect_processed" \
        '{
            hasErrors: $hasErrors,
            parameters: $params,
            overrides: $overrides,
            nonComplianceMessages: $ncm,
            effectProcessed: $ep
        }'
}

###############################################################################
# Build assignment definition at leaf
###############################################################################
# Processes leaf node: builds final assignment objects per scope.
# Arguments:
#   $1 - assignment_def: accumulated JSON definition
#   $2 - pac_environment: JSON
#   $3 - combined_policy_details: JSON
#   $4 - policy_role_ids: JSON { policyId: [roleDefIds] }
#   $5 - role_definitions: JSON { roleDefId: displayName }
#   $6 - flat_policy_list: JSON
# Outputs JSON: { hasErrors, assignments: [...] }

_epac_build_assignment_definition_at_leaf() {
    local assignment_def="$1"
    local pac_environment="$2"
    local role_definitions="$3"
    local flat_policy_list="$4"

    # Large data read from $EPAC_TMP_DIR on demand
    local combined_policy_details policy_role_ids
    combined_policy_details="$(cat "$EPAC_TMP_DIR/combined_policy_details.json")"
    policy_role_ids="$(cat "$EPAC_TMP_DIR/policy_role_ids.json")"

    local pac_owner_id
    pac_owner_id="$(echo "$pac_environment" | jq -r '.pacOwnerId')"
    local deployed_by
    deployed_by="$(echo "$pac_environment" | jq -r '.deployedBy // empty')"

    local node_name
    node_name="$(echo "$assignment_def" | jq -r '.nodeName // ""')"
    local definition_entry_list
    definition_entry_list="$(echo "$assignment_def" | jq '.definitionEntryList // []')"
    local scope_collection
    scope_collection="$(echo "$assignment_def" | jq '.scopeCollection // {}')"
    local has_errors="false"
    local assignments_list="[]"

    local entry_count
    entry_count="$(echo "$definition_entry_list" | jq 'length')"
    local is_multi=$([[ $entry_count -gt 1 ]] && echo "true" || echo "false")

    # Check required fields
    if [[ $entry_count -eq 0 ]]; then
        epac_log_error "Node ${node_name}: no definitionEntryList" >&2
        jq -n '{hasErrors: true, assignments: []}'
        return 0
    fi

    local scope_count
    scope_count="$(echo "$scope_collection" | jq 'length')"
    if [[ $scope_count -eq 0 ]]; then
        epac_log_error "Node ${node_name}: no scopeCollection" >&2
        jq -n '{hasErrors: true, assignments: []}'
        return 0
    fi

    # Check CSV usage restrictions
    local csv_parameter_array
    csv_parameter_array="$(echo "$assignment_def" | jq '.csvParameterArray // null')"
    local csv_rows_validated
    csv_rows_validated="$(echo "$assignment_def" | jq '.csvRowsValidated // false')"

    local effect_processed_for_policy="{}"
    local ei=0
    while [[ $ei -lt $entry_count ]]; do
        local entry
        entry="$(echo "$definition_entry_list" | jq --argjson i "$ei" '.[$i]')"
        local entry_id
        entry_id="$(echo "$entry" | jq -r '.id')"
        local is_policy_set
        is_policy_set="$(echo "$entry" | jq -r '.isPolicySet')"
        local entry_display_name
        entry_display_name="$(echo "$entry" | jq -r '.displayName // empty')"
        local append_entry
        append_entry="$(echo "$entry" | jq -r '.append // false')"

        # Build assignment name
        local base_name
        base_name="$(echo "$assignment_def" | jq -r '.assignment.name // ""')"
        local base_display_name
        base_display_name="$(echo "$assignment_def" | jq -r '.assignment.displayName // ""')"
        local base_description
        base_description="$(echo "$assignment_def" | jq -r '.assignment.description // ""')"

        local assignment_name="$base_name"
        local assignment_display_name="$base_display_name"
        local assignment_description="$base_description"

        if [[ "$is_multi" == "true" ]]; then
            local short_name
            short_name="$(echo "$entry" | jq -r '
                if .policySetName != "" then .policySetName
                elif .policySetId != "" then (.policySetId | split("/") | last)
                elif .policyName != "" then .policyName
                elif .policyId != "" then (.policyId | split("/") | last)
                else ""
                end
            ')"
            if [[ "$append_entry" == "true" ]]; then
                assignment_name="${assignment_name}${short_name}"
                [[ -n "$entry_display_name" ]] && assignment_display_name="${assignment_display_name} - ${entry_display_name}"
            else
                assignment_name="${short_name}${assignment_name}"
                [[ -n "$entry_display_name" ]] && assignment_display_name="${entry_display_name} - ${assignment_display_name}"
            fi
        fi

        # Validate name
        if [[ -z "$assignment_name" ]]; then
            epac_log_error "Node ${node_name}: assignment name is empty" >&2
            has_errors="true"
            ei=$((ei + 1))
            continue
        fi
        if ! epac_confirm_valid_policy_resource_name "$assignment_name"; then
            epac_log_error "Node ${node_name}: assignment name '${assignment_name}' has invalid characters" >&2
            has_errors="true"
            ei=$((ei + 1))
            continue
        fi

        # Build metadata
        local metadata
        metadata="$(echo "$assignment_def" | jq '.metadata // {}')"
        metadata="$(echo "$metadata" | jq --arg pid "$pac_owner_id" '.pacOwnerId = $pid')"
        if [[ -n "$deployed_by" ]]; then
            metadata="$(echo "$metadata" | jq --arg db "$deployed_by" 'if has("deployedBy") then . else .deployedBy = $db end')"
        fi
        # Add roles info to metadata
        if [[ "$policy_role_ids" != "{}" ]]; then
            local roles_for_this
            roles_for_this="$(echo "$policy_role_ids" | jq --arg id "$entry_id" '.[$id] // null')"
            if [[ "$roles_for_this" != "null" ]]; then
                metadata="$(echo "$metadata" | jq --argjson r "$roles_for_this" '.roles = $r')"
            fi
        fi

        # Get enforcement mode
        local enforcement_mode
        enforcement_mode="$(echo "$assignment_def" | jq -r '.enforcementMode // "Default"')"

        # Parameters
        local parameters
        parameters="$(echo "$assignment_def" | jq '.parameters // {}')"

        # Non-compliance messages
        local non_compliance_messages
        non_compliance_messages="$(echo "$assignment_def" | jq '.nonComplianceMessages // []')"

        # Resource selectors for this entry
        local resource_selectors
        resource_selectors="$(echo "$assignment_def" | jq '.resourceSelectors // []')"

        # Filter resource selectors for this entry
        if [[ "$is_multi" == "true" ]]; then
            resource_selectors="$(echo "$resource_selectors" | jq --argjson entry "$entry" '
                [.[] | select(
                    (has("policySetName") and .policySetName == ($entry.policySetName // "")) or
                    (has("policySetId") and .policySetId == ($entry.policySetId // "")) or
                    (has("policyName") and .policyName == ($entry.policyName // "")) or
                    (has("policyId") and .policyId == ($entry.policyId // "")) or
                    (has("policySetName") | not) and (has("policySetId") | not) and
                    (has("policyName") | not) and (has("policyId") | not)
                )]
            ')"
        fi

        # Overrides
        local overrides
        overrides="$(echo "$assignment_def" | jq '.overrides // []')"

        # Filter overrides for this entry
        if [[ "$is_multi" == "true" ]]; then
            if [[ "$is_policy_set" == "true" ]]; then
                overrides="$(echo "$overrides" | jq --argjson entry "$entry" '
                    [.[] | select(
                        (has("policySetName") and .policySetName == ($entry.policySetName // "")) or
                        (has("policySetId") and .policySetId == ($entry.policySetId // "")) or
                        (has("policySetName") | not) and (has("policySetId") | not)
                    )]
                ')"
            else
                # Single policy: overrides without selectors
                overrides="$(echo "$overrides" | jq '[.[] | select(has("selectors") | not)]')"
            fi
        fi

        # Determine identity
        local identity_required="false"
        local identity_obj="null"
        local policy_definition_id="$entry_id"
        local policy_role_def_ids
        policy_role_def_ids="$(echo "$policy_role_ids" | jq --arg id "$entry_id" '.[$id] // []')"
        local role_count
        role_count="$(echo "$policy_role_def_ids" | jq 'length')"

        local additional_role_assignments
        additional_role_assignments="$(echo "$assignment_def" | jq '.additionalRoleAssignments // []')"
        local add_role_count
        add_role_count="$(echo "$additional_role_assignments" | jq 'length')"

        if [[ $role_count -gt 0 || $add_role_count -gt 0 ]]; then
            identity_required="true"
            local user_assigned_identity
            user_assigned_identity="$(echo "$assignment_def" | jq -r '.userAssignedIdentity // empty')"

            if [[ -n "$user_assigned_identity" ]]; then
                identity_obj="$(jq -n --arg uai "$user_assigned_identity" '{
                    type: "UserAssigned",
                    userAssignedIdentities: {($uai): {}}
                }')"
            else
                identity_obj='{"type": "SystemAssigned"}'
            fi
        fi

        local managed_identity_location
        managed_identity_location="$(echo "$assignment_def" | jq -r '.managedIdentityLocation // "global"')"

        # Handle CSV parameter merge for PolicySets
        if [[ "$csv_parameter_array" != "null" && "$is_policy_set" == "true" ]]; then
            local param_instructions
            param_instructions="$(jq -n \
                --argjson csvArray "$csv_parameter_array" \
                --arg effectCol "$(echo "$assignment_def" | jq -r '.effectColumn // "effect"')" \
                --arg paramsCol "$(echo "$assignment_def" | jq -r '.parametersColumn // "parameters"')" \
                --arg ncmCol "$(echo "$assignment_def" | jq -r '.nonComplianceMessageColumn // empty')" \
                '{
                    csvParameterArray: $csvArray,
                    effectColumn: $effectCol,
                    parametersColumn: $paramsCol,
                    nonComplianceMessageColumn: (if $ncmCol == "" then null else $ncmCol end)
                }')"

            local merge_result
            merge_result="$(_epac_merge_assignment_parameters_ex \
                "$node_name" "$entry_id" \
                "$(jq -n --argjson p "$parameters" --argjson ncm "$non_compliance_messages" '{parameters: $p, nonComplianceMessages: $ncm}')" \
                "$param_instructions" "$flat_policy_list" "$effect_processed_for_policy")"

            local merge_errors
            merge_errors="$(echo "$merge_result" | jq -r '.hasErrors')"
            if [[ "$merge_errors" == "true" ]]; then
                has_errors="true"
            fi
            parameters="$(echo "$merge_result" | jq '.parameters')"
            non_compliance_messages="$(echo "$merge_result" | jq '.nonComplianceMessages')"
            effect_processed_for_policy="$(echo "$merge_result" | jq '.effectProcessed')"

            local csv_overrides
            csv_overrides="$(echo "$merge_result" | jq '.overrides // []')"
            local csv_override_count
            csv_override_count="$(echo "$csv_overrides" | jq 'length')"
            if [[ $csv_override_count -gt 0 ]]; then
                overrides="$(jq -n --argjson a "$overrides" --argjson b "$csv_overrides" '$a + $b')"
            fi
        fi

        # Build parameter object: filter to only params in the definition
        local definition_params="{}"
        if [[ "$is_policy_set" == "true" ]]; then
            definition_params="$(echo "$combined_policy_details" | jq --arg id "$entry_id" '
                .policySets[$id].parameters // {} | to_entries | map({key: .key, value: {defaultValue: .value.defaultValue}}) | from_entries
            ' 2>/dev/null || echo '{}')"
        else
            definition_params="$(echo "$combined_policy_details" | jq --arg id "$entry_id" '
                .policies[$id].parameters // {} | to_entries | map({key: .key, value: {defaultValue: .value.defaultValue}}) | from_entries
            ' 2>/dev/null || echo '{}')"
        fi

        local final_parameters
        final_parameters="$(_epac_build_assignment_parameter_object "$parameters" "$definition_params")"

        # Definition version
        local definition_version
        definition_version="$(echo "$assignment_def" | jq -r '.definitionVersion // empty')"

        # Build base assignment
        local base_assignment
        base_assignment="$(jq -n \
            --arg name "$assignment_name" \
            --arg dn "$assignment_display_name" \
            --arg desc "$assignment_description" \
            --arg defId "$entry_id" \
            --arg em "$enforcement_mode" \
            --argjson meta "$metadata" \
            --argjson params "$final_parameters" \
            --argjson ncm "$non_compliance_messages" \
            --argjson overrides "$overrides" \
            --argjson rsel "$resource_selectors" \
            --argjson identReq "$identity_required" \
            --argjson ident "$identity_obj" \
            --arg mil "$managed_identity_location" \
            --arg defVer "$definition_version" \
            '{
                name: $name,
                displayName: $dn,
                description: $desc,
                policyDefinitionId: $defId,
                enforcementMode: $em,
                metadata: $meta,
                parameters: $params,
                nonComplianceMessages: $ncm,
                overrides: $overrides,
                resourceSelectors: $rsel,
                identityRequired: $identReq,
                identity: $ident,
                managedIdentityLocation: $mil,
                definitionVersion: (if $defVer == "" then null else $defVer end)
            }')"

        # Iterate over scopes
        local scope_keys
        scope_keys="$(echo "$scope_collection" | jq -r 'keys[]')"
        while IFS= read -r scope; do
            [[ -z "$scope" ]] && continue
            local scope_entry
            scope_entry="$(echo "$scope_collection" | jq --arg s "$scope" '.[$s]')"
            local scope_val
            scope_val="$(echo "$scope_entry" | jq -r '.scope // empty')"
            [[ -z "$scope_val" ]] && scope_val="$scope"

            local assignment_id="${scope_val}/providers/Microsoft.Authorization/policyAssignments/${assignment_name}"

            local scoped_assignment
            scoped_assignment="$(echo "$base_assignment" | jq \
                --arg id "$assignment_id" \
                --arg scope "$scope_val" \
                --argjson notScopes "$(echo "$scope_entry" | jq '.notScopesList // []')" \
                '.id = $id | .scope = $scope | .notScopes = $notScopes')"

            # Add required role assignments
            if [[ "$identity_required" == "true" ]]; then
                local required_role_assignments="[]"

                # From policy role definitions
                local pri=0
                while [[ $pri -lt $role_count ]]; do
                    local role_def_id
                    role_def_id="$(echo "$policy_role_def_ids" | jq -r --argjson i "$pri" '.[$i]')"
                    local role_display
                    role_display="$(echo "$role_definitions" | jq -r --arg rid "$role_def_id" '.[$rid] // "Unknown"')"
                    local req_role
                    req_role="$(jq -n \
                        --arg scope "$scope_val" \
                        --arg rid "$role_def_id" \
                        --arg rdn "$role_display" \
                        --arg desc "Policy Assignment '${assignment_id}': Role required by Policy, deployed by: '${deployed_by}'" \
                        '{scope: $scope, roleDefinitionId: $rid, roleDisplayName: $rdn, description: $desc, crossTenant: false}')"
                    required_role_assignments="$(echo "$required_role_assignments" | jq --argjson r "$req_role" '. + [$r]')"
                    pri=$((pri + 1))
                done

                # From additional role assignments
                local ari=0
                while [[ $ari -lt $add_role_count ]]; do
                    local add_role
                    add_role="$(echo "$additional_role_assignments" | jq --argjson i "$ari" '.[$i]')"
                    local add_role_def_id add_role_scope is_cross_tenant
                    add_role_def_id="$(echo "$add_role" | jq -r '.roleDefinitionId')"
                    add_role_scope="$(echo "$add_role" | jq -r '.scope')"
                    is_cross_tenant="$(echo "$add_role" | jq -r '.crossTenant // false')"
                    local add_role_display
                    add_role_display="$(echo "$role_definitions" | jq -r --arg rid "$add_role_def_id" '.[$rid] // "Unknown"')"
                    local desc_prefix="additional"
                    [[ "$is_cross_tenant" == "true" ]] && desc_prefix="additional cross tenant"
                    local req_role
                    req_role="$(jq -n \
                        --arg scope "$add_role_scope" \
                        --arg rid "$add_role_def_id" \
                        --arg rdn "$add_role_display" \
                        --arg desc "Policy Assignment '${assignment_id}': ${desc_prefix} Role Assignment deployed by: '${deployed_by}'" \
                        --argjson ct "$is_cross_tenant" \
                        '{scope: $scope, roleDefinitionId: $rid, roleDisplayName: $rdn, description: $desc, crossTenant: $ct}')"
                    required_role_assignments="$(echo "$required_role_assignments" | jq --argjson r "$req_role" '. + [$r]')"
                    ari=$((ari + 1))
                done

                scoped_assignment="$(echo "$scoped_assignment" | jq --argjson rr "$required_role_assignments" '.requiredRoleAssignments = $rr')"
            fi

            assignments_list="$(echo "$assignments_list" | jq --argjson a "$scoped_assignment" '. + [$a]')"
        done <<< "$scope_keys"

        ei=$((ei + 1))
    done

    jq -n --argjson hasErrors "$has_errors" --argjson assignments "$assignments_list" \
        '{hasErrors: $hasErrors, assignments: $assignments}'
}

###############################################################################
# Build assignment definition node (recursive tree builder)
###############################################################################
# Recursively processes assignment definition tree nodes.
# Arguments:
#   $1 - pac_environment: JSON
#   $2 - assignment_def: accumulated JSON definition
#   $3 - node_object: current JSON node from file
#   $4 - combined_policy_details: JSON
#   $5 - policy_role_ids: JSON { policyId: [roleDefIds] }
#   $6 - role_definitions: JSON { roleDefId: displayName }
#   $7 - policy_definitions_scopes: JSON array of scopes
#   $8 - all_policy_definitions: JSON
#   $9 - all_policy_set_definitions: JSON
#   $10 - scope_table: JSON
#   $11 - flat_policy_list: JSON
# Outputs JSON: { hasErrors, assignments: [...] }

_epac_build_assignment_definition_node() {
    local pac_environment="$1"
    local assignment_def="$2"
    local node_object="$3"
    local role_definitions="$4"
    local policy_definitions_scopes="$5"
    local flat_policy_list="${6}"

    # NOTE: Large data (combined_policy_details, policy_role_ids,
    # all_policy_definitions, all_policy_set_definitions, scope_table)
    # are read from $EPAC_TMP_DIR files lazily where needed, not upfront.

    local pac_selector
    pac_selector="$(echo "$pac_environment" | jq -r '.pacSelector // "*"')"

    # Deep clone the assignment definition for this branch
    local def
    def="$(epac_deep_clone "$assignment_def")"

    # Accumulate nodeName
    local node_name_part
    node_name_part="$(echo "$node_object" | jq -r '.nodeName // empty')"
    if [[ -n "$node_name_part" ]]; then
        local current_node_name
        current_node_name="$(echo "$def" | jq -r '.nodeName // ""')"
        def="$(echo "$def" | jq --arg n "${current_node_name}/${node_name_part}" '.nodeName = $n')"
    fi
    local node_name
    node_name="$(echo "$def" | jq -r '.nodeName // ""')"

    # Enforcement mode
    local enforcement_mode
    enforcement_mode="$(echo "$node_object" | jq -r '.enforcementMode // empty')"
    if [[ -n "$enforcement_mode" ]]; then
        if [[ "$enforcement_mode" != "Default" && "$enforcement_mode" != "DoNotEnforce" ]]; then
            epac_log_error "Node ${node_name}: enforcementMode must be 'Default' or 'DoNotEnforce', got '${enforcement_mode}'" >&2
            jq -n '{hasErrors: true, assignments: []}'
            return 0
        fi
        def="$(echo "$def" | jq --arg em "$enforcement_mode" '.enforcementMode = $em')"
    fi

    # Assignment name/displayName/description (concatenate)
    local assign_node
    assign_node="$(echo "$node_object" | jq '.assignment // null')"
    if [[ "$assign_node" != "null" ]]; then
        local a_name a_dn a_desc
        a_name="$(echo "$assign_node" | jq -r '.name // empty')"
        a_dn="$(echo "$assign_node" | jq -r '.displayName // empty')"
        a_desc="$(echo "$assign_node" | jq -r '.description // empty')"

        if [[ -n "$a_name" ]]; then
            local cur_name
            cur_name="$(echo "$def" | jq -r '.assignment.name // ""')"
            def="$(echo "$def" | jq --arg n "${cur_name}${a_name}" '.assignment.name = $n')"
        fi
        if [[ -n "$a_dn" ]]; then
            local cur_dn
            cur_dn="$(echo "$def" | jq -r '.assignment.displayName // ""')"
            def="$(echo "$def" | jq --arg n "${cur_dn}${a_dn}" '.assignment.displayName = $n')"
        fi
        if [[ -n "$a_desc" ]]; then
            local cur_desc
            cur_desc="$(echo "$def" | jq -r '.assignment.description // ""')"
            def="$(echo "$def" | jq --arg n "${cur_desc}${a_desc}" '.assignment.description = $n')"
        fi
    fi

    # Definition entry or list
    local def_entry
    def_entry="$(echo "$node_object" | jq '.definitionEntry // null')"
    local def_entry_list
    def_entry_list="$(echo "$node_object" | jq '.definitionEntryList // null')"

    if [[ "$def_entry" != "null" && "$def_entry_list" != "null" ]]; then
        epac_log_error "Node ${node_name}: cannot have both definitionEntry and definitionEntryList" >&2
        jq -n '{hasErrors: true, assignments: []}'
        return 0
    fi

    if [[ "$def_entry" != "null" ]]; then
        # Single entry → convert to list
        local resolved
        resolved="$(_epac_build_assignment_definition_entry "$def_entry" "$policy_definitions_scopes" "$node_name")"
        local valid
        valid="$(echo "$resolved" | jq -r '.valid')"
        if [[ "$valid" != "true" ]]; then
            jq -n '{hasErrors: true, assignments: []}'
            return 0
        fi
        def="$(echo "$def" | jq --argjson e "[$resolved]" '.definitionEntryList = $e')"
    elif [[ "$def_entry_list" != "null" ]]; then
        local resolved_list="[]"
        local del_count
        del_count="$(echo "$def_entry_list" | jq 'length')"
        local di=0
        while [[ $di -lt $del_count ]]; do
            local single_entry
            single_entry="$(echo "$def_entry_list" | jq --argjson i "$di" '.[$i]')"
            local resolved
            resolved="$(_epac_build_assignment_definition_entry "$single_entry" "$policy_definitions_scopes" "$node_name")"
            local valid
            valid="$(echo "$resolved" | jq -r '.valid')"
            if [[ "$valid" != "true" ]]; then
                jq -n '{hasErrors: true, assignments: []}'
                return 0
            fi
            resolved_list="$(echo "$resolved_list" | jq --argjson e "$resolved" '. + [$e]')"
            di=$((di + 1))
        done
        def="$(echo "$def" | jq --argjson e "$resolved_list" '.definitionEntryList = $e')"
    fi

    # Metadata (shallow merge)
    local meta_node
    meta_node="$(echo "$node_object" | jq '.metadata // null')"
    if [[ "$meta_node" != "null" ]]; then
        def="$(echo "$def" | jq --argjson m "$meta_node" '.metadata = (.metadata // {} | . + $m)')"
    fi

    # Parameters (union, deeper wins)
    local params_node
    params_node="$(echo "$node_object" | jq '.parameters // null')"
    if [[ "$params_node" != "null" ]]; then
        def="$(echo "$def" | jq --argjson p "$params_node" '.parameters = (.parameters // {} | . + $p)')"
    fi

    # Non-compliance messages (accumulate)
    local ncm_node
    ncm_node="$(echo "$node_object" | jq '.nonComplianceMessages // null')"
    if [[ "$ncm_node" != "null" ]]; then
        def="$(echo "$def" | jq --argjson ncm "$ncm_node" '.nonComplianceMessages = ((.nonComplianceMessages // []) + $ncm)')"
    fi

    # Overrides (accumulate)
    local overrides_node
    overrides_node="$(echo "$node_object" | jq '.overrides // null')"
    if [[ "$overrides_node" != "null" ]]; then
        def="$(echo "$def" | jq --argjson o "$overrides_node" '.overrides = ((.overrides // []) + $o)')"
    fi

    # Resource selectors (accumulate)
    local rsel_node
    rsel_node="$(echo "$node_object" | jq '.resourceSelectors // null')"
    if [[ "$rsel_node" != "null" ]]; then
        def="$(echo "$def" | jq --argjson rs "$rsel_node" '.resourceSelectors = ((.resourceSelectors // []) + $rs)')"
    fi

    # Definition version (deeper wins)
    local dv_node
    dv_node="$(echo "$node_object" | jq -r '.definitionVersion // empty')"
    if [[ -n "$dv_node" ]]; then
        def="$(echo "$def" | jq --arg dv "$dv_node" '.definitionVersion = $dv')"
    fi

    # Additional role assignments (accumulate, pac-selector-aware)
    local ara_node
    ara_node="$(echo "$node_object" | jq '.additionalRoleAssignments // null')"
    if [[ "$ara_node" != "null" ]]; then
        local current_ara
        current_ara="$(echo "$def" | jq '.additionalRoleAssignments // []')"
        local merged_ara
        merged_ara="$(_epac_add_selected_pac_array "$current_ara" "$ara_node" "$pac_selector")"
        def="$(echo "$def" | jq --argjson a "$merged_ara" '.additionalRoleAssignments = $a')"
    fi

    # Managed identity location (pac-selector-aware, deeper wins)
    local mil_node
    mil_node="$(echo "$node_object" | jq '.managedIdentityLocations // null')"
    if [[ "$mil_node" != "null" ]]; then
        local mil_val
        mil_val="$(_epac_add_selected_pac_value "$mil_node" "$pac_selector")"
        if [[ "$mil_val" != "null" ]]; then
            def="$(echo "$def" | jq --arg v "$(echo "$mil_val" | jq -r '.')" '.managedIdentityLocation = $v')"
        fi
    fi

    # User assigned identity (pac-selector-aware, deeper wins)
    local uai_node
    uai_node="$(echo "$node_object" | jq '.userAssignedIdentity // null')"
    if [[ "$uai_node" != "null" ]]; then
        local uai_val
        uai_val="$(_epac_add_selected_pac_value "$uai_node" "$pac_selector")"
        if [[ "$uai_val" != "null" ]]; then
            def="$(echo "$def" | jq --arg v "$(echo "$uai_val" | jq -r '.')" '.userAssignedIdentity = $v')"
        fi
    fi

    # Scope processing — read scope_table lazily (only if scope or notScope present)
    local scope_node not_scope_node
    scope_node="$(echo "$node_object" | jq '.scope // null')"
    not_scope_node="$(echo "$node_object" | jq '.notScope // null')"
    if [[ "$scope_node" != "null" || "$not_scope_node" != "null" ]]; then
        local scope_table_lower
        scope_table_lower="$(cat "$EPAC_TMP_DIR/scope_table_lower.json")"
    fi
    if [[ "$scope_node" != "null" ]]; then
        local scope_val
        scope_val="$(_epac_add_selected_pac_value "$scope_node" "$pac_selector")"
        if [[ "$scope_val" != "null" ]]; then
            # Build scope collection from scope table (case-insensitive lookup)
            # scope_val may be a single string or an array of scope IDs
            local scope_collection="{}"
            local scope_ids
            scope_ids="$(echo "$scope_val" | jq -r 'if type == "array" then .[] else . end | ascii_downcase')"
            while IFS= read -r scope_id; do
                [[ -z "$scope_id" ]] && continue
                local scope_entry
                scope_entry="$(echo "$scope_table_lower" | jq --arg s "$scope_id" '.[$s] // null')"
                if [[ "$scope_entry" != "null" ]]; then
                    scope_collection="$(echo "$scope_collection" | jq --arg s "$scope_id" --argjson e "$scope_entry" '.[$s] = $e')"
                fi
            done <<< "$scope_ids"
            def="$(echo "$def" | jq --argjson sc "$scope_collection" '.scopeCollection = $sc')"
        fi
    fi

    # Not scopes (accumulate, filter by scope, support wildcards)
    if [[ "$not_scope_node" != "null" ]]; then
        local not_scope_list
        not_scope_list="$(_epac_add_selected_pac_array "[]" "$not_scope_node" "$pac_selector")"
        if [[ "$not_scope_list" != "[]" ]]; then
            # Merge not scopes into scope collection entries (case-insensitive)
            def="$(echo "$def" | jq --argjson ns "$not_scope_list" --argjson st "$scope_table_lower" '
                .scopeCollection as $sc |
                reduce ($sc | keys[]) as $sk (.;
                    ($sc[$sk].notScopesList // []) as $existing |
                    reduce ($ns[]) as $ns_item (.;
                        ($ns_item | ascii_downcase) as $ns_lower |
                        if ($ns_lower | test("\\*")) then
                            # Wildcard: filter scope table entries matching pattern
                            reduce ($st | keys[] | select(test($ns_lower | gsub("\\*"; ".*")))) as $match (.;
                                .scopeCollection[$sk].notScopesList = ((.scopeCollection[$sk].notScopesList // []) + [$match]) | .scopeCollection[$sk].notScopesList |= unique
                            )
                        else
                            # Direct scope: add if under this scope
                            if ($ns_lower | startswith($sk)) then
                                .scopeCollection[$sk].notScopesList = ((.scopeCollection[$sk].notScopesList // []) + [$ns_lower]) | .scopeCollection[$sk].notScopesList |= unique
                            else .
                            end
                        end
                    )
                )
            ')"
        fi
    fi

    # CSV parameter file handling
    local csv_node
    csv_node="$(echo "$node_object" | jq '.parameterFile // null')"
    if [[ "$csv_node" != "null" && "$csv_node" != "" ]]; then
        # Load CSV file path relative to the assignment file
        local csv_file_path
        csv_file_path="$(echo "$csv_node" | jq -r '.')"
        # Store parameter selector and other CSV info
        local param_selector
        param_selector="$(echo "$node_object" | jq -r '.parameterSelector // empty')"
        local effect_column
        effect_column="$(echo "$node_object" | jq -r '.effectColumn // "effect"')"
        local parameters_column
        parameters_column="$(echo "$node_object" | jq -r '.parametersColumn // "parameters"')"
        local non_compliance_msg_column
        non_compliance_msg_column="$(echo "$node_object" | jq -r '.nonComplianceMessageColumn // empty')"

        def="$(echo "$def" | jq \
            --arg pf "$csv_file_path" \
            --arg ps "$param_selector" \
            --arg ec "$effect_column" \
            --arg pc "$parameters_column" \
            --arg ncc "$non_compliance_msg_column" \
            '.parameterFile = $pf | .parameterSelector = $ps | .effectColumn = $ec | .parametersColumn = $pc | .nonComplianceMessageColumn = (if $ncc == "" then null else $ncc end)')"
    fi

    # Process children or leaf
    local children
    children="$(echo "$node_object" | jq '.children // null')"

    if [[ "$children" != "null" ]]; then
        local child_count
        child_count="$(echo "$children" | jq 'length')"
        local all_assignments="[]"
        local any_errors="false"
        local ci=0
        while [[ $ci -lt $child_count ]]; do
            local child
            child="$(echo "$children" | jq --argjson i "$ci" '.[$i]')"
            local child_result
            child_result="$(_epac_build_assignment_definition_node \
                "$pac_environment" "$(epac_deep_clone "$def")" "$child" \
                "$role_definitions" "$policy_definitions_scopes" "$flat_policy_list")"
            local child_errors
            child_errors="$(echo "$child_result" | jq -r '.hasErrors')"
            [[ "$child_errors" == "true" ]] && any_errors="true"
            local child_assignments
            child_assignments="$(echo "$child_result" | jq '.assignments')"
            all_assignments="$(jq -n --argjson a "$all_assignments" --argjson b "$child_assignments" '$a + $b')"
            ci=$((ci + 1))
        done
        jq -n --argjson hasErrors "$any_errors" --argjson assignments "$all_assignments" \
            '{hasErrors: $hasErrors, assignments: $assignments}'
    else
        # Leaf node
        _epac_build_assignment_definition_at_leaf "$def" "$pac_environment" \
            "$role_definitions" "$flat_policy_list"
    fi
}

###############################################################################
# Build assignment plan (main entry point)
###############################################################################
# Arguments:
#   $1 - assignments_root_folder: path to assignment JSON/JSONC files
#   $2 - pac_environment: JSON
#   $3 - deployed_assignments: JSON { managed: {id: assignment}, readOnly: {id: assignment} }
#   $4 - all_policy_definitions: JSON { id: def }
#   $5 - all_policy_set_definitions: JSON { id: setDef }
#   $6 - combined_policy_details: JSON { policies: {...}, policySets: {...} }
#   $7 - replace_definitions: JSON { id: def }  (policies that got replaced)
#   $8 - policy_role_ids: JSON { policyId: [roleDefIds] }
#   $9 - role_definitions: JSON { roleDefId: displayName }
#   $10 - scope_table: JSON { scope: {} }
#   $11 - deployed_role_assignments_by_principal: JSON { principalId: [role...] }
#   $12 - detailed_output: "true"|"false"
#
# Outputs JSON:
# {
#   assignments: { new:{}, update:{}, replace:{}, delete:{},
#                  numberUnchanged:N, numberOfChanges:N },
#   roleAssignments: { added:[], updated:[], removed:[], numberOfChanges:N },
#   numberTotalChanges: N
# }

epac_build_assignment_plan() {
    local assignments_root_folder="$1"
    local pac_environment="$2"
    local replace_definitions="$3"
    local role_definitions="$4"
    local deployed_role_assignments_by_principal="${5}"
    local detailed_output="${6:-false}"

    # Large data read from $EPAC_TMP_DIR (written by build-deployment-plans.sh)
    local deployed_assignments
    deployed_assignments="$(cat "$EPAC_TMP_DIR/deployed_assignments.json")"

    local pac_owner_id
    pac_owner_id="$(echo "$pac_environment" | jq -r '.pacOwnerId')"
    local strategy
    strategy="$(echo "$pac_environment" | jq -r '.desiredState.strategy // "full"')"
    local keep_dfc_security
    keep_dfc_security="$(echo "$pac_environment" | jq -r '.desiredState.keepDfcSecurityAssignments // false')"

    local policy_definitions_scopes
    policy_definitions_scopes="$(echo "$pac_environment" | jq '.policyDefinitionsScopes // []')"

    # Build flat policy list from details
    local flat_policy_list="{}"
    # We pass the details' policySet definitions through the flat list builder
    # For assignments, the flat list is built per-entry in the leaf node

    # Clone deployed managed assignments as delete candidates
    local delete_candidates
    delete_candidates="$(echo "$deployed_assignments" | jq '.managed // {}')"

    local assignments_new="{}"
    local assignments_update="{}"
    local assignments_replace="{}"
    local assignments_delete="{}"
    local assignments_unchanged=0

    # Role assignment accumulators — use temp files to avoid "Argument list too long"
    local _ra_added_file _ra_updated_file _ra_removed_file
    _ra_added_file="$(mktemp)"
    _ra_updated_file="$(mktemp)"
    _ra_removed_file="$(mktemp)"

    # Collect all JSON/JSONC files
    if [[ ! -d "$assignments_root_folder" ]]; then
        epac_write_status "Assignments folder not found: ${assignments_root_folder}" "warning" 2 >&2
        _epac_emit_assignment_plan_result \
            "$assignments_new" "$assignments_update" "$assignments_replace" "$assignments_delete" \
            "$assignments_unchanged" \
            "[]" "[]" "[]"
        rm -f "$_ra_added_file" "$_ra_updated_file" "$_ra_removed_file"
        return 0
    fi

    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$assignments_root_folder" -type f \( -name '*.json' -o -name '*.jsonc' \) -print0 2>/dev/null | sort -z)

    local file_count=${#files[@]}
    epac_write_section "Processing ${file_count} assignment files" 0 >&2

    for file in "${files[@]}"; do
        local file_content
        if ! file_content="$(epac_read_jsonc "$file")"; then
            epac_log_error "Failed to parse: ${file}" >&2
            continue
        fi

        # Build root definition template
        local root_def
        root_def="$(jq -n '{
            nodeName: "",
            assignment: {name: "", displayName: "", description: ""},
            enforcementMode: "Default",
            metadata: {},
            parameters: {},
            nonComplianceMessages: [],
            overrides: [],
            resourceSelectors: [],
            additionalRoleAssignments: [],
            definitionEntryList: [],
            scopeCollection: {},
            managedIdentityLocation: "global",
            userAssignedIdentity: null,
            definitionVersion: null,
            csvParameterArray: null,
            csvRowsValidated: false
        }')"

        # Recursively process the tree
        local tree_result
        tree_result="$(_epac_build_assignment_definition_node \
            "$pac_environment" "$root_def" "$file_content" \
            "$role_definitions" "$policy_definitions_scopes" "$flat_policy_list")"

        local tree_errors
        tree_errors="$(echo "$tree_result" | jq -r '.hasErrors')"
        if [[ "$tree_errors" == "true" ]]; then
            epac_log_error "Errors in assignment file: ${file}" >&2
            continue
        fi

        local desired_assignments
        desired_assignments="$(echo "$tree_result" | jq '.assignments')"
        local desired_count
        desired_count="$(echo "$desired_assignments" | jq 'length')"

        # Compare with deployed
        local di=0
        while [[ $di -lt $desired_count ]]; do
            local desired
            desired="$(echo "$desired_assignments" | jq --argjson i "$di" '.[$i]')"
            local assignment_id
            assignment_id="$(echo "$desired" | jq -r '.id')"

            # Remove from delete candidates
            delete_candidates="$(echo "$delete_candidates" | jq --arg id "$assignment_id" 'del(.[$id])')"

            local deployed
            deployed="$(echo "$deployed_assignments" | jq --arg id "$assignment_id" '.managed[$id] // null')"

            if [[ "$deployed" == "null" ]]; then
                # Check read-only
                deployed="$(echo "$deployed_assignments" | jq --arg id "$assignment_id" '.readOnly[$id] // null')"
            fi

            if [[ "$deployed" != "null" ]]; then
                # Compare existing vs desired
                local deployed_props
                deployed_props="$(echo "$deployed" | jq 'if .properties then .properties else . end')"

                # Field comparisons
                local dn_match="false" desc_match="false" em_match="false"
                local deployed_dn deployed_desc deployed_em

                deployed_dn="$(echo "$deployed_props" | jq -r '.displayName // empty')"
                deployed_desc="$(echo "$deployed_props" | jq -r '.description // empty')"
                deployed_em="$(echo "$deployed_props" | jq -r '.enforcementMode // "Default"')"
                local desired_dn desired_desc desired_em
                desired_dn="$(echo "$desired" | jq -r '.displayName // empty')"
                desired_desc="$(echo "$desired" | jq -r '.description // empty')"
                desired_em="$(echo "$desired" | jq -r '.enforcementMode // "Default"')"

                [[ "$deployed_dn" == "$desired_dn" ]] && dn_match="true"
                [[ "$deployed_desc" == "$desired_desc" ]] && desc_match="true"
                [[ "$deployed_em" == "$desired_em" ]] && em_match="true"

                # Metadata
                local deployed_meta
                deployed_meta="$(echo "$deployed_props" | jq '.metadata // {}')"
                local desired_meta
                desired_meta="$(echo "$desired" | jq '.metadata // {}')"
                local meta_result
                meta_result="$(epac_confirm_metadata_matches "$deployed_meta" "$desired_meta")"
                local meta_match change_pac_owner
                meta_match="$(echo "$meta_result" | jq -r '.match')"
                change_pac_owner="$(echo "$meta_result" | jq -r '.changePacOwnerId')"

                # Parameters
                local param_match="true"
                if ! epac_confirm_parameters_usage_matches \
                    "$(echo "$deployed_props" | jq '.parameters // null')" \
                    "$(echo "$desired" | jq '.parameters // null')"; then
                    param_match="false"
                fi

                # Not Scopes
                local not_scopes_match="true"
                local deployed_not_scopes desired_not_scopes
                deployed_not_scopes="$(echo "$deployed_props" | jq '.notScopes // []')"
                desired_not_scopes="$(echo "$desired" | jq '.notScopes // []')"
                if ! epac_deep_equal "$deployed_not_scopes" "$desired_not_scopes"; then
                    not_scopes_match="false"
                fi

                # Non-compliance messages (strip null-valued fields added by Resource Graph)
                local ncm_match="true"
                if ! epac_deep_equal \
                    "$(echo "$deployed_props" | jq '[(.nonComplianceMessages // [])[] | with_entries(select(.value != null))]')" \
                    "$(echo "$desired" | jq '[(.nonComplianceMessages // [])[] | with_entries(select(.value != null))]')"; then
                    ncm_match="false"
                fi

                # Overrides
                local overrides_match="true"
                if ! epac_deep_equal \
                    "$(echo "$deployed_props" | jq '.overrides // []')" \
                    "$(echo "$desired" | jq '.overrides // []')"; then
                    overrides_match="false"
                fi

                # Resource selectors
                local rsel_match="true"
                if ! epac_deep_equal \
                    "$(echo "$deployed_props" | jq '.resourceSelectors // []')" \
                    "$(echo "$desired" | jq '.resourceSelectors // []')"; then
                    rsel_match="false"
                fi

                # Definition version
                local version_match="true"
                local deployed_version desired_version
                deployed_version="$(echo "$deployed_props" | jq -r '.definitionVersion // empty')"
                desired_version="$(echo "$desired" | jq -r '.definitionVersion // empty')"
                [[ "$deployed_version" != "$desired_version" ]] && version_match="false"

                # Check if definition was replaced
                local definition_id
                definition_id="$(echo "$desired" | jq -r '.policyDefinitionId')"
                local def_replaced="false"
                local is_in_replace
                is_in_replace="$(echo "$replace_definitions" | jq --arg id "$definition_id" 'has($id)')"
                [[ "$is_in_replace" == "true" ]] && def_replaced="true"

                # Identity changes
                local identity_result
                identity_result="$(_epac_build_assignment_identity_changes \
                    "$deployed" "$desired" "$def_replaced" "$deployed_role_assignments_by_principal")"
                local identity_replaced
                identity_replaced="$(echo "$identity_result" | jq -r '.replaced')"

                local deployed_def_id
                deployed_def_id="$(echo "$deployed_props" | jq -r '.policyDefinitionId // empty')"
                local desired_def_id
                desired_def_id="$(echo "$desired" | jq -r '.policyDefinitionId // empty')"

                # Determine if replacement needed
                local needs_replace="false"
                [[ "$identity_replaced" == "true" ]] && needs_replace="true"
                [[ "$deployed_def_id" != "$desired_def_id" ]] && needs_replace="true"

                # Build changes string
                local changes=()
                [[ "$dn_match" != "true" ]] && changes+=("displayName")
                [[ "$desc_match" != "true" ]] && changes+=("description")
                [[ "$em_match" != "true" ]] && changes+=("enforcementMode")
                [[ "$meta_match" != "true" || "$change_pac_owner" == "true" ]] && changes+=("metadata")
                [[ "$param_match" != "true" ]] && changes+=("parameters")
                [[ "$not_scopes_match" != "true" ]] && changes+=("notScopes")
                [[ "$ncm_match" != "true" ]] && changes+=("nonComplianceMessages")
                [[ "$overrides_match" != "true" ]] && changes+=("overrides")
                [[ "$rsel_match" != "true" ]] && changes+=("resourceSelectors")
                [[ "$version_match" != "true" ]] && changes+=("version")
                [[ "$needs_replace" == "true" ]] && changes+=("replace")

                # Identity change strings
                local id_strings
                id_strings="$(echo "$identity_result" | jq -r '.changedIdentityStrings[]' 2>/dev/null || true)"
                while IFS= read -r s; do
                    [[ -n "$s" ]] && changes+=("$s")
                done <<< "$id_strings"

                # Collect role assignment changes
                local id_added id_updated id_removed
                id_added="$(echo "$identity_result" | jq '.added')"
                id_updated="$(echo "$identity_result" | jq '.updated')"
                id_removed="$(echo "$identity_result" | jq '.removed')"
                [[ "$(echo "$id_added" | jq 'length')" -gt 0 ]] && echo "$id_added" | jq -c '.[]' >> "$_ra_added_file"
                [[ "$(echo "$id_updated" | jq 'length')" -gt 0 ]] && echo "$id_updated" | jq -c '.[]' >> "$_ra_updated_file"
                [[ "$(echo "$id_removed" | jq 'length')" -gt 0 ]] && echo "$id_removed" | jq -c '.[]' >> "$_ra_removed_file"

                if [[ ${#changes[@]} -eq 0 ]]; then
                    assignments_unchanged=$((assignments_unchanged + 1))
                else
                    local changes_str
                    changes_str="$(IFS=','; echo "${changes[*]}")"
                    local display
                    display="$(echo "$desired" | jq -r '.displayName // .name')"

                    if [[ "$needs_replace" == "true" ]]; then
                        epac_write_status "Replace (${changes_str}): ${display}" "replace" 4 >&2
                        assignments_replace="$(echo "$assignments_replace" | jq --arg id "$assignment_id" --argjson d "$desired" '.[$id] = $d')"
                    else
                        epac_write_status "Update (${changes_str}): ${display}" "update" 4 >&2
                        assignments_update="$(echo "$assignments_update" | jq --arg id "$assignment_id" --argjson d "$desired" '.[$id] = $d')"
                    fi
                fi
            else
                # New assignment
                local display
                display="$(echo "$desired" | jq -r '.displayName // .name')"
                epac_write_status "New: ${display}" "new" 4 >&2
                assignments_new="$(echo "$assignments_new" | jq --arg id "$assignment_id" --argjson d "$desired" '.[$id] = $d')"

                # Role assignments for new
                local new_identity_result
                new_identity_result="$(_epac_build_assignment_identity_changes \
                    "null" "$desired" "false" "$deployed_role_assignments_by_principal")"
                local new_added
                new_added="$(echo "$new_identity_result" | jq '.added')"
                [[ "$(echo "$new_added" | jq 'length')" -gt 0 ]] && echo "$new_added" | jq -c '.[]' >> "$_ra_added_file"
            fi

            di=$((di + 1))
        done
    done

    # Process delete candidates
    local del_keys
    del_keys="$(echo "$delete_candidates" | jq -r 'keys[]' 2>/dev/null || true)"
    while IFS= read -r del_id; do
        [[ -z "$del_id" ]] && continue
        local del_assignment
        del_assignment="$(echo "$delete_candidates" | jq --arg id "$del_id" '.[$id]')"

        # Classify the pac owner
        local del_pac_owner_class
        del_pac_owner_class="$(epac_confirm_pac_owner "$pac_owner_id" "$del_assignment")"

        if epac_confirm_delete_for_strategy "$del_pac_owner_class" "$strategy" "$keep_dfc_security" "false"; then
            local del_props
            del_props="$(echo "$del_assignment" | jq 'if .properties then .properties else . end')"
            local del_display
            del_display="$(echo "$del_props" | jq -r '.displayName // empty')"
            epac_write_status "Delete: ${del_display}" "delete" 4 >&2
            assignments_delete="$(echo "$assignments_delete" | jq --arg id "$del_id" --argjson d "$del_assignment" '.[$id] = $d')"

            # Role assignments for deleted
            local del_identity_result
            del_identity_result="$(_epac_build_assignment_identity_changes \
                "$del_assignment" "null" "false" "$deployed_role_assignments_by_principal")"
            local del_removed
            del_removed="$(echo "$del_identity_result" | jq '.removed')"
            [[ "$(echo "$del_removed" | jq 'length')" -gt 0 ]] && echo "$del_removed" | jq -c '.[]' >> "$_ra_removed_file"
        fi
    done <<< "$del_keys"

    # Assemble role assignment arrays from temp files
    local role_assignments_added role_assignments_updated role_assignments_removed
    if [[ -s "$_ra_added_file" ]]; then
        role_assignments_added="$(jq -s '.' "$_ra_added_file")"
    else
        role_assignments_added="[]"
    fi
    if [[ -s "$_ra_updated_file" ]]; then
        role_assignments_updated="$(jq -s '.' "$_ra_updated_file")"
    else
        role_assignments_updated="[]"
    fi
    if [[ -s "$_ra_removed_file" ]]; then
        role_assignments_removed="$(jq -s '.' "$_ra_removed_file")"
    else
        role_assignments_removed="[]"
    fi
    rm -f "$_ra_added_file" "$_ra_updated_file" "$_ra_removed_file"

    _epac_emit_assignment_plan_result \
        "$assignments_new" "$assignments_update" "$assignments_replace" "$assignments_delete" \
        "$assignments_unchanged" \
        "$role_assignments_added" "$role_assignments_updated" "$role_assignments_removed"
}

###############################################################################
# Emit final result JSON
###############################################################################

_epac_emit_assignment_plan_result() {
    local new="$1"
    local update="$2"
    local replace="$3"
    local delete="$4"
    local unchanged="$5"
    local role_added="$6"
    local role_updated="$7"
    local role_removed="$8"

    local new_count update_count replace_count delete_count
    new_count="$(echo "$new" | jq 'length')"
    update_count="$(echo "$update" | jq 'length')"
    replace_count="$(echo "$replace" | jq 'length')"
    delete_count="$(echo "$delete" | jq 'length')"
    local total_changes=$((new_count + update_count + replace_count + delete_count))

    local role_added_count role_updated_count role_removed_count role_total
    role_added_count="$(echo "$role_added" | jq 'length')"
    role_updated_count="$(echo "$role_updated" | jq 'length')"
    role_removed_count="$(echo "$role_removed" | jq 'length')"
    role_total=$((role_added_count + role_updated_count + role_removed_count))

    # Use temp files for large args
    local _t1 _t2 _t3 _t4 _t5 _t6 _t7
    _t1="$(mktemp)"; _t2="$(mktemp)"; _t3="$(mktemp)"; _t4="$(mktemp)"; _t5="$(mktemp)"; _t6="$(mktemp)"; _t7="$(mktemp)"
    echo "$new" > "$_t1"; echo "$update" > "$_t2"; echo "$replace" > "$_t3"
    echo "$delete" > "$_t4"; echo "$role_added" > "$_t5"; echo "$role_updated" > "$_t6"; echo "$role_removed" > "$_t7"
    jq -n \
        --slurpfile new "$_t1" \
        --slurpfile update "$_t2" \
        --slurpfile replace "$_t3" \
        --slurpfile delete "$_t4" \
        --argjson unchanged "$unchanged" \
        --argjson totalChanges "$total_changes" \
        --slurpfile roleAdded "$_t5" \
        --slurpfile roleUpdated "$_t6" \
        --slurpfile roleRemoved "$_t7" \
        --argjson roleTotalChanges "$role_total" \
        '{
            assignments: {
                new: $new[0], update: $update[0], replace: $replace[0], delete: $delete[0],
                numberUnchanged: $unchanged, numberOfChanges: $totalChanges
            },
            roleAssignments: {
                added: $roleAdded[0], updated: $roleUpdated[0], removed: $roleRemoved[0],
                numberOfChanges: $roleTotalChanges
            },
            numberTotalChanges: ($totalChanges + $roleTotalChanges)
        }'
    rm -f "$_t1" "$_t2" "$_t3" "$_t4" "$_t5" "$_t6" "$_t7"
}
