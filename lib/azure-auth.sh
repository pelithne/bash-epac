#!/usr/bin/env bash
# lib/azure-auth.sh — Azure CLI authentication and context management
# Replaces PowerShell: Set-AzCloudTenantSubscription.ps1,
#   Select-PacEnvironment.ps1, Switch-PacEnvironment.ps1,
#   Get-PacFolders.ps1, Submit-EPACTelemetry.ps1

[[ -n "${_EPAC_AZURE_AUTH_LOADED:-}" ]] && return 0
readonly _EPAC_AZURE_AUTH_LOADED=1

# shellcheck source=core.sh
source "${BASH_SOURCE[0]%/*}/core.sh"
# shellcheck source=json.sh
source "${BASH_SOURCE[0]%/*}/json.sh"
# shellcheck source=output.sh
source "${BASH_SOURCE[0]%/*}/output.sh"

# ─── API version tables by cloud ─────────────────────────────────────────────

_epac_api_versions_for_cloud() {
    local cloud="${1,,}"
    case "$cloud" in
        azurechinacloud)
            jq -n '{
                policyDefinitions:    "2021-06-01",
                policySetDefinitions: "2023-04-01",
                policyAssignments:    "2022-06-01",
                policyExemptions:     "2022-07-01-preview",
                roleAssignments:      "2022-04-01"
            }'
            ;;
        azureusgovernment)
            jq -n '{
                policyDefinitions:    "2023-04-01",
                policySetDefinitions: "2023-04-01",
                policyAssignments:    "2023-04-01",
                policyExemptions:     "2024-12-01-preview",
                roleAssignments:      "2022-04-01"
            }'
            ;;
        *)
            jq -n '{
                policyDefinitions:    "2023-04-01",
                policySetDefinitions: "2023-04-01",
                policyAssignments:    "2023-04-01",
                policyExemptions:     "2022-07-01-preview",
                roleAssignments:      "2022-04-01"
            }'
            ;;
    esac
}

# ─── Map PowerShell cloud names to Azure CLI cloud names ──────────────────────

_epac_cloud_to_az_cloud() {
    local cloud="${1}"
    case "${cloud,,}" in
        azurecloud)         echo "AzureCloud" ;;
        azurechinacloud)    echo "AzureChinaCloud" ;;
        azureusgovernment)  echo "AzureUSGovernment" ;;
        azuregermancloud)   echo "AzureGermanCloud" ;;
        *)                  echo "$cloud" ;;
    esac
}

# ─── Get current Azure CLI context ───────────────────────────────────────────

epac_get_az_context() {
    local account
    account="$(az account show -o json 2>/dev/null)" || {
        echo ""
        return 1
    }
    echo "$account"
}

# ─── Set Azure cloud, tenant, subscription ────────────────────────────────────
# Equivalent of Set-AzCloudTenantSubscription.ps1

