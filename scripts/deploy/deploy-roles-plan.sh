#!/usr/bin/env bash
# scripts/deploy/deploy-roles-plan.sh — Deploy role assignments from a plan file
# Replaces: Deploy-RolesPlan.ps1
# Reads rolesPlan.json and deploys role assignment changes.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

###############################################################################
# Usage
###############################################################################

usage() {
    cat <<'EOF'
Usage: deploy-roles-plan.sh [OPTIONS]

Options:
  -e, --pac-environment SELECTOR  PAC environment selector
  -d, --definitions-folder PATH   Definitions folder (default: $PAC_DEFINITIONS_FOLDER or ./Definitions)
  -i, --input-folder PATH         Input folder for plan files (default: $PAC_INPUT_FOLDER or $PAC_OUTPUT_FOLDER or ./Output)
  --interactive                    Interactive mode
  -h, --help                       Show this help
EOF
    exit 0
}

###############################################################################
# Parse arguments
###############################################################################

pac_environment_selector=""
definitions_root_folder="${PAC_DEFINITIONS_FOLDER:-./Definitions}"
input_folder="${PAC_INPUT_FOLDER:-${PAC_OUTPUT_FOLDER:-./Output}}"
interactive="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--pac-environment) pac_environment_selector="$2"; shift 2 ;;
        -d|--definitions-folder) definitions_root_folder="$2"; shift 2 ;;
        -i|--input-folder) input_folder="$2"; shift 2 ;;
        --interactive) interactive="true"; shift ;;
        -h|--help) usage ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

###############################################################################
# Initialize
###############################################################################

script_start_time="$(date +%s)"

epac_write_header "Enterprise Policy as Code (EPAC)" "Deploying Role Assignments Plan"

pac_environment="$(epac_select_pac_environment "$pac_environment_selector" "$definitions_root_folder" "" "$input_folder" "$interactive")"

pac_selector="$(echo "$pac_environment" | jq -r '.pacSelector')"
tenant_id="$(echo "$pac_environment" | jq -r '.tenantId')"
cloud="$(echo "$pac_environment" | jq -r '.cloud // "AzureCloud"')"

epac_set_cloud_tenant_subscription "$cloud" "$tenant_id" "$interactive"

epac_write_section "Environment Configuration" 0
epac_write_status "PAC Environment: ${pac_selector}" "info" 2

api_assignments_ver="$(echo "$pac_environment" | jq -r '.apiVersions.policyAssignments')"
api_roles_ver="$(echo "$pac_environment" | jq -r '.apiVersions.roleAssignments')"

###############################################################################
# Load plan
###############################################################################

plan_file="$(echo "$pac_environment" | jq -r '.rolesPlanInputFile // .rolesPlanOutputFile')"
if [[ ! -f "$plan_file" ]]; then
    epac_write_section "Plan File Not Found" 0
    epac_write_status "Plan file '${plan_file}' does not exist, skipping role deployment" "skip" 2
    exit 0
fi

plan="$(jq '.' "$plan_file")"
epac_write_section "Role Assignment Plan Loaded" 0
epac_write_status "Plan file: ${plan_file}" "success" 2
epac_write_status "Plan created on: $(echo "$plan" | jq -r '.createdOn')" "info" 2

role_assignments="$(echo "$plan" | jq '.roleAssignments')"
added="$(echo "$role_assignments" | jq '.added // []')"
updated="$(echo "$role_assignments" | jq '.updated // []')"
removed="$(echo "$role_assignments" | jq '.removed // []')"

###############################################################################
# Phase 1: Remove obsolete role assignments
###############################################################################

