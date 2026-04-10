#!/usr/bin/env bash
# scripts/operations/new-epac-global-settings.sh
# Creates a global-settings.jsonc file with a new guid, managed identity location and tenant info
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/lib/epac.sh"

usage() {
    cat <<'EOF'
Usage: new-epac-global-settings.sh --location <LOCATION> --tenant-id <TENANT_ID> \
       --definitions-root-folder <PATH> --deployment-root-scope <SCOPE>

Creates a global-settings.jsonc file with a new GUID, managed identity location,
and tenant information.

Required arguments:
  --location                Azure region for managed identities (e.g. NorthCentralUS)
  --tenant-id               Azure tenant ID (GUID)
  --definitions-root-folder Path to definitions root folder
  --deployment-root-scope   Root management group path
                            (/providers/Microsoft.Management/managementGroups/<name>)

Options:
  --help                    Show this help message
EOF
    exit 0
}

location=""
tenant_id=""
definitions_root=""
deployment_root_scope=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --location) location="$2"; shift 2 ;;
        --tenant-id) tenant_id="$2"; shift 2 ;;
        --definitions-root-folder) definitions_root="$2"; shift 2 ;;
        --deployment-root-scope) deployment_root_scope="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$location" || -z "$tenant_id" || -z "$definitions_root" || -z "$deployment_root_scope" ]]; then
    epac_log_error "Missing required arguments. Use --help for usage."
    exit 1
fi

# Remove trailing slash
definitions_root="${definitions_root%/}"

# Validate deployment root scope format
if [[ "$deployment_root_scope" != /providers/Microsoft.Management/managementGroups/* ]]; then
    epac_log_error "Please provide the root management group path in the format /providers/Microsoft.Management/managementGroups/<MGName>"
    exit 1
fi

# Validate definitions folder exists
if [[ ! -d "$definitions_root" ]]; then
    epac_log_error "Definition path not found. Specify a valid definition folder path."
    exit 1
fi

# Validate Azure location
valid_location="$(az account list-locations --query "[?name=='${location}'].name" -o tsv 2>/dev/null || true)"
if [[ -z "$valid_location" ]]; then
    epac_log_error "Location $location invalid. Please check the location with 'az account list-locations'."
    exit 1
fi

# Generate new GUID
pac_owner_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"

# Build global-settings JSON
output_file="${definitions_root}/global-settings.jsonc"

jq -n \
    --arg schema "https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/global-settings-schema.json" \
    --arg owner_id "$pac_owner_id" \
    --arg location "$location" \
    --arg tenant "$tenant_id" \
    --arg scope "$deployment_root_scope" \
    '{
        "$schema": $schema,
        pacOwnerId: $owner_id,
        managedIdentityLocations: { "*": $location },
        pacEnvironments: [{
            pacSelector: "quick-start",
            cloud: "AzureCloud",
            tenantId: $tenant,
            deploymentRootScope: $scope
        }]
    }' > "$output_file"

epac_write_status "Created $output_file" "success" 2
cat "$output_file"
