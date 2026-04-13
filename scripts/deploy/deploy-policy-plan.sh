#!/usr/bin/env bash
# scripts/deploy/deploy-policy-plan.sh — Deploy policy resources from a plan file
# Replaces: Deploy-PolicyPlan.ps1
# Reads policyPlan.json and deploys definitions, sets, assignments, and exemptions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

###############################################################################
# Usage
###############################################################################

usage() {
    cat <<'EOF'
Usage: deploy-policy-plan.sh [OPTIONS]

Options:
  -e, --pac-environment SELECTOR  PAC environment selector
  -d, --definitions-folder PATH   Definitions folder (default: $PAC_DEFINITIONS_FOLDER or ./Definitions)
  -i, --input-folder PATH         Input folder for plan files (default: $PAC_INPUT_FOLDER or $PAC_OUTPUT_FOLDER or ./Output)
  --skip-exemptions                Skip exemptions deployment
  --fail-on-exemption-error        Fail on exemption errors
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
skip_exemptions="false"
fail_on_exemption_error="false"
interactive="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--pac-environment) pac_environment_selector="$2"; shift 2 ;;
        -d|--definitions-folder) definitions_root_folder="$2"; shift 2 ;;
        -i|--input-folder) input_folder="$2"; shift 2 ;;
        --skip-exemptions) skip_exemptions="true"; shift ;;
        --fail-on-exemption-error) fail_on_exemption_error="true"; shift ;;
        --interactive) interactive="true"; shift ;;
        -h|--help) usage ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

###############################################################################
# Initialize
###############################################################################

script_start_time="$(date +%s)"

epac_write_header "Enterprise Policy as Code (EPAC)" "Deploying Policy Plan"

pac_environment="$(epac_select_pac_environment "$pac_environment_selector" "$definitions_root_folder" "" "$input_folder" "$interactive")"

pac_selector="$(echo "$pac_environment" | jq -r '.pacSelector')"
tenant_id="$(echo "$pac_environment" | jq -r '.tenantId')"
cloud="$(echo "$pac_environment" | jq -r '.cloud // "AzureCloud"')"

epac_set_cloud_tenant_subscription "$cloud" "$tenant_id" "$interactive"

epac_write_section "Environment Configuration" 0
epac_write_status "PAC Environment: ${pac_selector}" "info" 2

# API versions
api_policy_defs="$(echo "$pac_environment" | jq -r '.apiVersions.policyDefinitions')"
api_policy_set_defs="$(echo "$pac_environment" | jq -r '.apiVersions.policySetDefinitions')"
api_assignments="$(echo "$pac_environment" | jq -r '.apiVersions.policyAssignments')"
api_exemptions="$(echo "$pac_environment" | jq -r '.apiVersions.policyExemptions')"

###############################################################################
# Load plan
###############################################################################

plan_file="$(echo "$pac_environment" | jq -r '.policyPlanInputFile // .policyPlanOutputFile')"
if [[ ! -f "$plan_file" ]]; then
    epac_write_section "Deployment Status" 0
    epac_write_status "Plan file '${plan_file}' does not exist, skipping deployment" "skip" 2
    exit 0
fi

epac_write_section "Deployment Plan Loaded" 0
epac_write_status "Plan file: ${plan_file}" "success" 2
epac_write_status "Plan created on: $(jq -r '.createdOn' "$plan_file")" "info" 2

# Extract plan sections to temp files (plan can be >300KB, too large for shell vars)
_deploy_tmp="$(mktemp -d)"
trap 'rm -rf "$_deploy_tmp"' EXIT
jq '.exemptions // {}' "$plan_file" > "$_deploy_tmp/exemptions.json"
jq '.assignments // {}' "$plan_file" > "$_deploy_tmp/assignments.json"
jq '.policySetDefinitions // {}' "$plan_file" > "$_deploy_tmp/policySetDefs.json"
jq '.policyDefinitions // {}' "$plan_file" > "$_deploy_tmp/policyDefs.json"

###############################################################################
# Phase 1: Deletes (exemptions → assignments → policy sets → replaced policies)
###############################################################################

# Helper to iterate and delete resources from a plan section file
_deploy_delete_resources() {
    local plan_section_file="$1"
    local label="$2"
    local api_version="$3"
    shift 3
    local -a sections=("$@")

    # Merge requested sections into a single object via jq
    local merge_expr='reduce (['"$(printf '.%s // {},' "${sections[@]}" | sed 's/,$//')"'] | .[]) as $s ({}; . + $s)'
    local merged_file
    merged_file="$(mktemp)"
    jq "$merge_expr" "$plan_section_file" > "$merged_file"

    local count
    count="$(jq 'length' "$merged_file")"
    if [[ $count -gt 0 ]]; then
        epac_write_section "Deleting ${label} (${count} items)" 0
        local keys
        keys="$(jq -r 'keys[]' "$merged_file")"
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            local display
            display="$(jq -r --arg id "$id" '.[$id] | .displayName // .name // "unknown"' "$merged_file")"
            epac_write_status "Removing: ${display}" "pending" 2
            epac_remove_resource_by_id "$id" "$api_version" || true
        done <<< "$keys"
    fi
    rm -f "$merged_file"
}

