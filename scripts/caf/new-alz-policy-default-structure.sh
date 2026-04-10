#!/usr/bin/env bash
# scripts/caf/new-alz-policy-default-structure.sh
# Create ALZ/FSI/AMBA/SLZ policy default structure from Azure Landing Zones Library
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/lib/epac.sh"

usage() {
    cat <<'EOF'
Usage: new-alz-policy-default-structure.sh --definitions-root <PATH> --pac-selector <NAME> [OPTIONS]

Create a policy default structure file from the Azure Landing Zones Library.
The structure file maps management groups, default parameter values, and
enforcement modes for use with sync-alz-policy-from-library.sh.

Required:
  --definitions-root   Path to Definitions root folder
  --pac-selector       PAC environment selector name

Options:
  --type               Library type: ALZ|FSI|AMBA|SLZ (default: ALZ)
  --library-path       Path to pre-cloned ALZ library (skips git clone)
  --tag                Git tag for ALZ library (default: latest known tag)
  --help               Show this help message
EOF
    exit 0
}

definitions_root=""
pac_selector=""
lib_type="ALZ"
library_path=""
tag=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --definitions-root) definitions_root="$2"; shift 2 ;;
        --pac-selector) pac_selector="$2"; shift 2 ;;
        --type) lib_type="$2"; shift 2 ;;
        --library-path) library_path="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$definitions_root" ]] && { epac_log_error "Missing --definitions-root"; exit 1; }
[[ -z "$pac_selector" ]] && { epac_log_error "Missing --pac-selector"; exit 1; }

# Validate type
case "$lib_type" in
    ALZ|FSI|AMBA|SLZ) ;;
    *) epac_log_error "Invalid type: $lib_type. Must be ALZ, FSI, AMBA, or SLZ."; exit 1 ;;
esac

# Default tags per type
if [[ -z "$tag" ]]; then
    case "$lib_type" in
        ALZ) tag="platform/alz/2026.01.3" ;;
        FSI) tag="platform/fsi/2025.03.0" ;;
        AMBA) tag="platform/amba/2025.11.0" ;;
        SLZ) tag="platform/slz/2026.02.1" ;;
    esac
fi

epac_log_info "Creating Policy Default Structure — Type: $lib_type, Tag: $tag"

# Clone or use existing library
temp_clone=false
if [[ -z "$library_path" ]]; then
    library_path="$(pwd)/temp"
    temp_clone=true
    if [[ -d "$library_path" ]]; then
        epac_log_info "Removing existing temp folder..."
        rm -rf "$library_path"
    fi
    epac_log_info "Cloning Azure Landing Zones Library (tag: $tag)..."
    if git clone --config advice.detachedHead=false --depth 1 --branch "$tag" \
        https://github.com/Azure/Azure-Landing-Zones-Library.git "$library_path" 2>/dev/null; then
        epac_log_success "Repository cloned successfully"
    else
        epac_log_error "Failed to clone repository"
        exit 1
    fi
fi

type_lower="$(echo "$lib_type" | tr '[:upper:]' '[:lower:]')"

# ══════════════════════════════════════════════════════════════════════════════
# Build the JSON output structure
# ══════════════════════════════════════════════════════════════════════════════

schema="https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-structure-schema.json"

# Start with base structure
json_output="$(jq -n --arg schema "$schema" '{
    "$schema": $schema,
    managementGroupNameMappings: {},
    enforcementMode: "Default",
    defaultParameterValues: {},
    enforceGuardrails: { deployments: [] }
}')"

# ── Management Group Name Mappings ──────────────────────────────────────────
epac_log_info "Processing Management Group Names..."

arch_def_file="${library_path}/platform/${type_lower}/architecture_definitions/${type_lower}.alz_architecture_definition.json"
if [[ ! -f "$arch_def_file" ]]; then
    epac_log_error "Architecture definition file not found: $arch_def_file"
    exit 1
fi

# Read MG mappings from architecture definition
json_output="$(echo "$json_output" | jq --slurpfile arch "$arch_def_file" '
    .managementGroupNameMappings = (
        [$arch[0].management_groups[] | {
            (.id): {
                management_group_function: .display_Name,
                value: ("/providers/Microsoft.Management/managementGroups/" + .id)
            }
        }] | add // {}
    )
')"

# ── Default Parameter Values ────────────────────────────────────────────────
epac_log_info "Building Parameter Values..."

policy_defaults_file="${library_path}/platform/${type_lower}/alz_policy_default_values.json"
if [[ ! -f "$policy_defaults_file" ]]; then
    epac_log_warning "Policy defaults file not found: $policy_defaults_file"
