#!/usr/bin/env bash
# lib/plans/exemptions-plan.sh — Exemptions plan building
# Replaces: Build-ExemptionsPlan.ps1, Get-CalculatedPolicyAssignmentsAndReferenceIds.ps1
# Reads exemption definition files (JSON/JSONC/CSV), resolves assignment references,
# compares with deployed exemptions, produces new/update/replace/delete plan.

[[ -n "${_EPAC_EXEMPTIONS_PLAN_LOADED:-}" ]] && return 0
readonly _EPAC_EXEMPTIONS_PLAN_LOADED=1

_EPAC_EXPLAN_DIR="${BASH_SOURCE[0]%/*}"
source "${_EPAC_EXPLAN_DIR}/../core.sh"
source "${_EPAC_EXPLAN_DIR}/../json.sh"
source "${_EPAC_EXPLAN_DIR}/../utils.sh"
source "${_EPAC_EXPLAN_DIR}/../output.sh"
source "${_EPAC_EXPLAN_DIR}/../validators.sh"
source "${_EPAC_EXPLAN_DIR}/../azure-resources.sh"

###############################################################################
# Helper: Build calculated policy assignments and reference IDs
###############################################################################
# Pre-processes assignments into lookup tables for exemption resolution.
# Arguments:
#   $1 - all_assignments: JSON { id: assignment }
#   $2 - combined_policy_details: JSON { policies:{}, policySets:{} }
# Outputs JSON:
# {
#   byAssignmentId: { assignId: [calcAssign...] },
#   byPolicySetId: { policySetId: [calcAssign...] },
#   byPolicyId: { policyId: [calcAssign...] }
# }

_epac_get_calculated_assignments() {
    local all_assignments="$1"
    local combined_policy_details="$2"

    local _tmp_asgn _tmp_details
    _tmp_asgn="$(mktemp)"
    _tmp_details="$(mktemp)"
    echo "$all_assignments" > "$_tmp_asgn"
    echo "$combined_policy_details" > "$_tmp_details"

    jq -f "${_EPAC_EXPLAN_DIR}/../jq/calculated-assignments.jq" \
        --slurpfile details "$_tmp_details" \
        "$_tmp_asgn"
    local rc=$?
    rm -f "$_tmp_asgn" "$_tmp_details"
    return $rc
}

###############################################################################
# Helper: Resolve assignment for exemption entry
###############################################################################
# Arguments:
#   $1 - entry: JSON exemption entry
#   $2 - calculated_assignments: JSON from _epac_get_calculated_assignments
#   $3 - policy_definitions_scopes: JSON array of scopes
#   $4 - all_policy_definitions: JSON { id: def }
#   $5 - all_policy_set_definitions: JSON { id: setDef }
# Outputs JSON array of matching calculated assignments (or empty [])