epac_set_az_cloud_tenant_subscription() {
    local cloud tenant_id interactive default_context

    # Support both calling conventions:
    #   1. epac_set_az_cloud_tenant_subscription "$cloud" "$tenant_id" "$interactive"
    #   2. epac_set_az_cloud_tenant_subscription "$pac_env_json"
    if [[ $# -eq 1 ]] && echo "$1" | jq -e '.cloud' > /dev/null 2>&1; then
        cloud="$(echo "$1" | jq -r '.cloud')"
        tenant_id="$(echo "$1" | jq -r '.tenantId')"
        interactive="$(echo "$1" | jq -r '.interactive // "false"')"
        default_context=""
    else
        cloud="$1"
        tenant_id="$2"
        interactive="${3:-false}"
        default_context="${4:-}"
    fi

    # Set the cloud if not default
    local az_cloud
    az_cloud="$(_epac_cloud_to_az_cloud "$cloud")"
    local current_cloud
    current_cloud="$(az cloud show --query name -o tsv 2>/dev/null)" || current_cloud=""

    if [[ -n "$current_cloud" && "${current_cloud,,}" != "${az_cloud,,}" ]]; then
        epac_log_info "Switching Azure cloud to ${az_cloud}..."
        az cloud set --name "$az_cloud" || epac_die "Failed to set Azure cloud to ${az_cloud}"
    fi

    # Set subscription context if specified
    if [[ -n "$default_context" ]]; then
        az account set --subscription "$default_context" 2>/dev/null || true
    fi

    # Check current context
    local account
    account="$(epac_get_az_context)" || account=""

    local current_tenant=""
    if [[ -n "$account" ]]; then
        current_tenant="$(echo "$account" | jq -r '.tenantId // empty')"
    fi

    if [[ -z "$account" || "$current_tenant" != "$tenant_id" ]]; then
        # Wrong tenant or not logged in
        if [[ "$interactive" == "true" ]]; then
            epac_log_info "Logging in to tenant ${tenant_id}..."
            az login --tenant "$tenant_id" || epac_die "Failed to login to tenant ${tenant_id}"

            if [[ -n "$default_context" ]]; then
                az account set --subscription "$default_context" 2>/dev/null || true
            else
                # Pick first subscription in the tenant
                local first_sub
                first_sub="$(az account list --tenant "$tenant_id" --query '[0].id' -o tsv 2>/dev/null)" || true
                if [[ -n "$first_sub" ]]; then
                    az account set --subscription "$first_sub" 2>/dev/null || true
                fi
            fi

            account="$(epac_get_az_context)" || epac_die "Failed to get Azure context after login"
        else
            epac_die "Wrong cloud or tenant logged in by SPN. Required cloud=${cloud}, tenantId=${tenant_id}. If running interactively, pass interactive=true."
        fi
    fi

    # Suppress Azure CLI warnings
    az config set core.only_show_errors=true 2>/dev/null || true

    echo "$account"
}

# Alias for backward compatibility
epac_set_cloud_tenant_subscription() {
    epac_set_az_cloud_tenant_subscription "$@"
}

# ─── Get access token for REST API calls ──────────────────────────────────────

epac_get_access_token() {
    local resource="${1:-https://management.azure.com}"
    az account get-access-token --resource "$resource" --query accessToken -o tsv 2>/dev/null || {
        epac_die "Failed to get access token for ${resource}. Are you logged in?"
    }
}

# ─── Get PAC folders ──────────────────────────────────────────────────────────
# Equivalent of Get-PacFolders.ps1

epac_get_pac_folders() {
    local definitions_root="${1:-}"
    local output_folder="${2:-}"
    local input_folder="${3:-}"

    # Resolve definitions root
    if [[ -z "$definitions_root" ]]; then
        definitions_root="${PAC_DEFINITIONS_FOLDER:-Definitions}"
    fi

    local global_settings_file="${definitions_root}/global-settings.jsonc"

    # Resolve output folder
    if [[ -z "$output_folder" ]]; then
        output_folder="${PAC_OUTPUT_FOLDER:-Output}"
    fi

    # Resolve input folder (only from env var or explicit arg, never defaults to output)
    if [[ -z "$input_folder" ]]; then
        input_folder="${PAC_INPUT_FOLDER:-}"
    fi

    jq -n \
        --arg drf "$definitions_root" \
        --arg gsf "$global_settings_file" \
        --arg out "$output_folder" \
        --arg inp "$input_folder" \
        '{"definitionsRootFolder": $drf, "globalSettingsFile": $gsf, "outputFolder": $out, "inputFolder": $inp}'
}

# ─── Switch PAC Environment ──────────────────────────────────────────────────
# Equivalent of Switch-PacEnvironment.ps1
# Takes the full pacEnvironments JSON, a selector key, and interactive flag.
# Logs in to the correct tenant and returns the pacEnvironment object.

epac_switch_pac_environment() {
    local pac_environments="$1"
    local selector="$2"
    local interactive="${3:-false}"

    # Check selector exists
    local pac_env
    pac_env="$(echo "$pac_environments" | jq --arg s "$selector" '.[$s] // empty')"
    if [[ -z "$pac_env" || "$pac_env" == "null" ]]; then
        epac_die "pacEnvironment '${selector}' does not exist"
    fi

    local cloud tenant_id
    cloud="$(echo "$pac_env" | jq -r '.cloud // "AzureCloud"')"
    tenant_id="$(echo "$pac_env" | jq -r '.tenantId')"

    epac_set_az_cloud_tenant_subscription "$cloud" "$tenant_id" "$interactive" > /dev/null

    echo "$pac_env"
}

# ─── Select PAC Environment (with interactive prompt) ─────────────────────────
# Equivalent of Select-PacEnvironment.ps1
# This is the main entry point that loads global settings, selects environment,
# and returns a full environment definition with plan file paths and API versions.

epac_select_pac_environment() {
    local pac_selector="${1:-}"
    local definitions_root="${2:-}"
    local output_folder="${3:-}"
    local input_folder="${4:-}"
    local interactive="${5:-false}"
    local pick_first="${6:-false}"

    # Get global settings (requires lib/config.sh from WI-03)
    # For now, we provide the interface; actual implementation will be
    # completed when config.sh is available. We call the function if it exists.
    local global_settings
    if type epac_get_global_settings &>/dev/null; then
        global_settings="$(epac_get_global_settings "$definitions_root" "$output_folder" "$input_folder")"
    else
        epac_die "Global settings loader not available. Ensure lib/config.sh is loaded (WI-03)."
    fi

    local pac_environments
    pac_environments="$(echo "$global_settings" | jq '.pacEnvironments')"

    local pac_selectors
    pac_selectors="$(echo "$global_settings" | jq -r '.pacEnvironmentSelectors[]')"

    # Pick first if requested
    if [[ "$pick_first" == "true" ]]; then
        pac_selector="$(echo "$pac_selectors" | head -1)"
    fi

    # If no selector provided, prompt interactively
    if [[ -z "$pac_selector" ]]; then
        interactive="true"
        local env_count
        env_count="$(echo "$pac_environments" | jq 'length')"

        if [[ "$env_count" -eq 1 ]]; then
            pac_selector="$(echo "$pac_selectors" | head -1)"
        else
            local prompt
            prompt="$(echo "$global_settings" | jq -r '.pacEnvironmentPrompt // empty')"
            while true; do
                echo "" >&2
                read -rp "Select Policy as Code environment [${prompt}]: " pac_selector
                if echo "$pac_environments" | jq -e --arg s "$pac_selector" 'has($s)' &>/dev/null; then
                    break
                else
                    epac_write_status "Invalid selection entered. Please try again." "warning" 2
                fi
            done
        fi
    else
        if ! echo "$pac_environments" | jq -e --arg s "$pac_selector" 'has($s)' &>/dev/null; then
            epac_die "Policy as Code environment selector '${pac_selector}' is not valid"
        fi
    fi

    local pac_env
    pac_env="$(echo "$pac_environments" | jq --arg s "$pac_selector" '.[$s]')"

    local cloud tenant_id deployment_root_scope
    cloud="$(echo "$pac_env" | jq -r '.cloud // "AzureCloud"')"
    tenant_id="$(echo "$pac_env" | jq -r '.tenantId')"
    deployment_root_scope="$(echo "$pac_env" | jq -r '.deploymentRootScope // empty')"

    # Display selection (to stderr so stdout stays clean for JSON return)
    epac_write_section "PAC Environment Selected" 0 >&2
    epac_write_status "Environment: ${pac_selector}" "success" 2 >&2
    epac_write_status "Cloud: ${cloud}" "info" 2 >&2
    epac_write_status "Tenant ID: ${tenant_id}" "info" 2 >&2
    epac_write_status "Deployment Root Scope: ${deployment_root_scope}" "info" 2 >&2

    # Resolve folders — prefer function args, fall back to global settings, then defaults
    local gs_output gs_input
    gs_output="$(echo "$global_settings" | jq -r '.outputFolder // empty')"
    gs_input="$(echo "$global_settings" | jq -r '.inputFolder // empty')"
    # Use global settings value if valid, otherwise keep function arg
    [[ -n "$gs_output" && "$gs_output" != "false" ]] && output_folder="$gs_output"
    [[ -z "$output_folder" ]] && output_folder="./Output"
    # Input folder: function arg > global settings > leave empty (deploy scripts set their own default)
    if [[ -n "$gs_input" && "$gs_input" != "false" ]]; then
        input_folder="$gs_input"
    fi
    [[ "$input_folder" == "false" ]] && input_folder=""

    # Get API versions for cloud
    local api_versions
    api_versions="$(_epac_api_versions_for_cloud "$cloud")"

    # Build plan file paths
    local plan_files
    plan_files="$(jq -n \
        --argjson interactive "$([ "$interactive" == "true" ] && echo true || echo false)" \
        --arg policy_plan_out "${output_folder}/plans-${pac_selector}/policy-plan.json" \
        --arg roles_plan_out "${output_folder}/plans-${pac_selector}/roles-plan.json" \
        --arg policy_plan_in "${input_folder:-$output_folder}/plans-${pac_selector}/policy-plan.json" \
        --arg roles_plan_in "${input_folder:-$output_folder}/plans-${pac_selector}/roles-plan.json" \
        '{
            interactive: $interactive,
            policyPlanOutputFile: $policy_plan_out,
            rolesPlanOutputFile: $roles_plan_out,
            policyPlanInputFile: $policy_plan_in,
            rolesPlanInputFile: $roles_plan_in
        }'
    )"

    # Merge everything into final environment definition
    jq -n \
        --argjson env "$pac_env" \
        --argjson plans "$plan_files" \
        --argjson global "$global_settings" \
        --argjson apiVersions "$api_versions" \
        '$env + $plans + $global + {apiVersions: $apiVersions}'
}

