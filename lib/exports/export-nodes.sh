#!/usr/bin/env bash
# lib/exports/export-nodes.sh — Export tree node management for assignment collation
# Replaces: New-ExportNode.ps1, Set-ExportNode.ps1, Merge-ExportNodeChild.ps1,
#           Set-ExportNodeAncestors.ps1, Merge-ExportNodeAncestors.ps1,
#           Export-AssignmentNode.ps1, Get-ScrubbedString.ps1, Get-DefinitionsFullPath.ps1,
#           Remove-GlobalNotScopes.ps1, Remove-NullFields.ps1

[[ -n "${_EPAC_EXPORT_NODES_LOADED:-}" ]] && return 0
readonly _EPAC_EXPORT_NODES_LOADED=1

# ─── Get-ScrubbedString equivalent ──────────────────────────────────────────
# Cleans a string by removing invalid chars, replacing spaces, truncating.
# Usage: _epac_export_scrub_string <string> <invalid_chars_regex> [max_length] [--replace-spaces-with <char>] [--lower] [--trim]
_epac_export_scrub_string() {
    local str="$1"
    local invalid_chars="$2"   # literal characters to remove
    local max_length="${3:-0}"

    local replace_spaces_with=""
    local to_lower=false
    local trim_ends=false
    shift 3 || true
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --replace-spaces-with) replace_spaces_with="$2"; shift 2 ;;
            --lower) to_lower=true; shift ;;
            --trim) trim_ends=true; shift ;;
            *) shift ;;
        esac
    done

    if $trim_ends; then
        str="${str#"${str%%[![:space:]]*}"}"
        str="${str%"${str##*[![:space:]]}"}"
    fi
    if $to_lower; then
        str="${str,,}"
    fi
    if [[ -n "$invalid_chars" ]]; then
        # Remove each invalid char using tr -d
        str="$(printf '%s' "$str" | tr -d "$invalid_chars")"
        # Collapse multiple consecutive dashes/dots
        while [[ "$str" == *"--"* ]]; do str="${str//--/-}"; done
        while [[ "$str" == *".."* ]]; do str="${str/../.}"; done
    fi
    if [[ -n "$replace_spaces_with" ]]; then
        str="${str// /$replace_spaces_with}"
    fi
    if [[ "$max_length" -gt 0 && ${#str} -gt "$max_length" ]]; then
        str="${str:0:$max_length}"
    fi
    echo "$str"
}

# ─── Get-DefinitionsFullPath equivalent ─────────────────────────────────────
# Builds the full file path for a definition export file.
# Usage: epac_get_definitions_full_path <folder> <name> <display_name> <invalid_chars> <file_extension>
#        [--sub-folder <raw_sub_folder>] [--file-suffix <suffix>]
#        [--max-sub-folder <n>] [--max-filename <n>]
epac_get_definitions_full_path() {
    local folder="$1"
    local name="$2"
    local display_name="$3"
    local invalid_chars="$4"
    local file_extension="$5"
    shift 5

    local raw_sub_folder=""
    local file_suffix=""
    local max_sub_folder=30
    local max_filename=100

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sub-folder) raw_sub_folder="$2"; shift 2 ;;
            --file-suffix) file_suffix="$2"; shift 2 ;;
            --max-sub-folder) max_sub_folder="$2"; shift 2 ;;
            --max-filename) max_filename="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local sub_folder="Unknown"
    if [[ -n "$raw_sub_folder" ]]; then
        local scrubbed
        scrubbed="$(_epac_export_scrub_string "$raw_sub_folder" "$invalid_chars" "$max_sub_folder" --trim)"
        if [[ -n "$scrubbed" ]]; then
            sub_folder="$scrubbed"
        fi
    fi

    # Determine file name: avoid GUIDs by using display name
    local filename="$name"
    local guid_pattern='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    if [[ "$name" =~ $guid_pattern ]]; then
        local dn_scrubbed
        dn_scrubbed="$(_epac_export_scrub_string "$display_name" "$invalid_chars" "$max_filename" --replace-spaces-with "-" --lower --trim)"
        if [[ -n "$dn_scrubbed" ]]; then
            filename="$dn_scrubbed"
        fi
    else
        filename="$(_epac_export_scrub_string "$name" "$invalid_chars" "$max_filename" --replace-spaces-with "-" --lower --trim)"
    fi

    if [[ -n "$raw_sub_folder" ]]; then
        echo "${folder}/${sub_folder}/${filename}${file_suffix,,}.${file_extension}"
    else
        echo "${folder}/${filename}${file_suffix,,}.${file_extension}"
    fi
}

