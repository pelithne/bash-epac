#!/usr/bin/env bash
# lib/rest/management-groups.sh — Management group REST methods
# Replaces: Get-AzManagementGroupRestMethod.ps1

[[ -n "${_EPAC_REST_MG_LOADED:-}" ]] && return 0
readonly _EPAC_REST_MG_LOADED=1

# ─── Get Management Group ────────────────────────────────────────────────────
# GET /providers/Microsoft.Management/managementGroups/{groupId}
# Optional: $expand=children, $recurse=True

epac_get_management_group() {
    local group_id="$1"
    local expand="${2:-false}"    # "true" to expand children
    local recurse="${3:-false}"   # "true" to recurse
    local api_version="${4:-2020-05-01}"

    local uri="https://management.azure.com/providers/Microsoft.Management/managementGroups/${group_id}?api-version=${api_version}"

    if [[ "$expand" == "true" ]]; then
        uri+='&$expand=children'
    fi
    if [[ "$recurse" == "true" ]]; then
        uri+='&$recurse=True'
    fi

    local response
    response="$(epac_invoke_az_rest "GET" "$uri")" || {
        epac_log_error "Failed to get management group '${group_id}'"
        return 1
    }

    echo "$response"
}