# ─── Telemetry ────────────────────────────────────────────────────────────────
# Equivalent of Submit-EPACTelemetry.ps1
# Sends a tracking deployment (expected to fail — only the PID matters in logs).

epac_submit_telemetry() {
    local cuapid="$1"
    local deployment_root_scope="$2"

    local scope_lower="${deployment_root_scope,,}"
    local uri=""

    if [[ "$scope_lower" == *"microsoft.management/managementgroups"* ]]; then
        local mg_id="${deployment_root_scope##*/}"
        uri="https://management.azure.com/providers/Microsoft.Management/managementGroups/${mg_id}/providers/Microsoft.Resources/deployments/${cuapid}?api-version=2021-04-01"
    elif [[ "$scope_lower" == *"subscriptions"* ]]; then
        local sub_id="${deployment_root_scope##*/}"
        uri="https://management.azure.com/subscriptions/${sub_id}/providers/Microsoft.Resources/deployments/${cuapid}?api-version=2021-04-01"
    else
        local sub_id
        sub_id="$(az account show --query id -o tsv 2>/dev/null)" || sub_id=""
        if [[ -z "$sub_id" ]]; then
            return 0  # Can't send telemetry without subscription
        fi
        uri="https://management.azure.com/subscriptions/${sub_id}/providers/Microsoft.Resources/deployments/${cuapid}?api-version=2021-04-01"
    fi

    if [[ -n "$uri" ]]; then
        local token
        token="$(epac_get_access_token 2>/dev/null)" || return 0
        # Fire and forget — expected to fail
        curl -s -X PUT \
            -H "Authorization: Bearer ${token}" \
            -H "Content-Type: application/json" \
            -d '{"properties":{"mode":"Incremental","template":{"$schema":"https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#","contentVersion":"1.0.0.0","resources":[]}}}' \
            "$uri" &>/dev/null &
    fi
}