# ─── Remove-NullFields equivalent ──────────────────────────────────────────
# Recursively removes null-valued keys from a JSON object.
epac_remove_null_fields() {
    local json="$1"
    # Use jq walk to remove nulls recursively from objects (not arrays)
    echo "$json" | jq '
        def remove_nulls:
            if type == "object" then
                with_entries(select(.value != null))
                | map_values(remove_nulls)
            elif type == "array" then
                map(remove_nulls)
            else .
            end;
        remove_nulls
    '
}

# ─── Remove-GlobalNotScopes equivalent ──────────────────────────────────────
# Removes global not-scopes from assignment-level not-scopes.
# Returns JSON array of remaining not-scopes, or "null".
epac_remove_global_not_scopes() {
    local assignment_not_scopes="$1"  # JSON array or null
    local global_not_scopes="$2"      # JSON array or null

    if [[ -z "$assignment_not_scopes" ]] || epac_is_null_or_empty "$assignment_not_scopes"; then
        echo "null"
        return
    fi
    if [[ -z "$global_not_scopes" ]] || epac_is_null_or_empty "$global_not_scopes"; then
        echo "$assignment_not_scopes"
        return
    fi

    # Filter out any assignment notScope that matches a global notScope pattern
    # PS uses -like (wildcard *), we use jq contains/startswith for prefix matching
    jq -n --argjson ans "$assignment_not_scopes" --argjson gns "$global_not_scopes" '
        [$ans[] | . as $scope |
            if [$gns[] | . as $g |
                ($scope | test("^" + ($g | gsub("\\*"; ".*")) + "$"))
            ] | any
            then empty
            else $scope
            end
        ] | if length == 0 then null else . end
    '
}

# ─── New-ExportNode equivalent ──────────────────────────────────────────────
# Creates a new tree node. Per-pacSelector properties (scopes, notScopes,
# additionalRoleAssignments, identityEntry) are wrapped in {pacSelector: value}.
# Stores tree as JSON in temp files for efficient manipulation.
#
# Node structure (JSON):
# {
#   "<propertyName>": <value>,   // the property this node holds
#   "children": [],              // child nodes
#   "clusters": {}               // cluster tracking for Merge-ExportNodeAncestors
# }
#
# Returns: path to temp file containing node JSON
epac_new_export_node() {
    local pac_selector="$1"
    local property_name="$2"
    local property_value="$3"  # JSON

    local modified_value="$property_value"
    case "$property_name" in
        additionalRoleAssignments)
            # Wrap as array under pacSelector
            modified_value="$(jq -n --arg ps "$pac_selector" --argjson v "$property_value" \
                '{($ps): (if ($v | type) == "array" then $v else [$v] end)}')"
            ;;
        identityEntry|notScopes)
            modified_value="$(jq -n --arg ps "$pac_selector" --argjson v "$property_value" \
                '{($ps): $v}')"
            ;;
        scopes)
            # property_value may be a bare string or JSON-quoted string; normalize
            local sv="$property_value"
            sv="${sv#\"}"
            sv="${sv%\"}"
            modified_value="$(jq -n --arg ps "$pac_selector" --arg v "$sv" \
                '{($ps): [$v]}')"
            ;;
    esac

    local node_file
    node_file="$(mktemp)"
    jq -n --arg pn "$property_name" --argjson pv "$modified_value" \
        '{($pn): $pv, children: [], clusters: {}}' > "$node_file"
    echo "$node_file"
}

