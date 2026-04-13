#!/usr/bin/env bash
# lib/rest/policy-definitions.sh — Policy definition REST methods
# Replaces: Set-AzPolicyDefinitionRestMethod.ps1

[[ -n "${_EPAC_REST_PDEF_LOADED:-}" ]] && return 0
readonly _EPAC_REST_PDEF_LOADED=1

# ─── Set Policy Definition ───────────────────────────────────────────────────
# PUT {definitionId}?api-version={apiVersion}

epac_set_policy_definition() {
    local definition_json="$1"
    local api_version="$2"

    local def_id
    def_id="$(echo "$definition_json" | jq -r '.id')"

    local body
    body="$(echo "$definition_json" | jq '{
        properties: (
            (if .properties then .properties else . end) | {
                displayName,
                description,
                metadata,
                mode,
                parameters,
                policyRule
            }
        )
    }')"

    # Handle [[ → [ escaping in policy rules (PS had this workaround)
    body="$(echo "$body" | sed 's/\[\[/[/g')"

    local uri="https://management.azure.com${def_id}?api-version=${api_version}"

    local response
    response="$(epac_invoke_az_rest "PUT" "$uri" "$body")" || {
        epac_log_error "Failed to set policy definition '${def_id}'"
        return 1
    }

    echo "$response"
}
