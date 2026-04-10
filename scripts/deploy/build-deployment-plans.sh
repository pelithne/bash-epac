#!/usr/bin/env bash
# scripts/deploy/build-deployment-plans.sh — Build deployment plans orchestrator
# Replaces: Build-DeploymentPlans.ps1
# Orchestrates policy, policy set, assignment, and exemption plan building.
# Writes policyPlan.json and rolesPlan.json, outputs DevOps variables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

###############################################################################
# Usage
###############################################################################

usage() {
    cat <<'EOF'
Usage: build-deployment-plans.sh [OPTIONS]

Options:
  -e, --pac-environment SELECTOR  PAC environment selector (required if >1 env)
  -d, --definitions-folder PATH   Definitions folder (default: $PAC_DEFINITIONS_FOLDER or ./Definitions)
  -o, --output-folder PATH        Output folder (default: $PAC_OUTPUT_FOLDER or ./Output)
  --build-exemptions-only          Only build the exemptions plan
  --skip-exemptions                Skip the exemptions plan
  --skip-not-scoped-exemptions     Skip exemptions not scoped
  --fail-on-exemption-error        Fail when exemptions reference missing assignments/scopes
  --devops-type TYPE               DevOps pipeline type: ado, gitlab, or '' (default: '')
  --detailed-output                Show detailed diffs
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
output_folder="${PAC_OUTPUT_FOLDER:-./Output}"
build_exemptions_only="false"
skip_exemptions="false"
skip_not_scoped_exemptions="false"
fail_on_exemption_error="false"
devops_type=""
detailed_output="false"
interactive="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        -e|--pac-environment) pac_environment_selector="$2"; shift 2 ;;
        -d|--definitions-folder) definitions_root_folder="$2"; shift 2 ;;
        -o|--output-folder) output_folder="$2"; shift 2 ;;
        --build-exemptions-only) build_exemptions_only="true"; shift ;;
        --skip-exemptions) skip_exemptions="true"; shift ;;
        --skip-not-scoped-exemptions) skip_not_scoped_exemptions="true"; shift ;;
        --fail-on-exemption-error) fail_on_exemption_error="true"; shift ;;
        --devops-type) devops_type="$2"; shift 2 ;;
        --detailed-output) detailed_output="true"; shift ;;
        --interactive) interactive="true"; shift ;;
        -h|--help) usage ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate conflicts
if [[ "$build_exemptions_only" == "true" && "$skip_exemptions" == "true" ]]; then
    epac_log_error "--build-exemptions-only and --skip-exemptions cannot be used together"
    exit 1
fi

###############################################################################
# Initialize
###############################################################################

script_start_time="$(date +%s)"

epac_write_header "Enterprise Policy as Code (EPAC)" "Building Deployment Plans"

# Load global settings & select environment
pac_environment="$(epac_select_pac_environment "$pac_environment_selector" "$definitions_root_folder" "$output_folder" "$interactive")"

pac_selector="$(echo "$pac_environment" | jq -r '.pacSelector')"
deployment_root_scope="$(echo "$pac_environment" | jq -r '.deploymentRootScope')"
tenant_id="$(echo "$pac_environment" | jq -r '.tenantId')"
cloud="$(echo "$pac_environment" | jq -r '.cloud // "AzureCloud"')"
pac_owner_id="$(echo "$pac_environment" | jq -r '.pacOwnerId')"

# Authenticate
epac_set_cloud_tenant_subscription "$cloud" "$tenant_id" "$interactive"

epac_write_section "Environment Configuration" 0
epac_write_status "PAC Environment: ${pac_selector}" "info" 2
epac_write_status "Deployment Root: ${deployment_root_scope}" "info" 2
epac_write_status "Tenant ID: ${tenant_id}" "info" 2
epac_write_status "Cloud: ${cloud}" "info" 2

###############################################################################
# Plan data structures
###############################################################################

timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

policy_definitions_folder="$(echo "$pac_environment" | jq -r '.policyDefinitionsFolder')"
policy_set_definitions_folder="$(echo "$pac_environment" | jq -r '.policySetDefinitionsFolder')"
policy_assignments_folder="$(echo "$pac_environment" | jq -r '.policyAssignmentsFolder')"
policy_exemptions_folder="$(echo "$pac_environment" | jq -r '.policyExemptionsFolder')"
policy_exemptions_folder_env="${policy_exemptions_folder}/${pac_selector}"

