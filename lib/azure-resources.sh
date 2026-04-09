#!/usr/bin/env bash
# lib/azure-resources.sh — Resource Graph queries, scope table building,
#   policy resource collection, and ownership determination
# Replaces: Search-AzGraphAllItems.ps1, Build-ScopeTableFor*.ps1,
#   Get-AzPolicyResources.ps1, Get-AzPolicyOrSetDefinitions.ps1,
#   Get-AzPolicyAssignments.ps1, Get-AzPolicyExemptions.ps1,
#   Get-AzPolicyResourcesDetails.ps1, Convert-PolicyResourcesToDetails.ps1,
#   Find-AzNonCompliantResources.ps1, Confirm-PolicyResourceExclusions.ps1,
#   Confirm-PacOwner.ps1, Get-PolicyResourceProperties.ps1

[[ -n "${_EPAC_AZ_RESOURCES_LOADED:-}" ]] && return 0
readonly _EPAC_AZ_RESOURCES_LOADED=1

_EPAC_LIB_DIR="${BASH_SOURCE[0]%/*}"
source "${_EPAC_LIB_DIR}/core.sh"
source "${_EPAC_LIB_DIR}/json.sh"
source "${_EPAC_LIB_DIR}/utils.sh"
source "${_EPAC_LIB_DIR}/output.sh"
source "${_EPAC_LIB_DIR}/azure-auth.sh"
source "${_EPAC_LIB_DIR}/config.sh"

###############################################################################
# Section 1: Resource Graph
###############################################################################

# ─── Search Azure Resource Graph with pagination ─────────────────────────────
# Replaces Search-AzGraphAllItems.ps1
# POST /providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01
# Handles skip tokens, ResponsePayloadTooLarge errors, retries.

epac_search_az_graph() {
    local query="$1"
    local progress_item="${2:-items}"
    local progress_increment="${3:-1000}"
    local scope_type="${4:-tenant}"       # "tenant" | "managementGroup" | "subscription"
    local scope_value="${5:-}"            # MG name or subscription ID

    local api_version="2022-10-01"
    local uri="https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=${api_version}"

    local collected="[]"
    local skip_token=""
    local total_count=0
    local retry_count=0
    local max_retries=5

    while true; do
        # Build request body
        local body
        body="$(jq -n --arg q "$query" --argjson top "$progress_increment" '{query: $q, options: {$top: $top}}')"

        # Add skip token if continuing pagination
        if [[ -n "$skip_token" ]]; then
            body="$(echo "$body" | jq --arg st "$skip_token" '.options["$skipToken"] = $st')"
        fi

        # Add scope
        case "$scope_type" in
            managementGroup)
                body="$(echo "$body" | jq --arg mg "$scope_value" '.managementGroups = [$mg]')"
                ;;
            subscription)
                body="$(echo "$body" | jq --arg sub "$scope_value" '.subscriptions = [$sub]')"
                ;;
            *)
                # Tenant scope — no scoping needed
                ;;
        esac

        local response
        if ! response="$(epac_invoke_az_rest "POST" "$uri" "$body")"; then
            local status="$EPAC_REST_STATUS_CODE"

            # Handle ResponsePayloadTooLarge by halving batch size
            if echo "$response" | grep -qi "ResponsePayloadTooLarge" 2>/dev/null; then
                progress_increment=$((progress_increment / 2))
                if [[ $progress_increment -lt 10 ]]; then
                    epac_log_error "Resource Graph query failed: payload too large even with batch size 10"
                    echo "[]"
                    return 1
                fi
                epac_log_warning "Payload too large, reducing batch size to ${progress_increment}"
                continue
            fi

            # Retry on transient errors
            retry_count=$((retry_count + 1))
            if [[ $retry_count -le $max_retries ]]; then
                epac_log_warning "Resource Graph query failed, retrying (${retry_count}/${max_retries})..."
                sleep "$((retry_count * 2))"
                continue
            fi

            epac_log_error "Resource Graph query failed after ${max_retries} retries"
            echo "$collected"
            return 1
        fi

        # Reset retry count on success
        retry_count=0

        # Extract data rows
        local data
        data="$(echo "$response" | jq '.data // []')"
        local data_type
        data_type="$(echo "$data" | jq -r 'type')"

        # Resource Graph can return data as array or as {columns,rows} table
        if [[ "$data_type" == "object" ]]; then
            # Table format — convert to array of objects
            local rows
            rows="$(echo "$data" | jq '
                .columns as $cols |
                [.rows[]? | . as $row |
                    [$cols | to_entries[] | {key: .value.name, value: $row[.key]}] | from_entries
                ]
            ')"
            collected="$(jq -n --argjson c "$collected" --argjson r "$rows" '$c + $r')"
            total_count=$((total_count + $(echo "$rows" | jq 'length')))
        elif [[ "$data_type" == "array" ]]; then
            collected="$(jq -n --argjson c "$collected" --argjson d "$data" '$c + $d')"
            total_count=$((total_count + $(echo "$data" | jq 'length')))
        fi

        # Check for skip token
        skip_token="$(echo "$response" | jq -r '."$skipToken" // .skipToken // empty')"
        if [[ -z "$skip_token" ]]; then
            break
        fi

        # Progress
        if [[ $((total_count % (progress_increment * 5))) -eq 0 ]]; then
            epac_log_info "Collected ${total_count} ${progress_item}..."
        fi
    done

    epac_log_debug "Resource Graph: collected ${total_count} ${progress_item}"
    echo "$collected"
}

###############################################################################
# Section 2: Helper functions
###############################################################################

# ─── Get Policy Resource Properties ──────────────────────────────────────────
# Returns .properties if it exists, otherwise the object itself.

