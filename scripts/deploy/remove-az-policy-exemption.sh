#!/usr/bin/env bash
# scripts/deploy/remove-az-policy-exemption.sh — Remove a single policy exemption
# Replaces: Remove-AzPolicyExemptionEpac.ps1
# Standalone script for removing individual exemptions via REST API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

usage() {
    cat <<'EOF'
Usage: remove-az-policy-exemption.sh [OPTIONS]

Required:
  --scope SCOPE           Resource scope
  --name NAME             Exemption name

Optional:
  --api-version VERSION   API version (default: 2022-07-01-preview)
  -h, --help              Show this help
EOF
    exit 0
}

scope="" name="" api_version="2022-07-01-preview"

while [[ $# -gt 0 ]]; do
    case $1 in
        --scope) scope="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        --api-version) api_version="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$scope" || -z "$name" ]]; then
    epac_log_error "Missing required parameters: --scope, --name"
    exit 1
fi

exemption_id="${scope}/providers/Microsoft.Authorization/policyExemptions/${name}"
epac_remove_resource_by_id "$exemption_id" "$api_version"
