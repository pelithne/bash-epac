#!/usr/bin/env bash
# scripts/operations/new-az-remediation-tasks.sh
# Replaces: New-AzRemediationTasks.ps1
# Creates remediation tasks for all non-compliant resources in the current tenant.
# If tasks fail, outputs JSON for pipeline integration (ADO variables).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

# ─── Argument parsing ──────────────────────────────────────────────────────
pac_selector=""
definitions_root=""
output_folder=""
interactive=true
only_managed=false
policy_def_filter=""       # comma-separated
policy_set_def_filter=""   # comma-separated
policy_assignment_filter="" # comma-separated
policy_effect_filter=""    # comma-separated
no_wait=false
test_run=false
only_default_enforcement=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pac-selector|-p) pac_selector="$2"; shift 2 ;;
        --definitions-root|-d) definitions_root="$2"; shift 2 ;;
        --output-folder|-o) output_folder="$2"; shift 2 ;;
        --non-interactive) interactive=false; shift ;;
        --only-managed) only_managed=true; shift ;;
        --policy-definition-filter) policy_def_filter="$2"; shift 2 ;;
        --policy-set-definition-filter) policy_set_def_filter="$2"; shift 2 ;;
        --policy-assignment-filter) policy_assignment_filter="$2"; shift 2 ;;
        --policy-effect-filter) policy_effect_filter="$2"; shift 2 ;;
        --no-wait) no_wait=true; shift ;;
        --test-run) test_run=true; shift ;;
        --only-default-enforcement) only_default_enforcement=true; shift ;;
        --help|-h)
            echo "Usage: $(basename "$0") [options]"
            echo "  --pac-selector <env>                   PAC environment"
            echo "  --definitions-root <path>              Definitions folder"
            echo "  --non-interactive                      Non-interactive mode"
            echo "  --only-managed                         Only managed assignments"
            echo "  --policy-definition-filter <names>     Comma-separated filter"
            echo "  --policy-set-definition-filter <names>  Comma-separated filter"
            echo "  --policy-assignment-filter <names>     Comma-separated filter"
            echo "  --policy-effect-filter <effects>       Comma-separated filter"
            echo "  --no-wait                              Don't wait for tasks"
            echo "  --test-run                             Dry run (no action)"
            echo "  --only-default-enforcement             Only Default enforcement mode"
            exit 0
            ;;
        *) shift ;;
    esac
done

# ─── Init ───────────────────────────────────────────────────────────────────
pac_env="$(epac_select_pac_environment "$pac_selector" "$definitions_root" "$output_folder" "" "$interactive")"
epac_set_cloud_tenant_subscription "$pac_env"

# ─── Build filter args for non-compliant query ─────────────────────────────
enforcement_mode=""
if $only_default_enforcement; then
    enforcement_mode="Default"
fi

raw_non_compliant="$(epac_find_non_compliant_resources \
    "$pac_env" \
    "true" \
    "false" \
    "$policy_effect_filter" \
    "$enforcement_mode")"

# ─── Collate by assignment+referenceId ──────────────────────────────────────
epac_write_section "Collating non-compliant resources by Assignment Id"

total="$(echo "$raw_non_compliant" | jq 'length')"
if [[ "$total" -eq 0 ]]; then
    epac_write_status "No non-compliant resources found — no remediation tasks created" "success" 2
    exit 0
fi
epac_write_status "Processing $total non-compliant resources" "info" 2