epac_get_policy_resource_properties() {
    local resource="$1"
    local has_props
    has_props="$(echo "$resource" | jq 'has("properties")')"
    if [[ "$has_props" == "true" ]]; then
        echo "$resource" | jq '.properties'
    else
        echo "$resource"
    fi
}

# ─── Confirm PAC Owner ──────────────────────────────────────────────────────
# Determines who owns a policy resource.
# Returns: "thisPaC" | "otherPaC" | "microsoft" | "managedByDfcSecurityPolicies"
#          | "managedByDfcDefenderPlans" | "unknownOwner"

epac_confirm_pac_owner() {
    local pac_owner_id="$1"
    local policy_resource="$2"
    local scope="${3:-}"

    local properties
    properties="$(epac_get_policy_resource_properties "$policy_resource")"

    # SystemHidden → microsoft
    local assignment_type
    assignment_type="$(echo "$properties" | jq -r '.assignmentType // empty')"
    if [[ "$assignment_type" == "SystemHidden" ]]; then
        echo "microsoft"
        return
    fi

    # Check metadata.pacOwnerId
    local resource_owner_id
    resource_owner_id="$(echo "$properties" | jq -r '.metadata.pacOwnerId // empty')"

    if [[ -z "$resource_owner_id" ]]; then
        # No owner — check for DfC patterns
        local description
        description="$(echo "$properties" | jq -r '.description // empty')"
        local description_lower="${description,,}"

        if [[ -n "$scope" ]]; then
            local scope_lower="${scope,,}"
            if [[ "$scope_lower" == /subscriptions/* && "$scope_lower" != */resourcegroups/* ]]; then
                local def_id
                def_id="$(echo "$properties" | jq -r '.policyDefinitionId // empty')"
                local def_lower="${def_id,,}"
                if [[ "$def_lower" == */providers/microsoft.authorization/policy*definitions/* ]]; then
                    if [[ "$description_lower" == *"this object has been generated by microsoft defender"* ]]; then
                        echo "managedByDfcSecurityPolicies"
                        return
                    fi
                    if [[ "$description_lower" == *"this policy assignment was automatically created"* ]]; then
                        echo "managedByDfcDefenderPlans"
                        return
                    fi
                fi
            fi
        fi

        echo "unknownOwner"
        return
    fi

    if [[ "$resource_owner_id" == "$pac_owner_id" ]]; then
        echo "thisPaC"
    else
        echo "otherPaC"
    fi
}

# ─── Confirm Policy Resource Exclusions ──────────────────────────────────────
# Checks if a resource should be included based on scope table, excluded scopes,
# and excluded IDs. Returns "true" or "false" on stdout.

epac_confirm_policy_resource_exclusions() {
    local test_id="$1"
    local resource_id="$2"
    local scope_table="$3"               # JSON object keyed by scope ID
    local excluded_scopes_table="$4"      # JSON array of excluded scope IDs
    local excluded_ids="${5:-[]}"          # JSON array of excluded resource IDs (wildcard patterns)

    # Parse the resource ID to get scope info
    local resource_parts
    resource_parts="$(epac_split_policy_resource_id "$test_id")"
    local scope
    scope="$(echo "$resource_parts" | jq -r '.scope')"

    # Built-in resources (empty scope, starts with /providers/) are always included
    if [[ -z "$scope" ]]; then
        echo "true"
        return
    fi

    # Check if scope is in scope table
    local in_scope
    in_scope="$(echo "$scope_table" | jq --arg s "$scope" 'has($s)')"
    if [[ "$in_scope" != "true" ]]; then
        echo "false"
        return
    fi

    # Check if scope is excluded
    local is_excluded
    is_excluded="$(echo "$excluded_scopes_table" | jq --arg s "$scope" 'any(. == $s)')"
    if [[ "$is_excluded" == "true" ]]; then
        echo "false"
        return
    fi

    # Check excluded IDs (wildcard matching)
    local test_id_lower="${test_id,,}"
    local exc_count
    exc_count="$(echo "$excluded_ids" | jq 'length')"
    local i=0
    while [[ $i -lt $exc_count ]]; do
        local pattern
        pattern="$(echo "$excluded_ids" | jq -r --argjson i "$i" '.[$i]')"
        local pattern_lower="${pattern,,}"
        # Simple wildcard: convert * to regex .*
        local regex="${pattern_lower//\*/.*}"
        if [[ "$test_id_lower" =~ ^${regex}$ ]]; then
            echo "false"
            return
        fi
        i=$((i + 1))
    done

    echo "true"
}

###############################################################################
# Section 3: Scope Table Building
###############################################################################

# ─── Build scope details object ──────────────────────────────────────────────

_epac_new_scope_details() {
    local id="$1"
    local type="$2"
    local name="$3"
    local display_name="${4:-$name}"
    local is_excluded="${5:-false}"
    local is_in_global_not_scope="${6:-false}"
    local state="${7:-Enabled}"
    local location="${8:-global}"

    jq -n \
        --arg id "$id" \
        --arg type "$type" \
        --arg name "$name" \
        --arg dn "$display_name" \
        --argjson ex "$is_excluded" \
        --argjson gns "$is_in_global_not_scope" \
        --arg st "$state" \
        --arg loc "$location" \
        '{
            id: $id,
            type: $type,
            name: $name,
            displayName: $dn,
            parentTable: {},
            childrenTable: {},
            resourceGroupsTable: {},
            notScopesList: [],
            notScopesTable: {},
            excludedScopesTable: {},
            isExcluded: $ex,
            isInGlobalNotScope: $gns,
            state: $st,
            location: $loc
        }'
}

