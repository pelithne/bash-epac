#!/usr/bin/env bash
# lib/hydration/hydration-mg.sh — Management group operations for hydration kit
[[ -n "${_EPAC_HYDRATION_MG_LOADED:-}" ]] && return 0
_EPAC_HYDRATION_MG_LOADED=1

SCRIPT_DIR_HM="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_HM}/hydration-core.sh"

# ══════════════════════════════════════════════════════════════════════════════
# CAF 3.0 Standard Hierarchy
# ══════════════════════════════════════════════════════════════════════════════

# The CAF 3.0 hierarchy layout:
# <Root>
# ├── Platform (Identity, Management, Connectivity, Security)
# ├── LandingZones (Corp, Online)
# ├── Decommissioned
# └── Sandbox

# Create CAF 3.0 management group hierarchy
# Usage: hydration_create_caf3 <root_name> [prefix] [suffix]
hydration_create_caf3() {
    local root_name="$1" prefix="${2:-}" suffix="${3:-}"
    local updated_root="${prefix}${root_name}${suffix}"

    # Root level children
    local -A hierarchy
    hierarchy["${updated_root}"]="Platform LandingZones Decommissioned Sandbox"
    hierarchy["Platform"]="Identity Management Connectivity Security"
    hierarchy["LandingZones"]="Corp Online"

    # Create root if needed
    if ! az account management-group show --name "$updated_root" &>/dev/null; then
        echo -e "\033[33mCreating root Management Group $updated_root\033[0m"
        az account management-group create --name "$updated_root" --display-name "$updated_root" -o none || {
            epac_log_error "Failed to create root Management Group $updated_root"
            return 1
        }
    else
        echo -e "\033[32mRoot Management Group $updated_root already exists.\033[0m"
    fi

    # Create children
    for parent_key in "$updated_root" "Platform" "LandingZones"; do
        local parent_name
        if [[ "$parent_key" == "$updated_root" ]]; then
            parent_name="$updated_root"
        else
            parent_name="${prefix}${parent_key}${suffix}"
        fi

        local parent_id="/providers/Microsoft.Management/managementGroups/${parent_name}"
        local children="${hierarchy[$parent_key]}"

        for child in $children; do
            local child_name="${prefix}${child}${suffix}"
            _hydration_create_mg_with_retry "$child_name" "$parent_id" 10
        done
    done
}

# Create a single management group with retry logic
_hydration_create_mg_with_retry() {
    local name="$1" parent_id="$2" max_attempts="${3:-10}"
    local i=0

    while [[ $i -lt $max_attempts ]]; do
        # Check if already exists in correct parent
        local existing
        existing="$(az account management-group show --name "$name" -o json 2>/dev/null || true)"
        if [[ -n "$existing" ]]; then
            local current_parent
            current_parent="$(echo "$existing" | jq -r '.details.parent.id // empty')"
            if [[ "$current_parent" == "$parent_id" ]]; then
                echo "  Verified $name in $parent_id"
                return 0
            elif [[ -n "$current_parent" ]]; then
                echo -e "\033[33m  Warning: $name exists in $current_parent, expected $parent_id\033[0m"
                return 1
            fi
        fi

        # Create
        if az account management-group create --name "$name" --display-name "$name" --parent "$parent_id" -o none 2>/dev/null; then
            echo "  Created $name in $parent_id"
            return 0
        fi

        i=$((i + 1))
        if [[ $i -lt $max_attempts ]]; then
            echo "  Retry $i/$max_attempts for $name (waiting 30s)..."
            sleep 30
        fi
    done

    epac_log_error "Failed to create Management Group $name after $max_attempts attempts"
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Copy Management Group Hierarchy
# ══════════════════════════════════════════════════════════════════════════════

# Copy (clone) an existing MG hierarchy with prefix/suffix
# Usage: hydration_copy_mg_hierarchy <source> <dest_parent> [prefix] [suffix]
hydration_copy_mg_hierarchy() {
    local source="$1" dest_parent="$2" prefix="${3:-}" suffix="${4:-}"

    if [[ -z "$prefix" && -z "$suffix" ]]; then
        epac_log_error "You must provide a --prefix, --suffix, or both to avoid naming collisions."
        return 1
    fi

    # Verify destination parent exists
    if ! az account management-group show --name "$dest_parent" &>/dev/null; then
        epac_log_error "Destination parent group '$dest_parent' not found."
        return 1
    fi

    # Get source hierarchy
    local hierarchy_json
    hierarchy_json="$(az rest --method GET \
        --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/${source}?api-version=2021-04-01&\$expand=children&\$recurse=true" \
        2>/dev/null)" || {
        epac_log_error "Failed to retrieve source hierarchy for '$source'"
        return 1
    }

    local new_root="${prefix}${source}${suffix}"
    local dest_id="/providers/Microsoft.Management/managementGroups/${dest_parent}"

    echo "Creating ${new_root} under ${dest_parent}..."
    az account management-group create --name "$new_root" --display-name "$new_root" --parent "$dest_id" -o none 2>/dev/null || true

    # Recursively create children
    _hydration_copy_mg_children "$hierarchy_json" "$prefix" "$suffix"
}

