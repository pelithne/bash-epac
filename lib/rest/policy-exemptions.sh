#!/usr/bin/env bash
# lib/rest/policy-exemptions.sh — Policy exemption REST methods
# Replaces: Get-AzPolicyExemptionsRestMethod.ps1, Set-AzPolicyExemptionRestMethod.ps1

[[ -n "${_EPAC_REST_PE_LOADED:-}" ]] && return 0
readonly _EPAC_REST_PE_LOADED=1

# ─── Get Policy Exemptions ──────────────────────────────────────────────────
# GET {scope}/providers/Microsoft.Authorization/policyExemptions?api-version=...
# Returns the .value array.

epac_get_policy_exemptions() {
    local scope="$1"
    local api_version="$2"
    local filter="${3:-}"

    local uri="https://management.azure.com${scope}/providers/Microsoft.Authorization/policyExemptions?api-version=${api_version}"
    if [[ -n "$filter" ]]; then
        uri+="&\$filter=${filter}"
    fi

    local response
    response="$(epac_invoke_az_rest "GET" "$uri")" || {
        epac_log_error "Failed to get policy exemptions at scope '${scope}'"
        return 1
    }

    echo "$response" | jq '.value // []'
}

# ─── Set Policy Exemption ───────────────────────────────────────────────────
# PUT {exemptionId}?api-version={apiVersion}
# Handles ScopeLocked warnings and optional error fail behavior.

epac_set_policy_exemption() {
    local exemption_json="$1"
    local api_version="$2"
    local fail_on_error="${3:-true}"

    local exemption_id
    exemption_id="$(echo "$exemption_json" | jq -r '.id')"

    # Build body with null fields removed
    local body
    body="$(echo "$exemption_json" | jq '{
        properties: (.properties | {
            policyAssignmentId,
            exemptionCategory,
            assignmentScopeValidation,
            displayName,
            description,
            expiresOn,
            metadata,
            policyDefinitionReferenceIds,
            resourceSelectors
        } | with_entries(select(.value != null)))
    }')"

    local uri="https://management.azure.com${exemption_id}?api-version=${api_version}"

    local response
    if response="$(epac_invoke_az_rest "PUT" "$uri" "$body")"; then
        echo "$response"
        return 0
    fi

    local status="$EPAC_REST_STATUS_CODE"

    # Check for ScopeLocked
    if echo "$response" | grep -qi "ScopeLocked" 2>/dev/null; then
        epac_log_warning "Scope is locked for exemption '${exemption_id}', skipping."
        return 0
    fi

    # 404 — resource not found
    if [[ "$status" == "404" ]]; then
        epac_log_warning "Policy exemption resource not found. Please verify Policy Exemptions are valid."
        return 1
    fi

    if [[ "$fail_on_error" == "true" ]]; then
        epac_log_error "Failed to set policy exemption '${exemption_id}'"
        return 1
    else
        epac_log_warning "Failed to set policy exemption '${exemption_id}' (non-fatal)"
        return 0
    fi
}
