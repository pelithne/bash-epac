#!/usr/bin/env bash
# lib/config.sh — Global settings parser, PAC environment configuration
# Replaces PowerShell: Get-GlobalSettings.ps1, Get-CustomMetadata.ps1,
#   Get-DeploymentPlan.ps1, Add-SelectedPacArray.ps1, Add-SelectedPacValue.ps1,
#   Get-SelectorArrays.ps1

[[ -n "${_EPAC_CONFIG_LOADED:-}" ]] && return 0
readonly _EPAC_CONFIG_LOADED=1

# shellcheck source=core.sh
source "${BASH_SOURCE[0]%/*}/core.sh"
# shellcheck source=json.sh
source "${BASH_SOURCE[0]%/*}/json.sh"
# shellcheck source=output.sh
source "${BASH_SOURCE[0]%/*}/output.sh"
# shellcheck source=azure-auth.sh
source "${BASH_SOURCE[0]%/*}/azure-auth.sh"

# ─── Get Custom Metadata ─────────────────────────────────────────────────────
# Equivalent of Get-CustomMetadata.ps1
# Strips Azure system-managed metadata properties and optionally removes extras.

epac_get_custom_metadata() {
    local metadata="$1"
    local remove="${2:-}"

    # System-managed properties to always strip
    local result
    result="$(echo "$metadata" | jq 'del(.createdBy, .createdOn, .updatedBy, .updatedOn, .lastSyncedToArgOn)')"

    # Remove additional keys if specified (comma-separated)
    if [[ -n "$remove" ]]; then
        local IFS=','
        for key in $remove; do
            key="$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            result="$(echo "$result" | jq --arg k "$key" 'del(.[$k])')"
        done
    fi

    echo "$result"
}

# ─── Get Deployment Plan ─────────────────────────────────────────────────────
# Equivalent of Get-DeploymentPlan.ps1
# Reads a plan JSON file if it exists.

epac_get_deployment_plan() {
    local plan_file="$1"

    if [[ ! -f "$plan_file" ]]; then
        echo "null"
        return
    fi

    local json
    json="$(cat "$plan_file")" || epac_die "Failed to read plan file: ${plan_file}"

    # Validate it's valid JSON
    echo "$json" | jq '.' 2>/dev/null || epac_die "Plan file '${plan_file}' is not valid JSON."
}

# ─── Add Selected PAC Array ──────────────────────────────────────────────────
# Equivalent of Add-SelectedPacArray.ps1
# Selects array values from a JSON object by pac selector, with '*' fallback.
# Input: JSON object with pac-selector keys, selector name, optional existing array
# Output: JSON array of merged values

epac_add_selected_pac_array() {
    local input_object="$1"
    local pac_selector="$2"
    local existing_list="${3:-[]}"
    local additional_roles="${4:-}"

    # Start with existing list
    local result="$existing_list"

    # Get array for this selector
    local arr
    arr="$(echo "$input_object" | jq --arg s "$pac_selector" 'if has($s) then .[$s] else null end')"

    if [[ "$arr" != "null" ]]; then
        # Ensure it's an array
        local arr_type
        arr_type="$(echo "$arr" | jq -r 'type')"
        if [[ "$arr_type" != "array" ]]; then
            arr="$(echo "$arr" | jq '[.]')"
        fi
        result="$(jq -n --argjson existing "$result" --argjson new "$arr" '$existing + $new')"
    fi

    # If no additional_roles restriction, or if additional_roles=true and no selector-specific array
    if [[ -z "$additional_roles" ]] || { [[ "$additional_roles" == "true" ]] && [[ "$arr" == "null" ]]; }; then
        local wildcard
        wildcard="$(echo "$input_object" | jq 'if has("*") then .["*"] else null end')"
        if [[ "$wildcard" != "null" ]]; then
            local wc_type
            wc_type="$(echo "$wildcard" | jq -r 'type')"
            if [[ "$wc_type" != "array" ]]; then
                wildcard="$(echo "$wildcard" | jq '[.]')"
            fi
            result="$(jq -n --argjson existing "$result" --argjson new "$wildcard" '$existing + $new')"
        fi
    fi

    echo "$result"
}

