#!/usr/bin/env bash
# lib/validators.sh — Validation & confirmation functions
# Replaces: Confirm-ObjectValueEqualityDeep.ps1, Confirm-MetadataMatches.ps1,
#   Confirm-ParametersDefinitionMatch.ps1, Confirm-ParametersUsageMatches.ps1,
#   Confirm-PolicyDefinitionsMatch.ps1, Confirm-PolicyDefinitionsParametersMatch.ps1,
#   Confirm-PolicyDefinitionsInPolicySetMatch.ps1, Confirm-EffectIsAllowed.ps1,
#   Confirm-DeleteForStrategy.ps1, Confirm-ActiveAzExemptions.ps1,
#   Confirm-PolicyDefinitionUsedExists.ps1, Confirm-PolicySetDefinitionUsedExists.ps1,
#   Confirm-ValidPolicyResourceName.ps1, Confirm-NullOrEmptyValue.ps1,
#   Compare-SemanticVersion.ps1 (supplement to core.sh)

[[ -n "${_EPAC_VALIDATORS_LOADED:-}" ]] && return 0
readonly _EPAC_VALIDATORS_LOADED=1

_EPAC_LIB_DIR="${BASH_SOURCE[0]%/*}"
source "${_EPAC_LIB_DIR}/core.sh"
source "${_EPAC_LIB_DIR}/json.sh"
source "${_EPAC_LIB_DIR}/utils.sh"
source "${_EPAC_LIB_DIR}/output.sh"

###############################################################################
# Section 1: Deep Equality
###############################################################################

# ─── Deep recursive equality check ──────────────────────────────────────────
# Handles: null=empty, order-independent arrays, case-insensitive keys,
# datetime strings, nested objects. This is the EPAC-semantics version
# (more lenient than epac_json_equal which uses strict jq ==).
# Returns: 0 (true) or 1 (false)

epac_deep_equal() {
    local a="$1"
    local b="$2"

    # Fast path: string-identical (covers most cases in tree building)
    [[ "$a" == "$b" ]] && return 0

    # Handle null/empty equivalence
    if [[ -z "$a" || "$a" == "null" ]] && [[ -z "$b" || "$b" == "null" ]]; then
        return 0
    fi
    if [[ -z "$a" || "$a" == "null" || -z "$b" || "$b" == "null" ]]; then
        return 1
    fi

    # Single jq call: normalize both values (sort keys recursively) and compare
    local eq
    eq="$(jq -n --argjson a "$a" --argjson b "$b" '
        def normalize:
            if type == "object" then to_entries | sort_by(.key) | map(.value |= normalize) | from_entries
            elif type == "array" then map(normalize)
            else . end;
        ($a | normalize) == ($b | normalize)
    ' 2>/dev/null)" || { return 1; }
    [[ "$eq" == "true" ]] && return 0
    return 1
}

# Helper: check if value is effectively null/empty
_is_null_or_empty_val() {
    local v="$1"
    if [[ -z "$v" || "$v" == "null" ]]; then
        echo "true"
        return
    fi
    local t len
    t="$(echo "$v" | jq -r 'type' 2>/dev/null)" || { echo "false"; return; }
    case "$t" in
        null)   echo "true" ;;
        string) len="$(echo "$v" | jq -r 'length')"; [[ "$len" == "0" ]] && echo "true" || echo "false" ;;
        array)  len="$(echo "$v" | jq 'length')"; [[ "$len" == "0" ]] && echo "true" || echo "false" ;;
        object) len="$(echo "$v" | jq 'length')"; [[ "$len" == "0" ]] && echo "true" || echo "false" ;;
        *)      echo "false" ;;
    esac
}

###############################################################################
# Section 2: Metadata Matching
###############################################################################

# ─── Compare metadata objects ────────────────────────────────────────────────
# Returns JSON: {"match": bool, "changePacOwnerId": bool}
# Strips system-managed properties before comparison.