# ─── Check if scope matches any pattern in a list ────────────────────────────

_epac_scope_matches_list() {
    local scope="$1"
    local pattern_list="$2"    # JSON array of scope ID patterns
    local scope_lower="${scope,,}"

    local count
    count="$(echo "$pattern_list" | jq 'length')"
    local i=0
    while [[ $i -lt $count ]]; do
        local pattern
        pattern="$(echo "$pattern_list" | jq -r --argjson i "$i" '.[$i]')"
        local pattern_lower="${pattern,,}"
        if [[ "$scope_lower" == "$pattern_lower" ]]; then
            echo "true"
            return
        fi
        i=$((i + 1))
    done
    echo "false"
}

# ─── Build scope table for a subscription ────────────────────────────────────

_epac_build_scope_table_subscription() {
    local sub_id="$1"
    local sub_name="$2"
    local rg_by_sub="$3"          # JSON: { subId: [{id, name, ...}] }
    local pac_environment="$4"    # JSON
    local scope_table="$5"        # JSON
    local is_excluded="${6:-false}"
    local is_in_gns="${7:-false}"
    local _empty_obj='{}'
    local parent_table="${8:-$_empty_obj}"

    local scope="/subscriptions/${sub_id}"

    # Check desiredState.excludeSubscriptions
    local exclude_subs
    exclude_subs="$(echo "$pac_environment" | jq -r '.desiredState.excludeSubscriptions // false')"
    if [[ "$exclude_subs" == "true" ]]; then
        is_excluded="true"
    fi

    # Check globalNotScopesSubscriptions
    local gns_subs
    gns_subs="$(echo "$pac_environment" | jq '.globalNotScopesSubscriptions // []')"
    if [[ "$(_epac_scope_matches_list "$scope" "$gns_subs")" == "true" ]]; then
        is_in_gns="true"
    fi

    # Check globalExcludedScopesSubscriptions
    local excluded_subs
    excluded_subs="$(echo "$pac_environment" | jq '.desiredState.globalExcludedScopesSubscriptions // []')"
    if [[ "$(_epac_scope_matches_list "$scope" "$excluded_subs")" == "true" ]]; then
        is_excluded="true"
    fi

    local scope_details
    scope_details="$(_epac_new_scope_details "$scope" "Microsoft.Resources/subscriptions" "$sub_id" "$sub_name" "$is_excluded" "$is_in_gns")"
    scope_details="$(echo "$scope_details" | jq --argjson p "$parent_table" '.parentTable = $p')"

    # Process resource groups
    local rgs
    rgs="$(echo "$rg_by_sub" | jq --arg s "$sub_id" '.[$s] // []')"
    local rg_count
    rg_count="$(echo "$rgs" | jq 'length')"
    local ri=0
    local rg_table="{}"
    while [[ $ri -lt $rg_count ]]; do
        local rg
        rg="$(echo "$rgs" | jq --argjson i "$ri" '.[$i]')"
        local rg_id
        rg_id="$(echo "$rg" | jq -r '.id')"
        local rg_name
        rg_name="$(echo "$rg" | jq -r '.name')"
        local rg_location
        rg_location="$(echo "$rg" | jq -r '.location // "global"')"

        local rg_excluded="$is_excluded"
        local rg_gns="$is_in_gns"

        # Check globalNotScopesResourceGroups
        local gns_rgs
        gns_rgs="$(echo "$pac_environment" | jq '.globalNotScopesResourceGroups // []')"
        if [[ "$(_epac_scope_matches_list "$rg_id" "$gns_rgs")" == "true" ]]; then
            rg_gns="true"
        fi

        # Check globalExcludedScopesResourceGroups
        local excluded_rgs
        excluded_rgs="$(echo "$pac_environment" | jq '.desiredState.globalExcludedScopesResourceGroups // []')"
        if [[ "$(_epac_scope_matches_list "$rg_id" "$excluded_rgs")" == "true" ]]; then
            rg_excluded="true"
        fi

        local rg_parent_table
        rg_parent_table="$(jq -n --arg s "$scope" '{($s): true}')"
        rg_parent_table="$(jq -n --argjson p "$parent_table" --argjson r "$rg_parent_table" '$p + $r')"

        local rg_scope_details
        rg_scope_details="$(_epac_new_scope_details "$rg_id" "microsoft.resources/subscriptions/resourcegroups" "$rg_name" "$rg_name" "$rg_excluded" "$rg_gns" "Enabled" "$rg_location")"
        rg_scope_details="$(echo "$rg_scope_details" | jq --argjson p "$rg_parent_table" '.parentTable = $p')"

        scope_table="$(echo "$scope_table" | jq --arg k "$rg_id" --argjson v "$rg_scope_details" '.[$k] = $v')"
        rg_table="$(echo "$rg_table" | jq --arg k "$rg_id" '.[$k] = true')"

        ri=$((ri + 1))
    done

    scope_details="$(echo "$scope_details" | jq --argjson rgt "$rg_table" '.resourceGroupsTable = $rgt')"
    scope_table="$(echo "$scope_table" | jq --arg k "$scope" --argjson v "$scope_details" '.[$k] = $v')"

    echo "$scope_table"
}

# ─── Build scope table for a management group (recursive) ────────────────────

