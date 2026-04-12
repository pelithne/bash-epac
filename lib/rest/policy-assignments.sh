#!/usr/bin/env bash
# lib/rest/policy-assignments.sh — Policy assignment REST methods
# Replaces: Get-AzPolicyAssignmentRestMethod.ps1, Set-AzPolicyAssignmentRestMethod.ps1

[[ -n "${_EPAC_REST_PA_LOADED:-}" ]] && return 0
readonly _EPAC_REST_PA_LOADED=1

# ─── Get Policy Assignment ───────────────────────────────────────────────────
# GET {assignmentId}?api-version={apiVersion}

epac_get_policy_assignment() {
    local assignment_id="$1"
    local api_version="$2"

    local uri="https://management.azure.com${assignment_id}?api-version=${api_version}"

    local response
    response="$(epac_invoke_az_rest "GET" "$uri")" || {
        epac_log_error "Failed to get policy assignment '${assignment_id}'"
        return 1
    }

    echo "$response"
}

# ─── Set Policy Assignment ───────────────────────────────────────────────────
# PUT {assignmentId}?api-version={apiVersion}
# Handles parameter wrapping ({value: ...}) and optional fields.

epac_set_policy_assignment() {
    local assignment_json="$1"
    local api_version="$2"

    local assignment_id
    assignment_id="$(echo "$assignment_json" | jq -r '.id')"

    # Build the core properties (handle both flat plan format and nested .properties format)
    local properties
    properties="$(echo "$assignment_json" | jq '{
        policyDefinitionId: (.properties.policyDefinitionId // .policyDefinitionId),
        displayName: (.properties.displayName // .displayName),
        description: (.properties.description // .description),
        metadata: (.properties.metadata // .metadata),
        enforcementMode: (.properties.enforcementMode // .enforcementMode),
        notScopes: (.properties.notScopes // .notScopes)
    }')"

    # Transform parameters: wrap each value in {value: ...}
    local raw_params
    raw_params="$(echo "$assignment_json" | jq '(.properties.parameters // .parameters) // null')"
    if [[ "$raw_params" != "null" ]]; then
        local wrapped_params
        wrapped_params="$(echo "$raw_params" | jq 'to_entries | map({
            key: .key,
            value: (if (.value | type) == "object" and (.value | has("value")) then .value else {value: .value} end)
        }) | from_entries')"
        properties="$(echo "$properties" | jq --argjson p "$wrapped_params" '.parameters = $p')"
    fi

    # Add optional fields if present (handle both flat and nested formats)
    for field in nonComplianceMessages overrides resourceSelectors definitionVersion; do
        local field_val
        field_val="$(echo "$assignment_json" | jq --arg f "$field" '(.properties[$f] // .[$f]) // null')"
        if [[ "$field_val" != "null" ]]; then
            properties="$(echo "$properties" | jq --arg f "$field" --argjson v "$field_val" '.[$f] = $v')"
        fi
    done

    # Build body with identity and location if needed
    local body="{}"
    local identity
    identity="$(echo "$assignment_json" | jq '.identity // null')"
    if [[ "$identity" != "null" ]]; then
        body="$(echo "$body" | jq --argjson i "$identity" '.identity = $i')"
    fi

    local location
    location="$(echo "$assignment_json" | jq -r '.location // empty')"
    if [[ -n "$location" ]]; then
        body="$(echo "$body" | jq --arg l "$location" '.location = $l')"
    fi

    body="$(echo "$body" | jq --argjson p "$properties" '.properties = $p')"

    local uri="https://management.azure.com${assignment_id}?api-version=${api_version}"

    epac_log_debug "Setting policy assignment: ${assignment_id}"

    local response
    response="$(epac_invoke_az_rest "PUT" "$uri" "$body")" || {
        epac_log_error "Failed to set policy assignment '${assignment_id}'"
        epac_log_debug "Assignment body: $(echo "$body" | jq -c '.')"
        return 1
    }

    echo "$response"
}
