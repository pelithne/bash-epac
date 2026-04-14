#!/usr/bin/env bash
# scripts/operations/build-policy-documentation.sh — Generate policy documentation
# Replaces: Scripts/Operations/Build-PolicyDocumentation.ps1
#
# Generates markdown, CSV, and JSONC documentation for policy sets and assignments.
# Reads documentation specification files (JSON/JSONC) from the definitions folder.
#
# Usage: build-policy-documentation.sh [options]
#   --definitions-folder <path>  Definitions root folder (default: $PAC_DEFINITIONS_FOLDER or ./Definitions)
#   --output-folder <path>       Output folder (default: $PAC_OUTPUT_FOLDER or ./Outputs)
#   --pac-selector <name>        Specific PAC environment to use
#   --include-manual             Include policies with Manual effect
#   --only-managed               Only document EPAC-managed assignments
#   --strict                     Fail on missing policy definitions
#   --suppress-confirmation      Suppress file deletion confirmation
#   --wiki-clone-pat <pat>       PAT for Azure DevOps Wiki push
#   --wiki-spn                   Use SPN for ADO Wiki push
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

# ── Defaults ──
definitions_folder="${PAC_DEFINITIONS_FOLDER:-./Definitions}"
output_folder="${PAC_OUTPUT_FOLDER:-./Outputs}"
pac_selector=""
include_manual=false
only_managed=false
strict_mode=false
suppress_confirmation=false
wiki_clone_pat=""
wiki_spn=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --definitions-folder) definitions_folder="$2"; shift 2 ;;
        --output-folder) output_folder="$2"; shift 2 ;;
        --pac-selector) pac_selector="$2"; shift 2 ;;
        --include-manual) include_manual=true; shift ;;
        --only-managed) only_managed=true; shift ;;
        --strict) strict_mode=true; shift ;;
        --suppress-confirmation) suppress_confirmation=true; shift ;;
        --wiki-clone-pat) wiki_clone_pat="$2"; shift 2 ;;
        --wiki-spn) wiki_spn=true; shift ;;
        -h|--help)
            head -20 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0 ;;
        *) shift ;;
    esac
done

# ── Initialize ──
epac_write_header "Build Policy Documentation"

# Load global settings
global_settings="$(epac_get_global_settings "$definitions_folder")"
pac_environments="$(echo "$global_settings" | jq '.pacEnvironments // {}')"

# Output paths
doc_output="${output_folder}/policy-documentation"
services_output="${doc_output}/services"
mkdir -p "$doc_output" "$services_output"

# ── Find documentation specification files ──
doc_folder="${definitions_folder}/policyDocumentations"
if [[ ! -d "$doc_folder" ]]; then
    epac_write_status "No policyDocumentations folder found at ${doc_folder}" "warning" 2
    exit 0
fi

epac_write_status "Scanning documentation specs in ${doc_folder}" "info" 2

# Cache for expensive Azure lookups
cached_details="{}"
cached_assignments="{}"
current_pac_env=""

# ── Helper: Process explicit environmentCategories ──
_process_explicit_assignments() {
    local da_section="$1"
    local global_doc_spec="$2"
    local doc_output="$3"
    local services_output="$4"

    local env_cats
    env_cats="$(echo "$da_section" | jq '.environmentCategories // []')"
    local ec_count
    ec_count="$(echo "$env_cats" | jq 'length')"

    # Build assignments by environment
    local assignments_by_env="{}"
    local eci=0
    while [[ $eci -lt $ec_count ]]; do
        local ec_entry
        ec_entry="$(echo "$env_cats" | jq --argjson i "$eci" '.[$i]')"
        local ec_name
        ec_name="$(echo "$ec_entry" | jq -r '.environmentCategory')"
        local ec_pac_env
        ec_pac_env="$(echo "$ec_entry" | jq -r '.pacEnvironment')"
        local ec_scopes
        ec_scopes="$(echo "$ec_entry" | jq '.scopes // []')"
        local ec_rep_assignments
        ec_rep_assignments="$(echo "$ec_entry" | jq '.representativeAssignments // []')"

        epac_write_status "Environment: ${ec_name} (${ec_pac_env})" "info" 4

        # Build item list
        local item_list
        item_list="$(echo "$ec_rep_assignments" | jq '[.[] | {shortName, assignmentId: .id, itemId: .id}]')"

        # Cache Azure lookups per pac environment
        local flat_list="{}"
        local a_details="{}"
        if [[ "$(echo "$cached_details" | jq --arg env "$ec_pac_env" 'has($env)')" == "true" ]]; then
            local details
            details="$(echo "$cached_details" | jq --arg env "$ec_pac_env" '.[$env]')"
            flat_list="$(epac_convert_details_to_flat_list "$item_list" "$details")"
        fi
        if [[ "$(echo "$cached_assignments" | jq --arg env "$ec_pac_env" 'has($env)')" == "true" ]]; then
            a_details="$(echo "$cached_assignments" | jq --arg env "$ec_pac_env" '.[$env]')"
        fi

        assignments_by_env="$(echo "$assignments_by_env" | jq --arg ec "$ec_name" --argjson fl "$flat_list" --argjson al "$item_list" --argjson ad "$a_details" --argjson sc "$ec_scopes" '
            .[$ec] = {flatPolicyList: $fl, itemList: $al, assignmentsDetails: $ad, scopes: $sc}
        ')"
        eci=$((eci + 1))
    done

    # Get documentation specs
    local doc_specs
    doc_specs="$(echo "$da_section" | jq '.documentationSpecifications // []')"
    if [[ "$(echo "$doc_specs" | jq 'length')" -eq 0 && "$(echo "$global_doc_spec" | jq 'has("fileNameStem")')" == "true" ]]; then
        doc_specs="[${global_doc_spec}]"
    fi

    local ds_count
    ds_count="$(echo "$doc_specs" | jq 'length')"
    local dsi=0
    while [[ $dsi -lt $ds_count ]]; do
        local ds
        ds="$(echo "$doc_specs" | jq --argjson i "$dsi" '.[$i]')"
        ds="$(jq -n --argjson g "$global_doc_spec" --argjson l "$ds" '$g + $l')"

        # Ensure environmentCategories is set from our ec list
        if [[ "$(echo "$ds" | jq 'has("environmentCategories")')" != "true" ]]; then
            ds="$(echo "$ds" | jq --argjson ecs "$(echo "$env_cats" | jq '[.[].environmentCategory]')" '.environmentCategories = $ecs')"
        fi

        local wiki_args=()
        [[ -n "$wiki_clone_pat" ]] && wiki_args+=(--wiki-clone-pat "$wiki_clone_pat")
        $wiki_spn && wiki_args+=(--wiki-spn)
        $include_manual && wiki_args+=(--include-manual)

        epac_out_documentation_for_assignments \
            --output-path "$doc_output" \
            --output-path-services "$services_output" \
            --doc-spec "$ds" \
            --assignments-by-env "$assignments_by_env" \
            --pac-environments "$pac_environments" \
            "${wiki_args[@]}"

        dsi=$((dsi + 1))
    done
}

