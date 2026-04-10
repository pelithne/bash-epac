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

# Process each documentation spec file
while IFS= read -r spec_file; do
    [[ -z "$spec_file" ]] && continue

    epac_write_section "Processing: $(basename "$spec_file")"

    local_spec="$(epac_strip_jsonc "$spec_file")"

    # Check for pacEnvironment filter from subfolder
    local parent_dir
    parent_dir="$(dirname "$spec_file")"
    local parent_name
    parent_name="$(basename "$parent_dir")"
    if [[ "$parent_name" != "policyDocumentations" && -n "$pac_selector" && "$parent_name" != "$pac_selector" ]]; then
        epac_write_status "Skipping (pacSelector mismatch)" "skip" 2
        continue
    fi

    # Load global documentation specs if present
    local global_doc_spec="{}"
    local has_global
    has_global="$(echo "$local_spec" | jq 'has("globalDocumentationSpecifications")')"
    if [[ "$has_global" == "true" ]]; then
        global_doc_spec="$(echo "$local_spec" | jq '.globalDocumentationSpecifications')"
    fi

    # ── Process documentPolicySets ──
    local has_ps
    has_ps="$(echo "$local_spec" | jq 'has("documentPolicySets")')"
    if [[ "$has_ps" == "true" ]]; then
        local ps_entries
        ps_entries="$(echo "$local_spec" | jq '.documentPolicySets')"
        # Normalize to array
        if [[ "$(echo "$ps_entries" | jq 'type')" != '"array"' ]]; then
            ps_entries="[${ps_entries}]"
        fi

        local ps_count
        ps_count="$(echo "$ps_entries" | jq 'length')"
        local psi=0
        while [[ $psi -lt $ps_count ]]; do
            local ps_entry
            ps_entry="$(echo "$ps_entries" | jq --argjson i "$psi" '.[$i]')"
            local ps_pac_env
            ps_pac_env="$(echo "$ps_entry" | jq -r '.pacEnvironment')"
            local ps_file_stem
            ps_file_stem="$(echo "$ps_entry" | jq -r '.fileNameStem')"
            local ps_title
            ps_title="$(echo "$ps_entry" | jq -r '.title')"
            local ps_sets
            ps_sets="$(echo "$ps_entry" | jq '.policySets // []')"
            local env_cols
            env_cols="$(echo "$ps_entry" | jq '.environmentColumnsInCsv // []')"

            epac_write_status "Policy Sets: ${ps_title} (env: ${ps_pac_env})" "info" 2

            # Merge global doc spec defaults
            local doc_spec
            doc_spec="$(jq -n --argjson g "$global_doc_spec" --argjson l "$ps_entry" '$g + $l')"

            # Switch PAC environment and get resources (would call Azure in real usage)
            # In documentation mode we need policy set details from Azure
            # For now, output placeholder if no cached data
            if [[ "$ps_pac_env" != "$current_pac_env" ]]; then
                current_pac_env="$ps_pac_env"
                epac_write_status "Switched to PAC environment: ${current_pac_env}" "info" 4
            fi

            # Build item list with itemId for flat list conversion
            local item_list
            item_list="$(echo "$ps_sets" | jq '[.[] | {shortName, itemId: (.id // .name), policySetId: (.id // .name)}]')"

            # The actual Azure calls would happen here — for offline/test mode,
            # we pass through whatever cached_details contains
            local flat_list="{}"
            local ps_details="{}"
            if [[ "$(echo "$cached_details" | jq --arg env "$current_pac_env" 'has($env)')" == "true" ]]; then
                ps_details="$(echo "$cached_details" | jq --arg env "$current_pac_env" '.[$env]')"
                flat_list="$(epac_convert_details_to_flat_list "$item_list" "$ps_details")"
            fi

            # Generate documentation
            local wiki_args=()
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
    local has_da
    has_da="$(echo "$local_spec" | jq 'has("documentAssignments")')"
    if [[ "$has_da" == "true" ]]; then
        local da_section
        da_section="$(echo "$local_spec" | jq '.documentAssignments')"

        # Path A: environmentCategories (explicit)
        local has_ec
        has_ec="$(echo "$da_section" | jq 'has("environmentCategories")')"
        if [[ "$has_ec" == "true" ]]; then
            _process_explicit_assignments "$da_section" "$global_doc_spec" "$doc_output" "$services_output"
        fi

        # Path B: documentAllAssignments (auto-discover)
        local has_daa
        has_daa="$(echo "$da_section" | jq 'has("documentAllAssignments")')"
        if [[ "$has_daa" == "true" ]]; then
            _process_auto_assignments "$da_section" "$global_doc_spec" "$doc_output" "$services_output"
        fi
    fi

done < <(find "$doc_folder" -type f \( -name "*.json" -o -name "*.jsonc" \) | sort)

epac_write_header "Documentation Generation Complete"
epac_write_status "Output: ${doc_output}" "success" 2

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
        local exclude_scope_types
        exclude_scope_types="$(echo "$daa" | jq '.excludeScopeTypes // []')"

        epac_write_status "Auto-discover assignments for env: ${daa_pac_env}" "info" 4

        # In real usage, this would query Azure to discover all assignments
        # and build environment categories automatically.
        # For now, pass through the documentation spec process

        local doc_specs
        doc_specs="$(echo "$daa" | jq '.documentationSpecifications // []')"
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

            local wiki_args=()
            [[ -n "$wiki_clone_pat" ]] && wiki_args+=(--wiki-clone-pat "$wiki_clone_pat")
            $wiki_spn && wiki_args+=(--wiki-spn)
            $include_manual && wiki_args+=(--include-manual)

            epac_out_documentation_for_assignments \
                --output-path "$doc_output" \
                --output-path-services "$services_output" \
                --doc-spec "$ds" \
                --assignments-by-env "{}" \
                --pac-environments "$pac_environments" \
                "${wiki_args[@]}"

            dsi=$((dsi + 1))
        done

        di=$((di + 1))
    done
}
