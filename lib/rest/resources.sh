#!/usr/bin/env bash
# lib/rest/resources.sh — Generic resource deletion REST methods
# Replaces: Remove-AzResourceByIdRestMethod.ps1

[[ -n "${_EPAC_REST_RES_LOADED:-}" ]] && return 0
readonly _EPAC_REST_RES_LOADED=1

# ─── Remove Azure Resource by ID ────────────────────────────────────────────
# DELETE {resourceId}?api-version={apiVersion}
# Handles 404 (already deleted) and ScopeLocked gracefully.

epac_remove_resource_by_id() {
    local resource_id="$1"
    local api_version="$2"

    local uri="https://management.azure.com${resource_id}?api-version=${api_version}"

    local response
    if response="$(epac_invoke_az_rest "DELETE" "$uri")"; then
        return 0
    fi

    local status="$EPAC_REST_STATUS_CODE"

    # 404 — already deleted, not an error
    if [[ "$status" == "404" ]]; then
        return 0
    fi

    # Check for ScopeLocked
    if echo "$response" | grep -qi "ScopeLocked" 2>/dev/null; then
        epac_log_warning "Scope is locked, cannot delete resource '${resource_id}'."
        return 1
    fi

    epac_log_error "Failed to delete resource '${resource_id}': HTTP ${status}"
    return 1
}