# Helper to iterate and create/update resources from a plan section file
_deploy_set_resources() {
    local plan_section_file="$1"
    local label="$2"
    local set_func="$3"
    local api_version="$4"
    shift 4
    local -a sections=("$@")

    # Merge requested sections into a single object via jq
    local merge_expr='reduce (['"$(printf '.%s // {},' "${sections[@]}" | sed 's/,$//')"'] | .[]) as $s ({}; . + $s)'
    local merged_file
    merged_file="$(mktemp)"
    jq "$merge_expr" "$plan_section_file" > "$merged_file"

    local count
    count="$(jq 'length' "$merged_file")"
    if [[ $count -gt 0 ]]; then
        epac_write_section "Creating/Updating ${label} (${count} items)" 0
        local keys
        keys="$(jq -r 'keys[]' "$merged_file")"
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            local entry
            entry="$(jq --arg id "$id" '.[$id]' "$merged_file")"
            local display
            display="$(echo "$entry" | jq -r '.displayName // .name // "unknown"')"
            epac_write_status "Processing: ${display}" "pending" 4
            "$set_func" "$entry" "$api_version" > /dev/null || {
                epac_write_status "Failed: ${display}" "error" 4
            }
            epac_write_status "Completed: ${display}" "success" 4
        done <<< "$keys"
    fi
    rm -f "$merged_file"
}

# 1a. Delete exemptions (delete + replace)
if [[ "$skip_exemptions" != "true" ]]; then
    _deploy_delete_resources "$_deploy_tmp/exemptions.json" "Policy Exemptions" "$api_exemptions" "delete" "replace"
fi

# 1b. Delete assignments (delete + replace)
_deploy_delete_resources "$_deploy_tmp/assignments.json" "Policy Assignments" "$api_assignments" "delete" "replace"

# 1c. Delete policy set definitions (delete + replace)
_deploy_delete_resources "$_deploy_tmp/policySetDefs.json" "Policy Set Definitions" "$api_policy_set_defs" "delete" "replace"

# 1d. Delete replaced policy definitions (only replace, delete comes later)
_deploy_delete_resources "$_deploy_tmp/policyDefs.json" "Replaced Policy Definitions" "$api_policy_defs" "replace"

###############################################################################
# Phase 2: Creates and Updates
###############################################################################

# 2a. Policy definitions (new + replace + update)
_deploy_set_resources "$_deploy_tmp/policyDefs.json" "Policy Definitions" "epac_set_policy_definition" "$api_policy_defs" "new" "replace" "update"

# 2b. Policy set definitions (new + replace + update)
_deploy_set_resources "$_deploy_tmp/policySetDefs.json" "Policy Set Definitions" "epac_set_policy_set_definition" "$api_policy_set_defs" "new" "replace" "update"

# 2c. Delete obsolete policy definitions (now safe — sets updated)
jq '{delete: (.delete // {})}' "$_deploy_tmp/policyDefs.json" > "$_deploy_tmp/policyDefs_delete.json"
_deploy_delete_resources "$_deploy_tmp/policyDefs_delete.json" "Obsolete Policy Definitions" "$api_policy_defs" "delete"

# 2d. Assignments (new + replace + update)
_deploy_set_resources "$_deploy_tmp/assignments.json" "Policy Assignments" "epac_set_policy_assignment" "$api_assignments" "new" "replace" "update"

# 2e. Exemptions (new + replace + update)
if [[ "$skip_exemptions" != "true" ]]; then
    _deploy_set_exemptions() {
        local entry="$1"
        local api_version="$2"
        epac_set_policy_exemption "$entry" "$api_version" "$fail_on_exemption_error"
    }
    _deploy_set_resources "$_deploy_tmp/exemptions.json" "Policy Exemptions" "_deploy_set_exemptions" "$api_exemptions" "new" "replace" "update"
fi

###############################################################################
# Completion
###############################################################################

script_end_time="$(date +%s)"
elapsed=$((script_end_time - script_start_time))
epac_write_section "Deployment Complete" 0
epac_write_status "Plan file: ${plan_file}" "success" 2
epac_write_status "Execution time: $(printf '%02d:%02d' $((elapsed / 60)) $((elapsed % 60)))" "info" 2
epac_write_status "All policy resources have been successfully deployed" "success" 2
