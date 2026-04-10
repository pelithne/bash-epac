#!/usr/bin/env bash
# scripts/caf/sync-alz-policy-from-library.sh
# Sync policy definitions, set definitions, and assignments from ALZ library
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/lib/epac.sh"

usage() {
    cat <<'EOF'
Usage: sync-alz-policy-from-library.sh --definitions-root <PATH> --pac-selector <NAME> [OPTIONS]

Sync policy definitions, policy set definitions, and policy assignments from
the Azure Landing Zones Library into your EPAC definitions structure.

Required:
  --definitions-root           Path to Definitions root folder
  --pac-selector               PAC environment selector name

Options:
  --type                       Library type: ALZ|FSI|AMBA|SLZ (default: ALZ)
  --library-path               Path to pre-cloned ALZ library (skips git clone)
  --tag                        Git tag for ALZ library (default: latest known tag)
  --create-guardrail-assignments  Create guardrail assignments
  --enable-overrides           Enable override processing from structure file
  --sync-assignments-only      Only sync assignments (skip definitions)
  --sync-amba-extended          Sync AMBA extended policies (AMBA type only)
  --help                       Show this help message
EOF
    exit 0
}

definitions_root=""
pac_selector=""
lib_type="ALZ"
library_path=""
tag=""
create_guardrails=false
enable_overrides=false
sync_assignments_only=false
sync_amba_extended=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --definitions-root) definitions_root="$2"; shift 2 ;;
        --pac-selector) pac_selector="$2"; shift 2 ;;
        --type) lib_type="$2"; shift 2 ;;
        --library-path) library_path="$2"; shift 2 ;;
        --tag) tag="$2"; shift 2 ;;
        --create-guardrail-assignments) create_guardrails=true; shift ;;
        --enable-overrides) enable_overrides=true; shift ;;
        --sync-assignments-only) sync_assignments_only=true; shift ;;
        --sync-amba-extended) sync_amba_extended=true; shift ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$definitions_root" ]] && { epac_log_error "Missing --definitions-root"; exit 1; }
[[ -z "$pac_selector" ]] && { epac_log_error "Missing --pac-selector"; exit 1; }

case "$lib_type" in
    ALZ|FSI|AMBA|SLZ) ;;
    *) epac_log_error "Invalid type: $lib_type"; exit 1 ;;
esac

# Default tags
if [[ -z "$tag" ]]; then
    case "$lib_type" in
        ALZ) tag="platform/alz/2026.01.3" ;;
        FSI) tag="platform/fsi/2025.03.0" ;;
        AMBA) tag="platform/amba/2025.11.0" ;;
        SLZ) tag="platform/slz/2026.02.1" ;;
    esac
fi

epac_log_info "Syncing Policies From Library — Type: $lib_type, Tag: $tag"

type_lower="$(echo "$lib_type" | tr '[:upper:]' '[:lower:]')"

# Clone library if no path provided
temp_clone=false
if [[ -z "$library_path" ]]; then
    library_path="$(pwd)/temp"
    temp_clone=true
    [[ -d "$library_path" ]] && rm -rf "$library_path"
    epac_log_info "Cloning Azure Landing Zones Library..."
    if git clone --config advice.detachedHead=false --depth 1 --branch "$tag" \
        https://github.com/Azure/Azure-Landing-Zones-Library.git "$library_path" 2>/dev/null; then
        epac_log_success "Repository cloned successfully"
    else
        epac_log_error "Failed to clone repository"
        exit 1
    fi
fi

# Clone AMBA extended if requested
amba_library_path=""
if [[ "$lib_type" == "AMBA" && "$sync_amba_extended" == "true" ]]; then
    amba_library_path="$(pwd)/temp_amba_extended"
    [[ -d "$amba_library_path" ]] && rm -rf "$amba_library_path"
    epac_log_info "Cloning AMBA extended policies..."
    if git clone --config advice.detachedHead=false --depth 1 \
        https://github.com/Azure/azure-monitor-baseline-alerts.git "$amba_library_path" 2>/dev/null; then
        epac_log_success "AMBA extended repository cloned"
    else
        epac_log_error "Failed to clone AMBA extended repository"
        exit 1
    fi
fi

# Ensure policyStructures directory exists
structure_dir="${definitions_root}/policyStructures"
mkdir -p "$structure_dir"

def_schema="https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-definition-schema.json"
set_schema="https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-set-definition-schema.json"
assign_schema="https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-assignment-schema.json"

