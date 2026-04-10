#!/usr/bin/env bash
# scripts/operations/new-epac-policy-definition.sh
# Exports a policy or policy set definition from Azure to JSON in EPAC format
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/lib/epac.sh"

usage() {
    cat <<'EOF'
Usage: new-epac-policy-definition.sh --policy-definition-id <ID> [--output-folder <PATH>]

Exports a policy or policy set definition from Azure to a local file in EPAC format.

Required arguments:
  --policy-definition-id    Full resource ID of the policy or policy set definition

Options:
  --output-folder           Destination folder (if omitted, outputs to stdout)
  --help                    Show this help message

Examples:
  new-epac-policy-definition.sh \
    --policy-definition-id "/providers/Microsoft.Management/managementGroups/epac/providers/Microsoft.Authorization/policyDefinitions/Deny-SQL"

  new-epac-policy-definition.sh \
    --policy-definition-id "/providers/Microsoft.Management/managementGroups/epac/providers/Microsoft.Authorization/policySetDefinitions/MCSB" \
    --output-folder ./output
EOF
    exit 0
}

policy_definition_id=""
output_folder=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --policy-definition-id) policy_definition_id="$2"; shift 2 ;;
        --output-folder) output_folder="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$policy_definition_id" ]]; then
    epac_log_error "Missing required arguments. Use --help for usage."
    exit 1
fi

if [[ "$policy_definition_id" == *"Microsoft.Authorization/policyDefinitions"* ]]; then
    # Fetch policy definition
    raw="$(az policy definition show --name "$(echo "$policy_definition_id" | rev | cut -d'/' -f1 | rev)" \
        --management-group "$(echo "$policy_definition_id" | grep -oP 'managementGroups/\K[^/]+' || true)" \
        2>/dev/null || az policy definition show --id "$policy_definition_id" 2>/dev/null)" || {
        epac_log_error "Failed to retrieve policy definition: $policy_definition_id"
        exit 1
    }

    result="$(echo "$raw" | jq '{
        name: .name,
        properties: {
            displayName: .displayName,
            mode: .mode,
            description: .description,
            metadata: { version: .metadata.version, category: .metadata.category },
            parameters: .parameters,
            policyRule: .policyRule
        }
    }')"

elif [[ "$policy_definition_id" == *"Microsoft.Authorization/policySetDefinitions"* ]]; then
    # Fetch policy set definition
    raw="$(az policy set-definition show --name "$(echo "$policy_definition_id" | rev | cut -d'/' -f1 | rev)" \
        --management-group "$(echo "$policy_definition_id" | grep -oP 'managementGroups/\K[^/]+' || true)" \
        2>/dev/null || az policy set-definition show --id "$policy_definition_id" 2>/dev/null)" || {
        epac_log_error "Failed to retrieve policy set definition: $policy_definition_id"
        exit 1
    }

    result="$(echo "$raw" | jq '{
        name: .name,
        properties: {
            displayName: .displayName,
            description: .description,
            metadata: { version: .metadata.version, category: .metadata.category },
            policyDefinitionGroups: .policyDefinitionGroups,
            parameters: .parameters,
            policyDefinitions: [.policyDefinitions[] | {
                policyDefinitionName: (.policyDefinitionId | split("/") | last)
            } + (del(.policyDefinitionId))]
        }
    }')"
else
    epac_log_error "ID must contain Microsoft.Authorization/policyDefinitions or policySetDefinitions"
    exit 1
fi

if [[ -n "$output_folder" ]]; then
    mkdir -p "$output_folder"
    policy_name="$(echo "$result" | jq -r '.name')"
    output_file="${output_folder}/${policy_name}.json"
    echo "$result" > "$output_file"
    epac_write_status "Exported to $output_file" "success" 2
else
    echo "$result"
fi