epac_confirm_metadata_matches() {
    local existing_metadata="$1"
    local defined_metadata="$2"
    local suppress_pac_msg="${3:-false}"

    if [[ -z "$existing_metadata" || "$existing_metadata" == "null" ]]; then
        echo '{"match":false,"changePacOwnerId":true}'
        return
    fi

    # Deep clone and strip system properties
    local sys_props='["createdBy","createdOn","updatedBy","updatedOn","lastSyncedToArgOn"]'
    local existing
    existing="$(echo "$existing_metadata" | jq --argjson sp "$sys_props" 'reduce $sp[] as $p (.; del(.[$p]))')"
    local defined
    defined="$(echo "$defined_metadata" | jq '.')"

    # Check pacOwnerId change
    local change_pac="false"
    local existing_pac defined_pac
    existing_pac="$(echo "$existing" | jq -r '.pacOwnerId // empty')"
    defined_pac="$(echo "$defined" | jq -r '.pacOwnerId // empty')"
    if [[ "$existing_pac" != "$defined_pac" ]]; then
        if [[ "$suppress_pac_msg" != "true" ]]; then
            epac_log_info "pacOwnerId has changed from '${existing_pac}' to '${defined_pac}'" >&2
        fi
        change_pac="true"
    fi

    # Remove pacOwnerId from both for comparison
    existing="$(echo "$existing" | jq 'del(.pacOwnerId)')"
    defined="$(echo "$defined" | jq 'del(.pacOwnerId)')"

    # Compare remaining fields
    local match="false"
    local existing_count defined_count
    existing_count="$(echo "$existing" | jq 'length')"
    defined_count="$(echo "$defined" | jq 'length')"
    if [[ "$existing_count" == "$defined_count" ]]; then
        if epac_deep_equal "$existing" "$defined"; then
            match="true"
        fi
    fi

    jq -n --argjson m "$match" --argjson c "$change_pac" '{match: $m, changePacOwnerId: $c}'
}

###############################################################################
# Section 3: Effect Validation
###############################################################################

# ─── Check if effect is in allowed list ──────────────────────────────────────
# Returns the matching effect string (with correct case) or empty string.

epac_confirm_effect_is_allowed() {
    local effect="$1"
    local allowed_effects="$2"   # JSON array

    echo "$allowed_effects" | jq -r --arg e "$effect" '
        .[] | select(ascii_downcase == ($e | ascii_downcase))
    ' | head -1
}

###############################################################################
# Section 4: Parameter Validation
###############################################################################

# ─── Check if parameters definition matches ─────────────────────────────────
# Returns JSON: {"match": bool, "incompatible": bool}

epac_confirm_parameters_definition_match() {
    local existing_params="$1"
    local defined_params="$2"

    [[ -z "$existing_params" || "$existing_params" == "null" ]] && existing_params="{}"
    [[ -z "$defined_params" || "$defined_params" == "null" ]] && defined_params="{}"

    local match="true"
    local incompatible="false"

    local existing_keys defined_keys
    existing_keys="$(echo "$existing_params" | jq -r 'keys[]')"
    defined_keys="$(echo "$defined_params" | jq -r 'keys[]')"

    # Track added parameters
    local added_params="$defined_params"

    # Check each existing parameter
    while IFS= read -r existing_key; do
        [[ -z "$existing_key" ]] && continue

        # Case-insensitive lookup in defined
        local defined_key
        defined_key="$(echo "$defined_params" | jq -r --arg k "$existing_key" '
            keys[] | select(ascii_downcase == ($k | ascii_downcase))
        ' | head -1)"

        if [[ -n "$defined_key" ]]; then
            # Remove from added tracking
            added_params="$(echo "$added_params" | jq --arg k "$defined_key" 'del(.[$k])')"

            local existing_val defined_val
            existing_val="$(echo "$existing_params" | jq --arg k "$existing_key" '.[$k]')"
            defined_val="$(echo "$defined_params" | jq --arg k "$defined_key" '.[$k]')"

            if epac_deep_equal "$existing_val" "$defined_val"; then
                continue
            fi
            match="false"

            # Check type compatibility
            local existing_type defined_type
            existing_type="$(echo "$existing_val" | jq -r '.type // empty')"
            defined_type="$(echo "$defined_val" | jq -r '.type // empty')"
            if [[ -n "$existing_type" && -n "$defined_type" && "$existing_type" != "$defined_type" ]]; then
                incompatible="true"
                break
            fi

            # Check strongType compatibility
            local existing_strong defined_strong
            existing_strong="$(echo "$existing_val" | jq -r '.metadata.strongType // empty')"
            defined_strong="$(echo "$defined_val" | jq -r '.metadata.strongType // empty')"
            if [[ "$existing_strong" != "$defined_strong" ]]; then
                incompatible="true"
                break
            fi

            # Check allowedValues compatibility
            local existing_av defined_av
            existing_av="$(echo "$existing_val" | jq '.allowedValues // null')"
            defined_av="$(echo "$defined_val" | jq '.allowedValues // null')"
            if ! epac_deep_equal "$existing_av" "$defined_av"; then
                incompatible="true"
                break
            fi
        else
            # Parameter deleted — incompatible
            match="false"
            incompatible="true"
            break
        fi
    done <<< "$existing_keys"

    # Check added parameters
    if [[ "$match" == "true" && "$incompatible" == "false" ]]; then
        local added_count
        added_count="$(echo "$added_params" | jq 'length')"
        if [[ "$added_count" -gt 0 ]]; then
            match="false"
            # Added parameter without defaultValue is incompatible
            local has_no_default
            has_no_default="$(echo "$added_params" | jq '
                to_entries | map(select(.value.defaultValue == null)) | length
            ')"
            if [[ "$has_no_default" -gt 0 ]]; then
                incompatible="true"
            fi
        fi
    fi

    jq -n --argjson m "$match" --argjson i "$incompatible" '{match: $m, incompatible: $i}'
}