_epac_build_scope_table_mg() {
    local mg_json="$1"           # MG REST response 
    local rg_by_sub="$2"
    local pac_environment="$3"
    local scope_table="$4"
    local is_excluded="${5:-false}"
    local is_in_gns="${6:-false}"
    local _empty_obj='{}'
    local parent_table="${7:-$_empty_obj}"

    # Extract MG details (handle both .properties.displayName and direct .displayName)
    local mg_name
    mg_name="$(echo "$mg_json" | jq -r '.name // .properties.displayName // empty')"
    local mg_display_name
    mg_display_name="$(echo "$mg_json" | jq -r '.properties.displayName // .displayName // .name // empty')"
    local mg_id
    mg_id="$(echo "$mg_json" | jq -r '.id // empty')"

    if [[ -z "$mg_id" ]]; then
        mg_id="/providers/Microsoft.Management/managementGroups/${mg_name}"
    fi

    # Check globalNotScopesManagementGroups
    local gns_mgs
    gns_mgs="$(echo "$pac_environment" | jq '.globalNotScopesManagementGroups // []')"
    if [[ "$(_epac_scope_matches_list "$mg_id" "$gns_mgs")" == "true" ]]; then
        is_in_gns="true"
    fi

    # Check globalExcludedScopesManagementGroups
    local excluded_mgs
    excluded_mgs="$(echo "$pac_environment" | jq '.desiredState.globalExcludedScopesManagementGroups // []')"
    if [[ "$(_epac_scope_matches_list "$mg_id" "$excluded_mgs")" == "true" ]]; then
        is_excluded="true"
    fi

    local scope_details
    scope_details="$(_epac_new_scope_details "$mg_id" "Microsoft.Management/managementGroups" "$mg_name" "$mg_display_name" "$is_excluded" "$is_in_gns")"
    scope_details="$(echo "$scope_details" | jq --argjson p "$parent_table" '.parentTable = $p')"

    local children_table="{}"
    local new_parent_table
    new_parent_table="$(jq -n --arg s "$mg_id" --argjson p "$parent_table" '$p + {($s): true}')"

    # Process children
    local children
    children="$(echo "$mg_json" | jq '.properties.children // .children // []')"
    local child_count
    child_count="$(echo "$children" | jq 'length')"
    local ci=0
    while [[ $ci -lt $child_count ]]; do
        local child
        child="$(echo "$children" | jq --argjson i "$ci" '.[$i]')"
        local child_type
        child_type="$(echo "$child" | jq -r '.type // empty')"
        local child_type_lower="${child_type,,}"

        if [[ "$child_type_lower" == *"subscriptions"* ]]; then
            local child_id
            child_id="$(echo "$child" | jq -r '.name // empty')"
            local child_display
            child_display="$(echo "$child" | jq -r '.displayName // .name // empty')"
            scope_table="$(_epac_build_scope_table_subscription "$child_id" "$child_display" "$rg_by_sub" "$pac_environment" "$scope_table" "$is_excluded" "$is_in_gns" "$new_parent_table")"
            children_table="$(echo "$children_table" | jq --arg k "/subscriptions/${child_id}" '.[$k] = true')"
        elif [[ "$child_type_lower" == *"managementgroups"* ]]; then
            scope_table="$(_epac_build_scope_table_mg "$child" "$rg_by_sub" "$pac_environment" "$scope_table" "$is_excluded" "$is_in_gns" "$new_parent_table")"
            local child_mg_id
            child_mg_id="$(echo "$child" | jq -r '.id // empty')"
            children_table="$(echo "$children_table" | jq --arg k "$child_mg_id" '.[$k] = true')"
        fi

        ci=$((ci + 1))
    done

    scope_details="$(echo "$scope_details" | jq --argjson ct "$children_table" '.childrenTable = $ct')"
    scope_table="$(echo "$scope_table" | jq --arg k "$mg_id" --argjson v "$scope_details" '.[$k] = $v')"

    echo "$scope_table"
}

# ─── Build scope table for deployment root scope ─────────────────────────────
# Replaces Build-ScopeTableForDeploymentRootScope.ps1
# Entry point: resolves root scope, collects RGs, builds hierarchy.
# Outputs JSON scope table to stdout.

epac_build_scope_table() {
    local pac_environment="$1"    # JSON pac environment definition

    local deployment_root_scope
    deployment_root_scope="$(echo "$pac_environment" | jq -r '.deploymentRootScope')"

    epac_write_section "Building Scope Table" 0 >&2
    epac_write_status "Root scope: ${deployment_root_scope}" "info" 2 >&2

    local scope_parts
    scope_parts="$(epac_split_scope_id "$deployment_root_scope")"
    local scope_type
    scope_type="$(echo "$scope_parts" | jq -r '.type')"

    local scope_splat_type scope_splat_value
    case "$scope_type" in
        managementGroup)
            local mg_name
            mg_name="$(echo "$scope_parts" | jq -r '.name')"
            scope_splat_type="managementGroup"
            scope_splat_value="$mg_name"
            ;;
        subscription)
            local sub_id
            sub_id="$(echo "$scope_parts" | jq -r '.id')"
            scope_splat_type="subscription"
            scope_splat_value="$sub_id"
            ;;
        *)
            epac_die "Deployment root scope must be a management group or subscription, got: ${scope_type}"
            ;;
    esac

    # Collect resource groups via Resource Graph
    epac_write_status "Collecting resource groups..." "info" 2 >&2
    local rg_query="resourcecontainers | where type == 'microsoft.resources/subscriptions/resourcegroups'"
    local rgs
    rgs="$(epac_search_az_graph "$rg_query" "resource groups" 1000 "$scope_splat_type" "$scope_splat_value")"

    # Group resource groups by subscription ID
    local rg_by_sub
    rg_by_sub="$(echo "$rgs" | jq 'group_by(.subscriptionId) | map({key: .[0].subscriptionId, value: .}) | from_entries')"

    epac_write_status "Found $(echo "$rgs" | jq 'length') resource groups" "success" 2 >&2

    # Build scope table
    local scope_table="{}"

    if [[ "$scope_type" == "subscription" ]]; then
        local sub_name
        sub_name="$(az account show --subscription "$scope_splat_value" --query name -o tsv 2>/dev/null)" || sub_name="$scope_splat_value"
        scope_table="$(_epac_build_scope_table_subscription "$scope_splat_value" "$sub_name" "$rg_by_sub" "$pac_environment" "$scope_table")"
    else
        # Get management group hierarchy
        local mg_hierarchy
        mg_hierarchy="$(epac_get_management_group "$mg_name" "true" "true")" || \
            epac_die "Failed to get management group hierarchy for '${mg_name}'"
        scope_table="$(_epac_build_scope_table_mg "$mg_hierarchy" "$rg_by_sub" "$pac_environment" "$scope_table")"
    fi

    # Add root entry
    scope_table="$(echo "$scope_table" | jq --arg root "$deployment_root_scope" '.root = $root')"

    local scope_count
    scope_count="$(echo "$scope_table" | jq 'keys | length')"
    epac_write_status "Scope table built: ${scope_count} entries" "success" 2 >&2

    echo "$scope_table"
}

