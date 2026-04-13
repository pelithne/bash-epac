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

        local item_list="[]"
        local assignment_details="{}"
        local assignment_ids
        assignment_ids="$(echo "$managed_assignments" | jq -r 'keys[]')"
        while IFS= read -r aid; do
            [[ -z "$aid" ]] && continue
            local a_entry
            a_entry="$(echo "$managed_assignments" | jq --arg id "$aid" '.[$id]')"

            # Check skip list
            local a_id_lower
            a_id_lower="$(echo "$aid" | tr '[:upper:]' '[:lower:]')"
            local skip_match
            skip_match="$(echo "$skip_assignments" | jq --arg id "$a_id_lower" '[.[] | select(ascii_downcase == $id)] | length')"
            [[ "$skip_match" -gt 0 ]] && continue

            local display_name
            display_name="$(echo "$a_entry" | jq -r '.properties.displayName // .name // ""')"
            local short_name
            short_name="$(echo "$display_name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | head -c 50)"
            [[ -z "$short_name" ]] && short_name="$(basename "$aid")"

            item_list="$(echo "$item_list" | jq --arg sn "$short_name" --arg id "$aid" '. + [{shortName: $sn, assignmentId: $id, itemId: $id}]')"

            # Get the policy definition reference for this assignment
            local ps_def_id
            ps_def_id="$(echo "$a_entry" | jq -r '.properties.policyDefinitionId // empty')"
            local ps_def_id_lower
            ps_def_id_lower="$(echo "$ps_def_id" | tr '[:upper:]' '[:lower:]')"
            local policy_type="Custom"
            local category=""
            local description=""

            # Look up in set definitions first, then individual definitions
            local set_def
            set_def="$(echo "$setdefs_json" | jq --arg id "$ps_def_id" '.all[$id] // null')"
            if [[ "$set_def" != "null" ]]; then
                policy_type="$(echo "$set_def" | jq -r '.properties.policyType // "Custom"')"
                category="$(echo "$set_def" | jq -r '.properties.metadata.category // ""')"
                description="$(echo "$set_def" | jq -r '.properties.description // ""')"
            else
                local pol_def
                pol_def="$(echo "$poldefs_json" | jq --arg id "$ps_def_id" '.all[$id] // null')"
                if [[ "$pol_def" != "null" ]]; then
                    policy_type="$(echo "$pol_def" | jq -r '.properties.policyType // "Custom"')"
                    category="$(echo "$pol_def" | jq -r '.properties.metadata.category // ""')"
                    description="$(echo "$pol_def" | jq -r '.properties.description // ""')"
                fi
            fi

            assignment_details="$(echo "$assignment_details" | jq \
                --arg id "$aid" \
                --arg dn "$display_name" \
                --arg pt "$policy_type" \
                --arg cat "$category" \
                --arg desc "$description" \
                --arg psid "$ps_def_id" \
                '.[$id] = {displayName: $dn, policyType: $pt, category: $cat, description: $desc, policySetId: $psid, assignment: {properties: {displayName: $dn}}}')"

        done <<< "$assignment_ids"

        local item_count
        item_count="$(echo "$item_list" | jq 'length')"
        epac_write_status "Discovered ${item_count} assignments" "info" 6

        # Build flat policy list from assignments
        # Build flat policy list from assignments using a single jq pass
        local _managed_file _setdefs_file _poldefs_file _flat_file
        _managed_file="$(mktemp)"
        _setdefs_file="$(mktemp)"
        _poldefs_file="$(mktemp)"
        _flat_file="$(mktemp)"
        echo "$managed_assignments" > "$_managed_file"
        echo "$setdefs_json" > "$_setdefs_file"
        echo "$poldefs_json" > "$_poldefs_file"

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

            # Switch PAC environment and get resources (would call Azure in real usage)
            # In documentation mode we need policy set details from Azure
            # For now, output placeholder if no cached data
            if [[ "$ps_pac_env" != "$current_pac_env" ]]; then
                current_pac_env="$ps_pac_env"
                epac_write_status "Switched to PAC environment: ${current_pac_env}" "info" 4
            fi

            # Build item list with itemId for flat list conversion
            item_list="$(echo "$ps_sets" | jq '[.[] | {shortName, itemId: (.id // .name), policySetId: (.id // .name)}]')"

            # The actual Azure calls would happen here — for offline/test mode,
            # we pass through whatever cached_details contains
            flat_list="{}"
            ps_details="{}"
            if [[ "$(echo "$cached_details" | jq --arg env "$current_pac_env" 'has($env)')" == "true" ]]; then
                ps_details="$(echo "$cached_details" | jq --arg env "$current_pac_env" '.[$env]')"
                flat_list="$(epac_convert_details_to_flat_list "$item_list" "$ps_details")"
            fi

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