# ─── Add Selected PAC Value ──────────────────────────────────────────────────
# Equivalent of Add-SelectedPacValue.ps1
# Selects a single value from a JSON object by pac selector, with '*' fallback.
# Returns the output object with the key set.

epac_add_selected_pac_value() {
    local input_object="$1"
    local pac_selector="$2"
    local output_object="$3"
    local output_key="$4"

    local value
    local has_selector
    has_selector="$(echo "$input_object" | jq --arg s "$pac_selector" 'has($s)')"

    if [[ "$has_selector" == "true" ]]; then
        value="$(echo "$input_object" | jq --arg s "$pac_selector" '.[$s]')"
    else
        local has_wildcard
        has_wildcard="$(echo "$input_object" | jq 'has("*")')"
        if [[ "$has_wildcard" == "true" ]]; then
            value="$(echo "$input_object" | jq '.["*"]')"
        else
            value="null"
        fi
    fi

    if [[ "$value" != "null" ]]; then
        # Verify it's not an array
        local val_type
        val_type="$(echo "$value" | jq -r 'type')"
        if [[ "$val_type" == "array" ]]; then
            epac_die "Value for '${pac_selector}' is an array. It must be a single value."
        fi
        echo "$output_object" | jq --arg k "$output_key" --argjson v "$value" '. + {($k): $v}'
    else
        echo "$output_object"
    fi
}

# ─── Get Selector Arrays ─────────────────────────────────────────────────────
# Equivalent of Get-SelectorArrays.ps1
# Extracts 'in' and 'notIn' arrays from selector objects.