removed_count="$(echo "$removed" | jq 'length')"
if [[ $removed_count -gt 0 ]]; then
    epac_write_section "Removing Role Assignments (${removed_count} items)" 0
    local_idx=0
    while [[ $local_idx -lt $removed_count ]]; do
        ra="$(echo "$removed" | jq --argjson i "$local_idx" '.[$i]')"
        ra_id="$(echo "$ra" | jq -r '.id')"
        principal_id="$(echo "$ra" | jq -r '.principalId // "unknown"')"
        role_display="$(echo "$ra" | jq -r '.roleDisplayName // "unknown"')"
        ra_scope="$(echo "$ra" | jq -r '.scope // "unknown"')"
        cross_tenant="$(echo "$ra" | jq -r '.crossTenant // false')"

        epac_write_status "Removing: principal=${principal_id} role=${role_display} scope=${ra_scope}" "pending" 2

        if [[ "$cross_tenant" != "true" ]]; then
            epac_remove_role_assignment "$ra_id" "$api_roles_ver" || true
        else
            # Cross-tenant: extract assignment ID from description
            assignment_id=""
            desc="$(echo "$ra" | jq -r '.description // ""')"
            if [[ "$desc" =~ \'(/subscriptions/[^\']+)\' ]]; then
                assignment_id="${BASH_REMATCH[1]}"
            fi
            managed_tenant="$(echo "$pac_environment" | jq -r '.managedTenantId // empty')"
            if [[ -n "$assignment_id" && -n "$managed_tenant" ]]; then
                epac_remove_role_assignment "$ra_id" "$api_roles_ver" "$managed_tenant" "$assignment_id" || true
            else
                epac_log_warning "Cannot determine cross-tenant assignment ID for role removal"
            fi
        fi

        local_idx=$((local_idx + 1))
    done
fi

###############################################################################
# Phase 2: Add new role assignments
###############################################################################

added_count="$(echo "$added" | jq 'length')"
if [[ $added_count -gt 0 ]]; then
    epac_write_section "Adding Role Assignments (${added_count} items)" 0

    # Cache: assignment ID → principal ID
    declare -A assignment_principal_cache

    local_idx=0
    while [[ $local_idx -lt $added_count ]]; do
        ra="$(echo "$added" | jq --argjson i "$local_idx" '.[$i]')"
        principal_id="$(echo "$ra" | jq -r '.properties.principalId // empty')"
        policy_assignment_id="$(echo "$ra" | jq -r '.assignmentId // empty')"

        # Resolve principal ID if not provided
        if [[ -z "$principal_id" ]]; then
            if [[ -n "${assignment_principal_cache[$policy_assignment_id]:-}" ]]; then
                principal_id="${assignment_principal_cache[$policy_assignment_id]}"
            elif [[ -n "$policy_assignment_id" ]]; then
                epac_write_status "Resolving identity for: ${policy_assignment_id}" "pending" 2
                local pa_resp
                if pa_resp="$(epac_get_policy_assignment "$policy_assignment_id" "$api_assignments_ver" 2>/dev/null)"; then
                    local identity_type
                    identity_type="$(echo "$pa_resp" | jq -r '.identity.type // "None"')"
                    if [[ "$identity_type" == "SystemAssigned" ]]; then
                        principal_id="$(echo "$pa_resp" | jq -r '.identity.principalId')"
                    elif [[ "$identity_type" == "UserAssigned" ]]; then
                        principal_id="$(echo "$pa_resp" | jq -r '.identity.userAssignedIdentities | to_entries[0].value.principalId')"
                    else
                        epac_log_error "Identity not found for assignment '${policy_assignment_id}'"
                        local_idx=$((local_idx + 1))
                        continue
                    fi
                else
                    epac_log_error "Failed to resolve assignment '${policy_assignment_id}'"
                    local_idx=$((local_idx + 1))
                    continue
                fi
                assignment_principal_cache["$policy_assignment_id"]="$principal_id"
            fi

            # Patch the role assignment with the resolved principal ID
            ra="$(echo "$ra" | jq --arg pid "$principal_id" '.properties.principalId = $pid')"
        elif [[ -z "${assignment_principal_cache[$policy_assignment_id]:-}" && -n "$policy_assignment_id" ]]; then
            assignment_principal_cache["$policy_assignment_id"]="$principal_id"
        fi

        role_display="$(echo "$ra" | jq -r '.roleDisplayName // "unknown"')"
        ra_scope="$(echo "$ra" | jq -r '.scope // "unknown"')"
        epac_write_status "Creating: principal=${principal_id} role=${role_display} scope=${ra_scope}" "pending" 2
        epac_set_role_assignment "$ra" "$pac_environment" || {
            epac_write_status "Failed: role=${role_display}" "error" 4
        }

        local_idx=$((local_idx + 1))
    done
fi

###############################################################################
# Phase 3: Update role assignments
###############################################################################

updated_count="$(echo "$updated" | jq 'length')"
if [[ $updated_count -gt 0 ]]; then
    epac_write_section "Updating Role Assignments (${updated_count} items)" 0

    local_idx=0
    while [[ $local_idx -lt $updated_count ]]; do
        ra="$(echo "$updated" | jq --argjson i "$local_idx" '.[$i]')"
        role_display="$(echo "$ra" | jq -r '.roleDisplayName // "unknown"')"
        ra_scope="$(echo "$ra" | jq -r '.scope // "unknown"')"
        principal_id="$(echo "$ra" | jq -r '.properties.principalId // "unknown"')"

        epac_write_status "Updating: principal=${principal_id} role=${role_display} scope=${ra_scope}" "pending" 2
        epac_set_role_assignment "$ra" "$pac_environment" || {
            epac_write_status "Failed: role=${role_display}" "error" 4
        }

        local_idx=$((local_idx + 1))
    done
fi

###############################################################################
# Completion
###############################################################################

script_end_time="$(date +%s)"
elapsed=$((script_end_time - script_start_time))
epac_write_section "Deployment Complete" 0
epac_write_status "Plan file: ${plan_file}" "success" 2
epac_write_status "Added: ${added_count}, Updated: ${updated_count}, Removed: ${removed_count}" "info" 2
epac_write_status "Execution time: $(printf '%02d:%02d' $((elapsed / 60)) $((elapsed % 60)))" "info" 2
epac_write_status "All role assignments have been successfully deployed" "success" 2