# ══════════════════════════════════════════════════════════════════════════════
# 1. Policy Definitions
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$sync_assignments_only" == "false" && "$lib_type" != "SLZ" ]]; then
    epac_log_info "Creating Policy Definition Objects..."
    def_src="${library_path}/platform/${type_lower}/policy_definitions"
    if [[ -d "$def_src" ]]; then
        while IFS= read -r -d '' file; do
            content="$(cat "$file")"
            name="$(echo "$content" | jq -r '.name')"
            category="$(echo "$content" | jq -r '.properties.metadata.category // "General"')"

            # Build EPAC template
            output_json="$(echo "$content" | jq --arg schema "$def_schema" '{
                "$schema": $schema,
                name: .name,
                properties: .properties
            }')"

            # Replace [[ with [ (ALZ library convention)
            output_json="$(echo "$output_json" | sed 's/\[\[/[/g')"

            output_dir="${definitions_root}/policyDefinitions/${lib_type}/${category}"
            mkdir -p "$output_dir"
            echo "$output_json" > "${output_dir}/${name}.json"
        done < <(find "$def_src" -name "*.json" -type f -print0 2>/dev/null)
    fi

    # ══════════════════════════════════════════════════════════════════════════
    # 2. Policy Set Definitions
    # ══════════════════════════════════════════════════════════════════════════
    epac_log_info "Creating Policy Set Definition Objects..."
    set_src="${library_path}/platform/${type_lower}/policy_set_definitions"
    if [[ -d "$set_src" ]]; then
        while IFS= read -r -d '' file; do
            content="$(cat "$file")"
            name="$(echo "$content" | jq -r '.name')"
            category="$(echo "$content" | jq -r '.properties.metadata.category // "General"')"

            # Build EPAC template — fix custom policy references
            output_json="$(echo "$content" | jq --arg schema "$set_schema" '{
                "$schema": $schema,
                name: .name,
                properties: {
                    description: .properties.description,
                    displayName: .properties.displayName,
                    metadata: .properties.metadata,
                    parameters: .properties.parameters,
                    policyDefinitions: [.properties.policyDefinitions[] | {
                        parameters: .parameters,
                        groupNames: .groupNames,
                        policyDefinitionReferenceId: .policyDefinitionReferenceId
                    } + (if .policyDefinitionId | test("managementGroups") then
                            {policyDefinitionName: (.policyDefinitionId | split("/") | last)}
                         else
                            {policyDefinitionId: .policyDefinitionId}
                         end)
                    ],
                    policyType: .properties.policyType,
                    policyDefinitionGroups: .properties.policyDefinitionGroups
                }
            }')"

            # Fix ALZ-specific template expressions
            output_json="$(echo "$output_json" | sed "s/\[\[/[/g")"

            output_dir="${definitions_root}/policySetDefinitions/${lib_type}/${category}"
            mkdir -p "$output_dir"
            echo "$output_json" > "${output_dir}/${name}.json"
        done < <(find "$set_src" -name "*.json" -type f -print0 2>/dev/null)
    fi

    # AMBA Extended policy definitions
    if [[ "$lib_type" == "AMBA" && "$sync_amba_extended" == "true" && -n "$amba_library_path" ]]; then
        epac_log_info "Creating AMBA Extended Policy Definition Objects..."
        while IFS= read -r -d '' file; do
            content="$(cat "$file")"
            name="$(echo "$content" | jq -r '.name | gsub("/"; "_") | gsub("%"; "pc")')"
            # Extract subpath from directory structure
            rel_dir="$(dirname "$file" | sed "s|${amba_library_path}/services/||" | head -c 100)"
            subpath="$(echo "$rel_dir" | awk -F/ '{print $1"/"$2}')"

            output_json="$(echo "$content" | jq --arg schema "$def_schema" --arg n "$name" '{
                "$schema": $schema,
                name: $n,
                properties: .properties
            }' | sed 's/\[\[/[/g')"

            output_dir="${definitions_root}/policyDefinitions/${lib_type}/${subpath}"
            mkdir -p "$output_dir"
            echo "$output_json" > "${output_dir}/${name}.json"
        done < <(find "$amba_library_path/services" -path "*/policy/*.json" -type f -print0 2>/dev/null)
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# 3. Assignment Objects
# ══════════════════════════════════════════════════════════════════════════════
epac_log_info "Creating Assignment Objects..."

# Read the structure file
structure_file="$(find "$structure_dir" -name "*${type_lower}.policy_default_structure.${pac_selector}.jsonc" -type f 2>/dev/null | head -1)"
if [[ -z "$structure_file" || ! -f "$structure_file" ]]; then
    epac_log_error "Policy default structure file not found. Run new-alz-policy-default-structure.sh first."
    exit 1
fi

structure="$(epac_read_jsonc "$structure_file")"
enforcement_mode="$(echo "$structure" | jq -r '.enforcementMode // "Default"')"
enforcement_text="must"
[[ "$enforcement_mode" == "DoNotEnforce" ]] && enforcement_text="should"

# Track existing assignments for cleanup
existing_assignments_dir="${definitions_root}/policyAssignments/${lib_type}/${pac_selector}"
declare -A existing_files
if [[ -d "$existing_assignments_dir" ]]; then
    while IFS= read -r -d '' ef; do
        aname="$(jq -r '.assignment.name // empty' "$ef" 2>/dev/null || epac_read_jsonc "$ef" | jq -r '.assignment.name // empty')"
        [[ -n "$aname" ]] && existing_files["$aname"]="$ef"
    done < <(find "$existing_assignments_dir" -name "*.jsonc" -type f -print0 2>/dev/null)
fi

# Load archetypes
archetype_dir="${library_path}/platform/${type_lower}/archetype_definitions"
archetypes_json="$(find "$archetype_dir" -name "*.json" -type f 2>/dev/null | xargs -I{} cat {} | jq -s '.')"

# Handle custom archetypes from overrides
ignore_archetypes="[]"
custom_archetypes="[]"
if [[ "$enable_overrides" == "true" ]]; then
    epac_log_info "Overrides enabled"
    ignore_archetypes="$(echo "$structure" | jq '.overrides.archetypes.ignore // []')"
    custom_archetypes="$(echo "$structure" | jq '.overrides.archetypes.custom // []')"
    # Merge custom archetypes
    archetypes_json="$(echo "$archetypes_json" "$custom_archetypes" | jq -s '.[0] + .[1]')"
fi

# Process existing-type archetypes (modify base archetypes)
final_archetypes="$(echo "$archetypes_json" | jq --argjson all "$archetypes_json" --arg type "$lib_type" '
    [.[] | select(.type == "existing") | . as $existing |
        (if .based_on then
            ($all | map(select(.name == $existing.based_on and (.type // "") != "existing")) | .[0].policy_assignments // [])
        elif .name == "landingzones" then
            ($all | map(select(.name | test("landing_zones") and (.type // "") != "existing")) | .[0].policy_assignments // [])
        elif .name == "alz" then
            ($all | map(select(.name | test("root") and (.type // "") != "existing")) | .[0].policy_assignments // [])
        elif .name == "sovereign_root" then
            ($all | map(select(.name | test("sovereign_root") and (.type // "") != "existing")) | .[0].policy_assignments // [])
        else
            ($all | map(select(.name == $existing.name and (.type // "") != "existing")) | .[0].policy_assignments // [])
        end) as $base_assignments |
        {
            name: (if .name == "alz" then (if $type == "AMBA" then "amba_root" else "root" end)
                   elif .name == "landingzones" then (if $type == "AMBA" then "amba_landing_zones" else .name end)
                   elif .name == "sovereign_root" then "slz"
                   elif $type == "AMBA" then ("amba_" + .name)
                   else .name end),
            policy_assignments: ([$base_assignments[] | select(. as $a | ($existing.policy_assignments_to_remove // []) | index($a) | not)]
                + ($existing.policy_assignments_to_add // []))
        }
    ] + [.[] | select((.type // "") != "existing")]
    | map(select(.policy_assignments | length > 0))
    | unique_by(.name)
')"

# Deduplicate landing zones
final_archetypes="$(echo "$final_archetypes" | jq '
    if ([.[] | select(.name == "landingzones")] | length > 0) and ([.[] | select(.name == "landing_zones")] | length > 0) then
        [.[] | select(.name != "landing_zones")]
    else . end
')"

# Remove assignments scheduled for removal from existing files
if [[ "$enable_overrides" == "true" ]]; then
    echo "$archetypes_json" | jq -r '.[] | .policy_assignments_to_remove // [] | .[]' 2>/dev/null | while IFS= read -r to_remove; do
        [[ -z "$to_remove" ]] && continue
        if [[ -n "${existing_files[$to_remove]:-}" ]]; then
            rm -f "${existing_files[$to_remove]}"
            epac_log_info "Removed assignment '$to_remove'"
        fi
    done
fi

# Track created assignments for cleanup
declare -A created_assignments

# Iterate archetypes and create assignment files
while IFS= read -r archetype_line; do
    [[ -z "$archetype_line" ]] && continue
    archetype_name="$(echo "$archetype_line" | jq -r '.name')"

    # Check if this archetype should be ignored
    if echo "$ignore_archetypes" | jq -e --arg n "$archetype_name" 'index($n) != null' &>/dev/null; then
        epac_log_info "Ignoring archetype: $archetype_name"
        continue
    fi

    while IFS= read -r required_assignment; do
        [[ -z "$required_assignment" ]] && continue

        # Skip guardrails unless requested
        if [[ "$create_guardrails" == "false" ]] && [[ "$required_assignment" =~ ^Enforce-(GR|Encrypt)- ]]; then
            continue
        fi

        # Find assignment file in library
        assign_file_name="${required_assignment}.alz_policy_assignment.json"
        case "$lib_type" in
            AMBA|FSI|SLZ) assign_file_name="${assign_file_name//-/_}" ;;
        esac

        assign_file="$(find "${library_path}/platform/${type_lower}/policy_assignments" -name "$assign_file_name" -type f 2>/dev/null | head -1)"
        file_content=""
        assignment_from_definition=false

        if [[ -n "$assign_file" && -f "$assign_file" ]]; then
            file_content="$(cat "$assign_file")"
        else
            # Try policy definitions as fallback (ALZ only)
            if [[ "$lib_type" == "ALZ" ]]; then
                fallback="$(find "${library_path}/platform/${type_lower}/policy_definitions" -name "${required_assignment}.*.json" -type f 2>/dev/null | head -1)"
                if [[ -n "$fallback" && -f "$fallback" ]]; then
                    file_content="$(cat "$fallback")"
                    assignment_from_definition=true
                fi
            fi
            if [[ -z "$file_content" ]]; then
                epac_log_warning "Skipping unresolved assignment '$required_assignment' in archetype '$archetype_name'"
                continue
            fi
        fi

        fc_name="$(echo "$file_content" | jq -r '.name')"
        [[ -z "$fc_name" || "$fc_name" == "null" ]] && continue

        # Determine scope
        scope_trim="$archetype_name"
        [[ "$scope_trim" == "root" ]] && scope_trim="alz"
        [[ "$scope_trim" =~ ^amba_ ]] && scope_trim="${scope_trim#amba_}" && [[ "$scope_trim" == "root" ]] && scope_trim="alz"
        [[ "$scope_trim" == "landing_zones" ]] && scope_trim="landingzones"
        [[ "$scope_trim" == "global" ]] && scope_trim="mcfs"
        [[ "$scope_trim" == "sovereign_root" && "$lib_type" == "SLZ" ]] && scope_trim="slz"
        [[ "$lib_type" == "FSI" && "$scope_trim" != "confidential" ]] && scope_trim="fsi"

        # Get scope value(s) from structure file
        if [[ "$scope_trim" == "confidential" ]]; then
            scope_values="$(echo "$structure" | jq --arg st "$scope_trim" '[
                .managementGroupNameMappings | to_entries[] |
                select(.value.management_group_function | test($st; "i")) |
                .value.value
            ] | flatten')"
        else
            scope_values="$(echo "$structure" | jq --arg st "$scope_trim" '
                .managementGroupNameMappings[$st].value |
                if type == "array" then . else [.] end')"
        fi

        # Node name prefix
        node_prefix="$archetype_name"
        [[ "$node_prefix" == "landingzones" ]] && node_prefix="landing_zones"

        # Determine enforcement mode (check overrides)
        effective_enforcement="$enforcement_mode"
        if [[ "$enable_overrides" == "true" ]]; then
            override_em="$(echo "$structure" | jq -r --arg name "$fc_name" '
                .overrides.enforcementMode // [] | map(select(.policy_assignment_name == $name)) | .[0].value // empty')"
            [[ -n "$override_em" ]] && effective_enforcement="$override_em"
        fi

        # Build definition entry
        def_entry="$(echo "$file_content" | jq -r '
            if .properties.policyRule then "policyName"
            elif .properties.policyDefinitions then "policySetName"
            elif (.properties.policyDefinitionId // "" | test("placeholder.*policySetDefinition")) then "policySetName"
            elif (.properties.policyDefinitionId // "" | test("placeholder.*policyDefinition")) then "policyName"
            elif (.properties.policyDefinitionId // "" | test("policySetDefinitions")) then "policySetId"
            else "policyId" end')"

        def_value="$(echo "$file_content" | jq -r '
            if .properties.policyRule or .properties.policyDefinitions then .name
            else (.properties.policyDefinitionId // .name) | split("/") | last end')"

        def_entry_json="{\"displayName\": $(echo "$file_content" | jq '.properties.displayName')}"
        if [[ "$def_entry" == "policySetId" || "$def_entry" == "policyId" ]]; then
            def_entry_json="$(echo "$def_entry_json" | jq --arg k "$def_entry" --arg v "$(echo "$file_content" | jq -r '.properties.policyDefinitionId // .name')" '. + {($k): $v}')"
        else
            def_entry_json="$(echo "$def_entry_json" | jq --arg k "$def_entry" --arg v "$def_value" '. + {($k): $v}')"
        fi

        # Build parameters
        parameters='{}'
        if [[ "$fc_name" != "Deploy-Private-DNS-Zones" && "$assignment_from_definition" == "false" ]]; then
            parameters="$(echo "$file_content" | jq '.properties.parameters // {} | to_entries | map({(.key): .value.value}) | add // {}')"

            # Apply default parameter values from structure
            while IFS=$'\t' read -r pk pv_name pv_value; do
                [[ -z "$pk" ]] && continue
                if echo "$structure" | jq -e --arg key "$pk" --arg name "$fc_name" '
                    .defaultParameterValues[$key] | any(.policy_assignment_name | if type == "array" then any(. == $name) else . == $name end)' &>/dev/null; then
                    pn="$(echo "$structure" | jq -r --arg k "$pk" '.defaultParameterValues[$k][0].parameters.parameter_name')"
                    pval="$(echo "$structure" | jq --arg k "$pk" '.defaultParameterValues[$k][0].parameters.value')"
                    parameters="$(echo "$parameters" | jq --arg pn "$pn" --argjson pv "$pval" '.[$pn] = $pv')"
                fi
            done < <(echo "$structure" | jq -r '.defaultParameterValues | keys[]' 2>/dev/null | while read -r key; do echo -e "${key}\t\t"; done)

            # Apply override parameters
            if [[ "$enable_overrides" == "true" ]]; then
                override_params="$(echo "$structure" | jq --arg arch "$archetype_name" --arg name "$fc_name" '
                    .overrides.parameters[$arch] // [] | map(select(.policy_assignment_name == $name)) | .[0].parameters // []')"
                if [[ "$override_params" != "[]" && "$override_params" != "null" ]]; then
                    while IFS= read -r op; do
                        opn="$(echo "$op" | jq -r '.parameter_name')"
                        opv="$(echo "$op" | jq '.value')"
                        parameters="$(echo "$parameters" | jq --arg k "$opn" --argjson v "$opv" '.[$k] = $v')"
                    done < <(echo "$override_params" | jq -c '.[]' 2>/dev/null)
                fi
                # Sort parameters
                parameters="$(echo "$parameters" | jq 'to_entries | sort_by(.key) | from_entries')"
            fi
        elif [[ "$fc_name" == "Deploy-Private-DNS-Zones" ]]; then
            # Special DNS zone handling
            dns_region="$(echo "$structure" | jq -r '.defaultParameterValues.private_dns_zone_region[0].parameters.value // ""')"
            dns_sub="$(echo "$structure" | jq -r '.defaultParameterValues.private_dns_zone_subscription_id[0].parameters.value // ""')"
            dns_rg="$(echo "$structure" | jq -r '.defaultParameterValues.private_dns_zone_resource_group_name[0].parameters.value // ""')"

            parameters="$(echo "$file_content" | jq --arg sub "$dns_sub" --arg rg "$dns_rg" '
                .properties.parameters // {} | to_entries | map({
                    (.key): ("/subscriptions/" + $sub + "/resourceGroups/" + $rg +
                             "/providers/Microsoft.Network/privateDnsZones/" +
                             (.value.value | split("/") | last))
                }) | add // {}')"

            # Replace .ne. with actual region
            parameters="$(echo "$parameters" | sed "s/\.ne\./.${dns_region}./g")"
        fi

        # Non-compliance messages
        nc_messages="$(echo "$file_content" | jq --arg em "$enforcement_text" '
            if .properties.nonComplianceMessages then
                [.properties.nonComplianceMessages[] | {
                    message: (.message | gsub("{enforcementMode}"; $em))
                }]
            else null end')"

        # Definition version
        def_version="$(echo "$file_content" | jq -r '.properties.definitionVersion // empty')"

        # Build the final assignment JSON
        assignment_json="$(jq -n \
            --arg schema "$assign_schema" \
            --arg node "${node_prefix}/${fc_name}" \
            --arg aname "$fc_name" \
            --arg display "$(echo "$file_content" | jq -r '.properties.displayName // ""')" \
            --arg desc "$(echo "$file_content" | jq -r '.properties.description // ""')" \
            --argjson defEntry "$def_entry_json" \
            --arg enforce "$effective_enforcement" \
            --argjson params "$parameters" \
            --arg pac "$pac_selector" \
            --argjson scopeVals "$scope_values" \
            '{
                "$schema": $schema,
                nodeName: $node,
                assignment: {name: $aname, displayName: $display, description: $desc},
                definitionEntry: $defEntry,
                enforcementMode: $enforce,
                parameters: $params,
                scope: {($pac): $scopeVals}
            }')"

        # Add definition version if present
        if [[ -n "$def_version" ]]; then
            assignment_json="$(echo "$assignment_json" | jq --arg v "$def_version" '.definitionVersion = $v')"
        fi

        # Add non-compliance messages if present
        if [[ "$nc_messages" != "null" ]]; then
            assignment_json="$(echo "$assignment_json" | jq --argjson nc "$nc_messages" '.nonComplianceMessages = $nc')"
        fi

        # DNS Zones: add additional role assignments
        if [[ "$fc_name" == "Deploy-Private-DNS-Zones" ]]; then
            dns_sub_val="$(echo "$structure" | jq -r '.defaultParameterValues.private_dns_zone_subscription_id[0].parameters.value // ""')"
            assignment_json="$(echo "$assignment_json" | jq --arg pac "$pac_selector" --arg sub "$dns_sub_val" '
                .additionalRoleAssignments = {
                    ($pac): [{
                        roleDefinitionId: "/providers/microsoft.authorization/roleDefinitions/b12aa53e-6015-4669-85d0-8515ebb3ae7f",
                        scope: ("/subscriptions/" + $sub)
                    }]
                }')"
        fi

        # Fix [[ → [ in output
        assignment_json="$(echo "$assignment_json" | sed 's/\[\[/[/g')"

        # Determine category and write file
        category="$(echo "$structure" | jq -r --arg st "$scope_trim" '.managementGroupNameMappings[$st].management_group_function // "General"')"

        output_dir="${definitions_root}/policyAssignments/${lib_type}/${pac_selector}/${category}"
        mkdir -p "$output_dir"

        if [[ "$assignment_from_definition" == "true" ]]; then
            # Select subset of fields for definition-based assignments
            echo "$assignment_json" | jq '{
                "$schema", nodeName, assignment, definitionEntry, enforcementMode, parameters, scope
            }' > "${output_dir}/${fc_name}.jsonc"
        elif [[ "$fc_name" == "Deploy-Private-DNS-Zones" ]]; then
            echo "$assignment_json" | jq '{
                "$schema", nodeName, assignment, definitionEntry, definitionVersion, enforcementMode,
                parameters, nonComplianceMessages, scope, additionalRoleAssignments
            }' > "${output_dir}/${fc_name}.jsonc"
        else
            echo "$assignment_json" | jq '{
                "$schema", nodeName, assignment, definitionEntry, definitionVersion, enforcementMode,
                parameters, nonComplianceMessages, scope
            }' > "${output_dir}/${fc_name}.jsonc"
        fi

        created_assignments["$fc_name"]=1

    done < <(echo "$archetype_line" | jq -r '.policy_assignments[]?' 2>/dev/null)
done < <(echo "$final_archetypes" | jq -c '.[]')

# Clean up assignments not in the new structure
for existing_name in "${!existing_files[@]}"; do
    if [[ -z "${created_assignments[$existing_name]:-}" ]]; then
        rm -f "${existing_files[$existing_name]}"
        epac_log_info "Removed assignment '${existing_name}' (no longer in library structure)"
    fi
done

# Cleanup temp directories
temp_path="$(pwd)/temp"
[[ "$library_path" == "$temp_path" && "$temp_clone" == "true" ]] && rm -rf "$library_path"
[[ -n "$amba_library_path" && -d "$amba_library_path" ]] && rm -rf "$amba_library_path"

epac_log_success "ALZ Policy sync completed successfully"