# ─── Categorize role assignment scopes by type ───────────────────────────────
# Replaces Set-UniqueRoleAssignmentScopes.ps1
# Adds a scope ID to the appropriate scope-type bucket.
# Input/output: JSON { subscriptions:{}, managementGroups:{}, resourceGroups:{}, resources:{}, unknown:{} }

epac_set_unique_role_assignment_scopes() {
    local scope_id="$1"
    local scopes_json="$2"

    local IFS='/'
    read -ra segments <<< "$scope_id"
    local count=${#segments[@]}

    local scope_type
    case $count in
        3) scope_type="subscriptions" ;;
        5) scope_type="${segments[3]}" ;;
        *) if [[ $count -gt 5 ]]; then scope_type="resources"; else scope_type="unknown"; fi ;;
    esac

    echo "$scopes_json" | jq --arg t "$scope_type" --arg id "$scope_id" '.[$t][$id] = $t'
}

###############################################################################
# Section 4: Policy Resource Collection
###############################################################################

# ─── Collect policy or set definitions ───────────────────────────────────────
# Replaces Get-AzPolicyOrSetDefinitions.ps1
# Queries Resource Graph for policy[Set]Definitions and categorizes them.

epac_get_policy_or_set_definitions() {
    local definition_type="$1"       # "policyDefinitions" or "policySetDefinitions"
    local pac_environment="$2"       # JSON
    local scope_table="$3"           # JSON

    local az_type
    if [[ "$definition_type" == "policyDefinitions" ]]; then
        az_type="microsoft.authorization/policydefinitions"
    else
        az_type="microsoft.authorization/policysetdefinitions"
    fi

    local increment=1000
    [[ "$definition_type" == "policySetDefinitions" ]] && increment=250

    epac_write_status "Collecting ${definition_type}..." "info" 2 >&2

    local query="PolicyResources | where type == '${az_type}'"
    local all_defs
    all_defs="$(epac_search_az_graph "$query" "$definition_type" "$increment")"

    local pac_owner_id
    pac_owner_id="$(echo "$pac_environment" | jq -r '.pacOwnerId')"
    local tenant_id
    tenant_id="$(echo "$pac_environment" | jq -r '.tenantId')"
    local deployment_root_scope
    deployment_root_scope="$(echo "$pac_environment" | jq -r '.deploymentRootScope')"
    local policy_defs_scopes
    policy_defs_scopes="$(echo "$pac_environment" | jq '.policyDefinitionsScopes // []')"
    local excluded_scopes
    excluded_scopes="$(echo "$pac_environment" | jq '.desiredState.excludedScopes // []')"
    local excluded_ids="[]"
    if [[ "$definition_type" == "policyDefinitions" ]]; then
        excluded_ids="$(echo "$pac_environment" | jq '.desiredState.excludedPolicyDefinitions // []')"
    else
        excluded_ids="$(echo "$pac_environment" | jq '.desiredState.excludedPolicySetDefinitions // []')"
    fi

    # Result structure
    local result
    result="$(jq -n '{
        all: {},
        readOnly: {},
        managed: {},
        counters: {
            builtIn: 0,
            inherited: 0,
            managedBy: { thisPaC: 0, otherPaC: 0, unknown: 0 },
            excluded: 0,
            unmanagedScopes: 0
        }
    }')"

    local def_count
    def_count="$(echo "$all_defs" | jq 'length')"
    local di=0
    while [[ $di -lt $def_count ]]; do
        local resource
        resource="$(echo "$all_defs" | jq --argjson i "$di" '.[$i]')"
        local resource_id
        resource_id="$(echo "$resource" | jq -r '.id')"

        # Validate tenant
        local res_tenant
        res_tenant="$(echo "$resource" | jq -r '.tenantId // empty')"
        if [[ -n "$res_tenant" && "$res_tenant" != "$tenant_id" ]]; then
            di=$((di + 1))
            continue
        fi

        # Check exclusions
        local included
        included="$(epac_confirm_policy_resource_exclusions "$resource_id" "$resource_id" "$scope_table" "$excluded_scopes" "$excluded_ids")"
        if [[ "$included" != "true" ]]; then
            result="$(echo "$result" | jq '.counters.excluded += 1')"
            di=$((di + 1))
            continue
        fi

        # Determine pac owner
        local pac_owner
        pac_owner="$(epac_confirm_pac_owner "$pac_owner_id" "$resource")"

        # Categorize by scope
        local resource_parts
        resource_parts="$(epac_split_policy_resource_id "$resource_id")"
        local scope_type_r
        scope_type_r="$(echo "$resource_parts" | jq -r '.scopeType')"

        if [[ "$scope_type_r" == "builtin" ]]; then
            result="$(echo "$result" | jq --arg id "$resource_id" --argjson r "$resource" '.all[$id] = $r | .readOnly[$id] = $r | .counters.builtIn += 1')"
        else
            local scope_r
            scope_r="$(echo "$resource_parts" | jq -r '.scope')"
            local scope_lower_r="${scope_r,,}"
            local root_lower="${deployment_root_scope,,}"

            if [[ "$scope_lower_r" == "$root_lower" ]]; then
                # Managed scope
                result="$(echo "$result" | jq --arg id "$resource_id" --argjson r "$resource" --arg o "$pac_owner" '
                    .all[$id] = $r | .managed[$id] = $r | .counters.managedBy[$o] += 1')"
            else
                # Read-only or inherited
                result="$(echo "$result" | jq --arg id "$resource_id" --argjson r "$resource" '.all[$id] = $r | .readOnly[$id] = $r | .counters.inherited += 1')"
            fi
        fi

        di=$((di + 1))
    done

    epac_write_status "${definition_type}: $(echo "$result" | jq '.all | length') total" "success" 2 >&2
    echo "$result"
}

