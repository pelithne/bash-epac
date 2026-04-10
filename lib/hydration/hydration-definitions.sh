#!/usr/bin/env bash
# lib/hydration/hydration-definitions.sh — Definition scaffolding and manipulation
[[ -n "${_EPAC_HYDRATION_DEFS_LOADED:-}" ]] && return 0
_EPAC_HYDRATION_DEFS_LOADED=1

SCRIPT_DIR_HD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_HD}/hydration-core.sh"

# ══════════════════════════════════════════════════════════════════════════════
# Create Definitions Folder Structure
# ══════════════════════════════════════════════════════════════════════════════

# Create the standard definitions directory structure
# Usage: hydration_create_definitions_folder [path]
hydration_create_definitions_folder() {
    local root="${1:-Definitions}"

    if [[ ! -d "$root" ]]; then
        mkdir -p "$root"
        cat > "${root}/global-settings.jsonc" << 'EOF'
{
    "$schema": "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/global-settings-schema.json"
}
EOF
    fi

    for subdir in policyAssignments policySetDefinitions policyDefinitions policyDocumentations; do
        mkdir -p "${root}/${subdir}"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Generate Global Settings File
# ══════════════════════════════════════════════════════════════════════════════

# Create a full global-settings.jsonc with main + epac-dev environments
# Usage: hydration_create_global_settings <args...>
hydration_create_global_settings() {
    local pac_owner_id="" mi_location="" main_pac_selector="" epac_pac_selector=""
    local cloud="" tenant_id="" main_root="" epac_root="" strategy=""
    local definitions_root="" log_file="" keep_dfc=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pac-owner-id) pac_owner_id="$2"; shift 2 ;;
            --mi-location) mi_location="$2"; shift 2 ;;
            --main-pac-selector) main_pac_selector="$2"; shift 2 ;;
            --epac-pac-selector) epac_pac_selector="$2"; shift 2 ;;
            --cloud) cloud="$2"; shift 2 ;;
            --tenant-id) tenant_id="$2"; shift 2 ;;
            --main-root) main_root="$2"; shift 2 ;;
            --epac-root) epac_root="$2"; shift 2 ;;
            --strategy) strategy="$2"; shift 2 ;;
            --definitions-root) definitions_root="$2"; shift 2 ;;
            --log-file) log_file="$2"; shift 2 ;;
            --keep-dfc) keep_dfc=true; shift ;;
            *) shift ;;
        esac
    done

    # Ensure definitions folder exists
    if [[ ! -d "$definitions_root" ]]; then
        hydration_create_definitions_folder "$definitions_root"
        [[ -n "$log_file" ]] && hydration_log logEntryDataAsPresented "Created Definitions folder at $definitions_root" "$log_file" --color yellow
    fi

    local mg_base="/providers/Microsoft.Management/managementGroups"
    local main_scope="${mg_base}/${main_root}"
    local epac_scope="${mg_base}/${epac_root}"
    # Normalize double-slash
    main_scope="${main_scope//\/\///}"
    epac_scope="${epac_scope//\/\///}"

    local output_file="${definitions_root}/global-settings.jsonc"

    jq -n \
        --arg schema "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/global-settings-schema.json" \
        --arg owner "$pac_owner_id" \
        --arg main_selector "$main_pac_selector" \
        --arg epac_selector "$epac_pac_selector" \
        --arg cloud "$cloud" \
        --arg tenant "$tenant_id" \
        --arg main_scope "$main_scope" \
        --arg epac_scope "$epac_scope" \
        --arg strategy "$strategy" \
        --argjson keep_dfc "$keep_dfc" \
        --arg mi_location "$mi_location" \
        '{
            "$schema": $schema,
            pacOwnerId: $owner,
            pacEnvironments: [
                {
                    pacSelector: $main_selector,
                    cloud: $cloud,
                    tenantId: $tenant,
                    deploymentRootScope: $main_scope,
                    desiredState: {
                        strategy: $strategy,
                        keepDfcSecurityAssignments: $keep_dfc,
                        excludedScopes: [],
                        excludedPolicyDefinitions: [],
                        excludedPolicySetDefinitions: [],
                        excludedPolicyAssignments: []
                    },
                    globalNotScopes: [],
                    managedIdentityLocation: $mi_location
                },
                {
                    pacSelector: $epac_selector,
                    cloud: $cloud,
                    tenantId: $tenant,
                    deploymentRootScope: $epac_scope,
                    desiredState: {
                        strategy: $strategy,
                        keepDfcSecurityAssignments: $keep_dfc,
                        excludedScopes: [],
                        excludedPolicyDefinitions: [],
                        excludedPolicySetDefinitions: [],
                        excludedPolicyAssignments: []
                    },
                    globalNotScopes: [],
                    managedIdentityLocation: $mi_location
                }
            ]
        }' > "$output_file"

    [[ -n "$log_file" ]] && hydration_log logEntryDataAsPresented "Global Settings file created: $output_file" "$log_file" --color yellow
    echo "$output_file"
}

# ══════════════════════════════════════════════════════════════════════════════
# Assignment PAC Selector Clone
# ══════════════════════════════════════════════════════════════════════════════