else
    # Build additional values for ALZ
    additional_values='[]'
    if [[ "$lib_type" == "ALZ" ]]; then
        additional_values='[
            {
                "default_name": "ama_mdfc_sql_workspace_id",
                "description": "Workspace Id of the Log Analytics workspace destination for the Data Collection Rule.",
                "policy_assignments": [{"policy_assignment_name": "Deploy-MDFC-DefSQL-AMA", "parameter_names": ["userWorkspaceId"]}]
            },
            {
                "default_name": "ama_mdfc_sql_workspace_region",
                "description": "The region short name that should be used for the Log Analytics workspace for the SQL MDFC deployment.",
                "policy_assignments": [{"policy_assignment_name": "Deploy-MDFC-DefSQL-AMA", "parameter_names": ["workspaceRegion"]}]
            },
            {
                "default_name": "mdfc_email_security_contact",
                "description": "Email address for Microsoft Defender for Cloud alerts.",
                "policy_assignments": [{"policy_assignment_name": "Deploy-MDFC-Config-H224", "parameter_names": ["emailSecurityContact"]}]
            },
            {
                "default_name": "mdfc_export_resource_group_name",
                "description": "Resource Group name for the export to Log Analytics workspace configuration",
                "policy_assignments": [{"policy_assignment_name": "Deploy-MDFC-Config-H224", "parameter_names": ["ascExportResourceGroupName"]}]
            },
            {
                "default_name": "mdfc_export_resource_group_location",
                "description": "Resource Group location for the export to Log Analytics workspace configuration",
                "policy_assignments": [{"policy_assignment_name": "Deploy-MDFC-Config-H224", "parameter_names": ["ascExportResourceGroupLocation"]}]
            }
        ]'
    fi

    # Process each parameter default
    defaults_json="$(jq '.defaults' "$policy_defaults_file")"
    combined="$(echo "$defaults_json" "$additional_values" | jq -s '.[0] + .[1]')"

    param_values='{}'
    while IFS= read -r param_line; do
        [[ -z "$param_line" ]] && continue
        default_name="$(echo "$param_line" | jq -r '.default_name')"
        description="$(echo "$param_line" | jq -r '.description')"

        # Skip log_analytics_workspace_id and resource_group_location — handled separately with suffixed entries
        if [[ "$default_name" == "log_analytics_workspace_id" || "$default_name" == "resource_group_location" ]]; then
            # These need per-parameter-name entries with suffix
            suffix=0
            while IFS= read -r param_name; do
                [[ -z "$param_name" ]] && continue
                # Find the assignment name for this parameter
                assign_names="$(echo "$param_line" | jq -r --arg pn "$param_name" '
                    [.policy_assignments[] | select(.parameter_names[] == $pn) | .policy_assignment_name] | unique')"

                # Find assignment file to get default value
                first_assign="$(echo "$param_line" | jq -r '.policy_assignments[0].policy_assignment_name')"
                assign_file_name="${first_assign}.alz_policy_assignment.json"
                if [[ "$lib_type" == "AMBA" ]]; then
                    assign_file_name="${assign_file_name//-/_}"
                fi
                assign_file="$(find "$library_path" -name "$assign_file_name" -type f 2>/dev/null | head -1)"
                default_value=""
                if [[ -n "$assign_file" && -f "$assign_file" ]]; then
                    default_value="$(jq -r --arg pn "$param_name" '.properties.parameters[$pn].value // ""' "$assign_file")"
                fi

                entry_name="${default_name}_${suffix}"
                param_values="$(echo "$param_values" | jq \
                    --arg key "$entry_name" \
                    --arg desc "$description" \
                    --argjson assigns "$assign_names" \
                    --arg pname "$param_name" \
                    --arg val "$default_value" \
                    '.[$key] = [{
                        description: $desc,
                        policy_assignment_name: $assigns,
                        parameters: {
                            parameter_name: $pname,
                            value: $val
                        }
                    }]')"
                suffix=$((suffix + 1))
            done < <(echo "$param_line" | jq -r '.policy_assignments[].parameter_names[]' | sort -u)
            continue
        fi

        # Standard parameter — grab default value from first referenced assignment file
        first_assign="$(echo "$param_line" | jq -r '.policy_assignments[0].policy_assignment_name')"
        first_param="$(echo "$param_line" | jq -r '.policy_assignments[0].parameter_names[0]')"
        assign_file_name="${first_assign}.alz_policy_assignment.json"
        if [[ "$lib_type" == "AMBA" ]]; then
            assign_file_name="${assign_file_name//-/_}"
        fi
        assign_file="$(find "$library_path" -name "$assign_file_name" -type f 2>/dev/null | head -1)"

        default_value=""
        if [[ -n "$assign_file" && -f "$assign_file" ]]; then
            default_value="$(jq -r --arg pn "$first_param" '.properties.parameters[$pn].value // ""' "$assign_file" 2>/dev/null || echo "")"
        else
            epac_log_warning "Could not find assignment file: $assign_file_name"
            continue
        fi

        assign_names="$(echo "$param_line" | jq '[.policy_assignments[].policy_assignment_name]')"

        param_values="$(echo "$param_values" | jq \
            --arg key "$default_name" \
            --arg desc "$description" \
            --argjson assigns "$assign_names" \
            --arg pname "$first_param" \
            --arg val "$default_value" \
            '.[$key] = [{
                description: $desc,
                policy_assignment_name: $assigns,
                parameters: {
                    parameter_name: $pname,
                    value: $val
                }
            }]')"
    done < <(echo "$combined" | jq -c '.[]')

    json_output="$(echo "$json_output" | jq --argjson pv "$param_values" '.defaultParameterValues = $pv')"
fi

# ── Write Output ────────────────────────────────────────────────────────────
epac_log_info "Writing Output Files..."
output_dir="${definitions_root}/policyStructures"
mkdir -p "$output_dir"

if [[ -n "$pac_selector" ]]; then
    output_file="${output_dir}/${type_lower}.policy_default_structure.${pac_selector}.jsonc"
else
    output_file="${output_dir}/${type_lower}.policy_default_structure.jsonc"
fi

echo "$json_output" | jq '.' > "$output_file"
epac_log_success "Default structure file: $output_file"

# Cleanup temp clone
if [[ "$temp_clone" == "true" ]]; then
    rm -rf "$library_path"
fi

epac_log_success "ALZ Policy default structure created successfully"