# ─── Collect policy assignments ──────────────────────────────────────────────
# Replaces Get-AzPolicyAssignments.ps1

epac_get_policy_assignments() {
    local pac_environment="$1"       # JSON
    local scope_table="$2"           # JSON
    local skip_role_assignments="${3:-false}"

    local pac_owner_id
    pac_owner_id="$(echo "$pac_environment" | jq -r '.pacOwnerId')"
    local tenant_id
    tenant_id="$(echo "$pac_environment" | jq -r '.tenantId')"
    local cloud
    cloud="$(echo "$pac_environment" | jq -r '.cloud')"
    local excluded_scopes
    excluded_scopes="$(echo "$pac_environment" | jq '.desiredState.excludedScopes // []')"
    local excluded_ids
    excluded_ids="$(echo "$pac_environment" | jq '.desiredState.excludedPolicyAssignments // []')"

    epac_write_status "Collecting policy assignments..." "info" 2 >&2

    local query="PolicyResources | where type == 'microsoft.authorization/policyassignments'"
    local all_assignments
    all_assignments="$(epac_search_az_graph "$query" "policy assignments" 1000)"

    local result
    result="$(jq -n '{
        managed: {},
        counters: {
            managedBy: {
                thisPaC: 0,
                otherPaC: 0,
                microsoft: 0,
                dfcSecurityPolicies: 0,
                dfcDefenderPlans: 0,
                unknown: 0
            },
            excluded: 0,
            unmanagedScopes: 0
        }
    }')"

    local principal_ids="[]"
    local assignment_count
    assignment_count="$(echo "$all_assignments" | jq 'length')"
    local ai=0

    while [[ $ai -lt $assignment_count ]]; do
        local resource
        resource="$(echo "$all_assignments" | jq --argjson i "$ai" '.[$i]')"
        local resource_id
        resource_id="$(echo "$resource" | jq -r '.id')"

        # Validate tenant
        local res_tenant
        res_tenant="$(echo "$resource" | jq -r '.tenantId // empty')"
        if [[ -n "$res_tenant" && "$res_tenant" != "$tenant_id" ]]; then
            ai=$((ai + 1))
            continue
        fi

        # Check exclusions
        local included
        included="$(epac_confirm_policy_resource_exclusions "$resource_id" "$resource_id" "$scope_table" "$excluded_scopes" "$excluded_ids")"
        if [[ "$included" != "true" ]]; then
            result="$(echo "$result" | jq '.counters.excluded += 1')"
            ai=$((ai + 1))
            continue
        fi

        # Parse scope
        local resource_parts
        resource_parts="$(epac_split_policy_resource_id "$resource_id")"
        local scope
        scope="$(echo "$resource_parts" | jq -r '.scope')"

        # Determine owner
        local pac_owner
        pac_owner="$(epac_confirm_pac_owner "$pac_owner_id" "$resource" "$scope")"

        # Map owner to counter key
        local counter_key
        case "$pac_owner" in
            thisPaC)                         counter_key="thisPaC" ;;
            otherPaC)                        counter_key="otherPaC" ;;
            microsoft)                       counter_key="microsoft" ;;
            managedByDfcSecurityPolicies)     counter_key="dfcSecurityPolicies" ;;
            managedByDfcDefenderPlans)        counter_key="dfcDefenderPlans" ;;
            *)                               counter_key="unknown" ;;
        esac

        result="$(echo "$result" | jq --arg id "$resource_id" --argjson r "$resource" --arg ck "$counter_key" '
            .managed[$id] = $r | .counters.managedBy[$ck] += 1')"

        # Track principal IDs for role assignment lookup
        local principal_id
        principal_id="$(echo "$resource" | jq -r '.identity.principalId // empty')"
        if [[ -n "$principal_id" ]]; then
            principal_ids="$(echo "$principal_ids" | jq --arg p "$principal_id" 'if any(. == $p) then . else . + [$p] end')"
        fi

        ai=$((ai + 1))
    done

    epac_write_status "Policy assignments: $(echo "$result" | jq '.managed | length') collected" "success" 2 >&2

    # Collect role assignments if not skipped
    local role_assignments="{}"
    local role_definitions="{}"

    if [[ "$skip_role_assignments" != "true" ]]; then
        local pid_count
        pid_count="$(echo "$principal_ids" | jq 'length')"
        if [[ $pid_count -gt 0 ]]; then
            local cloud_lower="${cloud,,}"

            if [[ "$cloud_lower" != "azurechinacloud" && "$cloud_lower" != "azureusgovernment" ]]; then
                # Use Resource Graph for role assignments (most clouds)
                local pid_list
                pid_list="$(echo "$principal_ids" | jq -r '[.[] | "\"" + . + "\""] | join(",")')"
                local ra_query="authorizationresources | where type == \"microsoft.authorization/roleassignments\" and properties.principalId in (${pid_list})"
                local ra_results
                ra_results="$(epac_search_az_graph "$ra_query" "role assignments" 1000)"

                # Role definitions
                local rd_query="authorizationresources | where type == \"microsoft.authorization/roledefinitions\""
                local rd_results
                rd_results="$(epac_search_az_graph "$rd_query" "role definitions" 1000)"

                role_definitions="$(echo "$rd_results" | jq '[.[] | {key: .id, value: .}] | from_entries')"
                role_assignments="$(echo "$ra_results" | jq 'group_by(.properties.principalId) | map({key: .[0].properties.principalId, value: .}) | from_entries')"
            else
                epac_write_status "China/USGov: using REST for role assignments (slower)" "warning" 2 >&2
                # Fallback to REST for restricted clouds
            fi
        fi
    fi

    # Build combined result
    jq -n \
        --argjson assignments "$result" \
        --argjson roleAssignments "$role_assignments" \
        --argjson roleDefinitions "$role_definitions" \
        '$assignments + {roleAssignmentsByPrincipalId: $roleAssignments, roleDefinitions: $roleDefinitions}'
}

