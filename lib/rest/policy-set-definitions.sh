#!/usr/bin/env bash
# lib/rest/policy-set-definitions.sh — Policy set definition REST methods
# Replaces: Set-AzPolicySetDefinitionRestMethod.ps1

[[ -n "${_EPAC_REST_PSDEF_LOADED:-}" ]] && return 0
readonly _EPAC_REST_PSDEF_LOADED=1

# ─── Set Policy Set Definition ───────────────────────────────────────────────
# PUT {definitionId}?api-version={apiVersion}

epac_set_policy_set_definition() {
    local definition_json="$1"
    local api_version="$2"

    local def_id
    def_id="$(echo "$definition_json" | jq -r '.id')"

    # Build body, removing null fields
    local body
    body="$(echo "$definition_json" | jq '{
        properties: (.properties | {
            displayName,
            description,
            metadata,
            parameters,
            policyDefinitions,
            policyDefinitionGroups
        } | with_entries(select(.value != null)))
    }')"

    local uri="https://management.azure.com${def_id}?api-version=${api_version}"

    local response
    response="$(epac_invoke_az_rest "PUT" "$uri" "$body")" || {
        epac_log_error "Failed to set policy set definition '${def_id}'"
        return 1
    }

    echo "$response"
}