# ─── Merge-ExportNodeChild equivalent ───────────────────────────────────────
# Tries to merge a property value into an existing child of parent node.
# If no matching child found, creates a new child node.
# Returns: path to the matched/new child node file
epac_merge_export_node_child() {
    local parent_file="$1"
    local pac_selector="$2"
    local property_name="$3"
    local property_value="$4"  # JSON

    local parent_json
    parent_json="$(cat "$parent_file")"

    # Extract all children file paths at once
    local -a child_files
    mapfile -t child_files < <(echo "$parent_json" | jq -r '.children[]?' 2>/dev/null)

    local i=0
    for child_file in "${child_files[@]}"; do
        [[ -z "$child_file" ]] && continue
        local child_json
        child_json="$(cat "$child_file")"
        local child_value
        child_value="$(echo "$child_json" | jq --arg pn "$property_name" '.[$pn]')"

        local match=false
        case "$property_name" in
            additionalRoleAssignments|identityEntry)
                if echo "$child_value" | jq -e --arg ps "$pac_selector" 'has($ps)' >/dev/null 2>&1; then
                    # Check if pacSelector value matches
                    local existing_ps_val
                    existing_ps_val="$(echo "$child_value" | jq --arg ps "$pac_selector" '.[$ps]')"
                    if epac_deep_equal "$existing_ps_val" "$property_value"; then
                        match=true
                    fi
                else
                    # Different pacSelector — merge in
                    match=true
                    child_json="$(echo "$child_json" | jq --arg pn "$property_name" --arg ps "$pac_selector" --argjson v "$property_value" \
                        '.[$pn][$ps] = $v')"
                    echo "$child_json" > "$child_file"
                fi
                ;;
            notScopes)
                if echo "$child_value" | jq -e --arg ps "$pac_selector" 'has($ps)' >/dev/null 2>&1; then
                    local existing_ns
                    existing_ns="$(echo "$child_value" | jq --arg ps "$pac_selector" '.[$ps]')"
                    if epac_deep_equal "$existing_ns" "$property_value"; then
                        match=true
                    fi
                else
                    match=true
                    child_json="$(echo "$child_json" | jq --arg pn "$property_name" --arg ps "$pac_selector" --argjson v "$property_value" \
                        '.[$pn][$ps] = $v')"
                    echo "$child_json" > "$child_file"
                fi
                ;;
            scopes)
                match=true
                # Normalize: strip outer JSON quotes if present
                local sv="$property_value"
                sv="${sv#\"}"
                sv="${sv%\"}"
                if echo "$child_value" | jq -e --arg ps "$pac_selector" 'has($ps)' >/dev/null 2>&1; then
                    # Add scope to existing array if not already present
                    child_json="$(echo "$child_json" | jq --arg pn "$property_name" --arg ps "$pac_selector" --arg v "$sv" \
                        'if (.[$pn][$ps] | index($v)) then . else .[$pn][$ps] += [$v] end')"
                else
                    child_json="$(echo "$child_json" | jq --arg pn "$property_name" --arg ps "$pac_selector" --arg v "$sv" \
                        '.[$pn][$ps] = [$v]')"
                fi
                echo "$child_json" > "$child_file"
                ;;
            parameters)
                if epac_deep_equal "$child_value" "$property_value"; then
                    match=true
                fi
                ;;
            *)
                if epac_deep_equal "$child_value" "$property_value"; then
                    match=true
                fi
                ;;
        esac

        if $match; then
            echo "$child_file"
            return
        fi
    done

    # No match found — create new child node
    local new_child_file
    new_child_file="$(epac_new_export_node "$pac_selector" "$property_name" "$property_value")"

    # Add child file path to parent's children array
    parent_json="$(cat "$parent_file")"
    echo "$parent_json" | jq --arg cf "$new_child_file" '.children += [$cf]' > "$parent_file"

    echo "$new_child_file"
}

