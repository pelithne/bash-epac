#!/usr/bin/env bash
# lib/exports/export-output.sh — Output helpers for export operations
# Replaces: Out-PolicyDefinition.ps1, Out-PolicyExemptions.ps1, Out-PolicyAssignmentFile.ps1

[[ -n "${_EPAC_EXPORT_OUTPUT_LOADED:-}" ]] && return 0
readonly _EPAC_EXPORT_OUTPUT_LOADED=1

# ─── Out-PolicyDefinition equivalent ────────────────────────────────────────
# Writes a policy/policyset definition to a JSON file.
# Usage: epac_out_policy_definition <definition_json> <folder> <properties_by_name_file>
#        <invalid_chars> <id> <file_extension>
# properties_by_name_file: temp file tracking seen names (JSON object)
epac_out_policy_definition() {
    local definition="$1"
    local folder="$2"
    local properties_by_name_file="$3"
    local invalid_chars="$4"
    local id="$5"
    local file_extension="$6"

    local name
    name="$(echo "$definition" | jq -r '.name')"
    local properties
    properties="$(echo "$definition" | jq '.properties')"
    local display_name
    display_name="$(echo "$properties" | jq -r '.displayName // ""')"
    [[ -z "$display_name" ]] && display_name="$name"

    local metadata
    metadata="$(echo "$properties" | jq '.metadata // {}')"
    local sub_folder="Unknown Category"
    local category
    category="$(echo "$metadata" | jq -r '.category // empty')"
    if [[ -n "$category" ]]; then
        sub_folder="$category"
    fi

    local full_path
    full_path="$(epac_get_definitions_full_path "$folder" "$name" "$display_name" "$invalid_chars" "$file_extension" \
        --sub-folder "$sub_folder" --max-sub-folder 30 --max-filename 100)"

    # Check for duplicates
    local seen_names
    seen_names="$(cat "$properties_by_name_file")"
    local already_seen
    already_seen="$(echo "$seen_names" | jq --arg n "$name" 'has($n)')"
    if [[ "$already_seen" == "false" ]]; then
        echo "$seen_names" | jq --arg n "$name" --argjson p "$properties" '.[$n] = $p' > "$properties_by_name_file"
    fi

    # Remove null fields
    definition="$(epac_remove_null_fields "$definition")"

    # Build output with schema
    local schema="https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-definition-schema.json"
    local has_policy_defs
    has_policy_defs="$(echo "$properties" | jq 'has("policyDefinitions")')"
    if [[ "$has_policy_defs" == "true" ]]; then
        schema="https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-set-definition-schema.json"
    fi

    local out_definition
    out_definition="$(jq -n --arg s "$schema" --argjson d "$definition" \
        '{"$schema": $s} + $d')"

    # Ensure directory exists & write
    mkdir -p "$(dirname "$full_path")"
    echo "$out_definition" | jq '.' > "$full_path"
    epac_log_debug "Wrote definition: $full_path"
}

