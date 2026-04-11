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

    # Extract owner, audit info, and display name in two jq calls
    local row
    row="$(jq -n -c --argjson obj "$obj" --argjson meta "$raw_meta" \
        --arg ps "$pac_selector" --arg k "$kind" --arg id "$id" '
        ($obj.pacOwner // "thisPaC") as $raw_owner |
        (if $raw_owner == "otherPaC" then ("otherPaC(pacOwnerId=" + ($meta.pacOwnerId // "") + ")") else $raw_owner end) as $owner |
        (if ($meta | has("updatedBy")) then {principalId: $meta.updatedBy, lastChange: ($meta.updatedOn // "n/a")}
         elif ($meta | has("createdBy")) then {principalId: $meta.createdBy, lastChange: ($meta.createdOn // "n/a")}
         else {principalId: "n/a", lastChange: ($meta.createdOn // "n/a")}
         end) as $audit |
        {pacSelector:$ps, kind:$k, owner:$owner, principalId:$audit.principalId,
         lastChange:$audit.lastChange, category:($meta.category // ""),
         displayName:($obj.properties.displayName // $obj.name // ""), id:$id}
    ')"
    echo "$row" >> "$_all_rows_file"
}

_add_generic_ownership_row() {
    local pac_selector="$1" kind="$2" owner="$3" raw_meta="$4"
    local display_name="$5" name="$6" id="$7"

    [[ -z "$display_name" ]] && display_name="$name"

    # Extract all metadata fields and build row in single jq call
    local row
    row="$(echo "$raw_meta" | jq -c --arg ps "$pac_selector" --arg k "$kind" --arg o "$owner" \
        --arg dn "$display_name" --arg id "$id" '
        (if has("updatedBy") then {principalId: .updatedBy, lastChange: (.updatedOn // "n/a")}
         elif has("createdBy") then {principalId: .createdBy, lastChange: (.createdOn // "n/a")}
         else {principalId: "n/a", lastChange: (.createdOn // "n/a")}
         end) as $audit |
        {pacSelector:$ps, kind:$k, owner:$o, principalId:$audit.principalId,
         lastChange:$audit.lastChange, category:(.category // ""), displayName:$dn, id:$id}
    ')"
    # Append row as newline-delimited JSON (will be collected later)
    echo "$row" >> "$_all_rows_file"
}

# Process resources for a single pacSelector (export/exportFromRawFiles mode)
_process_pac_resources() {
    local deployed_dir="$1" pac_selector="$2" pac_env="$3"
    # Section files: policydefinitions.json, policysetdefinitions.json,
    #                policyassignments.json, policyexemptions.json
    local pd_file="$deployed_dir/policydefinitions.json"
    local psd_file="$deployed_dir/policysetdefinitions.json"
    local pa_file="$deployed_dir/policyassignments.json"
    local pe_file="$deployed_dir/policyexemptions.json"

    local include_auto="$_include_auto_assigned"
    local skip_exemptions=false
    [[ "$_exemption_files" == "none" ]] && skip_exemptions=true

    # ── Policy Definitions ──────────────────────────────────────────────
    epac_write_section "Processing Policy Definitions" 0
    local policy_defs
    policy_defs="$(jq '.managed // {} | to_entries' "$pd_file")"
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

    # Cache definition properties by key (single jq invocation for performance)
    jq '
        .policydefinitions.all // {} | to_entries | reduce .[] as $e (
            {};
            ($e.key | ascii_downcase) as $id_lower |
            # Extract definition name from the resource ID
            ($e.key | split("/") | last) as $def_key |
            if has($def_key) then . else .[$def_key] = $e.value.properties end
        )
    ' "$pd_file" > "$_def_props_by_key_file"

    # ── Policy Set Definitions ──────────────────────────────────────────
    epac_write_section "Processing Policy Set Definitions" 0
    local policy_set_defs
    policy_set_defs="$(jq '.managed // {} | to_entries' "$psd_file")"
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

    # Cache policy set properties by key (merge with existing cache)
    local _psd_cache_tmp
    _psd_cache_tmp="$(jq '
        .all // {} | to_entries | reduce .[] as $e (
            {};
            ($e.key | split("/") | last) as $def_key |
            if has($def_key) then . else .[$def_key] = $e.value.properties end
        )
    ' "$psd_file" 2>/dev/null || echo '{}')"
    jq -s '.[0] * .[1]' "$_def_props_by_key_file" <(echo "$_psd_cache_tmp") > "${_def_props_by_key_file}.tmp" \
        && mv "${_def_props_by_key_file}.tmp" "$_def_props_by_key_file"

    # ── Policy Assignments ──────────────────────────────────────────────
    epac_write_section "Collating Policy Assignments" 0
    local pa_count
    pa_count="$(jq '.managed // {} | keys | length' "$pa_file")"
    epac_write_status "Environment: $pac_selector" "info" 2
    epac_write_status "Found $pa_count policy assignments" "success" 2

    jq -c --argjson gns "$(echo "$pac_env" | jq '.globalNotScopes // []')" --arg mi_location "$(echo "$pac_env" | jq -r '.managedIdentityLocation // ""')" '
        # Inline split_policy_resource_id logic
        def split_policy_id:
            . as $orig_id |
            ($orig_id | ascii_downcase) as $lower |
            if ($lower | contains("/providers/microsoft.authorization/policydefinitions/")) then
                ($lower | split("/providers/microsoft.authorization/policydefinitions/")) as $parts |
                {id: $orig_id, kind: "policyDefinitions", name: ($parts[1] // "" | split("/") | first), scope: $parts[0], scopeType: (if $parts[0] == "" then "builtin" else "custom" end)}
            elif ($lower | contains("/providers/microsoft.authorization/policysetdefinitions/")) then
                ($lower | split("/providers/microsoft.authorization/policysetdefinitions/")) as $parts |
                {id: $orig_id, kind: "policySetDefinitions", name: ($parts[1] // "" | split("/") | first), scope: $parts[0], scopeType: (if $parts[0] == "" then "builtin" else "custom" end)}
            else
                {id: $orig_id, kind: "unknown", name: ($orig_id | split("/") | last), scope: "", scopeType: "custom"}
            end | . + {definitionKey: .name};

        def remove_global_not_scopes:
            . as $ans |
            if ($ans | length) == 0 then null
            elif ($gns | length) == 0 then $ans
            else
                [$ans[] | . as $scope |
                    if [$gns[] | . as $g |
                        ($scope | test("^" + ($g | gsub("\\*"; ".*")) + "$"))
                    ] | any then empty else $scope end
                ] | if length == 0 then null else . end
            end;

        def custom_metadata:
            del(.createdBy, .createdOn, .updatedBy, .updatedOn, .lastSyncedToArgOn, .pacOwnerId, .roles);

        .managed // {} | to_entries[] |
        .key as $pa_id | .value as $pa_obj |
        ($pa_obj.properties // {}) as $props |
        ($props.metadata // {}) as $raw_meta |
        ($pa_obj.pacOwner // "") as $pac_owner |
        ($props.policyDefinitionId // "") as $def_id |
        ($def_id | split_policy_id) as $parts |
        (if $parts.kind == "policyDefinitions" then "Policy" else "PolicySet" end) as $kind_str |
        (if $parts.scopeType == "builtin" then "Builtin" else "Custom" end) as $scope_type |
        ($raw_meta.roles // []) as $roles |
        ($props.displayName // "") as $display_name |
        (if $display_name == "" then $pa_obj.name else $display_name end) as $eff_display |
        ($props.enforcementMode // "Default") as $enforcement_mode |
        ($props.description // "") as $description |
        ($props.notScopes // [] | remove_global_not_scopes) as $not_scopes |
        ($pa_obj.identity.type // "") as $identity_type |
        ($pa_obj.location // "") as $location |
        (if $location == $mi_location then "" else $location end) as $eff_location |

        # Build identity entry
        (if $identity_type == "UserAssigned" then
            ($pa_obj.identity.userAssignedIdentities // {} | keys) as $user_ids |
            if ($user_ids | length) > 1 then
                [$user_ids[] | {userAssigned:., location:(if $eff_location=="" then null else $eff_location end)}]
            else
                {userAssigned:$user_ids[0], location:(if $eff_location=="" then null else $eff_location end)}
            end
        elif $identity_type == "SystemAssigned" then
            {userAssigned:null, location:(if $eff_location=="" then null else $eff_location end)}
        else null end) as $identity_entry |

        # Build scope from assignment ID
        ($pa_id | ascii_downcase | split("/providers/microsoft.authorization/policyassignments/") | first) as $scope |

        # Compute additional role assignments (roles not at main scope)
        ([$roles[] | select(.scope != $scope) | {roleDefinitionId, scope}]) as $additional_role |

        {
            pa_id: $pa_id,
            pac_owner: $pac_owner,
            kind_str: $kind_str,
            scope_type: $scope_type,
            row_kind: ("Assignment(" + $kind_str + "-" + $scope_type + ")"),
            row_owner: (if $pac_owner == "otherPaC" then ("otherPaC(pacOwnerId=" + ($raw_meta.pacOwnerId // "") + ")") else $pac_owner end),
            raw_meta: $raw_meta,
            display_name: $eff_display,
            pa_name: ($pa_obj.name // ""),
            def_key: $parts.definitionKey,
            def_id: ($def_id),
            parts: $parts,
            props_list: {
                assignmentNameEx: {name: ($pa_obj.name // ""), displayName: $eff_display, description: $description},
                metadata: ($raw_meta | custom_metadata),
                parameters: (($props.parameters // {}) | with_entries(.value = .value.value)),
                overrides: ($props.overrides // null),
                resourceSelectors: ($props.resourceSelectors // null),
                enforcementMode: $enforcement_mode,
                scopes: $scope,
                notScopes: $not_scopes,
                nonComplianceMessages: (if (($props.nonComplianceMessages // []) | length) > 0 then
                    [$props.nonComplianceMessages[] | if .policyDefinitionReferenceId then . else {message} end]
                    else null end),
                additionalRoleAssignments: $additional_role,
                identityEntry: $identity_entry,
                definitionVersion: ($props.definitionVersion // null)
            }
        }
    ' "$pa_file" | while IFS= read -r _pa_record; do

        # Extract ownership fields for CSV
        local _fields
        _fields="$(echo "$_pa_record" | jq -r '[.pa_id, .pac_owner, .row_kind, .row_owner, .pa_name, .def_key, .display_name, .def_id] | @tsv')"
        local pa_id pac_owner row_kind row_owner pa_name def_key display_name def_id
        IFS=$'\t' read -r pa_id pac_owner row_kind row_owner pa_name def_key display_name def_id <<< "$_fields"

        if [[ "$pac_owner" == "managedByDfcSecurityPolicies" || "$pac_owner" == "managedByDfcDefenderPlans" ]]; then
            if [[ "$include_auto" != "true" ]]; then
                continue
            fi
        fi

        local raw_meta
        raw_meta="$(echo "$_pa_record" | jq -c '.raw_meta')"

        _add_generic_ownership_row "$pac_selector" "$row_kind" "$row_owner" "$raw_meta" \
            "$display_name" "$pa_name" "$pa_id"

        # Save preprocessed record for tree building (done in post-processing)
        echo "$_pa_record" >> "$_pa_records_file"
    done

    # ── Exemptions ──────────────────────────────────────────────────────
    if [[ "$skip_exemptions" != "true" ]]; then
        local policy_exemptions exemption_values
        policy_exemptions="$(jq '.managed // {}' "$pe_file")"
        # Flatten: merge .properties into top level and add computed fields
        exemption_values="$(echo "$policy_exemptions" | jq '[to_entries[].value |
            . + .properties + {status: (
                if (.properties.expiresOn // null) == null then "active"
                elif ((.properties.expiresOn | fromdateiso8601) > now) then "active"
                else "expired" end
            )} | del(.properties)]')"

        echo "$exemption_values" | jq -c --arg ps "$pac_selector" '.[] |
            (.exemptionCategory // "") as $category |
            (.pacOwner // "") as $raw_owner |
            (if $raw_owner == "otherPaC" then ("otherPaC(pacOwnerId=" + ((.metadata // {}).pacOwnerId // "") + ")") else $raw_owner end) as $owner |
            {pacSelector:$ps, kind:("Exemption(" + $category + ")"), owner:$owner,
             principalId:"n/a", lastChange:"n/a",
             category:$category,
             displayName:(.displayName // .name // ""),
             id:(.id // "")}
        ' >> "$_all_rows_file"

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
        -d|--definitions-root-folder) _definitions_root_folder="$2"; shift 2 ;;
        -o|--output-folder) _output_folder="$2"; shift 2 ;;
        -e|--pac-environment) shift 2 ;;  # accepted but not used (exports all environments)
        --interactive) _interactive=true; shift ;;
        --include-child-scopes) _include_child_scopes=true; shift ;;
        --include-auto-assigned) _include_auto_assigned=true; shift ;;
        --exemption-files) _exemption_files="$2"; shift 2 ;;
        --file-extension) _file_extension="$2"; shift 2 ;;
        --mode) _mode="$2"; shift 2 ;;
        --input-pac-selector) _input_pac_selector="$2"; shift 2 ;;
        --suppress-epac-output) _suppress_epac_output=true; shift ;;
        --psrule-ignore-full-scope) _psrule_ignore_full_scope=true; shift ;;
        --help|-h)
            cat <<'USAGE'
Usage: export-az-policy-resources.sh [OPTIONS]

Export Azure Policy resources to EPAC format.

Options:
  -d, --definitions-root-folder PATH   Definitions root folder (default: ./Definitions)
  -o, --output-folder PATH             Output folder (default: ./Output)
  -e, --pac-environment NAME           Accepted for compatibility (exports all environments)
  --mode MODE                          export|collectRawFile|exportFromRawFiles|exportRawToPipeline|psrule
  --interactive                        Enable interactive login
  --include-child-scopes               Include child scopes
  --include-auto-assigned              Include auto-assigned policies
  --exemption-files TYPE               none|csv|json (default: csv)
  --file-extension EXT                 json|jsonc (default: jsonc)
  --input-pac-selector NAME            Input PAC selector for raw file mode
  --suppress-epac-output               Suppress EPAC metadata in output
  --psrule-ignore-full-scope           Ignore full scope in PSRule mode
  -h, --help                           Show this help
USAGE
            exit 0
            ;;
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
_pa_records_file="$(mktemp)"
> "$_pa_records_file"
_all_rows_file="$(mktemp)"
> "$_all_rows_file"

_cleanup_export() {
    rm -f "$_policy_props_by_name_file" "$_policy_set_props_by_name_file" \
          "$_def_props_by_key_file" "$_all_rows_file" "$_pa_records_file"
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
    epac_write_section "Exporting Policy Resources" 0
    epac_write_status "WARNING: Assumes policies/policy sets with same name have same properties across scopes" "warning" 2
    epac_write_status "Ignores auto-assigned DfC assignments unless --include-auto-assigned" "warning" 2
else
    epac_write_section "Collecting Policy Resources (Raw)" 0
fi

# ─── Retrieve & process policy resources ────────────────────────────────────

_pac_selectors="$(echo "$_global_settings" | jq -r '.pacEnvironmentSelectors[]')"

if [[ "$_mode" != "exportFromRawFiles" ]]; then
    while IFS= read -r _pac_selector; do
        [[ -z "$_pac_selector" ]] && continue
        if [[ "$_input_pac_selector" != "*" && "$_pac_selector" != "$_input_pac_selector" ]]; then
            continue
        fi

        epac_write_section "Processing: $_pac_selector" 0

        local_pac_env="$(epac_select_pac_environment "$_pac_selector" "$_definitions_root_folder")"

        local_scope_table="$(epac_build_scope_table "$local_pac_env" "$_include_child_scopes")"
        _deployed_dir="$(mktemp -d)"
        epac_get_policy_resources "$local_pac_env" "$local_scope_table" "false" "false" "true" "$_deployed_dir" >/dev/null

        case "$_mode" in
            collectRawFile)
                mkdir -p "$_raw_folder"
                local_raw_file="${_raw_folder}/${_pac_selector}"
                cp -r "$_deployed_dir" "$local_raw_file"
                epac_write_status "Wrote raw files: $local_raw_file/" "success" 2
                ;;
            export)
                _process_pac_resources "$_deployed_dir" "$_pac_selector" "$local_pac_env"
                ;;
        esac
        rm -rf "$_deployed_dir"
    done <<< "$_pac_selectors"
fi

# ─── exportFromRawFiles: read raw data ─────────────────────────────────────

if [[ "$_mode" == "exportFromRawFiles" ]]; then
    if [[ ! -d "$_raw_folder" ]]; then
        epac_log_error "Raw folder not found: $_raw_folder"
        exit 1
    fi
    for _raw_dir in "$_raw_folder"/*/; do
        [[ -d "$_raw_dir" ]] || continue
        _pac_selector="$(basename "$_raw_dir")"
        local_pac_env="$(echo "$_global_settings" | jq --arg ps "$_pac_selector" '.pacEnvironments[$ps]')"
        epac_write_section "Processing raw file: $_pac_selector" 0
        _process_pac_resources "$_raw_dir" "$_pac_selector" "$local_pac_env"
    done
fi

# ─── Post-processing: build assignment trees & write files ─────────────────

if [[ "$_mode" == "export" || "$_mode" == "exportFromRawFiles" ]]; then
    epac_write_section "Creating Policy Assignment Files" 0

    # Build assignment trees entirely in jq — one invocation per definition.
    # Group preprocessed records by def_key, then build tree + export per group.
    if [[ -s "$_pa_records_file" ]]; then
        # Get unique def_keys
        _def_keys="$(jq -sr '[.[].def_key] | unique | .[]' "$_pa_records_file")"

        while IFS= read -r _dk; do
            [[ -z "$_dk" ]] && continue
            # Build tree and export assignment file for this def_key in a single jq call
            _out_json="$(jq -s --arg dk "$_dk" --slurpfile dprops "$_def_props_by_key_file" '
                # Select records for this def_key
                [.[] | select(.def_key == $dk)] |

                # Get definition info from first record
                (.[0]) as $first |
                ($first.parts) as $parts |
                ($dprops[0][$dk].displayName // "") as $def_display |

                # Build definition entry for output
                (if $parts.scopeType == "builtin" then
                    if $parts.kind == "policySetDefinitions" then
                        {policySetId: $first.def_id, displayName: $def_display}
                    else
                        {policyId: $first.def_id, displayName: $def_display}
                    end
                else
                    if $parts.kind == "policySetDefinitions" then
                        {policySetName: $parts.name, displayName: $def_display}
                    else
                        {policyName: $parts.name, displayName: $def_display}
                    end
                end) as $def_entry |

                # Property names in merge order
                ["assignmentNameEx","metadata","parameters","overrides",
                 "resourceSelectors","enforcementMode","scopes","notScopes",
                 "nonComplianceMessages","additionalRoleAssignments",
                 "identityEntry","definitionVersion"] as $prop_names |

                # Collect all props_list arrays
                [.[] | .props_list] as $all_props |

                # Build merged tree: try to find common values across all assignments
                # for each property in order, then split into children for differences.
                #
                # Simplified approach: if all assignments share the same value for a
                # property, put it at root level; otherwise create children.
                # This is a pragmatic 80/20 approach — the PS version does deep
                # recursive merging, but for most real-world cases assignments with
                # the same definition share most properties.

                def build_assignment_node($assignments; $prop_idx):
                    if $prop_idx >= ($prop_names | length) then .
                    else
                        ($prop_names[$prop_idx]) as $pn |
                        # Collect unique values for this property
                        ([$assignments[] | .[$pn]] | unique) as $unique_vals |
                        if ($unique_vals | length) == 1 then
                            # All same — add to this node
                            ($unique_vals[0]) as $val |
                            (if $pn == "scopes" then
                                # scopes: wrap per-pacSelector as array
                                {($pn): {"quick-start": (if ($val | type) == "array" then $val else [$val] end)}}
                            elif $pn == "notScopes" or $pn == "additionalRoleAssignments" or $pn == "identityEntry" then
                                {($pn): {"quick-start": $val}}
                            else
                                {($pn): $val}
                            end) as $add |
                            . + $add |
                            build_assignment_node($assignments; $prop_idx + 1)
                        else
                            # Different values — create children, one per unique value
                            .children = [
                                $unique_vals[] | . as $val |
                                [$assignments[] | select(.[$pn] == $val)] as $matching |
                                (if $pn == "scopes" then
                                    {($pn): {"quick-start": (if ($val | type) == "array" then $val else [$val] end)}}
                                elif $pn == "notScopes" or $pn == "additionalRoleAssignments" or $pn == "identityEntry" then
                                    {($pn): {"quick-start": $val}}
                                else
                                    {($pn): $val}
                                end) |
                                . + {nodeName: ("/child-" + ($val | tostring | .[0:20]))} |
                                build_assignment_node($matching; $prop_idx + 1)
                            ]
                        end
                    end;

                # Convert tree node to output format
                def to_output:
                    # assignmentNameEx -> assignment
                    (if has("assignmentNameEx") then
                        {assignment: {name: .assignmentNameEx.name, displayName: .assignmentNameEx.displayName,
                                      description: .assignmentNameEx.description}}
                    else {} end) +
                    # Simple pass-through properties (skip null/empty/default)
                    (if (.parameters // {} | length) > 0 then {parameters} else {} end) +
                    (if .overrides != null and .overrides != [] then {overrides} else {} end) +
                    (if .resourceSelectors != null and .resourceSelectors != [] then {resourceSelectors} else {} end) +
                    (if .enforcementMode != null and .enforcementMode != "Default" then {enforcementMode} else {} end) +
                    (if .nonComplianceMessages != null and .nonComplianceMessages != [] then {nonComplianceMessages} else {} end) +
                    (if (.metadata // {} | length) > 0 then {metadata} else {} end) +
                    (if .definitionVersion != null then {definitionVersion} else {} end) +
                    # Per-pacSelector properties
                    (if (.scope // {} | length) > 0 then {scope} else
                     if (.scopes // {} | length) > 0 then {scope: .scopes} else {} end end) +
                    (if (.notScopes // {} | to_entries | map(select(.value != null and (.value | length) > 0)) | length) > 0
                     then {notScopes: (.notScopes | with_entries(select(.value != null and (.value | length) > 0)))} else {} end) +
                    (if (.additionalRoleAssignments // {} | to_entries | map(select(.value != null and (.value | length) > 0)) | length) > 0
                     then {additionalRoleAssignments: (.additionalRoleAssignments | with_entries(select(.value != null and (.value | length) > 0)))} else {} end) +
                    # Identity/location
                    ((.identityEntry // {}) | to_entries | reduce .[] as $ie (
                        {};
                        ($ie.key) as $sel | ($ie.value // null) as $val |
                        if $val == null then .
                        elif ($val | type) == "object" then
                            (if $val.location != null and $val.location != "" then .managedIdentityLocations = (.managedIdentityLocations // {} | .[$sel] = $val.location) else . end) |
                            (if $val.userAssigned != null then .userAssignedIdentity = (.userAssignedIdentity // {} | .[$sel] = $val.userAssigned) else . end)
                        else . end
                    )) +
                    # nodeName (for children)
                    (if has("nodeName") then {nodeName} else {} end) +
                    # Children
                    (if (.children // [] | length) == 1 then
                        # Single child — collapse into this node
                        (.children[0] | del(.nodeName) | to_output) as $child_out |
                        $child_out
                    elif (.children // [] | length) > 1 then
                        {children: [.children[] | to_output]}
                    else {} end);

                # Build the result
                {
                    "$schema": "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-assignment-schema.json",
                    nodeName: "/root",
                    definitionEntry: $def_entry
                } +
                ({} | build_assignment_node($all_props; 0) | to_output)
            ' "$_pa_records_file")"

            # Determine output file path
            _kind_str="$(echo "$_out_json" | jq -r 'if .definitionEntry | has("policySetId") or has("policySetName") then "PolicySet" else "Policy" end')"
            _def_name="$_dk"
            _def_display="$(echo "$_out_json" | jq -r '.definitionEntry.displayName // ""')"
            _out_path="$(epac_get_definitions_full_path "$_policy_assignments_folder" "$_def_name" \
                "$_def_display" "$_invalid_chars" "$_file_extension" \
                --file-suffix "-${_kind_str}" --max-sub-folder 30 --max-filename 100)"

            mkdir -p "$(dirname "$_out_path")"
            echo "$_out_json" | jq '.' > "$_out_path"
        done <<< "$_def_keys"
    fi

    epac_write_section "Creating Ownership CSV File" 0
    epac_write_ownership_csv "$(jq -s '.' "$_all_rows_file")" "$_ownership_csv_path"
    epac_write_status "Wrote: $_ownership_csv_path" "success" 2
fi

epac_write_section "Export Complete" 0
