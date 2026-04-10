#!/usr/bin/env bash
# lib/rest/role-definitions.sh — Role definition REST methods
# Replaces: Get-AzRoleDefinitionsRestMethod.ps1

[[ -n "${_EPAC_REST_RD_LOADED:-}" ]] && return 0
readonly _EPAC_REST_RD_LOADED=1

# ─── Get Role Definitions ───────────────────────────────────────────────────
# GET {scope}/providers/Microsoft.Authorization/roleDefinitions?$filter=atScopeAndBelow&api-version=...
# Returns the .value array.

epac_get_role_definitions() {
    local scope="$1"
    local api_version="$2"

    local uri="https://management.azure.com${scope}/providers/Microsoft.Authorization/roleDefinitions?\$filter=atScopeAndBelow&api-version=${api_version}"

    local response
    response="$(epac_invoke_az_rest "GET" "$uri")" || {
        epac_log_error "Failed to get role definitions at scope '${scope}'"
        return 1
    }

    echo "$response" | jq '.value // []'
}