# ─── Set-ExportNode equivalent ──────────────────────────────────────────────
# Recursively builds the tree by walking through property names.
# properties_json is a JSON object with all property name/value pairs.
epac_set_export_node() {
    local parent_file="$1"
    local pac_selector="$2"
    local property_names_json="$3"  # JSON array of property name strings
    local properties_json="$4"      # JSON object of all properties
    local current_index="${5:-0}"

    # Extract all property names as array once
    local -a prop_names
    mapfile -t prop_names < <(echo "$property_names_json" | jq -r '.[]')
    local total=${#prop_names[@]}

    # Iterate instead of recursing
    local i=$current_index
    local current_parent="$parent_file"
    while [[ $i -lt $total ]]; do
        local pn="${prop_names[$i]}"
        local pv
        pv="$(echo "$properties_json" | jq --arg pn "$pn" '.[$pn]')"

        current_parent="$(epac_merge_export_node_child "$current_parent" "$pac_selector" "$pn" "$pv")"
        i=$((i + 1))
    done
}

# ─── Merge-ExportNodeAncestors equivalent ───────────────────────────────────
# Tries to merge property value into an ancestor's cluster for deduplication.
# Returns 0 if match found (already present), 1 if new value added.
epac_merge_export_node_ancestors() {
    local parent_file="$1"
    local property_name="$2"
    local property_value="$3"  # JSON

    local parent_json
    parent_json="$(cat "$parent_file")"
    local has_cluster
    has_cluster="$(echo "$parent_json" | jq --arg pn "$property_name" '.clusters | has($pn)')"

    if [[ "$has_cluster" == "false" ]]; then
        # First time seeing this property — set it on parent
        parent_json="$(echo "$parent_json" | jq --arg pn "$property_name" --argjson pv "$property_value" \
            '.clusters[$pn] = [$pv] | .[$pn] = $pv')"
        echo "$parent_json" > "$parent_file"
        return 1
    fi

    # Check if value already in cluster
    local cluster
    cluster="$(echo "$parent_json" | jq --arg pn "$property_name" '.clusters[$pn]')"
    local cluster_len
    cluster_len="$(echo "$cluster" | jq 'length')"

    local j=0
    while [[ $j -lt $cluster_len ]]; do
        local cluster_item
        cluster_item="$(echo "$cluster" | jq ".[$j]")"
        local is_match=false
        if [[ "$property_name" == "parameters" ]]; then
            if epac_confirm_parameters_usage_matches "$cluster_item" "$property_value"; then
                is_match=true
            fi
        else
            if epac_deep_equal "$cluster_item" "$property_value"; then
                is_match=true
            fi
        fi
        if $is_match; then
            return 0
        fi
        j=$((j + 1))
    done

    # New value — add to cluster and remove from parent (no longer unique)
    parent_json="$(echo "$parent_json" | jq --arg pn "$property_name" --argjson pv "$property_value" \
        '.clusters[$pn] += [$pv] | del(.[$pn])')"
    echo "$parent_json" > "$parent_file"
    return 1
}

# ─── Set-ExportNodeAncestors equivalent ─────────────────────────────────────
# Walks tree bottom-up to propagate properties to ancestors for deduplication.
epac_set_export_node_ancestors() {
    local current_file="$1"
    local property_names_json="$2"
    local current_index="${3:-0}"

    local property_name
    property_name="$(echo "$property_names_json" | jq -r ".[$current_index]")"
    local current_json
    current_json="$(cat "$current_file")"
    local property_value
    property_value="$(echo "$current_json" | jq --arg pn "$property_name" '.[$pn] // null')"

    if [[ "$property_value" != "null" ]]; then
        # Walk up ancestor chain via parent_file references
        local parent_file
        parent_file="$(echo "$current_json" | jq -r '.parent_file // empty')"
        while [[ -n "$parent_file" && -f "$parent_file" ]]; do
            if epac_merge_export_node_ancestors "$parent_file" "$property_name" "$property_value"; then
                break  # Found existing match — stop propagating
            fi
            local pj
            pj="$(cat "$parent_file")"
            parent_file="$(echo "$pj" | jq -r '.parent_file // empty')"
        done
    fi

    # Recurse into children for next property
    local next_index=$((current_index + 1))
    local total
    total="$(echo "$property_names_json" | jq 'length')"
    if [[ $next_index -lt $total ]]; then
        local children
        children="$(echo "$current_json" | jq -r '.children[]')"
        local child_file
        while IFS= read -r child_file; do
            [[ -z "$child_file" ]] && continue
            epac_set_export_node_ancestors "$child_file" "$property_names_json" "$next_index"
        done <<< "$children"
    fi
}

# ─── Export-AssignmentNode equivalent ───────────────────────────────────────
# Converts the internal tree node to an assignment JSON structure.
# Writes to stdout as JSON.
epac_export_assignment_node() {
    local tree_node_file="$1"
    local assignment_node="$2"    # JSON of current assignment node
    local property_names_json="$3" # JSON array of property names to process

    local tree_json
    tree_json="$(cat "$tree_node_file")"
    local remaining_names="[]"

    local total
    total="$(echo "$property_names_json" | jq 'length')"
    local i=0
    while [[ $i -lt $total ]]; do
        local pn
        pn="$(echo "$property_names_json" | jq -r ".[$i]")"
        local has_prop
        has_prop="$(echo "$tree_json" | jq --arg pn "$pn" 'has($pn)')"

        if [[ "$has_prop" == "true" ]]; then
            local pv
            pv="$(echo "$tree_json" | jq --arg pn "$pn" '.[$pn]')"
            assignment_node="$(_epac_add_assignment_property "$assignment_node" "$pn" "$pv")"
        else
            remaining_names="$(echo "$remaining_names" | jq --arg pn "$pn" '. += [$pn]')"
        fi
        i=$((i + 1))
    done

    # Process children with remaining properties
    local remaining_count
    remaining_count="$(echo "$remaining_names" | jq 'length')"
    if [[ $remaining_count -gt 0 ]]; then
        local children
        children="$(echo "$tree_json" | jq -r '.children // [] | .[]')"
        local child_count
        child_count="$(echo "$tree_json" | jq '.children | length')"

        if [[ $child_count -eq 1 ]]; then
            # Only child — collapse into current node
            local child_file
            child_file="$(echo "$tree_json" | jq -r '.children[0]')"
            assignment_node="$(epac_export_assignment_node "$child_file" "$assignment_node" "$remaining_names")"
        elif [[ $child_count -gt 1 ]]; then
            # Multiple children — create children array
            local children_array="[]"
            local ci=0
            local child_file
            while IFS= read -r child_file; do
                [[ -z "$child_file" ]] && continue
                local child_node
                child_node="$(jq -n --arg nn "/child-$ci" '{nodeName: $nn}')"
                child_node="$(epac_export_assignment_node "$child_file" "$child_node" "$remaining_names")"
                children_array="$(echo "$children_array" | jq --argjson cn "$child_node" '. += [$cn]')"
                ci=$((ci + 1))
            done <<< "$(echo "$tree_json" | jq -r '.children[]')"
            assignment_node="$(echo "$assignment_node" | jq --argjson ch "$children_array" '.children = $ch')"
        fi
    fi

    echo "$assignment_node"
}

# ─── Helper: add a property to assignment node based on property name ───────
_epac_add_assignment_property() {
    local node="$1"
    local property_name="$2"
    local property_value="$3"  # JSON

    case "$property_name" in
        parameters)
            if [[ "$property_value" != "null" && "$property_value" != "{}" ]]; then
                node="$(echo "$node" | jq --argjson v "$property_value" '.parameters = $v')"
            fi
            ;;
        overrides)
            if [[ "$property_value" != "null" ]]; then
                node="$(echo "$node" | jq --argjson v "$property_value" '.overrides = $v')"
            fi
            ;;
        resourceSelectors)
            if [[ "$property_value" != "null" ]]; then
                node="$(echo "$node" | jq --argjson v "$property_value" '.resourceSelectors = $v')"
            fi
            ;;
        enforcementMode)
            local em_val
            em_val="$(echo "$property_value" | jq -r '.')"
            if [[ "$em_val" != "null" && "$em_val" != "Default" ]]; then
                node="$(echo "$node" | jq --argjson v "$property_value" '.enforcementMode = $v')"
            fi
            ;;
        nonComplianceMessages)
            if [[ "$property_value" != "null" && "$property_value" != "[]" ]]; then
                local node_name
                node_name="$(echo "$node" | jq -r '.nodeName // ""')"
                if [[ "$node_name" == "/root" ]]; then
                    node="$(echo "$node" | jq --argjson v "$property_value" '.definitionEntry.nonComplianceMessages = $v')"
                else
                    node="$(echo "$node" | jq --argjson v "$property_value" '.nonComplianceMessages = $v')"
                fi
            fi
            ;;
        metadata)
            if [[ "$property_value" != "null" && "$property_value" != "{}" ]]; then
                node="$(echo "$node" | jq --argjson v "$property_value" '.metadata = $v')"
            fi
            ;;
        assignmentNameEx)
            node="$(echo "$node" | jq --argjson v "$property_value" \
                '.assignment = {name: $v.name, displayName: $v.displayName, description: $v.description}')"
            ;;
        additionalRoleAssignments)
            local filtered
            filtered="$(echo "$property_value" | jq '
                with_entries(select(.value != null and (.value | length) > 0))
            ')"
            if [[ "$filtered" != "{}" ]]; then
                node="$(echo "$node" | jq --argjson v "$filtered" '.additionalRoleAssignments = $v')"
            fi
            ;;
        identityEntry)
            local locations="{}"
            local user_assigned="{}"
            local selectors
            selectors="$(echo "$property_value" | jq -r 'keys[]')"
            local sel
            while IFS= read -r sel; do
                [[ -z "$sel" ]] && continue
                local val
                val="$(echo "$property_value" | jq --arg s "$sel" '.[$s]')"
                local loc
                loc="$(echo "$val" | jq -r '.location // empty')"
                if [[ -n "$loc" ]]; then
                    locations="$(echo "$locations" | jq --arg s "$sel" --arg l "$loc" '.[$s] = $l')"
                fi
                local ua
                ua="$(echo "$val" | jq '.userAssigned // null')"
                if [[ "$ua" != "null" ]]; then
                    user_assigned="$(echo "$user_assigned" | jq --arg s "$sel" --argjson u "$ua" '.[$s] = $u')"
                fi
            done <<< "$selectors"
            if [[ "$locations" != "{}" ]]; then
                node="$(echo "$node" | jq --argjson v "$locations" '.managedIdentityLocations = $v')"
            fi
            if [[ "$user_assigned" != "{}" ]]; then
                node="$(echo "$node" | jq --argjson v "$user_assigned" '.userAssignedIdentity = $v')"
            fi
            ;;
        notScopes)
            local filtered
            filtered="$(echo "$property_value" | jq '
                with_entries(select(.value != null and (.value | length) > 0))
            ')"
            if [[ "$filtered" != "{}" ]]; then
                node="$(echo "$node" | jq --argjson v "$filtered" '.notScopes = $v')"
            fi
            ;;
        scopes)
            local filtered
            filtered="$(echo "$property_value" | jq '
                with_entries(select(.value != null and (.value | length) > 0))
            ')"
            if [[ "$filtered" != "{}" ]]; then
                node="$(echo "$node" | jq --argjson v "$filtered" '.scope = $v')"
            fi
            ;;
        definitionVersion)
            if [[ "$property_value" != "null" ]]; then
                node="$(echo "$node" | jq --argjson v "$property_value" '.definitionVersion = $v')"
            fi
            ;;
    esac
    echo "$node"
}

# ─── Cleanup helper: remove all temp node files ────────────────────────────
epac_cleanup_export_nodes() {
    local root_file="$1"
    if [[ -f "$root_file" ]]; then
        _epac_cleanup_node_tree "$root_file"
    fi
}

_epac_cleanup_node_tree() {
    local node_file="$1"
    [[ -f "$node_file" ]] || return 0
    local children
    children="$(jq -r '.children // [] | .[]' "$node_file" 2>/dev/null)"
    local child
    while IFS= read -r child; do
        [[ -z "$child" ]] && continue
        _epac_cleanup_node_tree "$child"
    done <<< "$children"
    rm -f "$node_file"
}