# ─── Check if parameters usage matches ──────────────────────────────────────
# Compares parameter values (not definitions). Returns 0/1.

epac_confirm_parameters_usage_matches() {
    local existing_params="$1"
    local defined_params="$2"

    [[ -z "$existing_params" || "$existing_params" == "null" ]] && existing_params="{}"
    [[ -z "$defined_params" || "$defined_params" == "null" ]] && defined_params="{}"

    local existing_count defined_count
    existing_count="$(echo "$existing_params" | jq 'keys | length')"
    defined_count="$(echo "$defined_params" | jq 'keys | length')"

    [[ "$existing_count" != "$defined_count" ]] && return 1

    # Check unique keys match
    local all_unique_count
    all_unique_count="$(jq -n --argjson a "$existing_params" --argjson b "$defined_params" '
        ([($a | keys[]), ($b | keys[])] | map(ascii_downcase) | unique | length)
    ')"
    [[ "$all_unique_count" != "$existing_count" ]] && return 1

    local existing_keys
    existing_keys="$(echo "$existing_params" | jq -r 'keys[]')"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue

        local existing_val defined_val
        existing_val="$(echo "$existing_params" | jq --arg k "$key" '.[$k]')"
        # Case-insensitive key lookup in defined
        defined_val="$(echo "$defined_params" | jq --arg k "$key" '
            . as $obj | (keys[] | select(ascii_downcase == ($k | ascii_downcase))) as $found | $obj[$found]
        ' 2>/dev/null)"

        if [[ -z "$defined_val" || "$defined_val" == "null" ]]; then
            return 1
        fi

        # Extract .value if it's a hashtable with a value key
        local ev_type
        ev_type="$(echo "$existing_val" | jq -r 'type')"
        if [[ "$ev_type" == "object" ]]; then
            local has_value
            has_value="$(echo "$existing_val" | jq 'has("value")')"
            [[ "$has_value" == "true" ]] && existing_val="$(echo "$existing_val" | jq '.value')"
        fi

        local dv_type
        dv_type="$(echo "$defined_val" | jq -r 'type')"
        if [[ "$dv_type" == "object" ]]; then
            local has_value
            has_value="$(echo "$defined_val" | jq 'has("value")')"
            [[ "$has_value" == "true" ]] && defined_val="$(echo "$defined_val" | jq '.value')"
        fi

        epac_deep_equal "$existing_val" "$defined_val" || return 1
    done <<< "$existing_keys"

    return 0
}

###############################################################################
# Section 5: Policy Definition Matching
###############################################################################

# ─── Check if policy definitions parameters match ────────────────────────────
# Returns 0 (match) or 1 (no match)