# Recursive helper to create children
_hydration_copy_mg_children() {
    local hierarchy_json="$1" prefix="$2" suffix="$3"

    local children
    children="$(echo "$hierarchy_json" | jq -c '.properties.children // [] | .[]' 2>/dev/null)" || return 0

    while IFS= read -r child; do
        [[ -z "$child" ]] && continue
        local child_name child_parent
        child_name="$(echo "$child" | jq -r '.name')"
        child_parent="$(echo "$hierarchy_json" | jq -r '.name')"

        local new_child="${prefix}${child_name}${suffix}"
        local new_parent="${prefix}${child_parent}${suffix}"
        local parent_id="/providers/Microsoft.Management/managementGroups/${new_parent}"

        _hydration_create_mg_with_retry "$new_child" "$parent_id" 10

        # Recurse into grandchildren
        _hydration_copy_mg_children "$child" "$prefix" "$suffix"
    done <<< "$children"
}

# ══════════════════════════════════════════════════════════════════════════════
# Remove Management Group Hierarchy
# ══════════════════════════════════════════════════════════════════════════════

# Recursively remove a management group and all children
# Usage: hydration_remove_mg_recursive <root_name>
hydration_remove_mg_recursive() {
    local root_name="$1"

    # Get full hierarchy
    local hierarchy_json
    hierarchy_json="$(az rest --method GET \
        --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/${root_name}?api-version=2021-04-01&\$expand=children&\$recurse=true" \
        2>/dev/null)" || {
        epac_log_error "Failed to retrieve hierarchy for '$root_name'"
        return 1
    }

    # Remove children first (depth-first)
    _hydration_remove_mg_children "$hierarchy_json"

    # Remove root
    _hydration_remove_mg_with_retry "$root_name" 6
}

_hydration_remove_mg_children() {
    local hierarchy_json="$1"
    local children
    children="$(echo "$hierarchy_json" | jq -c '.properties.children // [] | .[]' 2>/dev/null)" || return 0

    while IFS= read -r child; do
        [[ -z "$child" ]] && continue
        # Recurse into grandchildren first
        _hydration_remove_mg_children "$child"
        local child_name
        child_name="$(echo "$child" | jq -r '.name')"
        _hydration_remove_mg_with_retry "$child_name" 6
    done <<< "$children"
}

_hydration_remove_mg_with_retry() {
    local name="$1" max_attempts="${2:-6}"
    local i=0

    while [[ $i -lt $max_attempts ]]; do
        if ! az account management-group show --name "$name" &>/dev/null; then
            echo "  $name confirmed removed."
            return 0
        fi

        echo "  Removing $name..."
        az account management-group delete --name "$name" -o none 2>/dev/null || true

        if ! az account management-group show --name "$name" &>/dev/null; then
            echo "  $name confirmed removed."
            return 0
        fi

        i=$((i + 1))
        if [[ $i -lt $max_attempts ]]; then
            echo "  Retry $i/$max_attempts for removing $name..."
            sleep 10
        fi
    done

    epac_log_error "Failed to remove $name after $max_attempts attempts"
    return 1
}

# ══════════════════════════════════════════════════════════════════════════════
# Test CAF3 Hierarchy
# ══════════════════════════════════════════════════════════════════════════════

# Verify CAF3 hierarchy exists and is correctly structured
# Usage: hydration_test_caf3 <root_name> [prefix] [suffix]
hydration_test_caf3() {
    local root_name="$1" prefix="${2:-}" suffix="${3:-}"
    local updated_root="${prefix}${root_name}${suffix}"
    local errors=0

    # Expected: root → Platform, LandingZones, Decommissioned, Sandbox
    #           Platform → Identity, Management, Connectivity, Security
    #           LandingZones → Corp, Online
    local expected_groups=("Platform" "LandingZones" "Decommissioned" "Sandbox"
                           "Identity" "Management" "Connectivity" "Security"
                           "Corp" "Online")

    for group in "${expected_groups[@]}"; do
        local full_name="${prefix}${group}${suffix}"
        if ! az account management-group show --name "$full_name" &>/dev/null; then
            echo "  MISSING: $full_name"
            errors=$((errors + 1))
        else
            echo "  OK: $full_name"
        fi
    done

    return "$errors"
}

# ══════════════════════════════════════════════════════════════════════════════
# Get child management group names
# ══════════════════════════════════════════════════════════════════════════════

# Get list of child MG names for a given parent
hydration_get_mg_children() {
    local parent_name="$1"
    az rest --method GET \
        --url "https://management.azure.com/providers/Microsoft.Management/managementGroups/${parent_name}?api-version=2021-04-01&\$expand=children" \
        2>/dev/null | jq -r '.properties.children[]?.name // empty'
}