# ─── Invoke Azure REST Method ─────────────────────────────────────────────────
# Core wrapper replacing Invoke-AzRestMethod. Used by all REST API wrappers.
# Returns JSON response body. Sets EPAC_REST_STATUS_CODE.

EPAC_REST_STATUS_CODE=""

epac_invoke_az_rest() {
    local method="$1"
    local uri="$2"
    local body="${3:-}"
    local max_retries="${4:-3}"

    # URL-encode spaces in URI path (e.g. assignment names with spaces)
    uri="${uri// /%20}"

    local token
    token="$(epac_get_access_token)" || return 1

    local retry_count=0
    local response status_code

    while [[ $retry_count -le $max_retries ]]; do
        local curl_args=(
            -s -w "\n%{http_code}"
            -X "$method"
            -H "Authorization: Bearer ${token}"
            -H "Content-Type: application/json"
        )

        if [[ -n "$body" && "$method" != "GET" && "$method" != "DELETE" ]]; then
            curl_args+=(-d "$body")
        fi

        curl_args+=("$uri")

        local raw_response
        raw_response="$(curl "${curl_args[@]}" 2>/dev/null)" || {
            retry_count=$((retry_count + 1))
            if [[ $retry_count -le $max_retries ]]; then
                epac_log_warning "REST call failed, retrying (${retry_count}/${max_retries})..."
                sleep "$((retry_count * 2))"
                continue
            fi
            epac_log_error "REST call failed after ${max_retries} retries: ${method} ${uri}"
            return 1
        }

        # Split response body and status code
        status_code="$(echo "$raw_response" | tail -1)"
        response="$(echo "$raw_response" | sed '$d')"

        EPAC_REST_STATUS_CODE="$status_code"

        # Handle throttling (429)
        if [[ "$status_code" == "429" ]]; then
            local retry_after
            retry_after="$((retry_count * 5 + 5))"
            epac_log_warning "Throttled (429), waiting ${retry_after}s before retry..."
            sleep "$retry_after"
            retry_count=$((retry_count + 1))
            continue
        fi

        # Success (2xx)
        if [[ "$status_code" =~ ^2[0-9][0-9]$ ]]; then
            echo "$response"
            return 0
        fi

        # Client error (4xx) — don't retry except for 429 (handled above)
        if [[ "$status_code" =~ ^4[0-9][0-9]$ ]]; then
            epac_log_error "REST ${method} ${uri} returned ${status_code}: ${response}"
            echo "$response"
            return 1
        fi

        # Server error (5xx) — retry
        if [[ "$status_code" =~ ^5[0-9][0-9]$ ]]; then
            retry_count=$((retry_count + 1))
            if [[ $retry_count -le $max_retries ]]; then
                epac_log_warning "Server error ${status_code}, retrying (${retry_count}/${max_retries})..."
                sleep "$((retry_count * 2))"
                continue
            fi
            epac_log_error "REST ${method} ${uri} returned ${status_code} after ${max_retries} retries"
            echo "$response"
            return 1
        fi

        # Unknown status
        epac_log_error "Unexpected HTTP status ${status_code} from ${method} ${uri}"
        echo "$response"
        return 1
    done
}