# ─── Collect policy exemptions ───────────────────────────────────────────────
# Replaces Get-AzPolicyExemptions.ps1

epac_get_policy_exemptions() {
    local pac_environment="$1"
    local scope_table="$2"

    local pac_owner_id
    pac_owner_id="$(echo "$pac_environment" | jq -r '.pacOwnerId')"
    local tenant_id
    tenant_id="$(echo "$pac_environment" | jq -r '.tenantId')"
    local cloud
    cloud="$(echo "$pac_environment" | jq -r '.cloud')"
    local excluded_scopes
    excluded_scopes="$(echo "$pac_environment" | jq '.desiredState.excludedScopes // []')"

    epac_write_status "Collecting policy exemptions..." "info" 2 >&2

    local all_exemptions
    local cloud_lower="${cloud,,}"

    if [[ "$cloud_lower" == "azurechinacloud" ]]; then
        # China Cloud: per-scope REST calls
        all_exemptions="[]"
        local scopes
        scopes="$(echo "$scope_table" | jq -r 'keys[] | select(. != "root")')"
        while IFS= read -r scope_id; do
            [[ -z "$scope_id" ]] && continue
            local scope_type_val
            scope_type_val="$(echo "$scope_table" | jq -r --arg s "$scope_id" '.[$s].type // empty')"
            local api_version
            api_version="$(echo "$pac_environment" | jq -r '.apiVersions.policyExemptions // "2022-07-01-preview"')"
            local filter=""
            local st_lower="${scope_type_val,,}"
            if [[ "$st_lower" == *"managementgroups"* ]]; then
                filter="atScope()"
            fi
            local scope_exemptions
            if scope_exemptions="$(epac_get_policy_exemptions_rest "$scope_id" "$api_version" "$filter" 2>/dev/null)"; then
                all_exemptions="$(jq -n --argjson e "$all_exemptions" --argjson s "$scope_exemptions" '$e + $s')"
            fi
        done <<< "$scopes"
    else
        local query="PolicyResources | where type == 'microsoft.authorization/policyexemptions'"
        all_exemptions="$(epac_search_az_graph "$query" "policy exemptions" 1000)"
    fi

    local result
    result="$(jq -n '{
        managed: {},
        counters: {
            managedBy: { thisPaC: 0, otherPaC: 0, unknown: 0 },
            orphaned: 0,
            expired: 0,
            excluded: 0,
            unmanagedScopes: 0
        }
    }')"

    local now_epoch
    now_epoch="$(date -u +%s)"

    local ex_count
    ex_count="$(echo "$all_exemptions" | jq 'length')"
    local ei=0
    while [[ $ei -lt $ex_count ]]; do
        local resource
        resource="$(echo "$all_exemptions" | jq --argjson i "$ei" '.[$i]')"
        local resource_id
        resource_id="$(echo "$resource" | jq -r '.id')"

        # Validate tenant
        local res_tenant
        res_tenant="$(echo "$resource" | jq -r '.tenantId // empty')"
        if [[ -n "$res_tenant" && "$res_tenant" != "$tenant_id" ]]; then
            ei=$((ei + 1))
            continue
        fi

        # Get properties
        local properties
        properties="$(epac_get_policy_resource_properties "$resource")"

        # Check assignment reference for exclusion test
        local policy_assignment_id
        policy_assignment_id="$(echo "$properties" | jq -r '.policyAssignmentId // empty')"

        local included
        included="$(epac_confirm_policy_resource_exclusions "${policy_assignment_id:-$resource_id}" "$resource_id" "$scope_table" "$excluded_scopes")"
        if [[ "$included" != "true" ]]; then
            result="$(echo "$result" | jq '.counters.excluded += 1')"
            ei=$((ei + 1))
            continue
        fi

        # Process expiration
        local expires_on
        expires_on="$(echo "$properties" | jq -r '.expiresOn // empty')"
        local expiry_status="active"
        local expires_in_days=999999

        if [[ -n "$expires_on" ]]; then
            local expires_epoch
            expires_epoch="$(date -u -d "$expires_on" +%s 2>/dev/null)" || expires_epoch=0
            if [[ $expires_epoch -gt 0 ]]; then
                expires_in_days=$(( (expires_epoch - now_epoch) / 86400 ))
                if [[ $expires_in_days -lt -15 ]]; then
                    expiry_status="expired-over-15-days"
                elif [[ $expires_in_days -lt 0 ]]; then
                    expiry_status="expired-within-15-days"
                elif [[ $expires_in_days -lt 15 ]]; then
                    expiry_status="active-expiring-within-15-days"
                fi
            fi
        fi

        # Determine owner
        local pac_owner
        pac_owner="$(epac_confirm_pac_owner "$pac_owner_id" "$resource")"
        local counter_key
        case "$pac_owner" in
            thisPaC)    counter_key="thisPaC" ;;
            otherPaC)   counter_key="otherPaC" ;;
            *)          counter_key="unknown" ;;
        esac

        # Build normalized exemption
        local normalized
        normalized="$(echo "$resource" | jq --arg es "$expiry_status" --argjson eid "$expires_in_days" --arg po "$pac_owner" '
            . + {
                expiryStatus: $es,
                expiresInDays: $eid,
                pacOwner: $po
            }')"

        result="$(echo "$result" | jq --arg id "$resource_id" --argjson r "$normalized" --arg ck "$counter_key" '
            .managed[$id] = $r | .counters.managedBy[$ck] += 1')"

        ei=$((ei + 1))
    done

    epac_write_status "Policy exemptions: $(echo "$result" | jq '.managed | length') collected" "success" 2 >&2
    echo "$result"
}