# ── Helper: Process auto-discover all assignments ──
_process_auto_assignments() {
    local da_section="$1"
    local global_doc_spec="$2"
    local doc_output="$3"
    local services_output="$4"

    local daa_entries
    daa_entries="$(echo "$da_section" | jq '.documentAllAssignments // []')"
    if [[ "$(echo "$daa_entries" | jq 'type')" != '"array"' ]]; then
        daa_entries="[${daa_entries}]"
    fi

    local daa_count
    daa_count="$(echo "$daa_entries" | jq 'length')"
    local di=0
    while [[ $di -lt $daa_count ]]; do
        local daa
        daa="$(echo "$daa_entries" | jq --argjson i "$di" '.[$i]')"
        local daa_pac_env
        daa_pac_env="$(echo "$daa" | jq -r '.pacEnvironment')"
        local prefix
        prefix="$(echo "$daa" | jq -r '.fileNameStemPrefix // "all-assignments"')"
        local skip_assignments
        skip_assignments="$(echo "$daa" | jq '.skipPolicyAssignments // []')"
        local skip_definitions
        skip_definitions="$(echo "$daa" | jq '.skipPolicyDefinitions // []')"

        epac_write_status "Auto-discover assignments for env: ${daa_pac_env}" "info" 4

        # Select and authenticate to PAC environment
        local pac_env
        pac_env="$(epac_select_pac_environment "$daa_pac_env" "$definitions_folder")"
        epac_set_az_cloud_tenant_subscription "$pac_env"

        # Build scope table
        local scope_table
        scope_table="$(epac_build_scope_table "$pac_env" "true")"

        # Fetch deployed policy resources
        local _tmp_dir
        _tmp_dir="$(mktemp -d)"
        epac_get_policy_resources "$pac_env" "$scope_table" "true" "true" "false" "$_tmp_dir" >/dev/null

        local assignments_json
        assignments_json="$(cat "$_tmp_dir/policyassignments.json")"
        local setdefs_json
        setdefs_json="$(cat "$_tmp_dir/policysetdefinitions.json")"
        local poldefs_json
        poldefs_json="$(cat "$_tmp_dir/policydefinitions.json")"

        # Build assignments_by_env with a single "all" environment category
        # containing all discovered assignments
        local root_scope
        root_scope="$(echo "$pac_env" | jq -r '.deploymentRootScope')"
        local ec_name="all"

        # Build item list and assignment details from discovered assignments
        local managed_assignments
        managed_assignments="$(echo "$assignments_json" | jq '.managed // {}')"

        # Write large JSON data to temp files once — avoid re-piping 40MB+ per jq call
        local _managed_file _setdefs_file _poldefs_file _flat_file
        _managed_file="$(mktemp)"
        _setdefs_file="$(mktemp)"
        _poldefs_file="$(mktemp)"
        _flat_file="$(mktemp)"
        echo "$managed_assignments" > "$_managed_file"
        echo "$setdefs_json" > "$_setdefs_file"
        echo "$poldefs_json" > "$_poldefs_file"

        # Build item_list and assignment_details in a single jq pass
        local _skip_file
        _skip_file="$(mktemp)"
        echo "$skip_assignments" > "$_skip_file"
        local _item_detail_file
        _item_detail_file="$(mktemp)"
        jq -n \
            --slurpfile managed "$_managed_file" \
            --slurpfile sd "$_setdefs_file" \
            --slurpfile pd "$_poldefs_file" \
            --slurpfile skip "$_skip_file" \
        '
        $managed[0] as $ma |
        ($sd[0].all // {}) as $setdefs |
        ($pd[0].all // {}) as $poldefs |
        ($skip[0] // []) as $skip_list |
        reduce ($ma | keys[]) as $aid (
            {item_list: [], assignment_details: {}};
            ($aid | ascii_downcase) as $aid_lower |
            # Check skip list
            if ([$skip_list[] | select(ascii_downcase == $aid_lower)] | length) > 0 then .
            else
                $ma[$aid] as $a_entry |
                ($a_entry.properties.displayName // $a_entry.name // "") as $display_name |
                ($display_name | gsub(" "; "-") | ascii_downcase | .[:50]) as $raw_sn |
                (if $raw_sn == "" then ($aid | split("/") | last) else $raw_sn end) as $short_name |
                ($a_entry.properties.policyDefinitionId // "") as $ps_def_id |
                # Look up metadata from set definitions, then policy definitions
                (if $setdefs[$ps_def_id] != null then
                    {pt: ($setdefs[$ps_def_id].properties.policyType // "Custom"),
                     cat: ($setdefs[$ps_def_id].properties.metadata.category // ""),
                     desc: ($setdefs[$ps_def_id].properties.description // "")}
                 elif $poldefs[$ps_def_id] != null then
                    {pt: ($poldefs[$ps_def_id].properties.policyType // "Custom"),
                     cat: ($poldefs[$ps_def_id].properties.metadata.category // ""),
                     desc: ($poldefs[$ps_def_id].properties.description // "")}
                 else
                    {pt: "Custom", cat: "", desc: ""}
                 end) as $meta |
                .item_list += [{shortName: $short_name, assignmentId: $aid, itemId: $aid}] |
                .assignment_details[$aid] = {
                    displayName: $display_name,
                    policyType: $meta.pt,
                    category: $meta.cat,
                    description: $meta.desc,
                    policySetId: $ps_def_id,
                    assignment: {properties: {displayName: $display_name}}
                }
            end
        )
        ' > "$_item_detail_file"
        rm -f "$_skip_file"

        local item_list
        item_list="$(jq '.item_list' "$_item_detail_file")"
        local assignment_details
        assignment_details="$(jq '.assignment_details' "$_item_detail_file")"
        rm -f "$_item_detail_file"

        local item_count
        item_count="$(echo "$item_list" | jq 'length')"
        epac_write_status "Discovered ${item_count} assignments" "info" 6

        # Build flat policy list from assignments using a single jq pass

        jq -n --arg ec "$ec_name" \
            --slurpfile ma "$_managed_file" \
            --slurpfile sd "$_setdefs_file" \
            --slurpfile pd "$_poldefs_file" \
        '
        ($ma[0]) as $managed |
        ($sd[0].all) as $setdefs |
        ($pd[0].all) as $poldefs |

        reduce ($managed | keys[]) as $aid (
            {};
            . as $flat |
            ($managed[$aid].properties.policyDefinitionId // "") as $ps_def_id |

            # Check if this is a policy set definition
            if ($setdefs[$ps_def_id] // null) != null then
                ($setdefs[$ps_def_id]) as $set_def |
                reduce ($set_def.properties.policyDefinitions // [] | .[]) as $member (
                    $flat;
                    ($member.policyDefinitionId) as $mid |
                    ($poldefs[$mid] // null) as $pol |
                    (if $pol != null then $pol.properties.displayName // "" else "" end) as $dn |
                    (if $pol != null then $pol.properties.description // "" else "" end) as $desc |
                    (if $pol != null then $pol.properties.metadata.category // "" else "" end) as $cat |
                    (if $pol != null then $pol.properties.policyType // "BuiltIn" else "BuiltIn" end) as $pt |
                    (if $pol != null then
                        (($pol.properties.parameters // {} | to_entries
                        | map(select(.value.metadata.displayName == "Effect" or .key == "effect"))
                        | .[0] // null) as $ep |
                        if $ep != null then ($ep.value.defaultValue // "Disabled") else "Disabled" end)
                    else "Disabled" end) as $effect |
                    if has($mid) then
                        .[$mid].environmentList[$ec] = {environmentCategory: $ec, effectValue: $effect, parameters: {}}
                    else
                        .[$mid] = {
                            policyTableId: $mid, name: $mid,
                            referencePath: "", displayName: $dn, description: $desc,
                            policyType: $pt, category: $cat,
                            isEffectParameterized: false, ordinal: 99,
                            effectDefault: $effect, effectAllowedValues: {},
                            effectAllowedOverrides: [], groupNames: [],
                            policySetEffectStrings: [], isReferencePathMatch: false,
                            environmentList: {($ec): {environmentCategory: $ec, effectValue: $effect, parameters: {}}}
                        }
                    end
                )
            else
                # Single policy definition
                ($poldefs[$ps_def_id] // null) as $pol |
                (if $pol != null then $pol.properties.displayName // "" else "" end) as $dn |
                (if $pol != null then $pol.properties.description // "" else "" end) as $desc |
                (if $pol != null then $pol.properties.metadata.category // "" else "" end) as $cat |
                (if $pol != null then $pol.properties.policyType // "BuiltIn" else "BuiltIn" end) as $pt |
                (if $pol != null then
                    (($pol.properties.parameters // {} | to_entries
                    | map(select(.value.metadata.displayName == "Effect" or .key == "effect"))
                    | .[0] // null) as $ep |
                    if $ep != null then ($ep.value.defaultValue // "Disabled") else "Disabled" end)
                else "Disabled" end) as $effect |
                .[$ps_def_id] = {
                    policyTableId: $ps_def_id, name: $ps_def_id,
                    referencePath: "", displayName: $dn, description: $desc,
                    policyType: $pt, category: $cat,
                    isEffectParameterized: false, ordinal: 99,
                    effectDefault: $effect, effectAllowedValues: {},
                    effectAllowedOverrides: [], groupNames: [],
                    policySetEffectStrings: [], isReferencePathMatch: false,
                    environmentList: {($ec): {environmentCategory: $ec, effectValue: $effect, parameters: {}}}
                }
            end
        )
        ' > "$_flat_file"

        local flat_count
        flat_count="$(jq 'keys | length' "$_flat_file")"
        epac_write_status "Built flat policy list with ${flat_count} policies" "info" 6

        # Build assignments_by_env using temp files (data too large for CLI args)
        local _il_file _ad_file
        _il_file="$(mktemp)"
        _ad_file="$(mktemp)"
        echo "$item_list" > "$_il_file"
        echo "$assignment_details" > "$_ad_file"

        local _aby_file
        _aby_file="$(mktemp)"
        jq -n \
            --arg ec "$ec_name" \
            --slurpfile fl "$_flat_file" \
            --slurpfile il "$_il_file" \
            --slurpfile ad "$_ad_file" \
            --arg scope "$root_scope" \
            '{($ec): {flatPolicyList: $fl[0], itemList: $il[0], assignmentsDetails: $ad[0], scopes: [$scope]}}' > "$_aby_file"
        local assignments_by_env
        assignments_by_env="$(cat "$_aby_file")"
        rm -f "$_flat_file" "$_managed_file" "$_setdefs_file" "$_poldefs_file" "$_il_file" "$_ad_file" "$_aby_file"

        # Get documentation specs — check individual entry first, then parent section
        local doc_specs
        doc_specs="$(echo "$daa" | jq '.documentationSpecifications // []')"
        if [[ "$(echo "$doc_specs" | jq 'length')" -eq 0 ]]; then
            doc_specs="$(echo "$da_section" | jq '.documentationSpecifications // []')"
        fi
        if [[ "$(echo "$doc_specs" | jq 'length')" -eq 0 && "$(echo "$global_doc_spec" | jq 'has("fileNameStem")')" == "true" ]]; then
            doc_specs="[${global_doc_spec}]"
        fi

        local ds_count
        ds_count="$(echo "$doc_specs" | jq 'length')"
        local dsi=0
        while [[ $dsi -lt $ds_count ]]; do
            local ds
            ds="$(echo "$doc_specs" | jq --argjson i "$dsi" '.[$i]')"
            ds="$(jq -n --argjson g "$global_doc_spec" --argjson l "$ds" '$g + $l')"

            # Override fileNameStem with prefix
            ds="$(echo "$ds" | jq --arg p "$prefix" '.fileNameStem = ($p + "-" + (.fileNameStem // "assignments"))')"

            # Ensure environmentCategories is set and non-empty
            local ec_len
            ec_len="$(echo "$ds" | jq '.environmentCategories // [] | length')"
            if [[ "$ec_len" -eq 0 ]]; then
                ds="$(echo "$ds" | jq --arg ec "$ec_name" '.environmentCategories = [$ec]')"
            fi

            local wiki_args=()
            [[ -n "$wiki_clone_pat" ]] && wiki_args+=(--wiki-clone-pat "$wiki_clone_pat")
            $wiki_spn && wiki_args+=(--wiki-spn)
            $include_manual && wiki_args+=(--include-manual)

            epac_out_documentation_for_assignments \
                --output-path "$doc_output" \
                --output-path-services "$services_output" \
                --doc-spec "$ds" \
                --assignments-by-env "$assignments_by_env" \
                --pac-environments "$pac_environments" \
                "${wiki_args[@]}"

            dsi=$((dsi + 1))
        done

        rm -rf "$_tmp_dir"

        di=$((di + 1))
    done
}

# Process each documentation spec file
while IFS= read -r spec_file; do
    [[ -z "$spec_file" ]] && continue

    epac_write_section "Processing: $(basename "$spec_file")"

    local_spec="$(epac_read_jsonc "$spec_file")"

    # Check for pacEnvironment filter from subfolder
    parent_dir="$(dirname "$spec_file")"
    parent_name="$(basename "$parent_dir")"
    if [[ "$parent_name" != "policyDocumentations" && -n "$pac_selector" && "$parent_name" != "$pac_selector" ]]; then
        epac_write_status "Skipping (pacSelector mismatch)" "skip" 2
        continue
    fi

    # Load global documentation specs if present
    global_doc_spec="{}"
    has_global="$(echo "$local_spec" | jq 'has("globalDocumentationSpecifications")')"
    if [[ "$has_global" == "true" ]]; then
        global_doc_spec="$(echo "$local_spec" | jq '.globalDocumentationSpecifications')"
    fi

    # ── Process documentPolicySets ──
    has_ps="$(echo "$local_spec" | jq 'has("documentPolicySets")')"
    if [[ "$has_ps" == "true" ]]; then
        ps_entries="$(echo "$local_spec" | jq '.documentPolicySets')"
        # Normalize to array
        if [[ "$(echo "$ps_entries" | jq 'type')" != '"array"' ]]; then
            ps_entries="[${ps_entries}]"
        fi

        ps_count="$(echo "$ps_entries" | jq 'length')"
        psi=0
        while [[ $psi -lt $ps_count ]]; do
            ps_entry="$(echo "$ps_entries" | jq --argjson i "$psi" '.[$i]')"
            ps_pac_env="$(echo "$ps_entry" | jq -r '.pacEnvironment')"
            ps_file_stem="$(echo "$ps_entry" | jq -r '.fileNameStem')"
            ps_title="$(echo "$ps_entry" | jq -r '.title')"
            ps_sets="$(echo "$ps_entry" | jq '.policySets // []')"
            env_cols="$(echo "$ps_entry" | jq '.environmentColumnsInCsv // []')"

            epac_write_status "Policy Sets: ${ps_title} (env: ${ps_pac_env})" "info" 2

            # Merge global doc spec defaults
            doc_spec="$(jq -n --argjson g "$global_doc_spec" --argjson l "$ps_entry" '$g + $l')"

            # Build item list with itemId for flat list conversion
            item_list="$(echo "$ps_sets" | jq '[.[] | {shortName, itemId: (.id // .name), policySetId: (.id // .name)}]')"

            # ── Fetch Azure policy resources for this PAC environment ──
            if [[ "$ps_pac_env" != "$current_pac_env" ]]; then
                current_pac_env="$ps_pac_env"
                epac_write_status "Switching to PAC environment: ${current_pac_env}" "info" 4

                pac_env="$(epac_select_pac_environment "$current_pac_env" "$definitions_folder")"
                epac_set_az_cloud_tenant_subscription "$pac_env"

                scope_table="$(epac_build_scope_table "$pac_env" "true")"

                _ps_tmp_dir="$(mktemp -d)"
                epac_get_policy_resources "$pac_env" "$scope_table" "true" "true" "false" "$_ps_tmp_dir" >/dev/null

                _ps_setdefs_file="${_ps_tmp_dir}/policysetdefinitions.json"
                _ps_poldefs_file="${_ps_tmp_dir}/policydefinitions.json"
            fi

            # ── Build policySetDetails via single jq pass ──
            # This implements Convert-PolicyToDetails + Convert-PolicySetToDetails
            # in one bulk jq operation, avoiding per-policy subprocess overhead.
            _ps_items_file="$(mktemp)"
            echo "$ps_sets" > "$_ps_items_file"

            _ps_details_file="$(mktemp)"

            jq -n \
                --slurpfile items "$_ps_items_file" \
                --slurpfile sd "$_ps_setdefs_file" \
                --slurpfile pd "$_ps_poldefs_file" \
            '
            ($items[0]) as $policy_sets |
            ($sd[0].all // {}) as $setdefs |
            ($pd[0].all // {}) as $poldefs |

            # Helper: extract parameter name from "[parameters('"'"'name'"'"')]" pattern
            # Returns {found: bool, name: string}
            def parse_param_ref:
                if type == "string" and startswith("[parameters(") and endswith(")]") then
                    {found: true, name: (ltrimstr("[parameters('"'"'") | rtrimstr("'"'"')]"))}
                else
                    {found: false, name: null}
                end;

            # Build policy details for each individual policy definition
            # (equivalent of Convert-PolicyToDetails)
            def build_policy_detail($pol_id):
                ($poldefs[$pol_id] // null) as $pol |
                if $pol == null then null
                else
                    ($pol.properties // {}) as $props |
                    ($props.metadata.category // "Unknown") as $category |
                    ($props.parameters // {}) as $params |
                    ($props.policyRule.then.effect // "Disabled") as $effectRaw |
                    ($effectRaw | parse_param_ref) as $parsed |

                    (if $parsed.found then
                        # Effect is parameterized
                        ($parsed.name) as $epn |
                        ($params[$epn] // {}) as $ep |
                        {
                            effectParameterName: $epn,
                            effectValue: ($ep.defaultValue // null),
                            effectDefault: ($ep.defaultValue // null),
                            effectAllowedValues: ($ep.allowedValues // []),
                            effectReason: (if $ep.defaultValue != null then "Policy Default" else "Policy No Default" end)
                        }
                    else
                        # Effect is fixed
                        {
                            effectParameterName: null,
                            effectValue: $effectRaw,
                            effectDefault: $effectRaw,
                            effectAllowedValues: [$effectRaw],
                            effectReason: "Policy Fixed"
                        }
                    end) as $effect_info |

                    # Determine effectAllowedOverrides from policy rule structure
                    ($props.policyRule.then.details // null) as $details |
                    (if ($effect_info.effectAllowedValues | length) > 0 and $effect_info.effectReason != "Policy Fixed" then
                        $effect_info.effectAllowedValues
                    elif $details != null then
                        if ($details.actionNames // null) != null then ["Disabled", "DenyAction"]
                        elif ($details.defaultState // null) != null then ["Disabled", "Manual"]
                        elif ($details.deployment // null) != null then ["Disabled", "AuditIfNotExists", "DeployIfNotExists"]
                        elif ($details.existenceCondition // null) != null then ["Disabled", "AuditIfNotExists"]
                        elif ($details.operations // null) != null then ["Disabled", "Audit", "Modify"]
                        elif ($details | type) == "array" then ["Disabled", "Audit", "Deny", "Append"]
                        else ["Disabled", "Audit", "Deny"]
                        end
                    else
                        ["Disabled", "Audit", "Deny"]
                    end) as $effectAllowedOverrides |

                    ($props.displayName // $pol.name // "") as $displayName |
                    ($props.metadata.version // "0.0.0") as $version |

                    {
                        id: $pol_id,
                        name: ($pol.name // ""),
                        displayName: $displayName,
                        description: ($props.description // ""),
                        policyType: ($props.policyType // "BuiltIn"),
                        category: $category,
                        version: $version,
                        isDeprecated: ($version | ascii_downcase | test("deprecated")),
                        effectParameterName: $effect_info.effectParameterName,
                        effectValue: $effect_info.effectValue,
                        effectDefault: $effect_info.effectDefault,
                        effectAllowedValues: $effect_info.effectAllowedValues,
                        effectAllowedOverrides: $effectAllowedOverrides,
                        effectReason: $effect_info.effectReason,
                        parameters: ($params | with_entries({
                            key: .key,
                            value: {
                                isEffect: (.key == $effect_info.effectParameterName),
                                value: null,
                                defaultValue: .value.defaultValue,
                                definition: .value
                            }
                        }))
                    }
                end;

            # Process each policy set (equivalent of Convert-PolicySetToDetails)
            reduce ($policy_sets[]) as $ps_spec (
                {};
                . as $all_details |
                ($ps_spec.id // $ps_spec.name) as $ps_id |
                ($setdefs[$ps_id] // null) as $set_def |
                if $set_def == null then
                    . # Skip missing set definitions
                else
                    ($set_def.properties // {}) as $set_props |
                    ($set_props.parameters // {}) as $set_params |
                    ($set_props.metadata.category // "Unknown") as $set_category |
                    ($set_props.displayName // $set_def.name // "") as $set_display_name |
                    ($set_props.description // "") as $set_description |

                    # Process each member policy in the set
                    (reduce ($set_props.policyDefinitions // [] | .[]) as $member (
                        {list: [], params_covered: {}, policies_seen: {}, multi_ref: {}};

                        ($member.policyDefinitionId) as $pol_id |
                        (build_policy_detail($pol_id)) as $pol_detail |
                        if $pol_detail == null then . # Skip inaccessible policies
                        else
                            ($member.parameters // {} | to_entries | map({key: .key, value: .value}) | from_entries) as $member_params |

                            # Resolve effect parameter chain: Policy → PolicySet
                            ($pol_detail.effectReason) as $base_reason |
                            ($pol_detail.effectParameterName) as $base_epn |
                            ($pol_detail.effectValue) as $base_ev |
                            ($pol_detail.effectDefault) as $base_ed |
                            ($pol_detail.effectAllowedValues) as $base_eav |
                            ($pol_detail.effectAllowedOverrides) as $base_eao |

                            (if $base_reason == "Policy Fixed" then
                                # Fixed at policy level — cannot be changed
                                {
                                    effectParameterName: null,
                                    effectValue: $base_ev,
                                    effectDefault: $base_ed,
                                    effectAllowedValues: $base_eav,
                                    effectAllowedOverrides: $base_eao,
                                    effectReason: "Policy Fixed"
                                }
                            else
                                # Effect is parameterized in Policy — check if PolicySet wires it
                                ($member_params[$base_epn] // null) as $member_effect_param |
                                if $member_effect_param == null then
                                    # PolicySet does not wire the effect parameter — Policy defaults apply
                                    {
                                        effectParameterName: $base_epn,
                                        effectValue: $base_ev,
                                        effectDefault: $base_ed,
                                        effectAllowedValues: $base_eav,
                                        effectAllowedOverrides: $base_eao,
                                        effectReason: $base_reason
                                    }
                                else
                                    # PolicySet wires the effect parameter
                                    (($member_effect_param.value // "") | parse_param_ref) as $ps_parsed |
                                    if $ps_parsed.found then
                                        # Effect is surfaced as a PolicySet parameter
                                        ($set_params[$ps_parsed.name] // {}) as $ps_param |
                                        {
                                            effectParameterName: $ps_parsed.name,
                                            effectValue: ($ps_param.defaultValue // null),
                                            effectDefault: ($ps_param.defaultValue // null),
                                            effectAllowedValues: ($ps_param.allowedValues // $base_eav),
                                            effectAllowedOverrides: $base_eao,
                                            effectReason: (if $ps_param.defaultValue != null then "PolicySet Default" else "PolicySet No Default" end)
                                        }
                                    else
                                        # Effect is hard-coded (fixed) by PolicySet
                                        ($member_effect_param.value // $base_ev) as $fixed_val |
                                        {
                                            effectParameterName: null,
                                            effectValue: $fixed_val,
                                            effectDefault: $fixed_val,
                                            effectAllowedValues: $base_eav,
                                            effectAllowedOverrides: $base_eao,
                                            effectReason: "PolicySet Fixed"
                                        }
                                    end
                                end
                            end) as $resolved |

                            # Build surfaced parameters (non-effect params wired through PolicySet)
                            (reduce ($member_params | to_entries[]) as $mp (
                                {};
                                ($mp.key) as $pname |
                                ($mp.value.value // null) as $raw_val |
                                if ($raw_val | type) == "string" then
                                    ($raw_val | parse_param_ref) as $pp |
                                    if $pp.found then
                                        ($set_params[$pp.name] // {}) as $sp |
                                        .[$pp.name] = {
                                            multiUse: false,
                                            isEffect: ($pp.name == $resolved.effectParameterName),
                                            value: ($sp.defaultValue // null),
                                            defaultValue: ($sp.defaultValue // null),
                                            definition: $sp
                                        }
                                    else .
                                    end
                                else .
                                end
                            )) as $surfaced_params |

                            # Track multi-reference policies
                            ($member.policyDefinitionReferenceId // "") as $pdr_id |
                            (if .policies_seen[$pol_id] != null then
                                # Already seen this policy — mark as multi-ref
                                .multi_ref[$pol_id] = ((.multi_ref[$pol_id] // .policies_seen[$pol_id]) + [$pdr_id])
                            else
                                .policies_seen[$pol_id] = [$pdr_id]
                            end) |

                            .list += [{
                                id: $pol_id,
                                name: $pol_detail.name,
                                displayName: $pol_detail.displayName,
                                description: $pol_detail.description,
                                policyType: $pol_detail.policyType,
                                category: $pol_detail.category,
                                version: $pol_detail.version,
                                isDeprecated: $pol_detail.isDeprecated,
                                effectParameterName: $resolved.effectParameterName,
                                effectValue: $resolved.effectValue,
                                effectDefault: $resolved.effectDefault,
                                effectAllowedValues: $resolved.effectAllowedValues,
                                effectAllowedOverrides: $resolved.effectAllowedOverrides,
                                effectReason: $resolved.effectReason,
                                parameters: $surfaced_params,
                                policyDefinitionReferenceId: $pdr_id,
                                groupNames: ($member.groupNames // [])
                            }]
                        end
                    )) as $result |

                    .[$ps_id] = {
                        id: $ps_id,
                        name: ($set_def.name // ""),
                        displayName: $set_display_name,
                        description: $set_description,
                        policyType: ($set_props.policyType // "BuiltIn"),
                        category: $set_category,
                        parameters: $set_params,
                        policyDefinitions: $result.list,
                        policiesWithMultipleReferenceIds: $result.multi_ref
                    }
                end
            )
            ' > "$_ps_details_file"

            rm -f "$_ps_items_file"
            ps_details="$(cat "$_ps_details_file")"

            ps_detail_count="$(echo "$ps_details" | jq 'keys | length')"
            epac_write_status "Built details for ${ps_detail_count} policy set(s)" "info" 4

            # ── Build flat policy list with policySetList — single jq pass ──
            # This replaces epac_convert_details_to_flat_list AND populates
            # policySetList (per-set effect/param data needed by doc-policy-sets.sh)
            _ps_il_file="$(mktemp)"
            echo "$item_list" > "$_ps_il_file"

            _ps_flat_file="$(mktemp)"
            jq -n \
                --slurpfile items "$_ps_il_file" \
                --slurpfile details "$_ps_details_file" '
            $items[0] as $il |
            $details[0] as $psd |

            # Effect ordinal mapping
            def effect_ordinal:
                (ascii_downcase) as $lev |
                if $lev == "modify" then 0
                elif $lev == "append" then 1
                elif $lev == "deployifnotexists" then 2
                elif $lev == "denyaction" then 3
                elif $lev == "deny" then 4
                elif $lev == "audit" then 5
                elif $lev == "manual" then 6
                elif $lev == "auditifnotexists" then 7
                elif $lev == "disabled" then 8
                else 98 end;

            # First pass: find policies with multiple reference IDs
            (reduce ($il[]) as $item ({};
                ($item.itemId) as $iid |
                ($psd[$iid] // null) as $d |
                if $d != null then . + ($d.policiesWithMultipleReferenceIds // {})
                else . end
            )) as $multi_refs |

            # Second pass: build flat list with policySetList
            reduce ($il[]) as $item ({};
                . as $flat |
                ($item.shortName) as $sn |
                ($item.itemId) as $iid |
                ($psd[$iid] // null) as $detail |
                if $detail == null then .
                else
                    reduce ($detail.policyDefinitions // [] | .[]) as $pip (.;
                        ($pip.id) as $pol_id |
                        ($pip.policyDefinitionReferenceId // "") as $pdr_id |
                        ($pip.effectReason // "") as $er |
                        ($pip.effectDefault // "") as $ed |
                        ($pip.effectValue // $ed) as $ev |
                        ($pip.effectParameterName // null) as $epn |
                        ($er == "PolicySet Default" or $er == "PolicySet No Default") as $is_ep |

                        # Build flat key (handle multi-ref policies)
                        ("") as $base_rp |
                        (if $multi_refs[$pol_id] != null then
                            ($detail.name + "\\" + $pdr_id) as $rp |
                            {key: ($pol_id + "\\" + $rp), rp: $rp}
                         else
                            {key: $pol_id, rp: ""}
                         end) as $fk |

                        # Effect string for policySetEffectStrings
                        ((if $er == "PolicySet Default" then
                            $ed + " (default: " + ($epn // "") + ")"
                          elif $er == "PolicySet No Default" then
                            $er + " (" + ($epn // "") + ")"
                          else
                            $ed + " (" + $er + ")"
                          end)) as $effect_string |

                        # Build perPolicySet entry for policySetList
                        ({
                            id: ($item.policySetId // $iid),
                            name: $detail.name,
                            shortName: $sn,
                            displayName: $detail.displayName,
                            description: $detail.description,
                            policyType: $detail.policyType,
                            effectParameterName: $epn,
                            effectValue: $ev,
                            effectDefault: $ed,
                            effectAllowedValues: ($pip.effectAllowedValues // []),
                            effectAllowedOverrides: ($pip.effectAllowedOverrides // []),
                            effectReason: $er,
                            isEffectParameterized: $is_ep,
                            effectString: $effect_string,
                            parameters: ($pip.parameters // {}),
                            policyDefinitionReferenceId: $pdr_id,
                            groupNames: ($pip.groupNames // [])
                        }) as $per_ps |

                        # Upsert into flat list
                        if has($fk.key) then
                            # Update existing entry
                            (if $is_ep then .[$fk.key].isEffectParameterized = true else . end) |
                            # Update ordinal if more impactful
                            (($ed | effect_ordinal) as $new_ord |
                             if $new_ord < .[$fk.key].ordinal then
                                .[$fk.key].ordinal = $new_ord |
                                .[$fk.key].effectValue = $ed |
                                .[$fk.key].effectDefault = $ed
                             else . end) |
                            # Add allowed values
                            .[$fk.key].effectAllowedValues += (($pip.effectAllowedValues // []) | map({key: ., value: .}) | from_entries) |
                            # Add group names
                            ((.[$fk.key].groupNames | keys) as $existing_gn |
                             .[$fk.key].groupNames += (($pip.groupNames // []) | map({key: ., value: .}) | from_entries) |
                             .[$fk.key].groupNamesList += [($pip.groupNames // [])[] | select(. as $g | $existing_gn | index($g) == null)]) |
                            # Add policySetEffectString
                            .[$fk.key].policySetEffectStrings += [$sn + ": " + $effect_string] |
                            # Add to policySetList
                            .[$fk.key].policySetList[$sn] = $per_ps
                        else
                            # Create new entry
                            (($ed | effect_ordinal)) as $ord |
                            .[$fk.key] = {
                                id: $pol_id,
                                name: ($pip.name // ""),
                                referencePath: $fk.rp,
                                displayName: ($pip.displayName // ""),
                                description: ($pip.description // ""),
                                policyType: ($pip.policyType // "BuiltIn"),
                                category: ($pip.category // ""),
                                version: ($pip.version // "0.0.0"),
                                isDeprecated: ($pip.isDeprecated // false),
                                effectDefault: $ed,
                                effectValue: $ed,
                                ordinal: $ord,
                                isEffectParameterized: $is_ep,
                                effectAllowedValues: (($pip.effectAllowedValues // []) | map({key: ., value: .}) | from_entries),
                                effectAllowedOverrides: ($pip.effectAllowedOverrides // []),
                                parameters: {},
                                policySetList: {($sn): $per_ps},
                                groupNames: (($pip.groupNames // []) | map({key: ., value: .}) | from_entries),
                                groupNamesList: ($pip.groupNames // []),
                                policySetEffectStrings: [$sn + ": " + $effect_string]
                            }
                        end
                    )
                end
            )
            ' > "$_ps_flat_file"

            flat_list="$(cat "$_ps_flat_file")"
            flat_count="$(jq 'keys | length' "$_ps_flat_file")"
            epac_write_status "Flat policy list has ${flat_count} entries" "info" 4

            rm -f "$_ps_details_file" "$_ps_il_file" "$_ps_flat_file"

            # Generate documentation
            wiki_args=()
            [[ -n "$wiki_clone_pat" ]] && wiki_args+=(--wiki-clone-pat "$wiki_clone_pat")
            $wiki_spn && wiki_args+=(--wiki-spn)
            $include_manual && wiki_args+=(--include-manual)

            epac_out_documentation_for_policy_sets \
                --output-path "$doc_output" \
                --doc-spec "$doc_spec" \
                --item-list "$item_list" \
                --env-columns-csv "$env_cols" \
                --policy-set-details "$ps_details" \
                --flat-policy-list "$flat_list" \
                "${wiki_args[@]}"

            psi=$((psi + 1))
        done
    fi

    # ── Process documentAssignments ──
    has_da="$(echo "$local_spec" | jq 'has("documentAssignments")')"
    if [[ "$has_da" == "true" ]]; then
        da_section="$(echo "$local_spec" | jq '.documentAssignments')"

        # Path A: environmentCategories (explicit)
        has_ec="$(echo "$da_section" | jq 'has("environmentCategories")')"
        if [[ "$has_ec" == "true" ]]; then
            _process_explicit_assignments "$da_section" "$global_doc_spec" "$doc_output" "$services_output"
        fi

        # Path B: documentAllAssignments (auto-discover)
        has_daa="$(echo "$da_section" | jq 'has("documentAllAssignments")')"
        if [[ "$has_daa" == "true" ]]; then
            _process_auto_assignments "$da_section" "$global_doc_spec" "$doc_output" "$services_output"
        fi
    fi

done < <(find "$doc_folder" -type f \( -name "*.json" -o -name "*.jsonc" \) | sort)

epac_write_header "Documentation Generation Complete"
epac_write_status "Output: ${doc_output}" "success" 2