policy_plan_output="$(echo "$pac_environment" | jq -r '.policyPlanOutputFile')"
roles_plan_output="$(echo "$pac_environment" | jq -r '.rolesPlanOutputFile')"

###############################################################################
# Determine build selections
###############################################################################

build_policy_definitions="false"
build_policy_set_definitions="false"
build_policy_assignments="false"
build_policy_exemptions="false"
build_any="false"

warning_messages=()

# Check exemptions folder
exemptions_managed="true"
exemptions_not_managed_msg=""
if [[ ! -d "$policy_exemptions_folder" ]]; then
    exemptions_not_managed_msg="Policy Exemptions folder '${policy_exemptions_folder}' not found. Not managed by this EPAC instance."
    exemptions_managed="false"
elif [[ ! -d "$policy_exemptions_folder_env" ]]; then
    exemptions_not_managed_msg="Policy Exemptions folder '${policy_exemptions_folder_env}' for environment ${pac_selector} not found. Not managed."
    exemptions_managed="false"
fi

if [[ "$build_exemptions_only" == "true" ]]; then
    # Only exemptions
    if [[ "$exemptions_managed" == "true" ]]; then
        build_policy_exemptions="true"
        build_any="true"
    else
        warning_messages+=("$exemptions_not_managed_msg")
        warning_messages+=("Exemptions plan will not be built. Exiting...")
    fi
elif [[ "$skip_exemptions" == "true" ]]; then
    # Everything except exemptions
    [[ -d "$policy_definitions_folder" ]] && { build_policy_definitions="true"; build_any="true"; } || \
        warning_messages+=("Policy definitions folder not found: ${policy_definitions_folder}")
    [[ -d "$policy_set_definitions_folder" ]] && { build_policy_set_definitions="true"; build_any="true"; } || \
        warning_messages+=("Policy set definitions folder not found: ${policy_set_definitions_folder}")
    [[ -d "$policy_assignments_folder" ]] && { build_policy_assignments="true"; build_any="true"; } || \
        warning_messages+=("Policy assignments folder not found: ${policy_assignments_folder}")
else
    # Everything
    [[ -d "$policy_definitions_folder" ]] && { build_policy_definitions="true"; build_any="true"; } || \
        warning_messages+=("Policy definitions folder not found: ${policy_definitions_folder}")
    [[ -d "$policy_set_definitions_folder" ]] && { build_policy_set_definitions="true"; build_any="true"; } || \
        warning_messages+=("Policy set definitions folder not found: ${policy_set_definitions_folder}")
    [[ -d "$policy_assignments_folder" ]] && { build_policy_assignments="true"; build_any="true"; } || \
        warning_messages+=("Policy assignments folder not found: ${policy_assignments_folder}")
    if [[ "$exemptions_managed" == "true" ]]; then
        build_policy_exemptions="true"
        build_any="true"
    else
        warning_messages+=("$exemptions_not_managed_msg")
    fi
fi

if [[ "$build_any" != "true" ]]; then
    warning_messages+=("No resources managed by this EPAC instance found. No plans will be built.")
fi

