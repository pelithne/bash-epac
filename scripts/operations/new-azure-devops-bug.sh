#!/usr/bin/env bash
# scripts/operations/new-azure-devops-bug.sh
# Replaces: New-AzureDevOpsBug.ps1
# Creates an Azure DevOps Bug work item from failed remediation tasks JSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

# ─── Argument parsing ──────────────────────────────────────────────────────
failed_tasks_json=""
org_name=""
project_name=""
pat=""
team_name=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --failed-tasks) failed_tasks_json="$2"; shift 2 ;;
        --org) org_name="$2"; shift 2 ;;
        --project) project_name="$2"; shift 2 ;;
        --pat) pat="$2"; shift 2 ;;
        --team) team_name="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $(basename "$0") --failed-tasks <json> --org <org> --project <project>"
            echo "  --pat <token> --team <team>"
            echo "  Creates an Azure DevOps Bug from failed remediation tasks."
            exit 0
            ;;
        *) shift ;;
    esac
done

if [[ -z "$failed_tasks_json" || -z "$org_name" || -z "$project_name" || -z "$pat" || -z "$team_name" ]]; then
    epac_log_error "Missing required arguments. Use --help for usage."
    exit 1
fi

epac_write_section "Creating Azure DevOps Bug for Failed Remediation Tasks"

# ─── Get current iteration ─────────────────────────────────────────────────
epac_write_status "Retrieving team iteration paths..." "info" 2
auth_header="$(printf ":%s" "$pat" | base64)"

# URL-encode team name for the API call
encoded_team="$(printf '%s' "$team_name" | jq -sRr @uri)"
iterations_url="https://dev.azure.com/${org_name}/${project_name}/${encoded_team}/_apis/work/teamsettings/iterations?api-version=5.1"

iterations_response="$(curl -s \
    -H "Authorization: Basic ${auth_header}" \
    -H "Content-Type: application/json" \
    "$iterations_url")"

current_iteration="$(echo "$iterations_response" | jq -r '[.value[] | select(.attributes.timeFrame == "current")][0]')"
iteration_path="$(echo "$current_iteration" | jq -r '.path // empty')"
iteration_name="$(echo "$current_iteration" | jq -r '.name // "unknown"')"

if [[ -z "$iteration_path" ]]; then
    epac_log_error "Could not determine current iteration for team '$team_name'"
    exit 1
fi
epac_write_status "Current iteration: $iteration_name" "info" 2

# ─── Build HTML table ──────────────────────────────────────────────────────
epac_write_status "Building HTML table..." "info" 2
html_table="$(echo "$failed_tasks_json" | jq -r '
    def url_encode: gsub("/"; "%2F");
    "<style>TABLE {border-width: 1px; border-style: solid; border-color: black; border-collapse: collapse;} TH {text-align: left; border-width: 1px; padding: 3px; border-style: solid; border-color: black; background-color: #6495ED;} TD {text-align: left; border-width: 1px; padding: 3px; border-style: solid; border-color: black;}</style>" +
    "<table><tr><th>Remediation Task Name</th><th>Remediation Task Url</th><th>Provisioning State</th></tr>" +
    ([.[] |
        "<tr><td>" + .Name + "</td><td>" +
        "https://portal.azure.com/#view/Microsoft_Azure_Policy/ManageRemediationTaskBlade/assignmentId/" +
        (.PolicyAssignmentId | url_encode) +
        "/remediationTaskId/" +
        (.Id | url_encode) +
        "</td><td>" + .ProvisioningState + "</td></tr>"
    ] | join("")) +
    "</table><H4><i>Table 1: Failed Remediation Tasks</i></H4>"
')"

# ─── Create Bug work item ──────────────────────────────────────────────────
title="Failed Remediation Tasks - $(date +%Y%m%d)"
description="As you can see in Table 1, one or more Remediation Tasks failed. Please investigate these in more detail."

epac_write_status "Creating Bug on iteration '$iteration_name'..." "info" 2

# ADO Work Item Tracking API uses JSON Patch format
work_item_url="https://dev.azure.com/${org_name}/${project_name}/_apis/wit/workitems/\$Bug?api-version=7.0"

patch_body="$(jq -n \
    --arg title "$title" \
    --arg desc "$description" \
    --arg repro "$html_table" \
    --arg iter "$iteration_path" \
    '[
        {op: "add", path: "/fields/System.Title", value: $title},
        {op: "add", path: "/fields/System.Description", value: $desc},
        {op: "add", path: "/fields/Microsoft.VSTS.TCM.ReproSteps", value: $repro},
        {op: "add", path: "/fields/System.IterationPath", value: $iter}
    ]')"

response_code="$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Basic ${auth_header}" \
    -H "Content-Type: application/json-patch+json" \
    -d "$patch_body" \
    "$work_item_url")"

if [[ "$response_code" == "200" ]]; then
    epac_write_status "Successfully created Bug on iteration '$iteration_name'" "success" 2
else
    epac_log_error "Failed to create Bug work item (HTTP $response_code)"
    exit 1
fi
