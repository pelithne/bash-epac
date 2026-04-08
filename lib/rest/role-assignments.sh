#!/usr/bin/env bash
# lib/rest/role-assignments.sh — Role assignment REST methods
# Replaces: Get-AzRoleAssignmentsRestMethod.ps1, Set-AzRoleAssignmentRestMethod.ps1,
#           Remove-AzRoleAssignmentRestMethod.ps1

[[ -n "${_EPAC_REST_RA_LOADED:-}" ]] && return 0
readonly _EPAC_REST_RA_LOADED=1

# ─── Get Role Assignments ───────────────────────────────────────────────────
# GET {scope}/providers/Microsoft.Authorization/roleAssignments?api-version=...
# Returns the .value array.

epac_get_role_assignments() {
    local scope="$1"
    local api_version="$2"
    local tenant_id="${3:-}"

    local uri="https://management.azure.com${scope}/providers/Microsoft.Authorization/roleAssignments?api-version=${api_version}"
    if [[ -n "$tenant_id" ]]; then
        uri+="&tenantId=${tenant_id}"
    fi

    local response
    response="$(epac_invoke_az_rest "GET" "$uri")" || {
        epac_log_error "Failed to get role assignments at scope '${scope}'"
        return 1
    }

    echo "$response" | jq '.value // []'
}

# ─── Set Role Assignment ────────────────────────────────────────────────────
# PUT for create/update of role assignments
# Handles delegated managed identity, ABAC conditions, and conflict detection.

epac_set_role_assignment() {
    local role_assignment_json="$1"
    local pac_environment_json="$2"
    local skip_delegated="${3:-false}"

    local api_version
    api_version="$(echo "$pac_environment_json" | jq -r '.apiVersions.roleAssignments // "2022-04-01"')"

    local ra_id
    ra_id="$(echo "$role_assignment_json" | jq -r '.id // empty')"

    local uri
    if [[ -n "$ra_id" ]]; then
        # Update existing
        uri="https://management.azure.com${ra_id}?api-version=${api_version}"
    else
        # Create new
        local scope
        scope="$(echo "$role_assignment_json" | jq -r '.scope')"
        local new_guid
        new_guid="$(epac_generate_guid)"
        uri="https://management.azure.com${scope}/providers/Microsoft.Authorization/roleAssignments/${new_guid}?api-version=${api_version}"
    fi

    # Build properties
    local properties
    properties="$(echo "$role_assignment_json" | jq '.properties')"

    # Add delegated managed identity resource ID if cross-tenant and not skipped
    local managed_tenant_id
    managed_tenant_id="$(echo "$pac_environment_json" | jq -r '.managedTenantId // empty')"
    if [[ -n "$managed_tenant_id" && "$skip_delegated" != "true" ]]; then
        local delegated_id
        delegated_id="$(echo "$role_assignment_json" | jq -r '.properties.principalId // empty')"
        if [[ -n "$delegated_id" ]]; then
            properties="$(echo "$properties" | jq --arg d "$delegated_id" '.delegatedManagedIdentityResourceId = $d')"
        fi
    fi

    local body
    body="$(jq -n --argjson p "$properties" '{properties: $p}')"

    local response
    if response="$(epac_invoke_az_rest "PUT" "$uri" "$body")"; then
        echo "$response"
        return 0
    fi

    local status="$EPAC_REST_STATUS_CODE"

    # 409 Conflict
    if [[ "$status" == "409" ]]; then
        if echo "$response" | grep -qi "ScopeLocked" 2>/dev/null; then
            epac_log_warning "Scope is locked, cannot create/update role assignment."
            return 1
        fi
        epac_log_warning "Role assignment already exists (ignore)."
        return 0
    fi

    # 403 Forbidden
    if [[ "$status" == "403" ]]; then
        if echo "$response" | grep -qi "ABAC condition" 2>/dev/null; then
            if [[ "$skip_delegated" != "true" ]]; then
                epac_log_warning "ABAC condition error, retrying without delegated identity..."
                epac_set_role_assignment "$role_assignment_json" "$pac_environment_json" "true"
                return $?
            fi
            epac_log_error "ABAC condition not fulfilled for role assignment."
            return 1
        fi
        epac_log_error "No authorization to create/update role assignment."
        return 1
    fi

    # 400 Bad Request — delegated identity issue
    if [[ "$status" == "400" ]]; then
        if echo "$response" | grep -qi "delegatedManagedIdentityResourceId" 2>/dev/null; then
            if [[ "$skip_delegated" != "true" ]]; then
                epac_log_warning "Delegated identity error, retrying without it..."
                epac_set_role_assignment "$role_assignment_json" "$pac_environment_json" "true"
                return $?
            fi
        fi
    fi

    epac_log_error "Failed to set role assignment: HTTP ${status}"
    return 1
}

# ─── Remove Role Assignment ─────────────────────────────────────────────────
# DELETE with pre-flight GET check.
# Handles cross-tenant scenarios and ScopeLocked.

epac_remove_role_assignment() {
    local role_assignment_id="$1"
    local api_version="$2"
    local tenant_id="${3:-}"
    local assignment_display_id="${4:-$role_assignment_id}"

    local uri="https://management.azure.com${role_assignment_id}?api-version=${api_version}"
    if [[ -n "$tenant_id" ]]; then
        uri+="&tenantId=${tenant_id}"
    fi

    # Pre-flight GET check
    local check_response
    if ! check_response="$(epac_invoke_az_rest "GET" "$uri")"; then
        local check_status="$EPAC_REST_STATUS_CODE"
        if [[ "$check_status" == "404" ]]; then
            epac_log_warning "Role assignment '${assignment_display_id}' already deleted (ignore)."
            return 0
        fi
        # If GET fails for other reasons, still try DELETE
    fi

    # Perform DELETE
    local response
    if response="$(epac_invoke_az_rest "DELETE" "$uri")"; then
        return 0
    fi

    local status="$EPAC_REST_STATUS_CODE"

    if [[ "$status" == "404" ]]; then
        epac_log_warning "Role assignment '${assignment_display_id}' already deleted (ignore)."
        return 0
    fi

    if echo "$response" | grep -qi "ScopeLocked" 2>/dev/null; then
        epac_log_warning "Scope is locked, cannot delete role assignment '${assignment_display_id}'."
        return 1
    fi

    epac_log_error "Failed to delete role assignment '${assignment_display_id}': HTTP ${status}"
    return 1
}
