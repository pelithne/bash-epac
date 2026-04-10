#!/usr/bin/env bash
# scripts/deploy/set-az-policy-exemption.sh — Create or update a single policy exemption
# Replaces: Set-AzPolicyExemptionEpac.ps1
# Standalone script for creating/updating individual exemptions via REST API.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

usage() {
    cat <<'EOF'
Usage: set-az-policy-exemption.sh [OPTIONS]

Required:
  --scope SCOPE                    Resource scope
  --name NAME                      Exemption name
  --display-name DISPLAYNAME       Display name
  --policy-assignment-id ID        Policy assignment ID

Optional:
  --description TEXT               Description (default: "description")
  --exemption-category CAT         Waiver or Mitigated (default: Waiver)
  --expires-on DATE                Expiration date (ISO 8601)
  --assignment-scope-validation V  Default or DoNotValidate (default: Default)
  --policy-definition-ref-ids IDS  Comma-separated reference IDs
  --resource-selectors JSON        Resource selectors JSON
  --metadata JSON                  Metadata JSON
  --api-version VERSION            API version (default: 2022-07-01-preview)
  -h, --help                       Show this help
EOF
    exit 0
}

scope="" name="" display_name="" description="description"
exemption_category="Waiver" expires_on="" policy_assignment_id=""
assignment_scope_validation="Default" policy_def_ref_ids=""
resource_selectors="null" metadata="null"
api_version="2022-07-01-preview"

while [[ $# -gt 0 ]]; do
    case $1 in
        --scope) scope="$2"; shift 2 ;;
        --name) name="$2"; shift 2 ;;
        --display-name) display_name="$2"; shift 2 ;;
        --description) description="$2"; shift 2 ;;
        --exemption-category) exemption_category="$2"; shift 2 ;;
        --expires-on) expires_on="$2"; shift 2 ;;
        --policy-assignment-id) policy_assignment_id="$2"; shift 2 ;;
        --assignment-scope-validation) assignment_scope_validation="$2"; shift 2 ;;
        --policy-definition-ref-ids) policy_def_ref_ids="$2"; shift 2 ;;
        --resource-selectors) resource_selectors="$2"; shift 2 ;;
        --metadata) metadata="$2"; shift 2 ;;
        --api-version) api_version="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate required params
if [[ -z "$scope" || -z "$name" || -z "$display_name" || -z "$policy_assignment_id" ]]; then
    epac_log_error "Missing required parameters: --scope, --name, --display-name, --policy-assignment-id"
    exit 1
fi

# Build ref IDs array
ref_ids_json="null"
if [[ -n "$policy_def_ref_ids" ]]; then
    ref_ids_json="$(echo "$policy_def_ref_ids" | tr ',' '\n' | jq -R '.' | jq -s '.')"
fi

# Build exemption ID
exemption_id="${scope}/providers/Microsoft.Authorization/policyExemptions/${name}"

# Build exemption object
exemption_obj="$(jq -n \
    --arg id "$exemption_id" \
    --arg paid "$policy_assignment_id" \
    --arg ec "$exemption_category" \
    --arg sv "$assignment_scope_validation" \
    --arg dn "$display_name" \
    --arg desc "$description" \
    --arg eo "$expires_on" \
    --argjson meta "$metadata" \
    --argjson refs "$ref_ids_json" \
    --argjson rsel "$resource_selectors" \
    '{
        id: $id,
        properties: {
            policyAssignmentId: $paid,
            exemptionCategory: $ec,
            assignmentScopeValidation: $sv,
            displayName: $dn,
            description: $desc,
            expiresOn: (if $eo == "" then null else $eo end),
            metadata: $meta,
            policyDefinitionReferenceIds: $refs,
            resourceSelectors: $rsel
        }
    }')"

epac_set_policy_exemption "$exemption_obj" "$api_version"
