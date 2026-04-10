#!/usr/bin/env bash
# scripts/operations/new-epac-policy-assignment-definition.sh
# Exports a policy assignment from Azure to JSON in EPAC format
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/lib/epac.sh"

usage() {
    cat <<'EOF'
Usage: new-epac-policy-assignment-definition.sh --policy-assignment-id <ID> [--output-folder <PATH>]

Exports a policy assignment from Azure to a local file in EPAC format.

Required arguments:
  --policy-assignment-id    Full resource ID of the policy assignment

Options:
  --output-folder           Destination folder (if omitted, outputs to stdout)
  --help                    Show this help message

Examples:
  new-epac-policy-assignment-definition.sh \
    --policy-assignment-id "/providers/Microsoft.Management/managementGroups/epac/providers/Microsoft.Authorization/policyAssignments/Deny-SQL"
EOF
    exit 0
}

policy_assignment_id=""
output_folder=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --policy-assignment-id) policy_assignment_id="$2"; shift 2 ;;
        --output-folder) output_folder="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$policy_assignment_id" ]]; then
    epac_log_error "Missing required arguments. Use --help for usage."
    exit 1
fi

# Fetch the assignment via az CLI
raw="$(az policy assignment show --name "$(echo "$policy_assignment_id" | rev | cut -d'/' -f1 | rev)" \
    --scope "$(echo "$policy_assignment_id" | sed 's|/providers/Microsoft.Authorization/policyAssignments/.*||')" \
    2>/dev/null)" || {
    epac_log_error "Failed to retrieve policy assignment: $policy_assignment_id"
    exit 1
}

policy_def_id="$(echo "$raw" | jq -r '.policyDefinitionId')"
assignment_name="$(echo "$raw" | jq -r '.name')"

if [[ "$policy_def_id" == *"Microsoft.Authorization/policyDefinitions"* ]]; then
    def_key="policyName"
elif [[ "$policy_def_id" == *"Microsoft.Authorization/policySetDefinitions"* ]]; then
    def_key="policySetName"
else
    epac_log_error "Cannot determine definition type from: $policy_def_id"
    exit 1
fi

# Build EPAC format output: extract parameters as flat key:value pairs
result="$(echo "$raw" | jq --arg defKey "$def_key" '{
    assignment: {
        name: .name,
        displayName: .displayName,
        description: .description
    },
    definitionEntry: {
        ($defKey): (.policyDefinitionId | split("/") | last)
    },
    parameters: (
        if .parameters != null and (.parameters | length) > 0 then
            .parameters | to_entries | map({key: .key, value: .value.value}) | from_entries
        else
            {}
        end
    )
}')"

if [[ -n "$output_folder" ]]; then
    mkdir -p "$output_folder"
    output_file="${output_folder}/${assignment_name}.json"
    echo "$result" > "$output_file"
    epac_write_status "Exported to $output_file" "success" 2
else
    echo "$result"
fi
