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

# Phase timing helper
_phase_start=0
_timer() {
    local label="$1"
    local now
    now="$(date +%s)"
    if [[ $_phase_start -gt 0 ]]; then
        local elapsed=$((now - _phase_start))
        epac_write_status "⏱  Phase completed in ${elapsed}s" "info" 2 >&2
    fi
    if [[ -n "$label" ]]; then
        epac_write_status "⏱  Starting: ${label}" "info" 2 >&2
    fi
    _phase_start=$now
}

epac_write_header "Enterprise Policy as Code (EPAC)" "Building Deployment Plans"

_timer "Global settings & environment selection"

# Load global settings & select environment
pac_environment="$(epac_select_pac_environment "$pac_environment_selector" "$definitions_root_folder" "$output_folder" "$interactive")"

pac_selector="$(echo "$pac_environment" | jq -r '.pacSelector')"
deployment_root_scope="$(echo "$pac_environment" | jq -r '.deploymentRootScope')"
tenant_id="$(echo "$pac_environment" | jq -r '.tenantId')"
cloud="$(echo "$pac_environment" | jq -r '.cloud // "AzureCloud"')"
pac_owner_id="$(echo "$pac_environment" | jq -r '.pacOwnerId')"

_timer "Azure authentication"
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
    _timer "Building scope table"
    epac_write_section "Building Scope Table" 0
    scope_table="$(epac_build_scope_table "$pac_environment")"

    # Fetch deployed resources
    local_skip_exemptions="true"
    [[ "$build_policy_exemptions" == "true" ]] && local_skip_exemptions="false"
    local_skip_roles="true"
    [[ "$build_policy_assignments" == "true" ]] && local_skip_roles="false"

    _timer "Fetching deployed policy resources"
    epac_write_section "Fetching Deployed Policy Resources" 0
    _deployed_dir="$(mktemp -d)"
    epac_get_policy_resources "$pac_environment" "$scope_table" "$local_skip_exemptions" "$local_skip_roles" "" "$_deployed_dir" >/dev/null

    _timer "Extracting deployed resources to temp files"
    # Files already written directly by epac_get_policy_resources:
    #   policydefinitions.json, policysetdefinitions.json, policyassignments.json, policyexemptions.json
    _tmp_defs="$_deployed_dir/policydefinitions.json"
    _tmp_set_defs="$_deployed_dir/policysetdefinitions.json"
    trap 'rm -rf "$_deployed_dir"' EXIT
    # Split policyassignments.json into separate files in a single jq pass
    jq '{managed, counters}' "$_deployed_dir/policyassignments.json" > "$_deployed_dir/assignments_managed.json"
    jq '.roleAssignmentsByPrincipalId // {}' "$_deployed_dir/policyassignments.json" > "$_deployed_dir/role_assignments.json"
    deployed_assignments="$(cat "$_deployed_dir/assignments_managed.json")"
    deployed_exemptions="$(cat "$_deployed_dir/policyexemptions.json")"
    deployed_role_assignments="$(cat "$_deployed_dir/role_assignments.json")"

    # Pre-populate role IDs from read-only policy definitions (single jq pass)
    policy_role_ids="$(jq '
        .readOnly | to_entries | reduce .[] as $e ({};
            ($e.value | (if .properties then .properties else . end)
                | .policyRule.then.details
                | if type == "array" then .[].roleDefinitionIds // empty
                  elif type == "object" then .roleDefinitionIds // null
                  else null end) as $roles |
            if $roles != null then .[$e.key] = $roles else . end
        )' "$_tmp_defs")"

    # Populate allDefinitions with all deployed policy definitions
    _tmp_all_from_defs="$(mktemp)"
    jq '.all // {}' "$_tmp_defs" > "$_tmp_all_from_defs"
    all_definitions="$(echo "$all_definitions" | jq --slurpfile all "$_tmp_all_from_defs" \
        '.policydefinitions = (.policydefinitions + $all[0])')"
    rm -f "$_tmp_all_from_defs"

    # ── Policy Definitions Plan ──
    if [[ "$build_policy_definitions" == "true" ]]; then
        epac_write_section "Building Policy Definitions Plan" 0
        pd_result="$(epac_build_policy_plan "$policy_definitions_folder" "$pac_environment" \
            "$(cat "$_tmp_defs")" "$all_definitions" "$replace_definitions" "$policy_role_ids" "$detailed_output")"
        policy_plan_defs="$(echo "$pd_result" | jq '.definitions')"
        all_definitions="$(echo "$pd_result" | jq '.allDefinitions')"
        replace_definitions="$(echo "$pd_result" | jq '.replaceDefinitions')"
        policy_role_ids="$(echo "$pd_result" | jq '.policyRoleIds')"
    fi

    # Pre-populate role IDs from read-only policy set definitions (single jq pass)
    _tmp_role_ids="$(mktemp)"
    echo "$policy_role_ids" > "$_tmp_role_ids"
    policy_role_ids="$(jq --slurpfile base "$_tmp_role_ids" '
        $base[0] as $b |
        (.readOnly // {}) | to_entries | reduce .[] as $e ($b;
            ($e.value | (if .properties then .properties else . end)
                | .policyDefinitions // []) as $members |
            ($members | reduce .[] as $m ({};
                ($m.policyDefinitionId) as $mid |
                if $b[$mid] != null then
                    ($b[$mid] | .[] | {(.): "added"}) as $r | . + $r
                else . end
            ) | keys) as $merged_roles |
            if ($merged_roles | length) > 0 then .[$e.key] = $merged_roles else . end
        )' "$_tmp_set_defs")"
    rm -f "$_tmp_role_ids"

    # Populate allDefinitions with all deployed policy set definitions
    _tmp_all_from_set_defs="$(mktemp)"
    jq '.all // {}' "$_tmp_set_defs" > "$_tmp_all_from_set_defs"
    all_definitions="$(echo "$all_definitions" | jq --slurpfile all "$_tmp_all_from_set_defs" \
        '.policysetdefinitions = (.policysetdefinitions + $all[0])')"
    rm -f "$_tmp_all_from_set_defs"

    # ── Policy Set Definitions Plan ──
    if [[ "$build_policy_set_definitions" == "true" ]]; then
        epac_write_section "Building Policy Set Definitions Plan" 0
        psd_result="$(epac_build_policy_set_plan "$policy_set_definitions_folder" "$pac_environment" \
            "$(cat "$_tmp_set_defs")" "$all_definitions" "$replace_definitions" "$policy_role_ids" "$detailed_output")"
        policy_set_plan_defs="$(echo "$psd_result" | jq '.definitions')"
        all_definitions="$(echo "$psd_result" | jq '.allDefinitions')"
        replace_definitions="$(echo "$psd_result" | jq '.replaceDefinitions')"
        policy_role_ids="$(echo "$psd_result" | jq '.policyRoleIds')"
    fi

    # ── Combined Policy Details ──
    _timer "Pre-calculating policy details"
    epac_write_section "Pre-calculating Policy Details" 0
    # Write large data to temp files for assignment plan (avoids Argument list too long)
    export EPAC_TMP_DIR; EPAC_TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$EPAC_TMP_DIR" "$_deployed_dir"' EXIT
    echo "$all_definitions" > "$EPAC_TMP_DIR/all_definitions.json"
    jq '.policydefinitions' "$EPAC_TMP_DIR/all_definitions.json" > "$EPAC_TMP_DIR/all_policy_defs.json"
    jq '.policysetdefinitions' "$EPAC_TMP_DIR/all_definitions.json" > "$EPAC_TMP_DIR/all_policy_set_defs.json"
    combined_policy_details="$(epac_convert_policy_resources_to_details \
        "$EPAC_TMP_DIR/all_policy_defs.json" "$EPAC_TMP_DIR/all_policy_set_defs.json")"
    echo "$combined_policy_details" > "$EPAC_TMP_DIR/combined_policy_details.json"
    echo "$deployed_assignments" > "$EPAC_TMP_DIR/deployed_assignments.json"
    echo "$scope_table" > "$EPAC_TMP_DIR/scope_table.json"
    echo "$scope_table" | jq 'with_entries(.key |= ascii_downcase)' > "$EPAC_TMP_DIR/scope_table_lower.json"
    echo "$policy_role_ids" > "$EPAC_TMP_DIR/policy_role_ids.json"
    echo "$deployed_exemptions" > "$EPAC_TMP_DIR/deployed_exemptions.json"

    # Pre-extract compact lookup files for fast jq-based assignment plan
    jq '{
      policies: (.policies | map_values({parameters: (.parameters // {})})),
      policySets: (.policySets | map_values({parameters: (.parameters // {})}))
    }' "$EPAC_TMP_DIR/combined_policy_details.json" > "$EPAC_TMP_DIR/policy_params.json"
    jq 'map_values(null)' "$EPAC_TMP_DIR/all_policy_defs.json" > "$EPAC_TMP_DIR/policy_def_index.json"
    jq 'map_values(null)' "$EPAC_TMP_DIR/all_policy_set_defs.json" > "$EPAC_TMP_DIR/policy_set_def_index.json"

    # Populate allAssignments
    _tmp_managed="$(mktemp)"
    echo "$deployed_assignments" | jq '.managed // {}' > "$_tmp_managed"
    all_assignments="$(echo "$all_assignments" | jq --slurpfile m "$_tmp_managed" '. + $m[0]')"
    rm -f "$_tmp_managed"

    # ── Assignment Plan ──
    if [[ "$build_policy_assignments" == "true" ]]; then
        _timer "Building assignment plan"
        epac_write_section "Building Assignment Plan" 0
        # Determine role definitions (simplified - map scopeTable roleDefinitions)
        role_definitions="{}"
        assignment_plan_result="$(epac_build_assignment_plan \
            "$policy_assignments_folder" "$pac_environment" \
            "$replace_definitions" \
            "$role_definitions" "$deployed_role_assignments" "$detailed_output")"

        # Merge any new all_assignments from the plan
        plan_all_assignments="$(echo "$assignment_plan_result" | jq '.allAssignments // {}')"
        if [[ "$plan_all_assignments" != "{}" && "$plan_all_assignments" != "null" ]]; then
            all_assignments="$(echo "$all_assignments" | jq --argjson p "$plan_all_assignments" '. + $p')"
        fi
    fi

    # ── Exemptions Plan ──
    if [[ "$build_policy_exemptions" == "true" ]]; then
        _timer "Building exemptions plan"
        epac_write_section "Building Exemptions Plan" 0
        replaced_assignments="$(echo "$assignment_plan_result" | jq '.assignments.replace // {}')"
        # Write remaining large data to files to avoid passing ~100MB through shell args
        echo "$all_assignments" > "$EPAC_TMP_DIR/all_assignments.json"
        exemption_plan_result="$(epac_build_exemptions_plan \
            "$policy_exemptions_folder_env" "$pac_environment" "$scope_table" \
            "$EPAC_TMP_DIR/all_definitions.json" "$EPAC_TMP_DIR/all_assignments.json" \
            "$EPAC_TMP_DIR/combined_policy_details.json" \
            "$replaced_assignments" "$deployed_exemptions" \
            "$skip_not_scoped_exemptions" "$fail_on_exemption_error")"
    fi

    _timer "Building summary"
    # ── Summary ──
    epac_write_header "EPAC Deployment Plan Summary" "Policy as Code Resource Analysis"

    if [[ "$build_policy_definitions" == "true" ]]; then
        read pd_new pd_upd pd_rep pd_del pd_unc pd_chg < <(echo "$policy_plan_defs" | jq -r '[(.new|length), (.update|length), (.replace|length), (.delete|length), .numberUnchanged, .numberOfChanges] | @tsv')
        epac_write_status "Policy Definitions: ${pd_chg} changes (new:${pd_new} upd:${pd_upd} rep:${pd_rep} del:${pd_del}) unchanged:${pd_unc}" "info" 2
    fi

    if [[ "$build_policy_set_definitions" == "true" ]]; then
        read psd_new psd_upd psd_rep psd_del psd_unc psd_chg < <(echo "$policy_set_plan_defs" | jq -r '[(.new|length), (.update|length), (.replace|length), (.delete|length), .numberUnchanged, .numberOfChanges] | @tsv')
        epac_write_status "Policy Set Definitions: ${psd_chg} changes (new:${psd_new} upd:${psd_upd} rep:${psd_rep} del:${psd_del}) unchanged:${psd_unc}" "info" 2
    fi

    if [[ "$build_policy_assignments" == "true" ]]; then
        read a_new a_upd a_rep a_del a_unc a_chg < <(echo "$assignment_plan_result" | jq -r '.assignments | [(.new|length), (.update|length), (.replace|length), (.delete|length), .numberUnchanged, .numberOfChanges] | @tsv')
        epac_write_status "Assignments: ${a_chg} changes (new:${a_new} upd:${a_upd} rep:${a_rep} del:${a_del}) unchanged:${a_unc}" "info" 2

        read r_add r_upd r_rem r_chg < <(echo "$assignment_plan_result" | jq -r '.roleAssignments | [(.added|length), (.updated|length), (.removed|length), .numberOfChanges] | @tsv')
        epac_write_status "Role Assignments: ${r_chg} changes (add:${r_add} upd:${r_upd} rem:${r_rem})" "info" 2
    fi

    if [[ "$build_policy_exemptions" == "true" ]]; then
        read e_new e_upd e_rep e_del e_unc e_chg e_orp e_exp < <(echo "$exemption_plan_result" | jq -r '.exemptions | [(.new|length), (.update|length), (.replace|length), (.delete|length), .numberUnchanged, .numberOfChanges, .numberOfOrphans, .numberOfExpired] | @tsv')
        epac_write_status "Exemptions: ${e_chg} changes (new:${e_new} upd:${e_upd} rep:${e_rep} del:${e_del}) unchanged:${e_unc} orphans:${e_orp} expired:${e_exp}" "info" 2
    fi
fi

###############################################################################
# Write output plan files
###############################################################################

epac_write_section "Deployment Plan Output" 0

# Write plan components to temp files to avoid Argument list too long
_t_pd="$(mktemp)"; echo "$policy_plan_defs" > "$_t_pd"
_t_psd="$(mktemp)"; echo "$policy_set_plan_defs" > "$_t_psd"
_t_assign="$(mktemp)"; echo "$assignment_plan_result" | jq '.assignments' > "$_t_assign"
_t_exempt="$(mktemp)"; echo "$exemption_plan_result" | jq '.exemptions' > "$_t_exempt"
_t_roles="$(mktemp)"; echo "$assignment_plan_result" | jq '.roleAssignments' > "$_t_roles"

# Assemble policyPlan via temp files
policy_plan_output_tmp="$(mktemp)"
jq -n \
    --arg ts "$timestamp" --arg pid "$pac_owner_id" \
    --slurpfile pd "$_t_pd" \
    --slurpfile psd "$_t_psd" \
    --slurpfile a "$_t_assign" \
    --slurpfile ex "$_t_exempt" \
    '{
        createdOn: $ts, pacOwnerId: $pid,
        policyDefinitions: $pd[0], policySetDefinitions: $psd[0],
        assignments: $a[0], exemptions: $ex[0]
    }' > "$policy_plan_output_tmp"

# Count total policy changes
policy_changes="$(jq '
    (.policyDefinitions.numberOfChanges // 0) +
    (.policySetDefinitions.numberOfChanges // 0) +
    (.assignments.numberOfChanges // 0) +
    (.exemptions.numberOfChanges // 0)' "$policy_plan_output_tmp")"

policy_stage="no"
if [[ $policy_changes -gt 0 ]]; then
    epac_write_status "Policy deployment plan created: ${policy_plan_output}" "success" 2
    mkdir -p "$(dirname "$policy_plan_output")"
    cp "$policy_plan_output_tmp" "$policy_plan_output"
    policy_stage="yes"
else
    epac_write_status "Policy deployment stage skipped - no changes detected" "skip" 2
    [[ -f "$policy_plan_output" ]] && rm -f "$policy_plan_output"
fi

# Assemble rolesPlan via temp files
roles_plan_output_tmp="$(mktemp)"
jq -n \
    --arg ts "$timestamp" --arg pid "$pac_owner_id" \
    --slurpfile ra "$_t_roles" \
    '{createdOn: $ts, pacOwnerId: $pid, roleAssignments: $ra[0]}' > "$roles_plan_output_tmp"

role_changes="$(jq '.roleAssignments.numberOfChanges // 0' "$roles_plan_output_tmp")"
role_stage="no"
if [[ $role_changes -gt 0 ]]; then
    epac_write_status "Role assignment plan created: ${roles_plan_output}" "success" 2
    mkdir -p "$(dirname "$roles_plan_output")"
    cp "$roles_plan_output_tmp" "$roles_plan_output"
    role_stage="yes"
else
    epac_write_status "Role assignment stage skipped - no changes detected" "skip" 2
    [[ -f "$roles_plan_output" ]] && rm -f "$roles_plan_output"
fi

rm -f "$_t_pd" "$_t_psd" "$_t_assign" "$_t_exempt" "$_t_roles" "$policy_plan_output_tmp" "$roles_plan_output_tmp"

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
_timer ""
script_end_time="$(date +%s)"
elapsed=$((script_end_time - script_start_time))
minutes=$((elapsed / 60))
seconds=$((elapsed % 60))
epac_write_header "EPAC Build Complete" "Deployment plans generated successfully"
epac_write_status "Total execution time: $(printf '%02d:%02d' $minutes $seconds)" "info"