epac_confirm_policy_definitions_parameters_match() {
    local existing_params="$1"
    local defined_params="$2"

    [[ -z "$existing_params" || "$existing_params" == "null" ]] && existing_params="{}"
    [[ -z "$defined_params" || "$defined_params" == "null" ]] && defined_params="{}"

    local existing_count defined_count
    existing_count="$(echo "$existing_params" | jq 'keys | length')"
    defined_count="$(echo "$defined_params" | jq 'keys | length')"
    [[ "$existing_count" != "$defined_count" ]] && return 1

    # Check each existing key has matching defined key with equal value
    local added="$defined_params"
    local existing_keys
    existing_keys="$(echo "$existing_params" | jq -r 'keys[]')"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local defined_key
        defined_key="$(echo "$defined_params" | jq -r --arg k "$key" '
            keys[] | select(ascii_downcase == ($k | ascii_downcase))
        ' | head -1)"
        if [[ -z "$defined_key" ]]; then
            return 1
        fi
        added="$(echo "$added" | jq --arg k "$defined_key" 'del(.[$k])')"

        local ev dv
        ev="$(echo "$existing_params" | jq --arg k "$key" '.[$k]')"
        dv="$(echo "$defined_params" | jq --arg k "$defined_key" '.[$k]')"
        epac_deep_equal "$ev" "$dv" || return 1
    done <<< "$existing_keys"

    local added_count
    added_count="$(echo "$added" | jq 'length')"
    [[ "$added_count" -eq 0 ]] && return 0
    return 1
}

# ─── Check if policy definitions match ──────────────────────────────────────
# Compares arrays of policy definitions (order-independent).
# Returns 0 (match) or 1 (no match)

epac_confirm_policy_definitions_match() {
    local obj1="$1"
    local obj2="$2"

    # Normalize nulls/empties
    local n1 n2
    n1="$(_is_null_or_empty_val "$obj1")"
    n2="$(_is_null_or_empty_val "$obj2")"
    [[ "$n1" == "true" && "$n2" == "true" ]] && return 0
    [[ "$n1" == "true" || "$n2" == "true" ]] && return 1

    # Coerce to arrays
    local t1 t2
    t1="$(echo "$obj1" | jq -r 'type')"
    t2="$(echo "$obj2" | jq -r 'type')"
    [[ "$t1" != "array" ]] && obj1="$(jq -n --argjson v "$obj1" '[$v]')"
    [[ "$t2" != "array" ]] && obj2="$(jq -n --argjson v "$obj2" '[$v]')"

    local len1 len2
    len1="$(echo "$obj1" | jq 'length')"
    len2="$(echo "$obj2" | jq 'length')"
    [[ "$len1" != "$len2" ]] && return 1

    # Order-independent matching
    local matched_indices=""
    local i=0
    while [[ $i -lt $len1 ]]; do
        local item1
        item1="$(echo "$obj1" | jq --argjson i "$i" '.[$i]')"
        local found="false"
        local j=0
        while [[ $j -lt $len2 ]]; do
            if echo "$matched_indices" | grep -qw "$j"; then
                j=$((j + 1))
                continue
            fi
            local item2
            item2="$(echo "$obj2" | jq --argjson j "$j" '.[$j]')"

            # Simple equality first
            if epac_deep_equal "$item1" "$item2"; then
                matched_indices+=" $j"
                found="true"
                break
            fi

            # Policy-specific match: refId + defId + params + groupNames
            local ref1 ref2 did1 did2
            ref1="$(echo "$item1" | jq -r '.policyDefinitionReferenceId // empty')"
            ref2="$(echo "$item2" | jq -r '.policyDefinitionReferenceId // empty')"
            did1="$(echo "$item1" | jq -r '.policyDefinitionId // empty')"
            did2="$(echo "$item2" | jq -r '.policyDefinitionId // empty')"

            if [[ "$ref1" == "$ref2" && "$did1" == "$did2" ]]; then
                local p1 p2 gn1 gn2
                p1="$(echo "$item1" | jq '.parameters // {}')"
                p2="$(echo "$item2" | jq '.parameters // {}')"
                gn1="$(echo "$item1" | jq '.groupNames // []')"
                gn2="$(echo "$item2" | jq '.groupNames // []')"

                if epac_confirm_policy_definitions_parameters_match "$p1" "$p2" && \
                   epac_deep_equal "$gn1" "$gn2"; then
                    matched_indices+=" $j"
                    found="true"
                    break
                fi
            fi

            j=$((j + 1))
        done
        [[ "$found" != "true" ]] && return 1
        i=$((i + 1))
    done
    return 0
}