# ─── Out-PolicyAssignmentFile equivalent ────────────────────────────────────
# Writes a policy assignment file from a per-definition tree.
# Usage: epac_out_policy_assignment_file <per_definition_json_file> <property_names_json>
#        <assignments_folder> <invalid_chars> <file_extension>
epac_out_policy_assignment_file() {
    local per_definition_file="$1"
    local property_names_json="$2"
    local assignments_folder="$3"
    local invalid_chars="$4"
    local file_extension="$5"

    local per_def_json
    per_def_json="$(cat "$per_definition_file")"
    local definition
    definition="$(echo "$per_def_json" | jq '.definitionEntry')"
    local definition_kind
    definition_kind="$(echo "$definition" | jq -r '.kind')"
    local definition_name
    definition_name="$(echo "$definition" | jq -r '.name')"
    local definition_id
    definition_id="$(echo "$definition" | jq -r '.id')"
    local definition_display_name
    definition_display_name="$(echo "$definition" | jq -r '.displayName // ""')"
    local is_builtin
    is_builtin="$(echo "$definition" | jq -r '.isBuiltin')"

    # File suffix from kind
    local kind_string
    kind_string="$(echo "$definition_kind" | sed 's/Definitions//')"
    local full_path
    full_path="$(epac_get_definitions_full_path "$assignments_folder" "$definition_name" \
        "$definition_display_name" "$invalid_chars" "$file_extension" \
        --file-suffix "-${kind_string}" --max-sub-folder 30 --max-filename 100)"

    # Build definitionEntry
    local def_entry
    if [[ "$is_builtin" == "true" ]]; then
        if [[ "$definition_kind" == "policySetDefinitions" ]]; then
            def_entry="$(jq -n --arg id "$definition_id" --arg dn "$definition_display_name" \
                '{policySetId: $id, displayName: $dn}')"
        else
            def_entry="$(jq -n --arg id "$definition_id" --arg dn "$definition_display_name" \
                '{policyId: $id, displayName: $dn}')"
        fi
    else
        if [[ "$definition_kind" == "policySetDefinitions" ]]; then
            def_entry="$(jq -n --arg n "$definition_name" --arg dn "$definition_display_name" \
                '{policySetName: $n, displayName: $dn}')"
        else
            def_entry="$(jq -n --arg n "$definition_name" --arg dn "$definition_display_name" \
                '{policyName: $n, displayName: $dn}')"
        fi
    fi

    # Build initial assignment definition
    local assignment_def
    assignment_def="$(jq -n --arg s "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-assignment-schema.json" \
        --argjson de "$def_entry" \
        '{"$schema": $s, nodeName: "/root", definitionEntry: $de}')"

    # Export tree into assignment structure
    assignment_def="$(epac_export_assignment_node "$per_definition_file" "$assignment_def" "$property_names_json")"

    # Move scope from top level to children if both exist
    local has_children
    has_children="$(echo "$assignment_def" | jq 'has("children")')"
    local has_scope
    has_scope="$(echo "$assignment_def" | jq 'has("scope")')"
    if [[ "$has_children" == "true" && "$has_scope" == "true" ]]; then
        assignment_def="$(echo "$assignment_def" | jq '
            .children = [.children[] | .scope = $node.scope] | del(.scope)
        ' --argjson node "$assignment_def")"
    fi

    # Write file
    mkdir -p "$(dirname "$full_path")"
    echo "$assignment_def" | jq '.' > "$full_path"
    epac_log_debug "Wrote assignment file: $full_path"
}