epac_get_selector_arrays() {
    local selector_object="$1"

    echo "$selector_object" | jq '{
        In: [(.selectors // [])[] | (.["in"] // [])[] ] ,
        NotIn: [(.selectors // [])[] | (.notIn // [])[] ]
    }'
}

# ─── Validate scope entry ────────────────────────────────────────────────────

_epac_validate_scope() {
    local scope="$1"
    local scope_lower="${scope,,}"
    if [[ "$scope_lower" == /subscriptions/* ]]; then
        return 0
    elif [[ "$scope_lower" == /providers/microsoft.management/managementgroups/* ]]; then
        return 0
    fi
    return 1
}

_epac_classify_scope() {
    local scope="$1"
    local scope_lower="${scope,,}"
    if [[ "$scope_lower" == /subscriptions/*/resourcegroups/* ]]; then
        echo "resourceGroup"
    elif [[ "$scope_lower" == /subscriptions/* ]]; then
        echo "subscription"
    elif [[ "$scope_lower" == /providers/microsoft.management/managementgroups/* ]]; then
        echo "managementGroup"
    else
        echo "unknown"
    fi
}

# ─── Get Global Settings ─────────────────────────────────────────────────────
# Equivalent of Get-GlobalSettings.ps1
# The main configuration loader. Parses global-settings.jsonc, validates all
# fields, and returns a complete settings JSON object.

epac_get_global_settings() {
    local definitions_root="${1:-}"
    local output_folder="${2:-}"
    local input_folder="${3:-}"

    # Get PAC folders
    local folders
    folders="$(epac_get_pac_folders "$definitions_root" "$output_folder" "$input_folder")"

    definitions_root="$(echo "$folders" | jq -r '.definitionsRootFolder')"
    output_folder="$(echo "$folders" | jq -r '.outputFolder')"
    input_folder="$(echo "$folders" | jq -r '.inputFolder')"
    local global_settings_file
    global_settings_file="$(echo "$folders" | jq -r '.globalSettingsFile')"

    epac_write_section "Global Settings Configuration" 0 >&2
    epac_write_status "Reading global settings from: ${global_settings_file}" "info" 2 >&2

    epac_require_file "$global_settings_file" "Global settings file"

    local settings
    settings="$(epac_read_jsonc "$global_settings_file")" || \
        epac_die "Global settings JSON file '${global_settings_file}' is not valid."

    epac_write_status "Successfully parsed global settings JSON" "success" 2 >&2

    # Create error info for collecting validation errors
    local ei
    ei="$(epac_new_error_info "$global_settings_file")"

    # ── Extract top-level fields ──
    local pac_owner_id
    pac_owner_id="$(echo "$settings" | jq -r '.pacOwnerId // empty')"
    if [[ -z "$pac_owner_id" ]]; then
        epac_add_error "$ei" -1 "Global settings error: does not contain the required pacOwnerId field. Add a pacOwnerId field with a GUID or other unique id!"
    fi

    local telemetry_enabled="true"
    local telemetry_opt_out
    telemetry_opt_out="$(echo "$settings" | jq -r '.telemetryOptOut // empty')"
    if [[ "$telemetry_opt_out" == "true" ]]; then
        telemetry_enabled="false"
    fi

    # ── Check for deprecated top-level fields ──
    if echo "$settings" | jq -e '.globalNotScopes' &>/dev/null; then
        epac_add_error "$ei" -1 "Global settings error: contains a deprecated globalNotScopes field. Move the values into each pacEnvironment!"
    fi
    if echo "$settings" | jq -e 'has("managedIdentityLocations")' 2>/dev/null | grep -q true; then
        epac_add_error "$ei" -1 "Global settings error: contains a deprecated managedIdentityLocations field. Move the values into each pacEnvironment!"
    fi

    # ── Validate pacEnvironments array ──
    local pac_envs_type
    pac_envs_type="$(echo "$settings" | jq -r '.pacEnvironments | type')"

    if [[ "$pac_envs_type" == "null" ]]; then
        epac_add_error "$ei" -1 "Global settings error: does not contain a pacEnvironments array. Add a pacEnvironments array with at least one environment!"
    elif [[ "$pac_envs_type" != "array" ]]; then
        epac_add_error "$ei" -1 "Global settings error: pacEnvironments must be an array of objects."
    else
        local pac_envs_count
        pac_envs_count="$(echo "$settings" | jq '.pacEnvironments | length')"
        if [[ "$pac_envs_count" -eq 0 ]]; then
            epac_add_error "$ei" -1 "Global settings error: pacEnvironments array must contain at least one environment."
        fi
    fi

    # ── Process each pacEnvironment ──
    local pac_environment_definitions="{}"
    local pac_environment_selectors="[]"

    if [[ "$pac_envs_type" == "array" && "$(echo "$settings" | jq '.pacEnvironments | length')" -gt 0 ]]; then
        local idx=0
        local env_count
        env_count="$(echo "$settings" | jq '.pacEnvironments | length')"

        while [[ $idx -lt $env_count ]]; do
            local pac_env
            pac_env="$(echo "$settings" | jq --argjson i "$idx" '.pacEnvironments[$i]')"

            # ── pacSelector ──
            local pac_selector
            pac_selector="$(echo "$pac_env" | jq -r '.pacSelector // empty')"
            if [[ -z "$pac_selector" ]]; then
                epac_add_error "$ei" -1 "Global settings error: a pacEnvironments array element does not contain the required pacSelector element."
                idx=$((idx + 1))
                continue
            fi
            pac_environment_selectors="$(echo "$pac_environment_selectors" | jq --arg s "$pac_selector" '. + [$s]')"

            # ── cloud ──
            local cloud
            cloud="$(echo "$pac_env" | jq -r '.cloud // empty')"
            if [[ -z "$cloud" ]]; then
                epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} does not define the required cloud element."
            fi

            # ── tenantId ──
            local tenant_id
            tenant_id="$(echo "$pac_env" | jq -r '.tenantId // empty')"
            if [[ -z "$tenant_id" ]]; then
                epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} does not contain required tenantId field."
            fi

            # ── managedIdentityLocation ──
            local managed_identity_location
            managed_identity_location="$(echo "$pac_env" | jq -r '.managedIdentityLocation // empty')"
            if [[ -z "$managed_identity_location" ]]; then
                epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} does not contain required managedIdentityLocation field."
            fi

            # ── managedTenantId ──
            local managed_tenant_id
            managed_tenant_id="$(echo "$pac_env" | jq -r '.managedTenantId // empty')"
            if [[ -n "$managed_tenant_id" ]]; then
                if ! epac_is_guid "$managed_tenant_id"; then
                    epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field managedTenantId (${managed_tenant_id}) must be a GUID."
                fi
            fi

            # ── Deprecated fields ──
            if echo "$pac_env" | jq -e '.defaultSubscriptionId' &>/dev/null; then
                epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} contains a deprecated defaultSubscriptionId. Remove it!"
            fi
            if echo "$pac_env" | jq -e '.rootScope' &>/dev/null; then
                epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} contains a deprecated rootScope. Replace rootScope with deploymentRootScope containing a fully qualified scope id!"
            fi
            if echo "$pac_env" | jq -e '.inheritedDefinitionsScopes' &>/dev/null; then
                epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} contains a deprecated inheritedDefinitionsScopes."
            fi

            # ── deploymentRootScope ──
            local deployment_root_scope
            deployment_root_scope="$(echo "$pac_env" | jq -r '.deploymentRootScope // empty')"
            if [[ -z "$deployment_root_scope" ]]; then
                epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} does not contain deploymentRootScope field."
            fi

            # ── defaultContext ──
            local default_context
            default_context="$(echo "$pac_env" | jq -r '.defaultContext // empty')"

            # ── deployedBy ──
            local deployed_by="epac/${pac_owner_id}/${pac_selector}"
            local custom_deployed_by
            custom_deployed_by="$(echo "$pac_env" | jq -r '.deployedBy // empty')"
            if [[ -n "$custom_deployed_by" ]]; then
                deployed_by="$custom_deployed_by"
            fi

            # ── skipResourceValidationForExemptions ──
            local skip_resource_validation="false"
            if echo "$pac_env" | jq -e '.skipResourceValidationForExemptions == true' &>/dev/null; then
                skip_resource_validation="true"
            fi

            # ── globalNotScopes processing ──
            local global_not_scopes="[]"
            local global_not_scopes_rg="[]"
            local global_not_scopes_sub="[]"
            local global_not_scopes_mg="[]"
            local excluded_scopes="[]"
            local excluded_scopes_rg="[]"
            local excluded_scopes_sub="[]"
            local excluded_scopes_mg="[]"

            local gns_type
            gns_type="$(echo "$pac_env" | jq -r '.globalNotScopes | type')"
            if [[ "$gns_type" == "array" ]]; then
                local gns_count
                gns_count="$(echo "$pac_env" | jq '.globalNotScopes | length')"
                local gi=0
                while [[ $gi -lt $gns_count ]]; do
                    local gns
                    gns="$(echo "$pac_env" | jq -r --argjson i "$gi" '.globalNotScopes[$i]')"
                    local gns_lower="${gns,,}"

                    if [[ "$gns_lower" == *"/resourcegrouppatterns/"* ]]; then
                        epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field globalNotScopes entry (${gns}) must not contain deprecated /resourceGroupPatterns/."
                    elif _epac_validate_scope "$gns"; then
                        global_not_scopes="$(echo "$global_not_scopes" | jq --arg s "$gns" '. + [$s]')"
                        excluded_scopes="$(echo "$excluded_scopes" | jq --arg s "$gns" '. + [$s]')"
                        local scope_class
                        scope_class="$(_epac_classify_scope "$gns")"
                        case "$scope_class" in
                            resourceGroup)
                                global_not_scopes_rg="$(echo "$global_not_scopes_rg" | jq --arg s "$gns" '. + [$s]')"
                                excluded_scopes_rg="$(echo "$excluded_scopes_rg" | jq --arg s "$gns" '. + [$s]')"
                                ;;
                            subscription)
                                global_not_scopes_sub="$(echo "$global_not_scopes_sub" | jq --arg s "$gns" '. + [$s]')"
                                excluded_scopes_sub="$(echo "$excluded_scopes_sub" | jq --arg s "$gns" '. + [$s]')"
                                ;;
                            managementGroup)
                                global_not_scopes_mg="$(echo "$global_not_scopes_mg" | jq --arg s "$gns" '. + [$s]')"
                                excluded_scopes_mg="$(echo "$excluded_scopes_mg" | jq --arg s "$gns" '. + [$s]')"
                                ;;
                            *)
                                epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field globalNotScopes entry (${gns}) must be a valid scope."
                                ;;
                        esac
                    else
                        epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field globalNotScopes entry (${gns}) must be a valid scope."
                    fi
                    gi=$((gi + 1))
                done
            elif [[ "$gns_type" != "null" ]]; then
                epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field globalNotScopes must be an array of strings."
            fi

            # ── desiredState processing ──
            local desired_state
            desired_state="$(jq -n '{
                strategy: "undefined",
                keepDfcSecurityAssignments: false,
                keepDfcPlanAssignments: false,
                cleanupObsoleteExemptions: false,
                excludedScopes: [],
                globalExcludedScopesResourceGroups: [],
                globalExcludedScopesSubscriptions: [],
                globalExcludedScopesManagementGroups: [],
                excludedPolicyDefinitions: [],
                excludedPolicySetDefinitions: [],
                excludedPolicyDefinitionFiles: [],
                excludedPolicySetDefinitionFiles: [],
                excludedPolicyAssignments: [],
                excludeSubscriptions: false,
                doNotDisableDeprecatedPolicies: false,
                manageChildScopeDefinitions: false
            }')"

            local do_not_disable_deprecated="false"

            local desired
            desired="$(echo "$pac_env" | jq '.desiredState // null')"

            if [[ "$desired" == "null" ]]; then
                epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} does not contain required desiredState field."
            else
                # strategy
                local strategy
                strategy="$(echo "$desired" | jq -r '.strategy // empty')"
                if [[ -z "$strategy" ]]; then
                    epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} does not contain required desiredState.strategy field."
                elif [[ "$strategy" != "full" && "$strategy" != "ownedOnly" ]]; then
                    epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.strategy (${strategy}) must be one of [\"full\",\"ownedOnly\"]."
                else
                    desired_state="$(echo "$desired_state" | jq --arg s "$strategy" '.strategy = $s')"
                fi

                # Deprecated: includeResourceGroups
                if echo "$desired" | jq -e '.includeResourceGroups' &>/dev/null; then
                    epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.includeResourceGroups is deprecated."
                fi

                # keepDfcSecurityAssignments (required boolean)
                _epac_validate_required_bool "$ei" "$desired" "$pac_selector" "keepDfcSecurityAssignments" desired_state

                # keepDfcPlanAssignments (optional boolean, default true)
                local has_kdpa
                has_kdpa="$(echo "$desired" | jq 'has("keepDfcPlanAssignments")')"
                if [[ "$has_kdpa" != "true" ]]; then
                    desired_state="$(echo "$desired_state" | jq '.keepDfcPlanAssignments = true')"
                else
                    _epac_validate_optional_bool "$ei" "$desired" "$pac_selector" "keepDfcPlanAssignments" desired_state
                fi

                # cleanupObsoleteExemptions (optional boolean)
                _epac_validate_optional_bool "$ei" "$desired" "$pac_selector" "cleanupObsoleteExemptions" desired_state

                # excludedScopes
                local ds_excluded
                ds_excluded="$(echo "$desired" | jq '.excludedScopes // null')"
                if [[ "$ds_excluded" != "null" ]]; then
                    local ds_exc_type
                    ds_exc_type="$(echo "$ds_excluded" | jq -r 'type')"
                    if [[ "$ds_exc_type" != "array" ]]; then
                        epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.excludedScopes must be an array of strings."
                    else
                        local exclude_subscriptions_val
                        exclude_subscriptions_val="$(echo "$desired" | jq -r 'if has("excludeSubscriptions") then .excludeSubscriptions else false end')"
                        local esi=0
                        local es_count
                        es_count="$(echo "$ds_excluded" | jq 'length')"
                        while [[ $esi -lt $es_count ]]; do
                            local es
                            es="$(echo "$ds_excluded" | jq -r --argjson i "$esi" '.[$i]')"
                            if [[ -n "$es" ]]; then
                                local es_lower="${es,,}"
                                if [[ "$es_lower" == *"/resourcegrouppatterns/"* ]]; then
                                    epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.excludedScopes (${es}) must not contain deprecated /resourceGroupPatterns/."
                                elif _epac_validate_scope "$es"; then
                                    excluded_scopes="$(echo "$excluded_scopes" | jq --arg s "$es" '. + [$s]')"
                                    local es_class
                                    es_class="$(_epac_classify_scope "$es")"
                                    if [[ "$exclude_subscriptions_val" != "true" ]]; then
                                        case "$es_class" in
                                            resourceGroup) excluded_scopes_rg="$(echo "$excluded_scopes_rg" | jq --arg s "$es" '. + [$s]')" ;;
                                            subscription)  excluded_scopes_sub="$(echo "$excluded_scopes_sub" | jq --arg s "$es" '. + [$s]')" ;;
                                            managementGroup) excluded_scopes_mg="$(echo "$excluded_scopes_mg" | jq --arg s "$es" '. + [$s]')" ;;
                                            *) epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.excludedScopes (${es}) must be a valid scope." ;;
                                        esac
                                    fi
                                else
                                    epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.excludedScopes (${es}) must be a valid scope."
                                fi
                            fi
                            esi=$((esi + 1))
                        done
                    fi
                fi

                # Excluded definitions/assignments arrays
                for field in excludedPolicyDefinitions excludedPolicySetDefinitions excludedPolicyAssignments excludedPolicyDefinitionFiles excludedPolicySetDefinitionFiles; do
                    local excl_val
                    excl_val="$(echo "$desired" | jq --arg f "$field" '.[$f] // null')"
                    if [[ "$excl_val" != "null" ]]; then
                        if ! echo "$excl_val" | jq -e 'type == "array"' &>/dev/null; then
                            epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.${field} must be an array of strings."
                        else
                            desired_state="$(echo "$desired_state" | jq --arg f "$field" --argjson v "$excl_val" '.[$f] = $v')"
                        fi
                    fi
                done

                # excludeSubscriptions
                if echo "$desired" | jq -e '.excludeSubscriptions == true' &>/dev/null; then
                    desired_state="$(echo "$desired_state" | jq '.excludeSubscriptions = true')"
                fi

                # Deprecated fields
                if echo "$desired" | jq -e '.deleteExpiredExemptions' &>/dev/null; then
                    epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.deleteExpiredExemptions is deprecated. Remove it!"
                fi
                if echo "$desired" | jq -e '.deleteOrphanedExemptions' &>/dev/null; then
                    epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.deleteOrphanedExemptions is deprecated. Remove it!"
                fi

                # doNotDisableDeprecatedPolicies
                _epac_validate_optional_bool "$ei" "$desired" "$pac_selector" "doNotDisableDeprecatedPolicies" desired_state
                do_not_disable_deprecated="$(echo "$desired_state" | jq -r '.doNotDisableDeprecatedPolicies')"

                # manageChildScopeDefinitions
                _epac_validate_optional_bool "$ei" "$desired" "$pac_selector" "manageChildScopeDefinitions" desired_state
            fi

            # Set scopes into desired state
            desired_state="$(echo "$desired_state" | jq \
                --argjson es "$excluded_scopes" \
                --argjson esrg "$excluded_scopes_rg" \
                --argjson essub "$excluded_scopes_sub" \
                --argjson esmg "$excluded_scopes_mg" \
                '.excludedScopes = $es | .globalExcludedScopesResourceGroups = $esrg | .globalExcludedScopesSubscriptions = $essub | .globalExcludedScopesManagementGroups = $esmg'
            )"

            # ── Build pac environment definition ──
            local pac_env_def
            pac_env_def="$(jq -n \
                --arg ps "$pac_selector" \
                --arg po "$pac_owner_id" \
                --arg db "$deployed_by" \
                --arg cl "$cloud" \
                --arg ti "$tenant_id" \
                --arg mti "$managed_tenant_id" \
                --arg drs "$deployment_root_scope" \
                --arg dc "$default_context" \
                --argjson srv "$skip_resource_validation" \
                --argjson dndp "$do_not_disable_deprecated" \
                --argjson ds "$desired_state" \
                --arg mil "$managed_identity_location" \
                --argjson gns "$global_not_scopes" \
                --argjson gnsrg "$global_not_scopes_rg" \
                --argjson gnssub "$global_not_scopes_sub" \
                --argjson gnsmg "$global_not_scopes_mg" \
                '{
                    pacSelector: $ps,
                    pacOwnerId: $po,
                    deployedBy: $db,
                    cloud: $cl,
                    tenantId: $ti,
                    managedTenantId: $mti,
                    deploymentRootScope: $drs,
                    defaultContext: $dc,
                    policyDefinitionsScopes: [$drs, ""],
                    skipResourceValidationForExemptions: $srv,
                    doNotDisableDeprecatedPolicies: $dndp,
                    desiredState: $ds,
                    managedIdentityLocation: $mil,
                    globalNotScopes: $gns,
                    globalNotScopesResourceGroups: $gnsrg,
                    globalNotScopesSubscriptions: $gnssub,
                    globalNotScopesManagementGroups: $gnsmg
                }'
            )"

            pac_environment_definitions="$(echo "$pac_environment_definitions" | jq --arg k "$pac_selector" --argjson v "$pac_env_def" '. + {($k): $v}')"

            idx=$((idx + 1))
        done
    fi

    # ── Write errors if any ──
    epac_write_status "Global settings validation complete" "success" 2 >&2
    if epac_has_errors "$ei"; then
        epac_write_errors "$ei" >&2
        epac_cleanup_error_info "$ei"
        exit 1
    fi
    epac_cleanup_error_info "$ei"

    # ── Build final global settings ──
    local prompt
    prompt="$(echo "$pac_environment_selectors" | jq -r 'join(", ")')"

    epac_write_section "Configuration Summary" 0 >&2
    epac_write_status "PAC Environments: ${prompt}" "info" 2 >&2
    epac_write_status "PAC Owner Id: ${pac_owner_id}" "info" 2 >&2
    epac_write_status "Definitions root folder: ${definitions_root}" "info" 2 >&2
    epac_write_status "Input folder: ${input_folder}" "info" 2 >&2
    epac_write_status "Output folder: ${output_folder}" "info" 2 >&2

    jq -n \
        --argjson te "$telemetry_enabled" \
        --arg drf "$definitions_root" \
        --arg gsf "$global_settings_file" \
        --arg of "$output_folder" \
        --arg inf "$input_folder" \
        --arg pdf "${definitions_root}/policyDocumentations" \
        --arg pdef "${definitions_root}/policyDefinitions" \
        --arg psdf "${definitions_root}/policySetDefinitions" \
        --arg paf "${definitions_root}/policyAssignments" \
        --arg pef "${definitions_root}/policyExemptions" \
        --argjson pes "$pac_environment_selectors" \
        --arg pep "$prompt" \
        --argjson pe "$pac_environment_definitions" \
        '{
            telemetryEnabled: $te,
            definitionsRootFolder: $drf,
            globalSettingsFile: $gsf,
            outputFolder: $of,
            inputFolder: $inf,
            policyDocumentationsFolder: $pdf,
            policyDefinitionsFolder: $pdef,
            policySetDefinitionsFolder: $psdf,
            policyAssignmentsFolder: $paf,
            policyExemptionsFolder: $pef,
            pacEnvironmentSelectors: $pes,
            pacEnvironmentPrompt: $pep,
            pacEnvironments: $pe
        }'
}

# ─── Helper: validate required boolean field ──────────────────────────────────

_epac_validate_required_bool() {
    local ei="$1"
    local json="$2"
    local pac_selector="$3"
    local field="$4"
    local -n ds_ref="$5"

    local has_field
    has_field="$(echo "$json" | jq --arg f "$field" 'has($f)')"
    if [[ "$has_field" != "true" ]]; then
        epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} does not contain required desiredState.${field} field."
    else
        local val
        val="$(echo "$json" | jq --arg f "$field" '.[$f]')"
        if [[ "$val" == "true" || "$val" == "false" ]]; then
            ds_ref="$(echo "$ds_ref" | jq --arg f "$field" --argjson v "$val" '.[$f] = $v')"
        else
            epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.${field} (${val}) must be a boolean value."
        fi
    fi
}

# ─── Helper: validate optional boolean field ─────────────────────────────────

_epac_validate_optional_bool() {
    local ei="$1"
    local json="$2"
    local pac_selector="$3"
    local field="$4"
    local -n ds_ref="$5"

    local has_field
    has_field="$(echo "$json" | jq --arg f "$field" 'has($f)')"
    if [[ "$has_field" == "true" ]]; then
        local val
        val="$(echo "$json" | jq --arg f "$field" '.[$f]')"
        if [[ "$val" == "true" || "$val" == "false" ]]; then
            ds_ref="$(echo "$ds_ref" | jq --arg f "$field" --argjson v "$val" '.[$f] = $v')"
        else
            epac_add_error "$ei" -1 "Global settings error: pacEnvironment ${pac_selector} field desiredState.${field} (${val}) must be a boolean value."
        fi
    fi
}