# Clone assignment files for a new PAC selector with MG scope remapping
# Usage: hydration_clone_assignments <src_selector> <new_selector> <defs_root> [--prefix P] [--suffix S]
hydration_clone_assignments() {
    local src_selector="$1" new_selector="$2" defs_root="$3"
    shift 3
    local prefix="" suffix=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix) prefix="$2"; shift 2 ;;
            --suffix) suffix="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local src_dir="${defs_root}/policyAssignments"
    if [[ ! -d "$src_dir" ]]; then
        epac_log_error "Assignment directory not found: $src_dir"
        return 1
    fi

    local count=0
    while IFS= read -r -d '' file; do
        local content
        content="$(cat "$file")"

        # Check if file contains the source selector
        if echo "$content" | jq -e --arg sel "$src_selector" 'tostring | contains($sel)' &>/dev/null; then
            # Replace scope references: add prefix/suffix to MG names in scope paths
            local new_content
            new_content="$(echo "$content" | jq \
                --arg old_sel "$src_selector" \
                --arg new_sel "$new_selector" \
                --arg prefix "$prefix" \
                --arg suffix "$suffix" \
                'walk(if type == "object" and has($old_sel) then
                    . + {($new_sel): .[$old_sel]} | del(.[$old_sel])
                 elif type == "string" and test("managementGroups/") then
                    gsub("managementGroups/(?<mg>[^/\"]+)"; "managementGroups/" + $prefix + .mg + $suffix)
                 else .
                 end)')"

            echo "$new_content" | jq '.' > "$file"
            count=$((count + 1))
        fi
    done < <(find "$src_dir" -name "*.json" -o -name "*.jsonc" | tr '\n' '\0')

    echo "Updated $count assignment files for new selector '$new_selector'"
}

# ══════════════════════════════════════════════════════════════════════════════
# Update Assignment Scopes
# ══════════════════════════════════════════════════════════════════════════════

# Update management group references in assignment files
# Usage: hydration_update_assignment_scope <file> <old_mg> <new_mg>
hydration_update_assignment_scope() {
    local file="$1" old_mg="$2" new_mg="$3"

    if [[ ! -f "$file" ]]; then
        epac_log_error "File not found: $file"
        return 1
    fi

    local content
    content="$(jq --arg old "$old_mg" --arg new "$new_mg" \
        'walk(if type == "string" then gsub($old; $new) else . end)' "$file")"
    echo "$content" | jq '.' > "$file"
}

# ══════════════════════════════════════════════════════════════════════════════
# Filtered Exemptions
# ══════════════════════════════════════════════════════════════════════════════

# Filter exemptions CSV by assignments that exist in definitions
# Usage: hydration_filter_exemptions <exemptions_csv> <output_folder> <definitions_folder>
hydration_filter_exemptions() {
    local exemptions_csv="$1" output_folder="$2" definitions_folder="$3"

    if [[ ! -f "$exemptions_csv" ]]; then
        epac_log_error "Exemptions CSV not found: $exemptions_csv"
        return 1
    fi

    mkdir -p "$output_folder"

    # Get all assignment names from definitions
    local assignment_names
    assignment_names="$(find "${definitions_folder}/policyAssignments" -name "*.json" -o -name "*.jsonc" 2>/dev/null | \
        xargs -I{} jq -r '.assignment.name // empty' {} 2>/dev/null | sort -u)"

    # Filter CSV: keep header + rows matching known assignments
    local header
    header="$(head -1 "$exemptions_csv")"
    echo "$header" > "${output_folder}/filtered-exemptions.csv"

    tail -n +2 "$exemptions_csv" | while IFS= read -r line; do
        # Check if any assignment name appears in the line
        while IFS= read -r aname; do
            if [[ "$line" == *"$aname"* ]]; then
                echo "$line" >> "${output_folder}/filtered-exemptions.csv"
                break
            fi
        done <<< "$assignment_names"
    done
}

# ══════════════════════════════════════════════════════════════════════════════
# Definition Folder Reorganization
# ══════════════════════════════════════════════════════════════════════════════

# Reorganize definitions by assignment ownership
# Usage: hydration_reorganize_definitions <definitions_root> <folder_order_json>
hydration_reorganize_definitions() {
    local definitions_root="$1" folder_order_json="$2"

    local assignments_dir="${definitions_root}/policyAssignments"
    if [[ ! -d "$assignments_dir" ]]; then
        epac_log_error "Assignments directory not found: $assignments_dir"
        return 1
    fi

    # folder_order_json should be: {"folder1": ["assignment1", "assignment2"], ...}
    echo "$folder_order_json" | jq -r 'to_entries[] | .key as $folder | .value[] | "\($folder)\t\(.)"' | \
    while IFS=$'\t' read -r folder assignment; do
        local target_dir="${assignments_dir}/${folder}"
        mkdir -p "$target_dir"
        # Find and move assignment files
        find "$assignments_dir" -maxdepth 1 -name "${assignment}.*" -exec mv {} "$target_dir/" \;
    done
}
