#!/usr/bin/env bash
# lib/hydration/hydration-tests.sh — Connectivity, path, and RBAC test helpers
[[ -n "${_EPAC_HYDRATION_TESTS_LOADED:-}" ]] && return 0
_EPAC_HYDRATION_TESTS_LOADED=1

SCRIPT_DIR_HT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_HT}/hydration-core.sh"

# ══════════════════════════════════════════════════════════════════════════════
# Path Tests
# ══════════════════════════════════════════════════════════════════════════════

# Test and optionally create a local path
# Usage: result=$(hydration_test_path <path> [log_file])
# Returns: "Passed" or "Failed"
hydration_test_path() {
    local path="$1" log_file="${2:-}"

    if [[ -d "$path" ]]; then
        [[ -n "$log_file" ]] && hydration_log testResult "$path -- Passed" "$log_file" --silent
        echo "Passed"
        return 0
    fi

    # Try to create
    if mkdir -p "$path" 2>/dev/null; then
        [[ -n "$log_file" ]] && hydration_log testResult "$path -- Passed (created)" "$log_file" --silent
        echo "Passed"
        return 0
    fi

    [[ -n "$log_file" ]] && hydration_log testResult "$path -- Failed" "$log_file" --silent
    echo "Failed"
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Network Connectivity Tests
# ══════════════════════════════════════════════════════════════════════════════

# Test network connectivity to a host
# Usage: result=$(hydration_test_connection <fqdn> [log_file])
# Returns: "Passed" or "Failed"
hydration_test_connection() {
    local fqdn="$1" log_file="${2:-}"

    if curl -s --max-time 10 -o /dev/null -w '%{http_code}' "https://${fqdn}" 2>/dev/null | grep -qE '^[23]'; then
        [[ -n "$log_file" ]] && hydration_log testResult "$fqdn -- Passed" "$log_file" --silent
        echo "Passed"
        return 0
    fi

    # Fallback: try ping
    if ping -c 1 -W 5 "$fqdn" &>/dev/null; then
        [[ -n "$log_file" ]] && hydration_log testResult "$fqdn -- Passed (ping)" "$log_file" --silent
        echo "Passed"
        return 0
    fi

    [[ -n "$log_file" ]] && hydration_log testResult "$fqdn -- Failed" "$log_file" --silent
    echo "Failed"
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# RBAC Permission Tests
# ══════════════════════════════════════════════════════════════════════════════

# Test RBAC permissions at a given scope
# Usage: result=$(hydration_test_rbac <scope> [log_file])
# Returns: "Passed" or "Failed"
hydration_test_rbac() {
    local scope="$1" log_file="${2:-}"

    # Get current user/SP
    local account_info
    account_info="$(az account show -o json 2>/dev/null)" || {
        [[ -n "$log_file" ]] && hydration_log testResult "RBAC -- Failed (no Azure connection)" "$log_file" --silent
        echo "Failed"
        return 1
    }

    # Test: try to list role assignments at scope
    if az role assignment list --scope "$scope" --query "[0].id" -o tsv &>/dev/null; then
        [[ -n "$log_file" ]] && hydration_log testResult "RBAC $scope -- Passed" "$log_file" --silent
        echo "Passed"
        return 0
    fi

    [[ -n "$log_file" ]] && hydration_log testResult "RBAC $scope -- Failed" "$log_file" --silent
    echo "Failed"
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Git Installation Test
# ══════════════════════════════════════════════════════════════════════════════

# Test if git is available
# Returns: "Passed" or "Failed"
hydration_test_git() {
    if command -v git &>/dev/null; then
        echo "Passed"
    else
        echo "Failed"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Get Current User Object ID
# ══════════════════════════════════════════════════════════════════════════════

hydration_get_user_object_id() {
    az ad signed-in-user show --query id -o tsv 2>/dev/null || echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
# Download EPAC Repo
# ══════════════════════════════════════════════════════════════════════════════

# Clone / update EPAC repo into temp directory
# Usage: hydration_get_epac_repo <repo_root>
hydration_get_epac_repo() {
    local repo_root="$1"
    local temp_dir="${repo_root}/temp"

    if command -v git &>/dev/null; then
        if [[ -d "${temp_dir}/.git" ]]; then
            (cd "$temp_dir" && git pull --quiet 2>/dev/null) || true
        else
            rm -rf "$temp_dir"
            git clone --depth 1 --quiet https://github.com/Azure/enterprise-azure-policy-as-code.git "$temp_dir" 2>/dev/null || {
                epac_log_error "Failed to clone EPAC repo"
                return 1
            }
        fi
    else
        epac_log_error "git is not installed; cannot download EPAC repo automatically"
        return 1
    fi
}
