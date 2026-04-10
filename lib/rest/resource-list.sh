#!/usr/bin/env bash
# lib/rest/resource-list.sh — Resource listing REST methods with pagination
# Replaces: Get-AzResourceListRestMethod.ps1

[[ -n "${_EPAC_REST_RL_LOADED:-}" ]] && return 0
readonly _EPAC_REST_RL_LOADED=1

# ─── Paginated GET helper ───────────────────────────────────────────────────
# Follows nextLink for Azure REST API pagination.
# Collects all .value arrays into a single JSON array.

_epac_rest_get_paginated() {
    local uri="$1"
    local collected="[]"

    while [[ -n "$uri" ]]; do
        local response
        if ! response="$(epac_invoke_az_rest "GET" "$uri")"; then
            epac_log_warning "Paginated GET failed for URI, returning partial results."
            break
        fi

        local values
        values="$(echo "$response" | jq '.value // []')"
        collected="$(jq -n --argjson c "$collected" --argjson v "$values" '$c + $v')"

        # Follow nextLink
        local next_link
        next_link="$(echo "$response" | jq -r '.nextLink // empty')"
        if [[ -n "$next_link" ]]; then
            uri="$next_link"
        else
            uri=""
        fi
    done

    echo "$collected"
}

# ─── Get Resource List ──────────────────────────────────────────────────────
# Lists all resources in a subscription with nested resource discovery.
# Discovers subnets, automation variables, APIM APIs.
# Optionally discovers custom role definitions.

epac_get_resource_list() {
    local subscription_id="$1"
    local check_custom_roles="${2:-false}"

    # 1. Get all resources in the subscription (paginated)
    local base_uri="https://management.azure.com/subscriptions/${subscription_id}/resources?api-version=2021-04-01"
    local resources
    resources="$(_epac_rest_get_paginated "$base_uri")"

    # 2. Discover subnets for each virtual network
    local vnets
    vnets="$(echo "$resources" | jq '[.[] | select(.type == "Microsoft.Network/virtualNetworks")]')"
    local vnet_count
    vnet_count="$(echo "$vnets" | jq 'length')"
    local i=0
    while [[ $i -lt $vnet_count ]]; do
        local vnet_id
        vnet_id="$(echo "$vnets" | jq -r --argjson i "$i" '.[$i].id')"
        local subnets_uri="https://management.azure.com${vnet_id}/subnets?api-version=2024-01-01"
        local subnets
        subnets="$(_epac_rest_get_paginated "$subnets_uri")"
        resources="$(jq -n --argjson r "$resources" --argjson s "$subnets" '$r + $s')"
        i=$((i + 1))
    done

    # 3. Discover automation account variables
    local auto_accounts
    auto_accounts="$(echo "$resources" | jq '[.[] | select(.type == "Microsoft.Automation/automationAccounts")]')"
    local aa_count
    aa_count="$(echo "$auto_accounts" | jq 'length')"
    i=0
    while [[ $i -lt $aa_count ]]; do
        local aa_id
        aa_id="$(echo "$auto_accounts" | jq -r --argjson i "$i" '.[$i].id')"
        local vars_uri="https://management.azure.com${aa_id}/variables?api-version=2023-11-01"
        local vars
        vars="$(_epac_rest_get_paginated "$vars_uri")"
        resources="$(jq -n --argjson r "$resources" --argjson v "$vars" '$r + $v')"
        i=$((i + 1))
    done

    # 4. Discover APIM APIs
    local apim_services
    apim_services="$(echo "$resources" | jq '[.[] | select(.type == "Microsoft.ApiManagement/service")]')"
    local apim_count
    apim_count="$(echo "$apim_services" | jq 'length')"
    i=0
    while [[ $i -lt $apim_count ]]; do
        local apim_id
        apim_id="$(echo "$apim_services" | jq -r --argjson i "$i" '.[$i].id')"
        local apis_uri="https://management.azure.com${apim_id}/apis?api-version=2024-05-01"
        local apis
        apis="$(_epac_rest_get_paginated "$apis_uri")"
        resources="$(jq -n --argjson r "$resources" --argjson a "$apis" '$r + $a')"
        i=$((i + 1))
    done

    # 5. Custom role definitions (optional)
    if [[ "$check_custom_roles" == "true" ]]; then
        local roles_uri="https://management.azure.com/subscriptions/${subscription_id}/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&\$filter=type%20eq%20%27CustomRole%27"
        local custom_roles
        custom_roles="$(_epac_rest_get_paginated "$roles_uri")"
        resources="$(jq -n --argjson r "$resources" --argjson cr "$custom_roles" '$r + $cr')"
    fi

    echo "$resources"
}
