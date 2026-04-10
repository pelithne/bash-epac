#!/usr/bin/env bash
# scripts/operations/new-az-policy-reader-role.sh
# Replaces: New-AzPolicyReaderRole.ps1
# Creates a custom role 'EPAC Resource Policy Reader' with read access to
# all Policy resources for the purpose of planning EPAC deployments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

# ─── Argument parsing ──────────────────────────────────────────────────────
pac_selector=""
definitions_root=""
interactive=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pac-selector|-p) pac_selector="$2"; shift 2 ;;
        --definitions-root|-d) definitions_root="$2"; shift 2 ;;
        --non-interactive) interactive=false; shift ;;
        --help|-h)
            echo "Usage: $(basename "$0") [--pac-selector <env>] [--definitions-root <path>] [--non-interactive]"
            echo "  Creates custom role 'EPAC Resource Policy Reader'."
            exit 0
            ;;
        *) shift ;;
    esac
done

# ─── Init ───────────────────────────────────────────────────────────────────
pac_env="$(epac_select_pac_environment "$pac_selector" "$definitions_root" "" "$interactive")"
epac_set_cloud_tenant_subscription "$pac_env"

epac_write_section "Creating custom role 'EPAC Resource Policy Reader'"

# Get deployment root scope
deployment_root_scope="$(echo "$pac_env" | jq -r '.policyDefinitionsScopes[0]')"
epac_write_status "Deployment root scope: $deployment_root_scope" "info" 2

# Role definition
role_name="EPAC Resource Policy Reader"
role_id="2baa1a7c-6807-46af-8b16-5e9d03fba029"
role_description="Provides read access to all Policy resources for the purpose of planning the EPAC deployments."

permissions='[
    "Microsoft.Authorization/policyassignments/read",
    "Microsoft.Authorization/policydefinitions/read",
    "Microsoft.Authorization/policyexemptions/read",
    "Microsoft.Authorization/policysetdefinitions/read",
    "Microsoft.Authorization/roleAssignments/read",
    "Microsoft.PolicyInsights/*",
    "Microsoft.Management/register/action",
    "Microsoft.Management/managementGroups/read",
    "Microsoft.Resources/subscriptions/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
]'

# Build role definition JSON
role_json="$(jq -n \
    --arg name "$role_name" \
    --arg id "$role_id" \
    --arg desc "$role_description" \
    --argjson perms "$permissions" \
    --arg scope "$deployment_root_scope" \
    '{
        Name: $name,
        Id: $id,
        IsCustom: true,
        Description: $desc,
        Actions: $perms,
        NotActions: [],
        AssignableScopes: [$scope]
    }')"

# Check if role already exists
epac_write_status "Checking for existing role..." "info" 2
existing="$(az role definition list --name "$role_name" --scope "$deployment_root_scope" -o json 2>/dev/null || echo '[]')"
existing_count="$(echo "$existing" | jq 'length')"

if [[ "$existing_count" -gt 0 ]]; then
    epac_write_status "Role '$role_name' already exists — updating" "update" 2
    echo "$role_json" | az role definition update --role-definition @- -o none 2>/dev/null
else
    epac_write_status "Creating role '$role_name'" "success" 2
    echo "$role_json" | az role definition create --role-definition @- -o none 2>/dev/null
fi

epac_write_status "Complete" "success" 2