# ─── Check policy definitions in policy set match ────────────────────────────
# Compares policy definition lists within a policy set (ordered).
# Returns 0 (match) or 1 (no match)

epac_confirm_policy_definitions_in_set_match() {
    local obj1="$1"
    local obj2="$2"

    local n1 n2
    n1="$(_is_null_or_empty_val "$obj1")"
    n2="$(_is_null_or_empty_val "$obj2")"
    [[ "$n1" == "true" && "$n2" == "true" ]] && return 0
    [[ "$n1" == "true" || "$n2" == "true" ]] && return 1

    # Coerce to arrays
    local t1 t2
    t1="$(echo "$obj1" | jq -r 'type')"
    t2="$(echo "$obj2" | jq -r 'type')"
    [[ "$t1" != "array" ]] && obj1="$(jq -n --argjson v "$obj1" '[$v]')"
    [[ "$t2" != "array" ]] && obj2="$(jq -n --argjson v "$obj2" '[$v]')"

    local len1 len2
    len1="$(echo "$obj1" | jq 'length')"
    len2="$(echo "$obj2" | jq 'length')"
    [[ "$len1" != "$len2" ]] && return 1

    local i=0
    while [[ $i -lt $len1 ]]; do
        local item1 item2
        item1="$(echo "$obj1" | jq --argjson i "$i" '.[$i]')"
        item2="$(echo "$obj2" | jq --argjson i "$i" '.[$i]')"

        if ! epac_deep_equal "$item1" "$item2"; then
            # Check structural match
            local ref1 ref2 did1 did2
            ref1="$(echo "$item1" | jq -r '.policyDefinitionReferenceId // empty')"
            ref2="$(echo "$item2" | jq -r '.policyDefinitionReferenceId // empty')"
            [[ "$ref1" != "$ref2" ]] && return 1

            did1="$(echo "$item1" | jq -r '.policyDefinitionId // empty')"
            did2="$(echo "$item2" | jq -r '.policyDefinitionId // empty')"
            [[ "$did1" != "$did2" ]] && return 1

            # GroupNames
            local gn1 gn2
            gn1="$(echo "$item1" | jq '.groupNames // null')"
            gn2="$(echo "$item2" | jq '.groupNames // null')"
            local gn1_null gn2_null
            gn1_null="$(_is_null_or_empty_val "$gn1")"
            gn2_null="$(_is_null_or_empty_val "$gn2")"
            if [[ "$gn1_null" != "true" && "$gn2_null" != "true" ]]; then
                local gn1_len gn2_len
                gn1_len="$(echo "$gn1" | jq 'length')"
                gn2_len="$(echo "$gn2" | jq 'length')"
                [[ "$gn1_len" != "$gn2_len" ]] && return 1
                if ! epac_deep_equal "$gn1" "$gn2"; then
                    return 1
                fi
            elif [[ "$gn1_null" != "$gn2_null" ]]; then
                return 1
            fi

            # Parameters usage
            local p1 p2
            p1="$(echo "$item1" | jq '.parameters // {}')"
            p2="$(echo "$item2" | jq '.parameters // {}')"
            epac_confirm_parameters_usage_matches "$p1" "$p2" || return 1
        fi
        i=$((i + 1))
    done
    return 0
}

###############################################################################
# Section 6: Strategy & Classification
###############################################################################

# ─── Determine if resource should be deleted ─────────────────────────────────
# Returns 0 (should delete) or 1 (should keep)

epac_confirm_delete_for_strategy() {
    local pac_owner="$1"
    local strategy="$2"
    local keep_dfc_security="${3:-false}"
    local keep_dfc_plans="${4:-false}"

    case "$pac_owner" in
        thisPaC)                     return 0 ;;
        otherPaC)                    return 1 ;;
        unknownOwner)
            [[ "$strategy" == "full" ]] && return 0 || return 1
            ;;
        managedByDfcSecurityPolicies)
            [[ "$keep_dfc_security" != "true" && "$strategy" == "full" ]] && return 0 || return 1
            ;;
        managedByDfcDefenderPlans)
            [[ "$keep_dfc_plans" != "true" && "$strategy" == "full" ]] && return 0 || return 1
            ;;
        *)  return 1 ;;
    esac
}