_epac_resolve_exemption_assignments() {
    local entry="$1"
    local calculated_assignments="$2"
    local policy_definitions_scopes="$3"
    local all_policy_definitions="$4"
    local all_policy_set_definitions="$5"

    local policy_assignment_id
    policy_assignment_id="$(echo "$entry" | jq -r '.policyAssignmentId // empty')"
    local policy_def_name
    policy_def_name="$(echo "$entry" | jq -r '.policyDefinitionName // empty')"
    local policy_def_id
    policy_def_id="$(echo "$entry" | jq -r '.policyDefinitionId // empty')"
    local policy_set_def_name
    policy_set_def_name="$(echo "$entry" | jq -r '.policySetDefinitionName // empty')"
    local policy_set_def_id
    policy_set_def_id="$(echo "$entry" | jq -r '.policySetDefinitionId // empty')"
    local assignment_ref_id
    assignment_ref_id="$(echo "$entry" | jq -r '.assignmentReferenceId // empty')"
    local scope_validation
    scope_validation="$(echo "$entry" | jq -r '.assignmentScopeValidation // "Default"')"

    # Parse assignmentReferenceId (CSV polymorphic field)
    if [[ -n "$assignment_ref_id" ]]; then
        local ref_lower="${assignment_ref_id,,}"
        if [[ "$ref_lower" == policydefinitions/* ]]; then
            policy_def_name="${assignment_ref_id#*/}"
        elif [[ "$ref_lower" == */providers/microsoft.authorization/policydefinitions/* ]]; then
            policy_def_id="$assignment_ref_id"
        elif [[ "$ref_lower" == policysetdefinitions/* ]]; then
            policy_set_def_name="${assignment_ref_id#*/}"
        elif [[ "$ref_lower" == */providers/microsoft.authorization/policysetdefinitions/* ]]; then
            policy_set_def_id="$assignment_ref_id"
        elif [[ "$ref_lower" == */providers/microsoft.authorization/policyassignments/* ]]; then
            policy_assignment_id="$assignment_ref_id"
        fi
    fi

    # DoNotValidate mode: synthetic assignment
    if [[ "$scope_validation" == "DoNotValidate" && -n "$policy_assignment_id" ]]; then
        jq -n --arg id "$policy_assignment_id" '[{
            id: $id, name: $id, scope: "", displayName: "",
            assignedPolicyDefinitionId: "",
            isPolicyAssignment: true, allowReferenceIdsInRow: false,
            policyDefinitionReferenceIds: [], policyDefinitionIds: [],
            perPolicyReferenceIdTable: {}, notScopes: []
        }]'
        return 0
    fi

    # Strategy 1: Direct assignment ID
    if [[ -n "$policy_assignment_id" ]]; then
        local result
        result="$(echo "$calculated_assignments" | jq --arg k "$policy_assignment_id" '.byAssignmentId[$k] // []')"
        echo "$result"
        return 0
    fi

    # Strategy 2: Policy definition (by name or ID)
    if [[ -n "$policy_def_name" ]]; then
        local resolved_pid
        if resolved_pid="$(epac_confirm_policy_definition_used_exists "" "$policy_def_name" "$policy_definitions_scopes" "$all_policy_definitions" "true" 2>/dev/null)"; then
            echo "$calculated_assignments" | jq --arg k "$resolved_pid" '.byPolicyId[$k] // []'
            return 0
        fi
        echo "[]"
        return 0
    fi
    if [[ -n "$policy_def_id" ]]; then
        if epac_confirm_policy_definition_used_exists "$policy_def_id" "" "$policy_definitions_scopes" "$all_policy_definitions" "true" >/dev/null 2>&1; then
            echo "$calculated_assignments" | jq --arg k "$policy_def_id" '.byPolicyId[$k] // []'
            return 0
        fi
        echo "[]"
        return 0
    fi

    # Strategy 3: Policy set definition (by name or ID)
    if [[ -n "$policy_set_def_name" ]]; then
        local resolved_psid
        if resolved_psid="$(epac_confirm_policy_set_definition_used_exists "" "$policy_set_def_name" "$policy_definitions_scopes" "$all_policy_set_definitions" 2>/dev/null)"; then
            echo "$calculated_assignments" | jq --arg k "$resolved_psid" '.byPolicySetId[$k] // []'
            return 0
        fi
        echo "[]"
        return 0
    fi
    if [[ -n "$policy_set_def_id" ]]; then
        if epac_confirm_policy_set_definition_used_exists "$policy_set_def_id" "" "$policy_definitions_scopes" "$all_policy_set_definitions" >/dev/null 2>&1; then
            echo "$calculated_assignments" | jq --arg k "$policy_set_def_id" '.byPolicySetId[$k] // []'
            return 0
        fi
        echo "[]"
        return 0
    fi

    echo "[]"
}

###############################################################################
# Build exemptions plan
###############################################################################
# Arguments:
#   $1 - exemptions_root_folder: path to exemption files (JSON/JSONC/CSV)
#   $2 - pac_environment: JSON pac environment
#   $3 - scope_table: JSON { scope: {} }
#   $4 - all_definitions: JSON { policydefinitions:{}, policysetdefinitions:{} }
#   $5 - all_assignments: JSON { id: assignment }
#   $6 - combined_policy_details: JSON { policies:{}, policySets:{} }
#   $7 - replaced_assignments: JSON { id: assignment } (assignments marked replace)
#   $8 - deployed_exemptions: JSON { managed: { id: exemption } }
#   $9 - skip_not_scoped: "true"|"false"
#   $10 - fail_on_error: "true"|"false"
#
# Outputs JSON:
# {
#   exemptions: { new:{}, update:{}, replace:{}, delete:{},
#                 numberOfOrphans:N, numberOfExpired:N,
#                 numberUnchanged:N, numberOfChanges:N }
# }

epac_build_exemptions_plan() {
    local exemptions_root_folder="$1"
    local pac_environment="$2"
    local scope_table="$3"
    local all_definitions_arg="$4"
    local all_assignments_arg="$5"
    local combined_policy_details_arg="$6"
    local replaced_assignments="$7"
    local deployed_exemptions="$8"
    local skip_not_scoped="${9:-false}"
    local fail_on_error="${10:-false}"

    # Support file paths: if arg is a file path, read from file
    local all_definitions all_assignments combined_policy_details
    if [[ -f "$all_definitions_arg" ]]; then
        all_definitions="$(cat "$all_definitions_arg")"
    else
        all_definitions="$all_definitions_arg"
    fi
    if [[ -f "$all_assignments_arg" ]]; then
        all_assignments="$(cat "$all_assignments_arg")"
    else
        all_assignments="$all_assignments_arg"
    fi
    if [[ -f "$combined_policy_details_arg" ]]; then
        combined_policy_details="$(cat "$combined_policy_details_arg")"
    else
        combined_policy_details="$combined_policy_details_arg"
    fi

    local pac_owner_id
    pac_owner_id="$(echo "$pac_environment" | jq -r '.pacOwnerId')"
    local pac_selector
    pac_selector="$(echo "$pac_environment" | jq -r '.pacSelector // "*"')"
    local deployed_by
    deployed_by="$(echo "$pac_environment" | jq -r '.deployedBy // empty')"
    local strategy
    strategy="$(echo "$pac_environment" | jq -r '.desiredState.strategy // "full"')"
    local policy_definitions_scopes
    policy_definitions_scopes="$(echo "$pac_environment" | jq '.policyDefinitionsScopes // []')"

    local all_policy_defs
    all_policy_defs="$(echo "$all_definitions" | jq '.policydefinitions // {}')"
    local all_policy_set_defs
    all_policy_set_defs="$(echo "$all_definitions" | jq '.policysetdefinitions // {}')"

    # Pre-calculate assignment lookup tables
    local calculated_assignments
    calculated_assignments="$(_epac_get_calculated_assignments "$all_assignments" "$combined_policy_details")"

    # Clone deployed managed exemptions as delete candidates
    local delete_candidates
    delete_candidates="$(echo "$deployed_exemptions" | jq '.managed // {}')"

    local unique_ids="{}"
    local exemptions_new="{}"
    local exemptions_update="{}"
    local exemptions_replace="{}"
    local exemptions_delete="{}"
    local number_unchanged=0
    local number_orphans=0
    local number_expired=0
    local has_errors="false"

    # Check folder
    if [[ ! -d "$exemptions_root_folder" ]]; then
        epac_write_status "Exemptions folder not found: ${exemptions_root_folder}" "warning" 2 >&2
        _epac_emit_exemptions_plan_result \
            "$exemptions_new" "$exemptions_update" "$exemptions_replace" "$exemptions_delete" \
            "$number_unchanged" "$number_orphans" "$number_expired"
        return 0
    fi

    # Collect files (JSON/JSONC/CSV)
    local -a files=()
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$exemptions_root_folder" -type f \( -name '*.json' -o -name '*.jsonc' -o -name '*.csv' \) -print0 2>/dev/null | sort -z)

    local file_count=${#files[@]}
    if [[ $file_count -eq 0 ]]; then
        epac_write_status "No exemption files found" "info" 2 >&2
        _epac_emit_exemptions_plan_result \
            "$exemptions_new" "$exemptions_update" "$exemptions_replace" "$exemptions_delete" \
            "$number_unchanged" "$number_orphans" "$number_expired"
        return 0
    fi

    epac_write_section "Processing ${file_count} exemption files" 0 >&2

    for file in "${files[@]}"; do
        local ext="${file##*.}"
        local entries="[]"

        if [[ "$ext" == "csv" ]]; then
            # Parse CSV: convert to JSON array of objects
            # Use jq -Rs for raw string then parse CSV
            if ! entries="$(_epac_parse_csv_exemptions "$file")"; then
                epac_log_error "Failed to parse CSV: ${file}" >&2
                has_errors="true"
                continue
            fi
        else
            # JSON/JSONC
            local file_content
            if ! file_content="$(epac_read_jsonc "$file")"; then
                epac_log_error "Failed to parse: ${file}" >&2
                has_errors="true"
                continue
            fi
            # Check if .exemptions array exists, otherwise treat root as array
            local content_type
            content_type="$(echo "$file_content" | jq -r 'type')"
            if [[ "$content_type" == "array" ]]; then
                entries="$file_content"
            elif [[ "$content_type" == "object" ]]; then
                entries="$(echo "$file_content" | jq '.exemptions // [.]')"
            fi
        fi

        local entry_count
        entry_count="$(echo "$entries" | jq 'length')"
        local ei=0
        while [[ $ei -lt $entry_count ]]; do
            local entry
            entry="$(echo "$entries" | jq --argjson i "$ei" '.[$i]')"

            # Extract fields
            local name display_name exemption_category description
            name="$(echo "$entry" | jq -r '.name // empty')"
            display_name="$(echo "$entry" | jq -r '.displayName // empty')"
            exemption_category="$(echo "$entry" | jq -r '.exemptionCategory // empty')"
            description="$(echo "$entry" | jq -r '.description // empty')"

            # Validate required fields
            if [[ -z "$name" ]]; then
                epac_log_error "Exemption in ${file} entry ${ei}: name is required" >&2
                has_errors="true"
                ei=$((ei + 1))
                continue
            fi
            if [[ -z "$display_name" ]]; then
                epac_log_error "Exemption '${name}': displayName is required" >&2
                has_errors="true"
                ei=$((ei + 1))
                continue
            fi
            if [[ -z "$exemption_category" ]]; then
                epac_log_error "Exemption '${name}': exemptionCategory is required" >&2
                has_errors="true"
                ei=$((ei + 1))
                continue
            fi
            if [[ "$exemption_category" != "Waiver" && "$exemption_category" != "Mitigated" ]]; then
                epac_log_error "Exemption '${name}': exemptionCategory must be 'Waiver' or 'Mitigated'" >&2
                has_errors="true"
                ei=$((ei + 1))
                continue
            fi
            if ! epac_confirm_valid_policy_resource_name "$name"; then
                epac_log_error "Exemption '${name}': invalid characters in name" >&2
                has_errors="true"
                ei=$((ei + 1))
                continue
            fi

            # Scope (single or array)
            local scopes_array="[]"
            local single_scope
            single_scope="$(echo "$entry" | jq -r '.scope // empty')"
            local multi_scopes
            multi_scopes="$(echo "$entry" | jq '.scopes // null')"
            if [[ -n "$single_scope" && "$multi_scopes" != "null" ]]; then
                epac_log_error "Exemption '${name}': cannot have both scope and scopes" >&2
                has_errors="true"
                ei=$((ei + 1))
                continue
            fi
            if [[ -n "$single_scope" ]]; then
                scopes_array="$(jq -n --arg s "$single_scope" '[$s]')"
            elif [[ "$multi_scopes" != "null" ]]; then
                scopes_array="$multi_scopes"
            else
                epac_log_error "Exemption '${name}': scope or scopes is required" >&2
                has_errors="true"
                ei=$((ei + 1))
                continue
            fi

            # Expiration
            local expires_on_raw
            expires_on_raw="$(echo "$entry" | jq -r '.expiresOn // empty')"
            local expires_on=""
            local is_expired="false"
            if [[ -n "$expires_on_raw" ]]; then
                expires_on="$expires_on_raw"
                # Check expiration
                local exp_epoch now_epoch
                if exp_epoch="$(date -d "$expires_on_raw" +%s 2>/dev/null)"; then
                    now_epoch="$(date +%s)"
                    if [[ $exp_epoch -lt $now_epoch ]]; then
                        is_expired="true"
                        number_expired=$((number_expired + 1))
                    fi
                fi
            fi

            # Policy definition reference IDs
            local pd_ref_ids
            pd_ref_ids="$(echo "$entry" | jq 'if (.policyDefinitionReferenceIds == "" or .policyDefinitionReferenceIds == null) then null else .policyDefinitionReferenceIds end')"
            # Handle "&" delimited string from CSV
            if [[ "$pd_ref_ids" != "null" ]]; then
                local ref_type
                ref_type="$(echo "$pd_ref_ids" | jq -r 'type')"
                if [[ "$ref_type" == "string" ]]; then
                    pd_ref_ids="$(echo "$pd_ref_ids" | jq -r '.' | tr '&' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R '.' | jq -s '.')"
                fi
            fi

            # Resource selectors (CSV stores as string, parse if JSON)
            local resource_selectors
            resource_selectors="$(echo "$entry" | jq 'if (.resourceSelectors | type) == "string" then (if .resourceSelectors == "" then null else ((.resourceSelectors | fromjson?) // null) end) else (.resourceSelectors // null) end')"

            # Metadata (CSV stores as string, need to parse)
            local user_metadata
            user_metadata="$(echo "$entry" | jq 'if (.metadata | type) == "string" then ((.metadata | fromjson?) // {}) else (.metadata // {}) end')"

            # Assignment scope validation
            local scope_validation
            scope_validation="$(echo "$entry" | jq -r '.assignmentScopeValidation // "Default"')"

            # Resolve assignments
            local calc_assignments
            calc_assignments="$(_epac_resolve_exemption_assignments "$entry" "$calculated_assignments" \
                "$policy_definitions_scopes" "$all_policy_defs" "$all_policy_set_defs")"

            local calc_count
            calc_count="$(echo "$calc_assignments" | jq 'length')"
            if [[ $calc_count -eq 0 ]]; then
                epac_log_warning "Exemption '${name}': no matching assignments found" >&2
                number_orphans=$((number_orphans + 1))
                if [[ "$fail_on_error" == "true" ]]; then
                    has_errors="true"
                fi
                ei=$((ei + 1))
                continue
            fi

            # Process each scope
            local scope_count
            scope_count="$(echo "$scopes_array" | jq 'length')"
            local si=0
            while [[ $si -lt $scope_count ]]; do
                local scope_raw
                scope_raw="$(echo "$scopes_array" | jq -r --argjson i "$si" '.[$i]')"

                # Parse postfix:scope format
                local scope_postfix="" current_scope="$scope_raw"
                if [[ "$scope_raw" == *:* ]]; then
                    scope_postfix="${scope_raw%%:*}"
                    current_scope="${scope_raw#*:}"
                fi

                # Process each matching assignment
                local ai=0
                while [[ $ai -lt $calc_count ]]; do
                    local calc_assign
                    calc_assign="$(echo "$calc_assignments" | jq --argjson i "$ai" '.[$i]')"
                    local policy_assignment_id
                    policy_assignment_id="$(echo "$calc_assign" | jq -r '.id')"
                    local policy_assignment_name
                    policy_assignment_name="$(echo "$calc_assign" | jq -r '.name')"

                    # Check scope is within assignment scope hierarchy
                    local assign_scope
                    assign_scope="$(echo "$calc_assign" | jq -r '.scope // empty')"
                    if [[ -n "$assign_scope" ]]; then
                        local scope_valid="false"
                        local scope_lower="${current_scope,,}"
                        local assign_lower="${assign_scope,,}"
                        if [[ "$scope_lower" == "$assign_lower" ]]; then
                            scope_valid="true"
                        elif [[ "$scope_lower" == "${assign_lower}"/* ]]; then
                            scope_valid="true"
                        else
                            # Check Azure hierarchy via scope table (handles MG → subscription relationships)
                            local _st_entry
                            _st_entry="$(echo "$scope_table" | jq --arg s "$scope_lower" '[to_entries[] | select((.key | ascii_downcase) == $s)] | .[0].value // null')"
                            if [[ "$_st_entry" != "null" && -n "$_st_entry" ]]; then
                                local _in_parent
                                _in_parent="$(echo "$_st_entry" | jq --arg p "$assign_lower" '[.parentTable | to_entries[] | select((.key | ascii_downcase) == $p)] | length > 0')"
                                if [[ "$_in_parent" == "true" ]]; then
                                    scope_valid="true"
                                fi
                            fi
                        fi
                        # Check not-scopes
                        if [[ "$scope_valid" == "true" && "$skip_not_scoped" != "true" ]]; then
                            local not_scopes_a
                            not_scopes_a="$(echo "$calc_assign" | jq '.notScopes // []')"
                            local ns_count
                            ns_count="$(echo "$not_scopes_a" | jq 'length')"
                            local nsi=0
                            while [[ $nsi -lt $ns_count ]]; do
                                local ns
                                ns="$(echo "$not_scopes_a" | jq -r --argjson i "$nsi" '.[$i]')"
                                if [[ "$current_scope" == "$ns" || "$current_scope" == "${ns}"/* ]]; then
                                    scope_valid="false"
                                    break
                                fi
                                nsi=$((nsi + 1))
                            done
                        fi
                        if [[ "$scope_valid" != "true" ]]; then
                            ai=$((ai + 1))
                            continue
                        fi
                    fi

                    # Compose exemption name and displayName
                    local exemption_name="$name"
                    local exemption_display_name="$display_name"
                    local exemption_description="$description"

                    # Add postfix
                    if [[ -n "$scope_postfix" ]]; then
                        exemption_display_name="${exemption_display_name} - ${scope_postfix}"
                        [[ -n "$exemption_description" ]] && exemption_description="${exemption_description} - ${scope_postfix}"
                    fi

                    # Add assignment disambiguation if policy-definition-specified
                    local is_policy_def_specified="false"
                    local pd_name pd_id psd_name psd_id
                    pd_name="$(echo "$entry" | jq -r '.policyDefinitionName // empty')"
                    pd_id="$(echo "$entry" | jq -r '.policyDefinitionId // empty')"
                    psd_name="$(echo "$entry" | jq -r '.policySetDefinitionName // empty')"
                    psd_id="$(echo "$entry" | jq -r '.policySetDefinitionId // empty')"
                    if [[ -n "$pd_name" || -n "$pd_id" || -n "$psd_name" || -n "$psd_id" ]]; then
                        is_policy_def_specified="true"
                        exemption_name="${exemption_name}-${policy_assignment_name}"
                        exemption_display_name="${exemption_display_name} - ${policy_assignment_name}"
                        [[ -n "$exemption_description" ]] && exemption_description="${exemption_description} - ${policy_assignment_name}"
                    fi

                    # Multi-assignment ordinal
                    if [[ $calc_count -gt 1 ]]; then
                        local ordinal_str
                        ordinal_str="$(printf "[%02d]" "$ai")"
                        exemption_name="${exemption_name}${ordinal_str}"
                        exemption_display_name="${exemption_display_name}${ordinal_str}"
                    fi

                    # Build exemption ID
                    local exemption_id="${current_scope}/providers/Microsoft.Authorization/policyExemptions/${exemption_name}"

                    # Duplicate check
                    local is_dup
                    is_dup="$(echo "$unique_ids" | jq --arg k "$exemption_id" 'has($k)')"
                    if [[ "$is_dup" == "true" ]]; then
                        epac_log_error "Duplicate exemption ID: ${exemption_id}" >&2
                        has_errors="true"
                        ai=$((ai + 1))
                        continue
                    fi
                    unique_ids="$(echo "$unique_ids" | jq --arg k "$exemption_id" '.[$k] = true')"

                    # Build metadata
                    local final_metadata
                    final_metadata="$(echo "$user_metadata" | jq --arg pid "$pac_owner_id" '.pacOwnerId = $pid')"
                    if [[ -n "$deployed_by" ]]; then
                        final_metadata="$(echo "$final_metadata" | jq --arg db "$deployed_by" 'if has("deployedBy") then . else .deployedBy = $db end')"
                    fi

                    # Build exemption object
                    local exemption_obj
                    exemption_obj="$(jq -n \
                        --arg id "$exemption_id" \
                        --arg name "$exemption_name" \
                        --arg dn "$exemption_display_name" \
                        --arg desc "$exemption_description" \
                        --arg ec "$exemption_category" \
                        --arg eo "$expires_on" \
                        --arg scope "$current_scope" \
                        --arg paid "$policy_assignment_id" \
                        --arg sv "$scope_validation" \
                        --argjson pdri "${pd_ref_ids:-null}" \
                        --argjson rsel "${resource_selectors:-null}" \
                        --argjson meta "$final_metadata" \
                        --argjson expired "$is_expired" \
                        '{
                            id: $id, name: $name, displayName: $dn,
                            description: $desc, exemptionCategory: $ec,
                            expiresOn: (if $eo == "" then null else $eo end),
                            scope: $scope, policyAssignmentId: $paid,
                            assignmentScopeValidation: $sv,
                            policyDefinitionReferenceIds: $pdri,
                            resourceSelectors: $rsel,
                            metadata: $meta, expired: $expired
                        }')"

                    # Remove from delete candidates
                    delete_candidates="$(echo "$delete_candidates" | jq --arg id "$exemption_id" 'del(.[$id])')"

                    # Compare with deployed
                    local deployed_ex
                    deployed_ex="$(echo "$deployed_exemptions" | jq --arg id "$exemption_id" '.managed[$id] // null')"

                    if [[ "$deployed_ex" != "null" ]]; then
                        # Check if assignment was replaced
                        local assign_in_replaced
                        assign_in_replaced="$(echo "$replaced_assignments" | jq --arg id "$policy_assignment_id" 'has($id)')"

                        local deployed_props
                        deployed_props="$(echo "$deployed_ex" | jq 'if .properties then .properties else . end')"
                        local deployed_paid
                        deployed_paid="$(echo "$deployed_props" | jq -r '.policyAssignmentId // empty')"

                        local needs_replace="false"
                        if [[ "$deployed_paid" != "$policy_assignment_id" ]]; then
                            needs_replace="true"
                        elif [[ "$assign_in_replaced" == "true" ]]; then
                            needs_replace="true"
                        fi

                        if [[ "$needs_replace" == "true" ]]; then
                            exemptions_replace="$(echo "$exemptions_replace" | jq --arg id "$exemption_id" --argjson d "$exemption_obj" '.[$id] = $d')"
                        else
                            # Detailed comparison
                            local changes=()
                            local deployed_dn deployed_desc deployed_ec deployed_eo
                            deployed_dn="$(echo "$deployed_props" | jq -r '.displayName // empty')"
                            deployed_desc="$(echo "$deployed_props" | jq -r '.description // empty')"
                            deployed_ec="$(echo "$deployed_props" | jq -r '.exemptionCategory // empty')"
                            deployed_eo="$(echo "$deployed_props" | jq -r '.expiresOn // empty')"

                            [[ "$deployed_dn" != "$exemption_display_name" ]] && changes+=("displayName")
                            [[ "$deployed_desc" != "$exemption_description" ]] && changes+=("description")
                            [[ "$deployed_ec" != "$exemption_category" ]] && changes+=("exemptionCategory")
                            [[ "$deployed_eo" != "$expires_on" ]] && changes+=("expiresOn")

                            # Metadata
                            local deployed_meta
                            deployed_meta="$(echo "$deployed_props" | jq '.metadata // {}')"
                            local meta_result
                            meta_result="$(epac_confirm_metadata_matches "$deployed_meta" "$final_metadata")"
                            local meta_match change_pac_owner
                            meta_match="$(echo "$meta_result" | jq -r '.match')"
                            change_pac_owner="$(echo "$meta_result" | jq -r '.changePacOwnerId')"
                            [[ "$meta_match" != "true" || "$change_pac_owner" == "true" ]] && changes+=("metadata")

                            # PolicyDefinitionReferenceIds
                            if ! epac_deep_equal \
                                "$(echo "$deployed_props" | jq '.policyDefinitionReferenceIds // null')" \
                                "${pd_ref_ids:-null}"; then
                                changes+=("policyDefinitionReferenceIds")
                            fi

                            # ResourceSelectors
                            if ! epac_deep_equal \
                                "$(echo "$deployed_props" | jq '.resourceSelectors // null')" \
                                "${resource_selectors:-null}"; then
                                changes+=("resourceSelectors")
                            fi

                            # AssignmentScopeValidation
                            local deployed_sv
                            deployed_sv="$(echo "$deployed_props" | jq -r '.assignmentScopeValidation // "Default"')"
                            [[ "$deployed_sv" != "$scope_validation" ]] && changes+=("assignmentScopeValidation")

                            if [[ ${#changes[@]} -eq 0 ]]; then
                                number_unchanged=$((number_unchanged + 1))
                            else
                                local changes_str
                                changes_str="$(IFS=','; echo "${changes[*]}")"
                                epac_write_status "Update (${changes_str}): ${exemption_display_name}" "update" 4 >&2
                                exemptions_update="$(echo "$exemptions_update" | jq --arg id "$exemption_id" --argjson d "$exemption_obj" '.[$id] = $d')"
                            fi
                        fi
                    else
                        # New exemption
                        epac_write_status "New: ${exemption_display_name}" "new" 4 >&2
                        exemptions_new="$(echo "$exemptions_new" | jq --arg id "$exemption_id" --argjson d "$exemption_obj" '.[$id] = $d')"
                    fi

                    ai=$((ai + 1))
                done
                si=$((si + 1))
            done
            ei=$((ei + 1))
        done
    done

    # Process delete candidates
    local del_keys
    del_keys="$(echo "$delete_candidates" | jq -r 'keys[]' 2>/dev/null || true)"
    while IFS= read -r del_id; do
        [[ -z "$del_id" ]] && continue
        local del_exemption
        del_exemption="$(echo "$delete_candidates" | jq --arg id "$del_id" '.[$id]')"

        local del_pac_owner_class
        del_pac_owner_class="$(epac_confirm_pac_owner "$pac_owner_id" "$del_exemption")"

        if epac_confirm_delete_for_strategy "$del_pac_owner_class" "$strategy" "false" "false"; then
            local del_display
            del_display="$(echo "$del_exemption" | jq -r '.displayName // .name // empty')"
            epac_write_status "Delete: ${del_display}" "delete" 4 >&2
            exemptions_delete="$(echo "$exemptions_delete" | jq --arg id "$del_id" --argjson d "$del_exemption" '.[$id] = $d')"
        fi
    done <<< "$del_keys"

    _epac_emit_exemptions_plan_result \
        "$exemptions_new" "$exemptions_update" "$exemptions_replace" "$exemptions_delete" \
        "$number_unchanged" "$number_orphans" "$number_expired"
}

###############################################################################
# CSV parser for exemption files
###############################################################################

_epac_parse_csv_exemptions() {
    local csv_file="$1"
    # Read CSV, skip empty lines, convert to JSON array of objects
    # Uses header row as keys
    local header=""
    local entries="[]"
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        # Skip empty lines and comments
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ -z "$header" ]]; then
            header="$line"
            continue
        fi
        # Convert CSV row to JSON object using header
        local obj
        obj="$(paste -d '|' <(echo "$header" | tr ',' '\n') <(echo "$line" | tr ',' '\n') | \
            jq -R 'split("|") | {key: .[0], value: .[1]}' | jq -s 'from_entries')" || continue
        entries="$(echo "$entries" | jq --argjson o "$obj" '. + [$o]')"
    done < "$csv_file"
    echo "$entries"
}

###############################################################################
# Emit exemptions plan result
###############################################################################

_epac_emit_exemptions_plan_result() {
    local new="$1" update="$2" replace="$3" delete="$4"
    local unchanged="$5" orphans="$6" expired="$7"

    local new_count update_count replace_count delete_count
    new_count="$(echo "$new" | jq 'length')"
    update_count="$(echo "$update" | jq 'length')"
    replace_count="$(echo "$replace" | jq 'length')"
    delete_count="$(echo "$delete" | jq 'length')"
    local total_changes=$((new_count + update_count + replace_count + delete_count))

    jq -n \
        --argjson new "$new" \
        --argjson update "$update" \
        --argjson replace "$replace" \
        --argjson delete "$delete" \
        --argjson unchanged "$unchanged" \
        --argjson orphans "$orphans" \
        --argjson expired "$expired" \
        --argjson totalChanges "$total_changes" \
        '{
            exemptions: {
                new: $new, update: $update, replace: $replace, delete: $delete,
                numberUnchanged: $unchanged, numberOfOrphans: $orphans,
                numberOfExpired: $expired, numberOfChanges: $totalChanges
            }
        }'
}