###############################################################################
# Section 5: Main Policy Resource Collection Orchestrator
###############################################################################

# ─── Get all deployed policy resources ───────────────────────────────────────
# Replaces Get-AzPolicyResources.ps1
# Main entry point for collecting all policy resources.

epac_get_policy_resources() {
    local pac_environment="$1"
    local scope_table="$2"
    local skip_role_assignments="${3:-false}"
    local skip_exemptions="${4:-false}"
    local collect_all="${5:-false}"

    epac_write_section "Collecting Deployed Policy Resources" 0 >&2

    local result="{}"

    # Policy definitions
    local policy_defs
    policy_defs="$(epac_get_policy_or_set_definitions "policyDefinitions" "$pac_environment" "$scope_table")"
    result="$(echo "$result" | jq --argjson pd "$policy_defs" '.policyDefinitions = $pd')"

    # Policy set definitions
    local policy_set_defs
    policy_set_defs="$(epac_get_policy_or_set_definitions "policySetDefinitions" "$pac_environment" "$scope_table")"
    result="$(echo "$result" | jq --argjson psd "$policy_set_defs" '.policySetDefinitions = $psd')"

    # Policy assignments (with optional role assignments)
    local assignments
    assignments="$(epac_get_policy_assignments "$pac_environment" "$scope_table" "$skip_role_assignments")"
    result="$(echo "$result" | jq --argjson pa "$assignments" '
        .policyAssignments = {managed: $pa.managed, counters: $pa.counters} |
        .roleAssignmentsByPrincipalId = $pa.roleAssignmentsByPrincipalId |
        .roleDefinitions = $pa.roleDefinitions')"

    # Policy exemptions
    if [[ "$skip_exemptions" != "true" ]]; then
        local exemptions
        exemptions="$(epac_get_policy_exemptions "$pac_environment" "$scope_table")"
        result="$(echo "$result" | jq --argjson pe "$exemptions" '.policyExemptions = $pe')"
    fi

    echo "$result"
}

# ─── Find non-compliant resources ────────────────────────────────────────────
# Replaces Find-AzNonCompliantResources.ps1
# Queries policy compliance states with optional filters.

epac_find_non_compliant_resources() {
    local pac_environment="$1"
    local remediation_only="${2:-false}"
    local exclude_manual="${3:-false}"
    local effect_filter="${4:-}"          # comma-separated effect list
    local enforcement_mode="${5:-}"       # "Default" to filter by enforcement mode

    local query="policyresources | where type == \"microsoft.policyinsights/policystates\" and properties.complianceState == \"NonCompliant\""

    # Effect filters
    local effect_clause=""
    if [[ "$remediation_only" == "true" ]]; then
        effect_clause=" and (properties.policyDefinitionAction == \"deployifnotexists\" or properties.policyDefinitionAction == \"modify\")"
    elif [[ -n "$effect_filter" ]]; then
        local IFS=','
        local parts=()
        for e in $effect_filter; do
            e="$(echo "$e" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            parts+=("properties.policyDefinitionAction == \"${e,,}\"")
        done
        local joined
        joined="$(printf " or %s" "${parts[@]}")"
        effect_clause=" and (${joined:4})"
    fi

    if [[ "$exclude_manual" == "true" ]]; then
        effect_clause+=" and properties.policyDefinitionAction != \"manual\""
    fi

    query+="$effect_clause"

    # Enforcement mode join
    if [[ "$enforcement_mode" == "Default" ]]; then
        query+=" | extend assignmentId = tostring(properties.policyAssignmentId)"
        query+=" | join kind=inner (policyresources | where type == \"microsoft.authorization/policyassignments\" | extend assignmentId = tolower(id), enforcementMode = tostring(properties.enforcementMode)) on assignmentId"
        query+=" | where enforcementMode == \"Default\""
    fi

    epac_write_status "Querying non-compliant resources..." "info" 2 >&2
    local results
    results="$(epac_search_az_graph "$query" "non-compliant resources" 1000)"

    epac_write_status "Found $(echo "$results" | jq 'length') non-compliant resources" "info" 2 >&2
    echo "$results"
}