###############################################################################
# Section 7: Exemption Classification
###############################################################################

# ─── Categorize exemptions as active/expired/orphaned ────────────────────────
# Returns JSON with categorized exemptions.

epac_confirm_active_exemptions() {
    local exemptions="$1"     # JSON object: { id: {properties...}, ... }
    local assignments="$2"    # JSON object: { id: ..., ... }

    local now_epoch
    now_epoch="$(date +%s)"

    local all="{}" active="{}" expired="{}" orphaned="{}"

    local exemption_ids
    exemption_ids="$(echo "$exemptions" | jq -r 'keys[]')"
    while IFS= read -r eid; do
        [[ -z "$eid" ]] && continue
        local exemption
        exemption="$(echo "$exemptions" | jq --arg id "$eid" '.[$id]')"

        local policy_assignment_id
        policy_assignment_id="$(echo "$exemption" | jq -r '.policyAssignmentId // empty')"

        # Check if assignment exists
        local is_valid="false"
        if [[ -n "$policy_assignment_id" ]]; then
            is_valid="$(echo "$assignments" | jq --arg aid "$policy_assignment_id" 'has($aid)')"
        fi

        # Check expiration
        local expires_on is_expired="false" expires_in_days="2147483647"
        expires_on="$(echo "$exemption" | jq -r '.expiresOn // empty')"
        if [[ -n "$expires_on" ]]; then
            local expires_epoch
            expires_epoch="$(date -d "$expires_on" +%s 2>/dev/null)" || expires_epoch="$now_epoch"
            if [[ $expires_epoch -lt $now_epoch ]]; then
                is_expired="true"
            fi
            expires_in_days=$(( (expires_epoch - now_epoch) / 86400 ))
        fi

        # Determine status
        local status="orphaned"
        if [[ "$is_valid" == "true" ]]; then
            if [[ "$is_expired" == "true" ]]; then
                status="expired"
            else
                status="active"
            fi
        fi

        local name display_name description exemption_category scope metadata pdri
        name="$(echo "$exemption" | jq -r '.name // empty')"
        display_name="$(echo "$exemption" | jq -r '.displayName // empty')"
        [[ -z "$display_name" ]] && display_name="$name"
        description="$(echo "$exemption" | jq -r '.description // empty')"
        exemption_category="$(echo "$exemption" | jq -r '.exemptionCategory // empty')"
        scope="$(echo "$exemption" | jq -r '.scope // empty')"
        metadata="$(echo "$exemption" | jq '.metadata // null')"
        pdri="$(echo "$exemption" | jq '.policyDefinitionReferenceIds // null')"

        # Empty metadata → null
        if [[ "$(echo "$metadata" | jq 'length')" == "0" ]]; then
            metadata="null"
        fi

        local exemption_obj
        exemption_obj="$(jq -n \
            --arg name "$name" \
            --arg dn "$display_name" \
            --arg desc "$description" \
            --arg ec "$exemption_category" \
            --arg eo "$expires_on" \
            --arg st "$status" \
            --argjson eid_val "$expires_in_days" \
            --arg sc "$scope" \
            --arg paid "$policy_assignment_id" \
            --argjson pdri "${pdri:-null}" \
            --argjson meta "${metadata:-null}" \
            --arg id "$eid" \
            '{
                name: $name, displayName: $dn, description: $desc,
                exemptionCategory: $ec, expiresOn: $eo, status: $st,
                expiresInDays: $eid_val, scope: $sc,
                policyAssignmentId: $paid,
                policyDefinitionReferenceIds: $pdri,
                metadata: $meta, id: $id
            }')"

        all="$(echo "$all" | jq --arg id "$eid" --argjson obj "$exemption_obj" '.[$id] = $obj')"
        case "$status" in
            active)   active="$(echo "$active" | jq --arg id "$eid" --argjson obj "$exemption_obj" '.[$id] = $obj')" ;;
            expired)  expired="$(echo "$expired" | jq --arg id "$eid" --argjson obj "$exemption_obj" '.[$id] = $obj')" ;;
            orphaned) orphaned="$(echo "$orphaned" | jq --arg id "$eid" --argjson obj "$exemption_obj" '.[$id] = $obj')" ;;
        esac
    done <<< "$exemption_ids"

    jq -n \
        --argjson all "$all" \
        --argjson active "$active" \
        --argjson expired "$expired" \
        --argjson orphaned "$orphaned" \
        '{all: $all, active: $active, expired: $expired, orphaned: $orphaned}'
}

