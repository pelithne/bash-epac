#!/usr/bin/env bash
# lib/json.sh — JSONC parsing, jq wrappers, deep clone/merge utilities
# Replaces PowerShell's ConvertFrom-Json, ConvertTo-Json, Get-DeepClone, etc.

[[ -n "${_EPAC_JSON_LOADED:-}" ]] && return 0
readonly _EPAC_JSON_LOADED=1

# Ensure core is loaded
# shellcheck source=core.sh
source "${BASH_SOURCE[0]%/*}/core.sh"

# ─── JSONC support (strip comments from JSON-with-comments) ──────────────────

# Strips // line comments and /* block comments */ from JSONC files.
# Handles comments inside strings correctly (preserves them).
epac_strip_jsonc_comments() {
    local input="$1"
    # Use jq if possible (it handles JSONC natively since jq 1.7+)
    # Fallback: sed-based stripping
    # Strategy: remove // comments not inside strings, remove /* */ blocks
    sed -e 's|//.*$||' \
        -e '/\/\*/,/\*\//d' \
        <<< "$input" | jq '.' 2>/dev/null || {
        # If jq fails on the sed output, try a more careful approach
        # Remove single-line comments outside of strings
        python3 -c "
import json, re, sys
text = sys.stdin.read()
# Remove block comments
text = re.sub(r'/\*.*?\*/', '', text, flags=re.DOTALL)
# Remove line comments (not inside strings)
lines = []
for line in text.split('\n'):
    in_string = False
    escape = False
    result = []
    for i, ch in enumerate(line):
        if escape:
            escape = False
            result.append(ch)
            continue
        if ch == '\\\\':
            escape = True
            result.append(ch)
            continue
        if ch == '\"':
            in_string = not in_string
            result.append(ch)
            continue
        if not in_string and ch == '/' and i+1 < len(line) and line[i+1] == '/':
            break
        result.append(ch)
    lines.append(''.join(result))
text = '\n'.join(lines)
# Remove trailing commas before } or ]
text = re.sub(r',\s*([}\]])', r'\1', text)
obj = json.loads(text)
json.dump(obj, sys.stdout)
" <<< "$input"
    }
}

# Read a JSONC file and output valid JSON
epac_read_jsonc() {
    local filepath="$1"
    epac_require_file "$filepath" "JSONC file"
    local content
    content="$(cat "$filepath")"
    epac_strip_jsonc_comments "$content"
}

# Read a JSON file (no comment stripping needed)
epac_read_json() {
    local filepath="$1"
    epac_require_file "$filepath" "JSON file"
    jq '.' "$filepath"
}

# ─── Deep clone ───────────────────────────────────────────────────────────────
# In bash+jq, JSON data is always strings, so "deep clone" is just parse+emit.
# This is the equivalent of Get-DeepCloneAsOrderedHashtable.

epac_deep_clone() {
    local json="$1"
    echo "$json" | jq '.'
}

# ─── Deep merge ──────────────────────────────────────────────────────────────
# Recursively merge two JSON objects. Values in $overlay override $base.
# Arrays are replaced, not concatenated (matching PowerShell behavior).

epac_deep_merge() {
    local base="$1"
    local overlay="$2"
    jq -n --argjson base "$base" --argjson overlay "$overlay" '
        def deep_merge(a; b):
            if (a | type) == "object" and (b | type) == "object" then
                a * b |
                to_entries | map(
                    if (.value | type) == "object" and (a[.key] | type) == "object" then
                        .value = deep_merge(a[.key]; .value)
                    else .
                    end
                ) | from_entries
            else b
            end;
        deep_merge($base; $overlay)
    '
}

# ─── JSON value accessors ────────────────────────────────────────────────────

# Get a value from JSON by path. Returns empty string if not found.
epac_json_get() {
    local json="$1"
    local path="$2"
    echo "$json" | jq -r "${path} // empty" 2>/dev/null || echo ""
}

# Test if a JSON path exists and is not null
epac_json_has() {
    local json="$1"
    local path="$2"
    local val
    val="$(echo "$json" | jq -r "${path} // \"__EPAC_NULL__\"" 2>/dev/null)"
    [[ "$val" != "__EPAC_NULL__" && "$val" != "null" ]]
}

# Get JSON value type: object, array, string, number, boolean, null
epac_json_type() {
    local json="$1"
    local path="${2:-.}"
    echo "$json" | jq -r "${path} | type" 2>/dev/null || echo "null"
}

# Count elements in a JSON array or object
epac_json_length() {
    local json="$1"
    local path="${2:-.}"
    echo "$json" | jq -r "${path} | length" 2>/dev/null || echo "0"
}
# ─── JSON construction ───────────────────────────────────────────────────────

# Create empty JSON object
epac_json_object() {
    echo '{}'
}

# Create empty JSON array
epac_json_array() {
    echo '[]'
}

# Set a value in a JSON object. Value must be valid JSON.
epac_json_set() {
    local json="$1"
    local path="$2"
    local value="$3"
    echo "$json" | jq --argjson val "$value" "${path} = \$val"
}

# Set a string value in a JSON object.
epac_json_set_str() {
    local json="$1"
    local path="$2"
    local value="$3"
    echo "$json" | jq --arg val "$value" "${path} = \$val"
}

# Append a value to a JSON array
epac_json_append() {
    local json="$1"
    local path="$2"
    local value="$3"
    echo "$json" | jq --argjson val "$value" "${path} += [\$val]"
}

# Delete a key from a JSON object
epac_json_delete() {
    local json="$1"
    local path="$2"
    echo "$json" | jq "del(${path})"
}

# ─── Remove null fields (recursive) ──────────────────────────────────────────
# Equivalent of Remove-NullFields.ps1

epac_remove_null_fields() {
    local json="$1"
    echo "$json" | jq '
        def remove_nulls:
            if type == "object" then
                with_entries(select(.value != null) | .value |= remove_nulls)
            elif type == "array" then
                map(remove_nulls)
            else .
            end;
        remove_nulls
    '
}

# ─── Confirm null or empty ───────────────────────────────────────────────────
# Equivalent of Confirm-NullOrEmptyValue.ps1
# Returns 0 (true) if value is null, empty string, empty array, or empty object.

epac_is_null_or_empty() {
    local json="$1"
    if [[ -z "$json" || "$json" == "null" ]]; then
        return 0
    fi
    local len
    len="$(echo "$json" | jq 'if type == "string" then length elif type == "array" then length elif type == "object" then length else 1 end' 2>/dev/null)" || return 1
    [[ "$len" == "0" ]]
}

# ─── Display string conversion ───────────────────────────────────────────────
# Equivalent of ConvertTo-DisplayString.ps1

epac_to_display_string() {
    local json="$1"
    if [[ -z "$json" || "$json" == "null" ]]; then
        echo "null"
        return
    fi
    local jtype
    jtype="$(echo "$json" | jq -r 'type' 2>/dev/null)" || { echo "$json"; return; }
    case "$jtype" in
        string) echo "$json" | jq -r '.' ;;  # Already quoted by jq if needed
        *)      echo "$json" | jq -c '.' ;;
    esac
}

# ─── JSON comparison ─────────────────────────────────────────────────────────
# Deep equality check. Returns 0 if equal, 1 if different.

epac_json_equal() {
    local a="$1"
    local b="$2"
    local result
    result="$(jq -n --argjson a "$a" --argjson b "$b" 'if $a == $b then "true" else "false" end' 2>/dev/null)"
    [[ "$result" == '"true"' ]]
}