# Collate into unique assignment+referenceId combos
collated="$(echo "$raw_non_compliant" | jq '
    reduce .[] as $entry ({};
        ($entry.properties.policyAssignmentId) as $aid |
        ($entry.properties.policyDefinitionReferenceId // "") as $refId |
        ($aid + "|" + $refId) as $key |
        if has($key) then
            .[$key].resourceCount += 1
        else
            .[$key] = {
                policyAssignmentId: $aid,
                policyAssignmentName: $entry.properties.policyAssignmentName,
                policyAssignmentScope: $entry.properties.policyAssignmentScope,
                policyDefinitionReferenceId: $refId,
                policyDefinitionName: ($entry.properties.policyDefinitionName // ""),
                policyDefinitionAction: ($entry.properties.policyDefinitionAction // ""),
                category: (($entry.properties.metadata // {}).category // "|unknown|"),
                resourceCount: 1
            }
        end
    )
')"

task_count="$(echo "$collated" | jq 'length')"

if $test_run; then
    epac_write_section "TEST RUN: Testing the creation of $task_count remediation tasks..."
else
    epac_write_section "Creating $task_count remediation tasks..."
fi

# ─── Create remediation tasks ──────────────────────────────────────────────
failed_tasks="[]"
running_tasks="[]"
needed="$task_count"
created=0
failed_to_create=0
failed=0
succeeded=0

while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    entry="$(echo "$collated" | jq --arg k "$key" '.[$k]')"
    assignment_id="$(echo "$entry" | jq -r '.policyAssignmentId')"
    assignment_name="$(echo "$entry" | jq -r '.policyAssignmentName')"
    assignment_scope="$(echo "$entry" | jq -r '.policyAssignmentScope')"
    ref_id="$(echo "$entry" | jq -r '.policyDefinitionReferenceId')"
    policy_name="$(echo "$entry" | jq -r '.policyDefinitionName')"
    policy_action="$(echo "$entry" | jq -r '.policyDefinitionAction')"
    resource_count="$(echo "$entry" | jq -r '.resourceCount')"

    short_scope="${assignment_scope//\/providers\/microsoft.management/}"
    if [[ -n "$ref_id" ]]; then
        epac_write_status "'${short_scope}/${assignment_name}|${ref_id}': ${resource_count} resources, '${policy_name}', ${policy_action}" "info" 2
    else
        epac_write_status "'${short_scope}/${assignment_name}': ${resource_count} resources, '${policy_name}', ${policy_action}" "info" 2
    fi

    task_name="${assignment_name}-$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"

    if $test_run; then
        echo "  TEST RUN: Remediation Task would have been created."
        created=$((created + 1))
        succeeded=$((succeeded + 1))
        continue
    fi

    # Build remediation task via REST API
    api_version="2021-10-01"
    remediation_url="https://management.azure.com${assignment_scope}/providers/Microsoft.PolicyInsights/remediations/${task_name}?api-version=${api_version}"

    body_json="$(jq -n \
        --arg aid "$assignment_id" \
        --arg refid "$ref_id" \
        '{
            properties: {
                policyAssignmentId: $aid,
                resourceDiscoveryMode: "ExistingNonCompliant",
                resourceCount: 50000,
                parallelDeployments: 30
            }
        } | if $refid != "" then .properties.policyDefinitionReferenceId = $refid else . end
    ')"

    response="$(epac_invoke_az_rest "PUT" "$remediation_url" "$body_json" 2>/dev/null || echo '{"error": true}')"
    prov_state="$(echo "$response" | jq -r '.properties.provisioningState // "Failed"')"
    task_id="$(echo "$response" | jq -r '.id // "Not created"')"

    if [[ "$(echo "$response" | jq 'has("error")')" == "true" && "$task_id" == "Not created" ]]; then
        echo "  Remediation Task could not be created."
        failed_tasks="$(echo "$failed_tasks" | jq --arg n "$task_name" --arg aid "$assignment_id" \
            '. + [{Name: $n, Id: "Not created", PolicyAssignmentId: $aid, ProvisioningState: "Failed"}]')"
        failed_to_create=$((failed_to_create + 1))
    elif [[ "$prov_state" == "Succeeded" ]]; then
        echo "  Remediation Task succeeded immediately."
        succeeded=$((succeeded + 1))
        created=$((created + 1))
    elif [[ "$prov_state" == "Failed" ]]; then
        echo "  Remediation Task failed immediately."
        failed_tasks="$(echo "$failed_tasks" | jq --arg n "$task_name" --arg id "$task_id" --arg aid "$assignment_id" --arg ps "$prov_state" \
            '. + [{Name: $n, Id: $id, PolicyAssignmentId: $aid, ProvisioningState: $ps}]')"
        failed=$((failed + 1))
        created=$((created + 1))
    else
        echo "  Remediation Task started."
        running_tasks="$(echo "$running_tasks" | jq --arg n "$task_name" --arg id "$task_id" --arg aid "$assignment_id" --arg ps "$prov_state" \
            '. + [{Name: $n, Id: $id, PolicyAssignmentId: $aid, ProvisioningState: $ps}]')"
        created=$((created + 1))
    fi
done < <(echo "$collated" | jq -r 'keys[]')

# ─── Wait for running tasks ────────────────────────────────────────────────
max_checks=30
wait_period=60
running_count="$(echo "$running_tasks" | jq 'length')"
canceled=0

if [[ "$running_count" -gt 0 ]]; then
    if $no_wait; then
        max_checks=1
        wait_period=120
    fi
    check_minutes=$(( (wait_period * max_checks + 59) / 60 ))
    epac_write_section "Waiting for remediation tasks (checking every ${wait_period}s for ${check_minutes} min)..."

    check_num=0
    while [[ "$running_count" -gt 0 && "$check_num" -lt "$max_checks" ]]; do
        check_num=$((check_num + 1))
        sleep "$wait_period"
        echo ""
        epac_write_status "Checking $running_count remediation tasks' provisioning state..." "info" 2

        new_running="[]"
        for (( i=0; i<running_count; i++ )); do
            task="$(echo "$running_tasks" | jq --argjson i "$i" '.[$i]')"
            task_id="$(echo "$task" | jq -r '.Id')"
            task_name="$(echo "$task" | jq -r '.Name')"
            task_aid="$(echo "$task" | jq -r '.PolicyAssignmentId')"

            check_url="https://management.azure.com${task_id}?api-version=2021-10-01"
            result="$(epac_invoke_az_rest "GET" "$check_url" 2>/dev/null || echo '{}')"
            state="$(echo "$result" | jq -r '.properties.provisioningState // "Check for status failed"')"

            if [[ "$state" == "Succeeded" ]]; then
                echo "  Remediation Task '$task_name' succeeded."
                succeeded=$((succeeded + 1))
            elif [[ "$state" == "Failed" ]]; then
                echo "  Remediation Task '$task_name' failed."
                failed_tasks="$(echo "$failed_tasks" | jq --arg n "$task_name" --arg id "$task_id" --arg aid "$task_aid" \
                    '. + [{Name: $n, Id: $id, PolicyAssignmentId: $aid, ProvisioningState: "Failed"}]')"
                failed=$((failed + 1))
            elif [[ "$state" == "Canceled" ]]; then
                echo "  Remediation Task '$task_name' was canceled."
                canceled=$((canceled + 1))
            else
                echo "  Remediation Task '$task_name' provisioning state is '$state'."
                new_running="$(echo "$new_running" | jq --argjson t "$task" '. + [$t]')"
            fi
        done
        running_tasks="$new_running"
        running_count="$(echo "$running_tasks" | jq 'length')"
    done
fi

# ─── Summary ───────────────────────────────────────────────────────────────
echo ""
create_work_item=false
if $test_run; then
    epac_write_section "TEST RUN: Remediation Task Status (NO ACTION TAKEN)"
    echo "TEST RUN: $needed needed"
    echo "TEST RUN: $created created"
    echo "TEST RUN: $succeeded succeeded"
else
    epac_write_section "Remediation Task Status"
    still_running="$(echo "$running_tasks" | jq 'length')"
    echo "$needed needed"
    [[ "$failed_to_create" -gt 0 ]] && echo "$failed_to_create failed to create"
    echo "$created created"
    echo "$succeeded succeeded"
    [[ "$failed" -gt 0 ]] && echo "$failed failed"
    [[ "$canceled" -gt 0 ]] && echo "$canceled canceled"
    [[ "$still_running" -gt 0 ]] && echo "$still_running still running after $(( (wait_period * max_checks + 59) / 60 )) minutes"

    if [[ "$interactive" == "false" ]]; then
        if [[ "$failed" -gt 0 || "$failed_to_create" -gt 0 ]]; then
            compressed="$(echo "$failed_tasks" | jq -c '.')"
            echo "##vso[task.setvariable variable=failedPolicyRemediationTasksJsonString;isOutput=true]${compressed}"
            create_work_item=true
        fi
        echo "##vso[task.setvariable variable=createWorkItem;isOutput=true]${create_work_item}"
    fi
fi
