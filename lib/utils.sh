#!/usr/bin/env bash
# lib/utils.sh — String manipulation, array operations, file path utilities
# Replaces PowerShell helpers: Get-ScrubbedString, Split-ArrayIntoChunks,
# Get-DefinitionsFullPath, Split-ScopeId, Split-AzPolicyResourceId, etc.

[[ -n "${_EPAC_UTILS_LOADED:-}" ]] && return 0
readonly _EPAC_UTILS_LOADED=1

# shellcheck source=core.sh
source "${BASH_SOURCE[0]%/*}/core.sh"

# ─── String scrubbing ────────────────────────────────────────────────────────
# Equivalent of Get-ScrubbedString.ps1
# Cleans a string by removing invalid characters, replacing spaces, etc.
#
# Usage: epac_scrub_string "my string" [options]
#   Options (as environment-style):
#     -i "chars"    Invalid characters to remove (string of chars)
#     -r "str"      Replace invalid chars with this (default: "")
#     -s            Replace spaces
#     -S "str"      Replace spaces with this (default: "")
#     -m N          Max length (0 = no limit)
#     -t            Trim leading/trailing whitespace
#     -l            Convert to lowercase
#     -1            Single-replace (collapse consecutive replacements)

epac_scrub_string() {
    local input="$1"
    shift

    local invalid_chars=""
    local replace_with=""
    local replace_spaces=false
    local replace_spaces_with=""
    local max_length=0
    local trim_ends=false
    local to_lower=false
    local single_replace=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -i) invalid_chars="$2"; shift 2 ;;
            -r) replace_with="$2"; shift 2 ;;
            -s) replace_spaces=true; shift ;;
            -S) replace_spaces_with="$2"; shift 2 ;;
            -m) max_length="$2"; shift 2 ;;
            -t) trim_ends=true; shift ;;
            -l) to_lower=true; shift ;;
            -1) single_replace=true; shift ;;
            *)  shift ;;
        esac
    done

    local result="$input"

    # Trim
    if $trim_ends; then
        result="$(echo "$result" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    fi

    # Lowercase
    if $to_lower; then
        result="${result,,}"
    fi

    # Remove invalid characters
    if [[ -n "$invalid_chars" ]]; then
        # Build sed character class from invalid chars (escape special chars)
        local escaped
        escaped="$(printf '%s' "$invalid_chars" | sed 's/[][\\/.*^$]/\\&/g')"
        result="$(echo "$result" | tr -d "$invalid_chars")"
        if [[ -n "$replace_with" ]]; then
            # Re-do with tr replacing instead of deleting
            result="$input"
            if $trim_ends; then
                result="$(echo "$result" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            fi
            if $to_lower; then
                result="${result,,}"
            fi
            # Replace each invalid char with replace_with
            local tmp=""
            local i
            for (( i=0; i<${#result}; i++ )); do
                local ch="${result:$i:1}"
                if [[ "$invalid_chars" == *"$ch"* ]]; then
                    tmp+="$replace_with"
                else
                    tmp+="$ch"
                fi
            done
            result="$tmp"
        fi

        # Collapse consecutive replacements
        if $single_replace && [[ -n "$replace_with" ]]; then
            local prev=""
            while [[ "$result" != "$prev" ]]; do
                prev="$result"
                result="${result//${replace_with}${replace_with}/${replace_with}}"
            done
        fi
    fi

    # Replace spaces
    if $replace_spaces; then
        if $single_replace; then
            local prev=""
            while [[ "$result" != "$prev" ]]; do
                prev="$result"
                result="${result//  / }"
            done
        fi
        result="${result// /${replace_spaces_with}}"
        if $single_replace && [[ -n "$replace_spaces_with" ]]; then
            local prev=""
            while [[ "$result" != "$prev" ]]; do
                prev="$result"
                result="${result//${replace_spaces_with}${replace_spaces_with}/${replace_spaces_with}}"
            done
        fi
    fi

    # Max length
    if [[ "$max_length" -gt 0 && "${#result}" -gt "$max_length" ]]; then
        result="${result:0:$max_length}"
    fi

    echo "$result"
}

# ─── Definitions full path ───────────────────────────────────────────────────
# Equivalent of Get-DefinitionsFullPath.ps1

epac_definitions_full_path() {
    local folder="$1"
    local raw_subfolder="${2:-}"
    local file_suffix="${3:-}"
    local name="$4"
    local display_name="${5:-}"
    local invalid_chars="${6:-}"
    local max_length_subfolder="${7:-0}"
    local max_length_filename="${8:-0}"
    local file_extension="${9:-json}"

    local subfolder="Unknown"
    if [[ -n "$raw_subfolder" ]]; then
        local sub
        sub="$(epac_scrub_string "$raw_subfolder" -i "$invalid_chars" -m "$max_length_subfolder" -t -1)"
        if [[ -n "$sub" ]]; then
            subfolder="$sub"
        fi
    fi

    local filename="$name"
    if epac_is_guid "$name"; then
        # Avoid GUID filenames — use display name instead
        if [[ -n "$display_name" ]]; then
            local temp
            temp="$(epac_scrub_string "$display_name" -i "$invalid_chars" -r "" -s -S "-" -m "$max_length_filename" -t -l -1)"
            if [[ -n "$temp" ]]; then
                filename="$temp"
            fi
        fi
    else
        filename="$(epac_scrub_string "$name" -i "$invalid_chars" -r "" -s -S "-" -m "$max_length_filename" -t -l -1)"
    fi

    local full_path
    if [[ -n "$raw_subfolder" ]]; then
        full_path="${folder}/${subfolder}/${filename}${file_suffix}.${file_extension}"
    else
        full_path="${folder}/${filename}${file_suffix}.${file_extension}"
    fi

    echo "$full_path"
}

# ─── Array chunking ──────────────────────────────────────────────────────────
# Equivalent of Split-ArrayIntoChunks.ps1
# Input: newline-separated items on stdin or as arguments
# Output: chunk files in a temp directory, prints directory path
#
# Usage: echo -e "a\nb\nc\nd\ne" | epac_split_array_chunks 3 2
#        Returns path to dir containing chunk_0, chunk_1, ... files

epac_split_array_chunks() {
    local num_chunks="${1:-5}"
    local min_chunk_size="${2:-5}"

    # Read all items
    local -a items=()
    while IFS= read -r line; do
        items+=("$line")
    done

    local count=${#items[@]}
    local chunk_dir
    chunk_dir="$(mktemp -d "${TMPDIR:-/tmp}/epac-chunks.XXXXXX")"

    if [[ $count -le $min_chunk_size ]]; then
        printf '%s\n' "${items[@]}" > "${chunk_dir}/chunk_0"
        echo "$chunk_dir"
        return
    fi

    local chunk_size=$(( (count + num_chunks - 1) / num_chunks ))
    if [[ $chunk_size -lt $min_chunk_size ]]; then
        num_chunks=$(( (count + min_chunk_size - 1) / min_chunk_size ))
        chunk_size=$(( (count + num_chunks - 1) / num_chunks ))
    fi

    if [[ $num_chunks -eq 1 ]]; then
        printf '%s\n' "${items[@]}" > "${chunk_dir}/chunk_0"
        echo "$chunk_dir"
        return
    fi

    local i chunk_idx=0
    for (( i=0; i<count; i+=chunk_size )); do
        local end=$((i + chunk_size))
        [[ $end -gt $count ]] && end=$count
        printf '%s\n' "${items[@]:$i:$((end - i))}" > "${chunk_dir}/chunk_${chunk_idx}"
        chunk_idx=$((chunk_idx + 1))
    done

    echo "$chunk_dir"
}

# ─── Scope ID parsing ────────────────────────────────────────────────────────
# Equivalent of Split-ScopeId.ps1
# Input: Azure scope string like /providers/Microsoft.Management/managementGroups/mg1
#        or /subscriptions/sub-guid/resourceGroups/rg1
# Output: JSON object with parsed components

epac_split_scope_id() {
    local scope_id="$1"

    # Normalize: lowercase for comparison, but keep original case
    local scope_lower="${scope_id,,}"

    if [[ "$scope_lower" == /providers/microsoft.management/managementgroups/* ]]; then
        local mg_name="${scope_id#/providers/Microsoft.Management/managementGroups/}"
        mg_name="${mg_name%%/*}"
        jq -n --arg scope "$scope_id" --arg mg "$mg_name" '{
            scope: $scope,
            type: "managementGroup",
            managementGroupName: $mg
        }'
    elif [[ "$scope_lower" == /subscriptions/* ]]; then
        local rest="${scope_id#/subscriptions/}"
        local sub_id="${rest%%/*}"
        local rg_part="${rest#*/}"

        if [[ "$rg_part" != "$rest" && "$rg_part" == resourceGroups/* ]]; then
            local rg_name="${rg_part#resourceGroups/}"
            rg_name="${rg_name%%/*}"
            jq -n --arg scope "$scope_id" --arg sub "$sub_id" --arg rg "$rg_name" '{
                scope: $scope,
                type: "resourceGroup",
                subscriptionId: $sub,
                resourceGroupName: $rg
            }'
        else
            jq -n --arg scope "$scope_id" --arg sub "$sub_id" '{
                scope: $scope,
                type: "subscription",
                subscriptionId: $sub
            }'
        fi
    else
        jq -n --arg scope "$scope_id" '{
            scope: $scope,
            type: "unknown"
        }'
    fi
}

# ─── Policy Resource ID parsing ──────────────────────────────────────────────
# Equivalent of Split-AzPolicyResourceId.ps1

epac_split_policy_resource_id() {
    local resource_id="$1"
    local id_lower="${resource_id,,}"

    local scope="" resource_type="" name=""

    # Extract resource type and name from the end
    if [[ "$id_lower" == */providers/microsoft.authorization/policydefinitions/* ]]; then
        resource_type="policyDefinitions"
        name="${resource_id##*/providers/Microsoft.Authorization/policyDefinitions/}"
        scope="${resource_id%%/providers/Microsoft.Authorization/policyDefinitions/*}"
    elif [[ "$id_lower" == */providers/microsoft.authorization/policysetdefinitions/* ]]; then
        resource_type="policySetDefinitions"
        name="${resource_id##*/providers/Microsoft.Authorization/policySetDefinitions/}"
        scope="${resource_id%%/providers/Microsoft.Authorization/policySetDefinitions/*}"
    elif [[ "$id_lower" == */providers/microsoft.authorization/policyassignments/* ]]; then
        resource_type="policyAssignments"
        name="${resource_id##*/providers/Microsoft.Authorization/policyAssignments/}"
        scope="${resource_id%%/providers/Microsoft.Authorization/policyAssignments/*}"
    elif [[ "$id_lower" == */providers/microsoft.authorization/policyexemptions/* ]]; then
        resource_type="policyExemptions"
        name="${resource_id##*/providers/Microsoft.Authorization/policyExemptions/}"
        scope="${resource_id%%/providers/Microsoft.Authorization/policyExemptions/*}"
    else
        resource_type="unknown"
        name="${resource_id##*/}"
        scope="${resource_id%/*}"
    fi

    # Remove trailing slash from name if any
    name="${name%%/*}"

    jq -n --arg id "$resource_id" --arg scope "$scope" \
          --arg type "$resource_type" --arg name "$name" '{
        id: $id,
        scope: $scope,
        resourceType: $type,
        name: $name
    }'
}

# ─── Parameter name extraction ───────────────────────────────────────────────
# Equivalent of Get-ParameterNameFromValueString.ps1
# Extracts parameter name from "[parameters('paramName')]" format

epac_get_parameter_name() {
    local value_string="$1"
    local result=""

    # Match [parameters('name')] or [parameters("name")]
    if [[ "$value_string" =~ \[parameters\([\'\"](.*)[\'\"]\)\] ]]; then
        result="${BASH_REMATCH[1]}"
    fi

    echo "$result"
}

# ─── File path utilities ─────────────────────────────────────────────────────

# Get relative path from base to target
epac_relative_path() {
    local base="$1"
    local target="$2"
    python3 -c "import os; print(os.path.relpath('$target', '$base'))"
}

# Ensure directory exists
epac_ensure_dir() {
    local dir="$1"
    [[ -d "$dir" ]] || mkdir -p "$dir"
}

# ─── Associative array helpers ────────────────────────────────────────────────
# Bash doesn't have ordered hashtables, but we can use files or jq for ordered ops.

# Convert a bash associative array to JSON object
# Usage: declare -A mymap=([key1]=val1 [key2]=val2)
#        epac_assoc_to_json mymap
epac_assoc_to_json() {
    local -n _map=$1
    local json="{}"
    for key in "${!_map[@]}"; do
        local val="${_map[$key]}"
        # Try to parse as JSON first; if it fails, treat as string
        if echo "$val" | jq '.' &>/dev/null; then
            json="$(echo "$json" | jq --arg k "$key" --argjson v "$val" '. + {($k): $v}')"
        else
            json="$(echo "$json" | jq --arg k "$key" --arg v "$val" '. + {($k): $v}')"
        fi
    done
    echo "$json"
}

# ─── Math helpers ─────────────────────────────────────────────────────────────

epac_ceil_div() {
    local numerator=$1
    local denominator=$2
    echo $(( (numerator + denominator - 1) / denominator ))
}

epac_min() {
    local a=$1 b=$2
    echo $(( a < b ? a : b ))
}

epac_max() {
    local a=$1 b=$2
    echo $(( a > b ? a : b ))
}
