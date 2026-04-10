#!/usr/bin/env bash
# scripts/operations/new-github-issue.sh
# Replaces: New-GitHubIssue.ps1
# Creates a GitHub Issue from failed remediation tasks JSON.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

# ─── Argument parsing ──────────────────────────────────────────────────────
failed_tasks_json=""
org_name=""
repo_name=""
pat=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --failed-tasks) failed_tasks_json="$2"; shift 2 ;;
        --org) org_name="$2"; shift 2 ;;
        --repo) repo_name="$2"; shift 2 ;;
        --pat) pat="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $(basename "$0") --failed-tasks <json> --org <org> --repo <repo> --pat <token>"
            echo "  Creates a GitHub Issue from failed remediation tasks."
            exit 0
            ;;
        *) shift ;;
    esac
done

if [[ -z "$failed_tasks_json" || -z "$org_name" || -z "$repo_name" || -z "$pat" ]]; then
    epac_log_error "Missing required arguments. Use --help for usage."
    exit 1
fi

epac_write_section "Creating GitHub Issue for Failed Remediation Tasks"

# Build the HTML table body
epac_write_status "Building HTML table..." "info" 2
html_table="$(echo "$failed_tasks_json" | jq -r '
    def url_encode: gsub("/"; "%2F");
    "<table><tr><th>Remediation Task Name</th><th>Remediation Task Url</th><th>Provisioning State</th></tr>" +
    ([.[] |
        "<tr><td>" + .Name + "</td><td>" +
        "https://portal.azure.com/#view/Microsoft_Azure_Policy/ManageRemediationTaskBlade/assignmentId/" +
        (.PolicyAssignmentId | url_encode) +
        "/remediationTaskId/" +
        (.Id | url_encode) +
        "</td><td>" + .ProvisioningState + "</td></tr>"
    ] | join("")) +
    "</table><h4><i>Table 1: Failed Remediation Tasks</i></h4>"
')"

body="<p>The Remediation Tasks in <i>Table 1</i> have failed. Please investigate and resolve the reason for failure as soon as possible.</p>${html_table}"

# Create the issue
title="Failed Remediation Tasks - $(date +%Y%m%d)"
epac_write_status "Creating issue in ${org_name}/${repo_name}..." "info" 2

issue_payload="$(jq -n \
    --arg title "$title" \
    --arg body "$body" \
    '{title: $title, body: $body, labels: ["Operations"]}')"

auth_header="$(printf ":%s" "$pat" | base64)"

response_code="$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Basic ${auth_header}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/vnd.github.v3+json" \
    -d "$issue_payload" \
    "https://api.github.com/repos/${org_name}/${repo_name}/issues")"

if [[ "$response_code" == "201" ]]; then
    epac_write_status "Successfully created GitHub Issue in ${org_name}/${repo_name}" "success" 2
else
    epac_log_error "Failed to create GitHub Issue (HTTP $response_code)"
    exit 1
fi