if [[ ${#warning_messages[@]} -gt 0 ]]; then
    epac_write_section "Configuration Warnings" 0
    for msg in "${warning_messages[@]}"; do
        epac_write_status "$msg" "warning" 2
        if [[ "$devops_type" == "ado" ]]; then
            echo "##vso[task.logissue type=warning]${msg}"
        fi
    done
fi

###############################################################################
# Build plan
###############################################################################

# Accumulators — these are JSON strings we pass between plan builders
all_definitions='{"policydefinitions":{},"policysetdefinitions":{}}'
replace_definitions="{}"
policy_role_ids="{}"
all_assignments="{}"

# Result accumulators
policy_plan_defs='{"new":{},"update":{},"replace":{},"delete":{},"numberOfChanges":0,"numberUnchanged":0}'
policy_set_plan_defs='{"new":{},"update":{},"replace":{},"delete":{},"numberOfChanges":0,"numberUnchanged":0}'
assignment_plan_result='{"assignments":{"new":{},"update":{},"replace":{},"delete":{},"numberOfChanges":0,"numberUnchanged":0},"roleAssignments":{"added":[],"updated":[],"removed":[],"numberOfChanges":0}}'
exemption_plan_result='{"exemptions":{"new":{},"update":{},"replace":{},"delete":{},"numberOfOrphans":0,"numberOfExpired":0,"numberOfChanges":0,"numberUnchanged":0}}'

if [[ "$build_any" == "true" ]]; then

    # Build scope table
    epac_write_section "Building Scope Table" 0
    scope_table="$(epac_build_scope_table "$pac_environment")"

    # Fetch deployed resources
    local_skip_exemptions="true"
    [[ "$build_policy_exemptions" == "true" ]] && local_skip_exemptions="false"
    local_skip_roles="true"
    [[ "$build_policy_assignments" == "true" ]] && local_skip_roles="false"

    epac_write_section "Fetching Deployed Policy Resources" 0
    deployed_resources="$(epac_get_az_policy_resources "$pac_environment" "$scope_table" "$local_skip_exemptions" "$local_skip_roles")"

    # Extract deployed resource sections
    deployed_policy_defs="$(echo "$deployed_resources" | jq '.policydefinitions // {managed:{},readOnly:{},all:{}}')"
    deployed_policy_set_defs="$(echo "$deployed_resources" | jq '.policysetdefinitions // {managed:{},readOnly:{},all:{}}')"
    deployed_assignments="$(echo "$deployed_resources" | jq '.policyassignments // {managed:{},readOnly:{}}')"
    deployed_exemptions="$(echo "$deployed_resources" | jq '.policyExemptions // {managed:{},readOnly:{}}')"
    deployed_role_assignments="$(echo "$deployed_resources" | jq '.roleAssignmentsByPrincipalId // {}')"

    # Pre-populate role IDs from read-only policy definitions
    local ro_keys
    ro_keys="$(echo "$deployed_policy_defs" | jq -r '.readOnly | keys[]' 2>/dev/null || true)"
    while IFS= read -r pid; do
        [[ -z "$pid" ]] && continue
        local rd
        rd="$(echo "$deployed_policy_defs" | jq --arg id "$pid" '.readOnly[$id]')"
        local role_ids
        role_ids="$(epac_get_policy_resource_properties "$rd" | jq '.policyRule.then.details.roleDefinitionIds // null')"
        if [[ "$role_ids" != "null" ]]; then
            policy_role_ids="$(echo "$policy_role_ids" | jq --arg id "$pid" --argjson r "$role_ids" '.[$id] = $r')"
        fi
    done <<< "$ro_keys"

    # Populate allDefinitions with all deployed policy definitions
    all_definitions="$(echo "$all_definitions" | jq --argjson all "$(echo "$deployed_policy_defs" | jq '.all // {}')" \
        '.policydefinitions = (.policydefinitions + $all)')"

    # ── Policy Definitions Plan ──
    if [[ "$build_policy_definitions" == "true" ]]; then
        epac_write_section "Building Policy Definitions Plan" 0
        local pd_result
        pd_result="$(epac_build_policy_plan "$policy_definitions_folder" "$pac_environment" \
            "$deployed_policy_defs" "$all_definitions" "$replace_definitions" "$policy_role_ids" "$detailed_output")"
        policy_plan_defs="$(echo "$pd_result" | jq '.definitions')"
        all_definitions="$(echo "$pd_result" | jq '.allDefinitions')"
        replace_definitions="$(echo "$pd_result" | jq '.replaceDefinitions')"
        policy_role_ids="$(echo "$pd_result" | jq '.policyRoleIds')"
    fi

    # Pre-populate role IDs from read-only policy set definitions
    ro_keys="$(echo "$deployed_policy_set_defs" | jq -r '.readOnly | keys[]' 2>/dev/null || true)"
    while IFS= read -r psid; do
        [[ -z "$psid" ]] && continue
        local psd_props
        psd_props="$(echo "$deployed_policy_set_defs" | jq --arg id "$psid" '.readOnly[$id]' | jq 'if .properties then .properties else . end')"
        local role_set="{}"
        local pd_array
        pd_array="$(echo "$psd_props" | jq '.policyDefinitions // []')"
        local pdi=0
        local pd_len
        pd_len="$(echo "$pd_array" | jq 'length')"
        while [[ $pdi -lt $pd_len ]]; do
            local member_pid
            member_pid="$(echo "$pd_array" | jq -r --argjson i "$pdi" '.[$i].policyDefinitionId')"
            local has_roles
            has_roles="$(echo "$policy_role_ids" | jq --arg id "$member_pid" 'has($id)')"
            if [[ "$has_roles" == "true" ]]; then
                local member_roles
                member_roles="$(echo "$policy_role_ids" | jq --arg id "$member_pid" '.[$id][]' -r)"
                while IFS= read -r rid; do
                    [[ -z "$rid" ]] && continue
                    role_set="$(echo "$role_set" | jq --arg r "$rid" '.[$r] = "added"')"
                done <<< "$member_roles"
            fi
            pdi=$((pdi + 1))
        done
        local role_count
        role_count="$(echo "$role_set" | jq 'length')"
        if [[ $role_count -gt 0 ]]; then
            local role_array
            role_array="$(echo "$role_set" | jq 'keys')"
            policy_role_ids="$(echo "$policy_role_ids" | jq --arg id "$psid" --argjson r "$role_array" '.[$id] = $r')"
        fi
    done <<< "$ro_keys"

    # Populate allDefinitions with all deployed policy set definitions
    all_definitions="$(echo "$all_definitions" | jq --argjson all "$(echo "$deployed_policy_set_defs" | jq '.all // {}')" \
        '.policysetdefinitions = (.policysetdefinitions + $all)')"

    # ── Policy Set Definitions Plan ──
    if [[ "$build_policy_set_definitions" == "true" ]]; then
        epac_write_section "Building Policy Set Definitions Plan" 0
        local psd_result
        psd_result="$(epac_build_policy_set_plan "$policy_set_definitions_folder" "$pac_environment" \
            "$deployed_policy_set_defs" "$all_definitions" "$replace_definitions" "$policy_role_ids" "$detailed_output")"
        policy_set_plan_defs="$(echo "$psd_result" | jq '.definitions')"
        all_definitions="$(echo "$psd_result" | jq '.allDefinitions')"
        replace_definitions="$(echo "$psd_result" | jq '.replaceDefinitions')"
        policy_role_ids="$(echo "$psd_result" | jq '.policyRoleIds')"
    fi

    # ── Combined Policy Details ──
    epac_write_section "Pre-calculating Policy Details" 0
    combined_policy_details="$(epac_convert_policy_resources_to_details \
        "$(echo "$all_definitions" | jq '.policydefinitions')" \
        "$(echo "$all_definitions" | jq '.policysetdefinitions')")"

    # Populate allAssignments
    local managed_assignments
    managed_assignments="$(echo "$deployed_assignments" | jq '.managed // {}')"
    all_assignments="$(echo "$all_assignments" | jq --argjson m "$managed_assignments" '. + $m')"

    # ── Assignment Plan ──
    if [[ "$build_policy_assignments" == "true" ]]; then
        epac_write_section "Building Assignment Plan" 0
        # Determine role definitions (simplified - map scopeTable roleDefinitions)
        local role_definitions="{}"
        assignment_plan_result="$(epac_build_assignment_plan \
            "$policy_assignments_folder" "$pac_environment" "$deployed_assignments" \
            "$(echo "$all_definitions" | jq '.policydefinitions')" \
            "$(echo "$all_definitions" | jq '.policysetdefinitions')" \
            "$combined_policy_details" "$replace_definitions" "$policy_role_ids" \
            "$role_definitions" "$scope_table" "$deployed_role_assignments" "$detailed_output")"

        # Merge any new all_assignments from the plan
        local plan_all_assignments
        plan_all_assignments="$(echo "$assignment_plan_result" | jq '.allAssignments // {}')"
        if [[ "$plan_all_assignments" != "{}" && "$plan_all_assignments" != "null" ]]; then
            all_assignments="$(echo "$all_assignments" | jq --argjson p "$plan_all_assignments" '. + $p')"
        fi
    fi

    # ── Exemptions Plan ──
    if [[ "$build_policy_exemptions" == "true" ]]; then
        epac_write_section "Building Exemptions Plan" 0
        local replaced_assignments
        replaced_assignments="$(echo "$assignment_plan_result" | jq '.assignments.replace // {}')"
        exemption_plan_result="$(epac_build_exemptions_plan \
            "$policy_exemptions_folder_env" "$pac_environment" "$scope_table" \
            "$all_definitions" "$all_assignments" "$combined_policy_details" \
            "$replaced_assignments" "$deployed_exemptions" \
            "$skip_not_scoped_exemptions" "$fail_on_exemption_error")"
    fi

    # ── Summary ──
    epac_write_header "EPAC Deployment Plan Summary" "Policy as Code Resource Analysis"

    if [[ "$build_policy_definitions" == "true" ]]; then
        local pd_new pd_upd pd_rep pd_del pd_unc pd_chg
        pd_new="$(echo "$policy_plan_defs" | jq '.new | length')"
        pd_upd="$(echo "$policy_plan_defs" | jq '.update | length')"
        pd_rep="$(echo "$policy_plan_defs" | jq '.replace | length')"
        pd_del="$(echo "$policy_plan_defs" | jq '.delete | length')"
        pd_unc="$(echo "$policy_plan_defs" | jq '.numberUnchanged')"
        pd_chg="$(echo "$policy_plan_defs" | jq '.numberOfChanges')"
        epac_write_status "Policy Definitions: ${pd_chg} changes (new:${pd_new} upd:${pd_upd} rep:${pd_rep} del:${pd_del}) unchanged:${pd_unc}" "info" 2
    fi

    if [[ "$build_policy_set_definitions" == "true" ]]; then
        local psd_new psd_upd psd_rep psd_del psd_unc psd_chg
        psd_new="$(echo "$policy_set_plan_defs" | jq '.new | length')"
        psd_upd="$(echo "$policy_set_plan_defs" | jq '.update | length')"
        psd_rep="$(echo "$policy_set_plan_defs" | jq '.replace | length')"
        psd_del="$(echo "$policy_set_plan_defs" | jq '.delete | length')"
        psd_unc="$(echo "$policy_set_plan_defs" | jq '.numberUnchanged')"
        psd_chg="$(echo "$policy_set_plan_defs" | jq '.numberOfChanges')"
        epac_write_status "Policy Set Definitions: ${psd_chg} changes (new:${psd_new} upd:${psd_upd} rep:${psd_rep} del:${psd_del}) unchanged:${psd_unc}" "info" 2
    fi

    if [[ "$build_policy_assignments" == "true" ]]; then
        local a_plan
        a_plan="$(echo "$assignment_plan_result" | jq '.assignments')"
        local a_new a_upd a_rep a_del a_unc a_chg
        a_new="$(echo "$a_plan" | jq '.new | length')"
        a_upd="$(echo "$a_plan" | jq '.update | length')"
        a_rep="$(echo "$a_plan" | jq '.replace | length')"
        a_del="$(echo "$a_plan" | jq '.delete | length')"
        a_unc="$(echo "$a_plan" | jq '.numberUnchanged')"
        a_chg="$(echo "$a_plan" | jq '.numberOfChanges')"
        epac_write_status "Assignments: ${a_chg} changes (new:${a_new} upd:${a_upd} rep:${a_rep} del:${a_del}) unchanged:${a_unc}" "info" 2

        local r_plan
        r_plan="$(echo "$assignment_plan_result" | jq '.roleAssignments')"
        local r_add r_upd r_rem r_chg
        r_add="$(echo "$r_plan" | jq '.added | length')"
        r_upd="$(echo "$r_plan" | jq '.updated | length')"
        r_rem="$(echo "$r_plan" | jq '.removed | length')"
        r_chg="$(echo "$r_plan" | jq '.numberOfChanges')"
        epac_write_status "Role Assignments: ${r_chg} changes (add:${r_add} upd:${r_upd} rem:${r_rem})" "info" 2
    fi

    if [[ "$build_policy_exemptions" == "true" ]]; then
        local ex_plan
        ex_plan="$(echo "$exemption_plan_result" | jq '.exemptions')"
        local e_new e_upd e_rep e_del e_unc e_chg e_orp e_exp
        e_new="$(echo "$ex_plan" | jq '.new | length')"
        e_upd="$(echo "$ex_plan" | jq '.update | length')"
        e_rep="$(echo "$ex_plan" | jq '.replace | length')"
        e_del="$(echo "$ex_plan" | jq '.delete | length')"
        e_unc="$(echo "$ex_plan" | jq '.numberUnchanged')"
        e_chg="$(echo "$ex_plan" | jq '.numberOfChanges')"
        e_orp="$(echo "$ex_plan" | jq '.numberOfOrphans')"
        e_exp="$(echo "$ex_plan" | jq '.numberOfExpired')"
        epac_write_status "Exemptions: ${e_chg} changes (new:${e_new} upd:${e_upd} rep:${e_rep} del:${e_del}) unchanged:${e_unc} orphans:${e_orp} expired:${e_exp}" "info" 2
    fi
fi

###############################################################################
# Write output plan files
###############################################################################

epac_write_section "Deployment Plan Output" 0

# Assemble policyPlan
policy_plan="$(jq -n \
    --arg ts "$timestamp" --arg pid "$pac_owner_id" \
    --argjson pd "$policy_plan_defs" \
    --argjson psd "$policy_set_plan_defs" \
    --argjson a "$(echo "$assignment_plan_result" | jq '.assignments')" \
    --argjson ex "$(echo "$exemption_plan_result" | jq '.exemptions')" \
    '{
        createdOn: $ts, pacOwnerId: $pid,
        policyDefinitions: $pd, policySetDefinitions: $psd,
        assignments: $a, exemptions: $ex
    }')"

# Assemble rolesPlan
roles_plan="$(jq -n \
    --arg ts "$timestamp" --arg pid "$pac_owner_id" \
    --argjson ra "$(echo "$assignment_plan_result" | jq '.roleAssignments')" \
    '{createdOn: $ts, pacOwnerId: $pid, roleAssignments: $ra}')"

# Count total policy changes
policy_changes="$(echo "$policy_plan" | jq '
    (.policyDefinitions.numberOfChanges // 0) +
    (.policySetDefinitions.numberOfChanges // 0) +
    (.assignments.numberOfChanges // 0) +
    (.exemptions.numberOfChanges // 0)')"

policy_stage="no"
if [[ $policy_changes -gt 0 ]]; then
    epac_write_status "Policy deployment plan created: ${policy_plan_output}" "success" 2
    mkdir -p "$(dirname "$policy_plan_output")"
    echo "$policy_plan" | jq '.' > "$policy_plan_output"
    policy_stage="yes"
else
    epac_write_status "Policy deployment stage skipped - no changes detected" "skip" 2
    [[ -f "$policy_plan_output" ]] && rm -f "$policy_plan_output"
fi

role_changes="$(echo "$roles_plan" | jq '.roleAssignments.numberOfChanges // 0')"
role_stage="no"
if [[ $role_changes -gt 0 ]]; then
    epac_write_status "Role assignment plan created: ${roles_plan_output}" "success" 2
    mkdir -p "$(dirname "$roles_plan_output")"
    echo "$roles_plan" | jq '.' > "$roles_plan_output"
    role_stage="yes"
else
    epac_write_status "Role assignment stage skipped - no changes detected" "skip" 2
    [[ -f "$roles_plan_output" ]] && rm -f "$roles_plan_output"
fi

###############################################################################
# DevOps variable output
###############################################################################

case "$devops_type" in
    ado)
        echo "##vso[task.setvariable variable=deployPolicyChanges;isOutput=true]${policy_stage}"
        echo "##vso[task.setvariable variable=deployRoleChanges;isOutput=true]${role_stage}"
        ;;
    gitlab)
        echo "deployPolicyChanges=${policy_stage}" >> build.env
        echo "deployRoleChanges=${role_stage}" >> build.env
        ;;
esac

# Completion
script_end_time="$(date +%s)"
elapsed=$((script_end_time - script_start_time))
minutes=$((elapsed / 60))
seconds=$((elapsed % 60))
epac_write_header "EPAC Build Complete" "Deployment plans generated successfully"
epac_write_status "Total execution time: $(printf '%02d:%02d' $minutes $seconds)" "info"