# ─── Out-PolicyExemptions equivalent ────────────────────────────────────────
# Exports exemptions to JSON and/or CSV files.
# Usage: epac_out_policy_exemptions <exemptions_json> <pac_environment_json>
#        <exemptions_folder> [--json] [--csv] [--file-extension ext] [--active-only]
epac_out_policy_exemptions() {
    local exemptions_json="$1"
    local pac_environment="$2"
    local exemptions_folder="$3"
    shift 3

    local output_json=false
    local output_csv=false
    local file_extension="json"
    local active_only=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) output_json=true; shift ;;
            --csv) output_csv=true; shift ;;
            --file-extension) file_extension="$2"; shift 2 ;;
            --active-only) active_only=true; shift ;;
            *) shift ;;
        esac
    done

    local pac_selector
    pac_selector="$(echo "$pac_environment" | jq -r '.pacSelector')"
    local output_path="${exemptions_folder}/${pac_selector}"
    mkdir -p "$output_path"

    local count
    count="$(echo "$exemptions_json" | jq 'length')"
    epac_write_section "Outputting Policy Exemptions"
    epac_write_status "Found $count exemptions" "success" 2

    # Sort metadata keys
    exemptions_json="$(echo "$exemptions_json" | jq '
        [.[] | .metadata = (.metadata | to_entries | sort_by(.key) | from_entries)
             | if .metadata.epacMetadata then
                 .metadata.epacMetadata = (.metadata.epacMetadata | to_entries | sort_by(.key) | from_entries)
               else . end
        ]
    ')"

    local stem
    local status_filter
    if $active_only; then
        stem="${output_path}/active-exemptions"
        status_filter='select(.status == "active" or .status == "active-expiring-within-15-days")'
        epac_write_section "Active Exemptions"
    else
        stem="${output_path}/all-exemptions"
        status_filter='.'
        epac_write_section "All Exemptions"
    fi
    epac_write_status "Environment: $pac_selector" "info" 2

    if $output_json; then
        local json_file="${stem}.${file_extension}"
        local selected
        selected="$(echo "$exemptions_json" | jq --arg sf "$status_filter" "[.[] | $status_filter |
            {
                name,
                displayName,
                description,
                exemptionCategory,
                expiresOn,
                scope,
                policyAssignmentId,
                policyDefinitionReferenceIds,
                resourceSelectors,
                metadata: (if .metadata then (.metadata | del(.pacOwnerId) | if . == {} then null else . end) else null end),
                assignmentScopeValidation
            }
            $(if ! $active_only; then echo '+ {status, expiresInDays: (if .expiresInDays == 2147483647 then "n/a" else .expiresInDays end)}'; fi)
        ]")"

        # Force metadata ordering: deployedBy first
        selected="$(echo "$selected" | jq '
            [.[] | if .metadata then
                .metadata = ({deployedBy: .metadata.deployedBy, epacMetadata: .metadata.epacMetadata} +
                    (.metadata | del(.deployedBy, .epacMetadata)))
            else . end]
        ')"

        local out_obj
        out_obj="$(jq -n --arg s "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-exemption-schema.json" \
            --argjson e "$selected" '{"$schema": $s, exemptions: $e}')"
        echo "$out_obj" | jq '.' > "$json_file"
        epac_write_status "Wrote $json_file" "success" 2
    fi

    if $output_csv; then
        local csv_file="${stem}.csv"
        local csv_header
        if $active_only; then
            csv_header="name,displayName,description,exemptionCategory,expiresOn,scope,policyAssignmentId,policyDefinitionReferenceIds,resourceSelectors,metadata,assignmentScopeValidation"
        else
            csv_header="name,displayName,description,exemptionCategory,expiresOn,status,expiresInDays,scope,policyAssignmentId,policyDefinitionReferenceIds,resourceSelectors,metadata,assignmentScopeValidation"
        fi

        # Build CSV lines using jq
        local csv_content
        csv_content="$(echo "$exemptions_json" | jq -r --arg active "$active_only" "
            [.[] | $status_filter] |
            if length == 0 then empty
            else .[] |
                def csv_escape: tostring | if test(\",|\\\"|\n\") then \"\\\"\" + gsub(\"\\\"\"; \"\\\"\\\"\") + \"\\\"\" else . end;
                def join_refs: if .policyDefinitionReferenceIds then (.policyDefinitionReferenceIds | join(\"&\")) else \"\" end;
                def meta_str: if .metadata then (.metadata | del(.pacOwnerId) | if . == {} then \"\" else tojson end) else \"\" end;
                def rs_str: if .resourceSelectors then (.resourceSelectors | tojson) else \"\" end;
                def expires_days: if .expiresInDays == 2147483647 then \"n/a\" else (.expiresInDays // \"\" | tostring) end;
                def asv_str: .assignmentScopeValidation // \"\";
                [
                    (.name // \"\" | csv_escape),
                    (.displayName // \"\" | csv_escape),
                    (.description // \"\" | csv_escape),
                    (.exemptionCategory // \"\" | csv_escape),
                    (.expiresOn // \"\" | csv_escape),
                    $(if ! $active_only; then echo '(.status // "" | csv_escape), (expires_days | csv_escape),'; fi)
                    (.scope // \"\" | csv_escape),
                    (.policyAssignmentId // \"\" | csv_escape),
                    (join_refs | csv_escape),
                    (rs_str | csv_escape),
                    (meta_str | csv_escape),
                    (asv_str | csv_escape)
                ] | join(\",\")
            end
        ")"

        echo "$csv_header" > "$csv_file"
        if [[ -n "$csv_content" ]]; then
            echo "$csv_content" >> "$csv_file"
        fi
        epac_write_status "Wrote $csv_file" "success" 2
    fi
}

# ─── Ownership CSV helper ──────────────────────────────────────────────────
# Writes the ownership CSV from collected rows.
# Usage: epac_write_ownership_csv <rows_json_array> <csv_path>
epac_write_ownership_csv() {
    local rows_json="$1"
    local csv_path="$2"

    mkdir -p "$(dirname "$csv_path")"
    echo "pacSelector,kind,owner,principalId,lastChange,category,displayName,id" > "$csv_path"

    echo "$rows_json" | jq -r '
        .[] |
        def csv_escape: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
        [
            (.pacSelector // "" | csv_escape),
            (.kind // "" | csv_escape),
            (.owner // "" | csv_escape),
            (.principalId // "" | csv_escape),
            (.lastChange // "" | csv_escape),
            (.category // "" | csv_escape),
            (.displayName // "" | csv_escape),
            (.id // "" | csv_escape)
        ] | join(",")
    ' >> "$csv_path"
}