###############################################################################
# Section 8: Resource Lookup Validation
###############################################################################

# ─── Verify policy definition exists ────────────────────────────────────────
# Returns the full ID if found, empty string if not.

epac_confirm_policy_definition_used_exists() {
    local id="${1:-}"
    local name="${2:-}"
    local policy_definitions_scopes="$3"   # JSON array of scope strings
    local all_definitions="$4"             # JSON object: { id: def, ... }
    local suppress_error="${5:-false}"

    # XOR check: must supply either id or name
    if [[ -n "$id" && -n "$name" ]] || [[ -z "$id" && -z "$name" ]]; then
        epac_log_error "Must supply either Policy id or Policy name, not both or neither."
        return 1
    fi

    if [[ -n "$id" ]]; then
        local has_id
        has_id="$(echo "$all_definitions" | jq --arg id "$id" 'has($id)')"
        if [[ "$has_id" == "true" ]]; then
            echo "$id"
            return 0
        fi
        [[ "$suppress_error" != "true" ]] && epac_log_error "Policy '${id}' not found." >&2
        return 1
    fi

    # Search by name across scopes
    local scope_count
    scope_count="$(echo "$policy_definitions_scopes" | jq 'length')"
    local si=0
    while [[ $si -lt $scope_count ]]; do
        local scope_id
        scope_id="$(echo "$policy_definitions_scopes" | jq -r --argjson i "$si" '.[$i]')"
        local full_id="${scope_id}/providers/Microsoft.Authorization/policyDefinitions/${name}"
        local has_id
        has_id="$(echo "$all_definitions" | jq --arg id "$full_id" 'has($id)')"
        if [[ "$has_id" == "true" ]]; then
            echo "$full_id"
            return 0
        fi
        si=$((si + 1))
    done

    [[ "$suppress_error" != "true" ]] && epac_log_error "Policy name '${name}' not found." >&2
    return 1
}

# ─── Verify policy set definition exists ─────────────────────────────────────
# Returns the full ID if found, empty string if not.

epac_confirm_policy_set_definition_used_exists() {
    local id="${1:-}"
    local name="${2:-}"
    local policy_definitions_scopes="$3"   # JSON array of scope strings
    local all_policy_set_definitions="$4"  # JSON object: { id: def, ... }

    if [[ -n "$id" && -n "$name" ]] || [[ -z "$id" && -z "$name" ]]; then
        epac_log_error "Must supply either PolicySet id or PolicySet name, not both or neither."
        return 1
    fi

    if [[ -n "$id" ]]; then
        local has_id
        has_id="$(echo "$all_policy_set_definitions" | jq --arg id "$id" 'has($id)')"
        if [[ "$has_id" == "true" ]]; then
            echo "$id"
            return 0
        fi
        epac_log_error "PolicySet '${id}' not found." >&2
        return 1
    fi

    local scope_count
    scope_count="$(echo "$policy_definitions_scopes" | jq 'length')"
    local si=0
    while [[ $si -lt $scope_count ]]; do
        local scope_id
        scope_id="$(echo "$policy_definitions_scopes" | jq -r --argjson i "$si" '.[$i]')"
        local full_id="${scope_id}/providers/Microsoft.Authorization/policySetDefinitions/${name}"
        local has_id
        has_id="$(echo "$all_policy_set_definitions" | jq --arg id "$full_id" 'has($id)')"
        if [[ "$has_id" == "true" ]]; then
            echo "$full_id"
            return 0
        fi
        si=$((si + 1))
    done

    epac_log_error "PolicySet name '${name}' not found." >&2
    return 1
}

###############################################################################
# Section 9: Name Validation
###############################################################################

# ─── Validate policy resource name ──────────────────────────────────────────
# Returns 0 (valid) or 1 (invalid)

epac_confirm_valid_policy_resource_name() {
    local name="$1"
    # Invalid chars: < > * % & : ? + / \ and trailing space
    if [[ "$name" =~ [\<\>\*%\&:\?\+/\\] ]] || [[ "$name" =~ [[:space:]]$ ]]; then
        return 1
    fi
    return 0
}
