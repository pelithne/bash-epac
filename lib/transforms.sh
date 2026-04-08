#!/usr/bin/env bash
# lib/transforms.sh — Data transformation utilities for policy resources
# Replaces: Convert-PolicyToDetails.ps1, Convert-PolicySetToDetails.ps1,
#   Convert-PolicyResourcesToDetails.ps1, Convert-PolicyResourcesDetailsToFlatList.ps1,
#   Convert-EffectToOrdinal.ps1, Convert-OrdinalToEffectDisplayName.ps1,
#   Convert-EffectToCsvString.ps1, Convert-AllowedEffectsToCsvString.ps1,
#   Convert-EffectToMarkdownString.ps1, Convert-ParametersToString.ps1,
#   ConvertTo-HashTable.ps1, Convert-HashtableToFlatPsObject.ps1,
#   Convert-ObjectToComparableJson.ps1

[[ -n "${_EPAC_TRANSFORMS_LOADED:-}" ]] && return 0
readonly _EPAC_TRANSFORMS_LOADED=1

_EPAC_LIB_DIR="${BASH_SOURCE[0]%/*}"
source "${_EPAC_LIB_DIR}/core.sh"
source "${_EPAC_LIB_DIR}/json.sh"
source "${_EPAC_LIB_DIR}/utils.sh"
source "${_EPAC_LIB_DIR}/output.sh"

###############################################################################
# Section 1: Effect Conversion Utilities
###############################################################################

# ─── Convert effect to ordinal ───────────────────────────────────────────────
# Lower ordinal = higher impact. Used for sorting/comparison.

epac_effect_to_ordinal() {
    local effect="${1:-}"
    case "${effect,,}" in
        modify)            echo 0 ;;
        append)            echo 1 ;;
        deployifnotexists) echo 2 ;;
        denyaction)        echo 3 ;;
        deny)              echo 4 ;;
        audit)             echo 5 ;;
        manual)            echo 6 ;;
        auditifnotexists)  echo 7 ;;
        disabled)          echo 8 ;;
        *)                 echo 98 ;;
    esac
}

# ─── Convert ordinal to effect display name ──────────────────────────────────
# Returns display_name and link slug (tab-separated).

epac_ordinal_to_effect_display_name() {
    local ordinal="$1"
    local display_name link
    case "$ordinal" in
        0) display_name="Policy effects Modify, Append and DeployIfNotExists(DINE)" ;;
        1) display_name="Policy effects Modify, Append and DeployIfNotExists(DINE)" ;;
        2) display_name="Policy effects Modify, Append and DeployIfNotExists(DINE)" ;;
        3) display_name="Policy effects Deny" ;;
        4) display_name="Policy effects Deny" ;;
        5) display_name="Policy effects Audit" ;;
        6) display_name="Policy effects Manual" ;;
        7) display_name="Policy effects AuditIfNotExists(AINE)" ;;
        8) display_name="Policy effects Disabled" ;;
        *) display_name="Unknown" ;;
    esac
    link="${display_name,,}"
    link="${link// /-}"
    link="$(echo "$link" | sed 's/[(),]/_/g')"
    printf '%s\t%s' "$display_name" "$link"
}

# ─── Normalize effect name for CSV ───────────────────────────────────────────

epac_effect_to_csv_string() {
    local effect="${1:-}"
    case "${effect,,}" in
        modify)            echo "Modify" ;;
        append)            echo "Append" ;;
        denyaction)        echo "DenyAction" ;;
        deny)              echo "Deny" ;;
        audit)             echo "Audit" ;;
        manual)            echo "Manual" ;;
        deployifnotexists) echo "DeployIfNotExists" ;;
        auditifnotexists)  echo "AuditIfNotExists" ;;
        disabled)          echo "Disabled" ;;
        *)                 echo "Error" ;;
    esac
}

# ─── Convert allowed effects to CSV string ───────────────────────────────────
# Builds a delimited string: "prefix<sep1>effect1<sep2>effect2..."

epac_allowed_effects_to_csv_string() {
    local default_effect="$1"
    local is_effect_parameterized="$2"   # "true"|"false"
    local effect_allowed_values="$3"     # JSON array
    local effect_allowed_overrides="$4"  # JSON array
    local sep1="${5:-,}"
    local sep2="${6:-,}"

    local prefix="default"
    local allowed_list="[]"

    local av_count ov_count
    av_count="$(echo "$effect_allowed_values" | jq 'length')"
    ov_count="$(echo "$effect_allowed_overrides" | jq 'length')"

    if [[ "$is_effect_parameterized" == "true" && $av_count -gt 1 ]]; then
        allowed_list="$effect_allowed_values"
        prefix="parameter"
    elif [[ $ov_count -gt 1 ]]; then
        allowed_list="$effect_allowed_overrides"
        prefix="override"
    elif [[ -n "$default_effect" && "$default_effect" != "null" ]]; then
        prefix="default"
        allowed_list="$(jq -n --arg e "$default_effect" '[$e]')"
    else
        echo "none${sep1}No effect allowed${sep2}Error"
        return
    fi

    # Sort by defined order using bash array
    local -a order=("Modify" "Append" "DenyAction" "Deny" "Audit" "Manual" "DeployIfNotExists" "AuditIfNotExists" "Disabled")
    local raw_effects
    raw_effects="$(echo "$allowed_list" | jq -r '.[]')"

    local effects_joined=""
    for candidate in "${order[@]}"; do
        while IFS= read -r eff; do
            [[ -z "$eff" ]] && continue
            if [[ "${eff,,}" == "${candidate,,}" ]]; then
                if [[ -n "$effects_joined" ]]; then
                    effects_joined+="${sep2}${candidate}"
                else
                    effects_joined="${candidate}"
                fi
                break
            fi
        done <<< "$raw_effects"
    done

    echo "${prefix}${sep1}${effects_joined}"
}

# ─── Convert effect to markdown string ───────────────────────────────────────

epac_effect_to_markdown_string() {
    local effect="${1:-}"
    local allowed_values="${2:-[]}"       # JSON array
    local in_table_break="${3:-<br/>}"

    if [[ -z "$effect" || "$effect" == "null" ]]; then
        echo ""
        return
    fi

    local text="**${effect}**"
    local count
    count="$(echo "$allowed_values" | jq 'length')"
    local i=0
    while [[ $i -lt $count ]]; do
        local allowed
        allowed="$(echo "$allowed_values" | jq -r --argjson i "$i" '.[$i]')"
        if [[ "$allowed" != "$effect" ]]; then
            text+="${in_table_break}${allowed}"
        fi
        i=$((i + 1))
    done

    echo "$text"
}

###############################################################################
# Section 2: Type/Format Conversion Utilities
###############################################################################

# ─── Ensure value is JSON object ─────────────────────────────────────────────
# Replaces ConvertTo-HashTable.ps1

epac_to_hashtable() {
    local input="${1:-null}"
    if [[ "$input" == "null" || -z "$input" ]]; then
        echo "{}"
        return
    fi
    local t
    t="$(echo "$input" | jq -r 'type' 2>/dev/null)" || { echo "{}"; return; }
    if [[ "$t" == "object" ]]; then
        echo "$input" | jq '.'
    else
        echo "{}"
    fi
}

# ─── Convert to display string ──────────────────────────────────────────────

epac_to_display_string() {
    local value="$1"
    if [[ -z "$value" || "$value" == "null" ]]; then
        echo '"null"'
    elif echo "$value" | jq -e '.' >/dev/null 2>&1; then
        echo "$value" | jq -c '.'
    else
        jq -n --arg v "$value" '$v'
    fi
}

# ─── Ensure value is JSON array ──────────────────────────────────────────────

epac_to_array() {
    local input="${1:-null}"
    local skip_null="${2:-false}"

    if [[ "$skip_null" == "true" && ( -z "$input" || "$input" == "null" ) ]]; then
        echo "[]"
        return
    fi

    local t
    t="$(echo "$input" | jq -r 'type' 2>/dev/null)" || { echo "[$input]"; return; }
    if [[ "$t" == "array" ]]; then
        echo "$input"
    else
        jq -n --argjson v "$input" '[$v]'
    fi
}

# ─── Convert to comparable JSON ─────────────────────────────────────────────

epac_to_comparable_json() {
    local obj="$1"
    local compress="${2:-false}"
    if [[ "$compress" == "true" ]]; then
        echo "$obj" | jq -cS '.'
    else
        echo "$obj" | jq -S '.'
    fi
}

# ─── Flatten object for CSV export ──────────────────────────────────────────
# Complex values become JSON strings; primitives stay as-is.

epac_flatten_for_csv() {
    local json_array="$1"
    echo "$json_array" | jq '[.[] | to_entries | map(
        if (.value | type) == "string" or (.value | type) == "number" or (.value | type) == "boolean" or .value == null then
            .
        else
            .value = (.value | tojson)
        end
    ) | from_entries]'
}

###############################################################################
# Section 3: Policy Definition Analysis
###############################################################################

# ─── Convert policy to details ──────────────────────────────────────────────
# Analyzes a single policy definition to extract effect metadata.
# Input: policy_id (string), policy_definition (JSON)
# Output: JSON object with effect analysis details

epac_convert_policy_to_details() {
    local policy_id="$1"
    local policy_definition="$2"

    # Get properties (handle both wrapped and unwrapped)
    local properties
    local has_props
    has_props="$(echo "$policy_definition" | jq 'has("properties")')"
    if [[ "$has_props" == "true" ]]; then
        properties="$(echo "$policy_definition" | jq '.properties')"
    else
        properties="$policy_definition"
    fi

    # Category
    local category
    category="$(echo "$properties" | jq -r '.metadata.category // "Unknown"')"

    # Effect
    local effect_raw
    effect_raw="$(echo "$properties" | jq -r '.policyRule.then.effect // empty')"

    local effect_parameter_name=""
    local effect_value="null"
    local effect_default="null"
    local effect_allowed_values="[]"
    local effect_allowed_overrides="[]"
    local effect_reason="Policy No Default"

    # Check if parameterized
    local param_name
    param_name="$(epac_get_parameter_name "$effect_raw")"

    local parameters
    parameters="$(epac_to_hashtable "$(echo "$properties" | jq '.parameters // null')")"

    if [[ -n "$param_name" ]]; then
        # Parameterized effect
        effect_parameter_name="$param_name"

        local has_param
        has_param="$(echo "$parameters" | jq --arg p "$param_name" 'has($p)')"
        if [[ "$has_param" != "true" ]]; then
            # Case-insensitive search
            local actual_key
            actual_key="$(echo "$parameters" | jq -r --arg p "$param_name" 'keys[] | select(ascii_downcase == ($p | ascii_downcase))')"
            if [[ -n "$actual_key" ]]; then
                param_name="$actual_key"
                has_param="true"
            else
                epac_log_error "Policy uses parameter '${param_name}' for effect but it's not defined"
                echo "null"
                return 1
            fi
        fi

        local effect_param
        effect_param="$(echo "$parameters" | jq --arg p "$param_name" '.[$p]')"

        local has_default
        has_default="$(echo "$effect_param" | jq 'has("defaultValue")')"
        if [[ "$has_default" == "true" ]]; then
            effect_value="$(echo "$effect_param" | jq -r '.defaultValue')"
            effect_default="$effect_value"
            effect_reason="Policy Default"
        fi

        local has_allowed
        has_allowed="$(echo "$effect_param" | jq 'has("allowedValues")')"
        if [[ "$has_allowed" == "true" ]]; then
            effect_allowed_values="$(echo "$effect_param" | jq '.allowedValues')"
            effect_allowed_overrides="$(echo "$effect_param" | jq '.allowedValues')"
        fi
    else
        # Fixed effect
        effect_value="$effect_raw"
        effect_default="$effect_raw"
        effect_allowed_values="$(jq -n --arg e "$effect_raw" '[$e]')"
        effect_reason="Policy Fixed"
    fi

    # If no allowed overrides, analyze policy anatomy
    local override_count
    override_count="$(echo "$effect_allowed_overrides" | jq 'length')"
    if [[ $override_count -eq 0 ]]; then
        local then_obj details
        then_obj="$(echo "$properties" | jq '.policyRule.then // {}')"
        details="$(echo "$then_obj" | jq '.details // null')"

        local has_action_names has_existence_condition has_deployment has_operations has_default_state
        has_action_names="$(echo "$details" | jq 'if type == "object" then has("actionNames") else false end')"
        has_existence_condition="$(echo "$details" | jq 'if type == "object" then has("existenceCondition") else false end')"
        has_deployment="$(echo "$details" | jq 'if type == "object" then has("deployment") else false end')"
        has_operations="$(echo "$details" | jq 'if type == "object" then has("operations") else false end')"
        has_default_state="$(echo "$details" | jq 'if type == "object" then has("defaultState") else false end')"
        local is_array
        is_array="$(echo "$details" | jq 'type == "array"')"

        if [[ "$has_action_names" == "true" ]]; then
            effect_allowed_overrides='["Disabled","DenyAction"]'
        elif [[ "$has_default_state" == "true" ]]; then
            effect_allowed_overrides='["Disabled","Manual"]'
        elif [[ "$has_existence_condition" == "true" && "$has_deployment" == "true" ]]; then
            effect_allowed_overrides='["Disabled","AuditIfNotExists","DeployIfNotExists"]'
        elif [[ "$has_existence_condition" == "true" ]]; then
            effect_allowed_overrides='["Disabled","AuditIfNotExists"]'
        elif [[ "$has_operations" == "true" ]]; then
            effect_allowed_overrides='["Disabled","Audit","Modify"]'
        elif [[ "$is_array" == "true" ]]; then
            effect_allowed_overrides='["Disabled","Audit","Deny","Append"]'
        else
            local ev_lower="${effect_value,,}"
            if [[ "$effect_reason" == "Policy Fixed" ]]; then
                if [[ "$ev_lower" == "deny" ]]; then
                    effect_allowed_overrides='["Disabled","Audit","Deny"]'
                elif [[ "$ev_lower" == "audit" ]]; then
                    effect_allowed_overrides='["Disabled","Audit","Deny"]'
                else
                    effect_allowed_overrides='["Disabled","Audit"]'
                fi
            else
                effect_allowed_overrides='["Disabled","Audit","Deny"]'
            fi
        fi
    fi

    # Display name and description
    local display_name
    display_name="$(echo "$properties" | jq -r '.displayName // empty')"
    if [[ -z "$display_name" ]]; then
        display_name="$(echo "$policy_definition" | jq -r '.name // empty')"
    fi
    local description
    description="$(echo "$properties" | jq -r '.description // ""')"

    # Version and deprecated status
    local version
    version="$(echo "$properties" | jq -r '.metadata.version // "0.0.0"')"
    local is_deprecated="false"
    if [[ "${version,,}" == *"deprecated"* ]]; then
        is_deprecated="true"
    fi

    local name
    name="$(echo "$policy_definition" | jq -r '.name // empty')"
    local policy_type
    policy_type="$(echo "$properties" | jq -r '.policyType // empty')"

    # Build parameter definitions
    local parameter_definitions
    parameter_definitions="$(echo "$parameters" | jq --arg epn "$effect_parameter_name" '
        to_entries | map({
            key: .key,
            value: {
                isEffect: (.key == $epn),
                value: null,
                defaultValue: (.value.defaultValue // null),
                definition: .value
            }
        }) | from_entries
    ')"

    # Build result
    jq -n \
        --arg id "$policy_id" \
        --arg name "$name" \
        --arg dn "$display_name" \
        --arg desc "$description" \
        --arg pt "$policy_type" \
        --arg cat "$category" \
        --arg ver "$version" \
        --argjson dep "$is_deprecated" \
        --arg epn "$effect_parameter_name" \
        --arg ev "$effect_value" \
        --arg ed "$effect_default" \
        --argjson eav "$effect_allowed_values" \
        --argjson eao "$effect_allowed_overrides" \
        --arg er "$effect_reason" \
        --argjson params "$parameter_definitions" \
        '{
            id: $id,
            name: $name,
            displayName: $dn,
            description: $desc,
            policyType: $pt,
            category: $cat,
            version: $ver,
            isDeprecated: $dep,
            effectParameterName: $epn,
            effectValue: $ev,
            effectDefault: $ed,
            effectAllowedValues: $eav,
            effectAllowedOverrides: $eao,
            effectReason: $er,
            parameters: $params
        }'
}

# ─── Convert policy set to details ──────────────────────────────────────────
# Analyzes a policy set definition with its member policies.
# Input: policy_set_id, policy_set_definition (JSON), policy_details (JSON obj keyed by ID)
# Output: JSON object with policy set analysis

epac_convert_policy_set_to_details() {
    local policy_set_id="$1"
    local policy_set_definition="$2"
    local policy_details="$3"            # JSON: { policyId: {detail...}, ... }

    local properties
    local has_props
    has_props="$(echo "$policy_set_definition" | jq 'has("properties")')"
    if [[ "$has_props" == "true" ]]; then
        properties="$(echo "$policy_set_definition" | jq '.properties')"
    else
        properties="$policy_set_definition"
    fi

    local category
    category="$(echo "$properties" | jq -r '.metadata.category // "Unknown"')"

    local policy_set_parameters
    policy_set_parameters="$(epac_to_hashtable "$(echo "$properties" | jq '.parameters // null')")"

    local policy_in_set_detail_list="[]"
    local parameters_already_covered="{}"

    local policy_definitions
    policy_definitions="$(echo "$properties" | jq '.policyDefinitions // []')"
    local pd_count
    pd_count="$(echo "$policy_definitions" | jq 'length')"
    local pi=0

    while [[ $pi -lt $pd_count ]]; do
        local policy_in_set
        policy_in_set="$(echo "$policy_definitions" | jq --argjson i "$pi" '.[$i]')"
        local policy_id
        policy_id="$(echo "$policy_in_set" | jq -r '.policyDefinitionId')"

        # Check if we have details for this policy
        local has_detail
        has_detail="$(echo "$policy_details" | jq --arg pid "$policy_id" 'has($pid)')"
        if [[ "$has_detail" != "true" ]]; then
            pi=$((pi + 1))
            continue
        fi

        local policy_detail
        policy_detail="$(echo "$policy_details" | jq --arg pid "$policy_id" '.[$pid]')"

        local pips_parameters
        pips_parameters="$(epac_to_hashtable "$(echo "$policy_in_set" | jq '.parameters // null')")"

        local policy_set_level_effect_param_name=""
        local effect_param_name
        effect_param_name="$(echo "$policy_detail" | jq -r '.effectParameterName // empty')"
        local effect_value
        effect_value="$(echo "$policy_detail" | jq -r '.effectValue // empty')"
        local effect_default
        effect_default="$(echo "$policy_detail" | jq -r '.effectDefault // empty')"
        local effect_allowed_values
        effect_allowed_values="$(echo "$policy_detail" | jq '.effectAllowedValues // []')"
        local effect_allowed_overrides
        effect_allowed_overrides="$(echo "$policy_detail" | jq '.effectAllowedOverrides // []')"
        local effect_reason
        effect_reason="$(echo "$policy_detail" | jq -r '.effectReason // empty')"

        if [[ "$effect_reason" != "Policy Fixed" && -n "$effect_param_name" ]]; then
            # Effect is parameterized in the policy — check policy set level
            local has_epn
            has_epn="$(echo "$pips_parameters" | jq --arg p "$effect_param_name" '
                if has($p) then true
                else (keys[] | select(ascii_downcase == ($p | ascii_downcase))) as $k | if $k then true else false end
                end
            ' 2>/dev/null)"

            if [[ "$has_epn" == "true" ]]; then
                local pips_param
                pips_param="$(echo "$pips_parameters" | jq --arg p "$effect_param_name" '
                    if has($p) then .[$p]
                    else . as $obj | (keys[] | select(ascii_downcase == ($p | ascii_downcase))) as $k | $obj[$k]
                    end
                ')"

                if [[ -n "$pips_param" && "$pips_param" != "null" ]]; then
                    local effect_raw_value
                    effect_raw_value="$(echo "$pips_param" | jq -r '.value // empty')"

                    local ps_param_name
                    ps_param_name="$(epac_get_parameter_name "$effect_raw_value")"

                    if [[ -n "$ps_param_name" ]]; then
                        # Effect is surfaced as a policy set parameter
                        policy_set_level_effect_param_name="$ps_param_name"
                        local has_ps_param
                        has_ps_param="$(echo "$policy_set_parameters" | jq --arg p "$ps_param_name" 'has($p)')"
                        if [[ "$has_ps_param" == "true" ]]; then
                            local ps_effect_param
                            ps_effect_param="$(echo "$policy_set_parameters" | jq --arg p "$ps_param_name" '.[$p]')"
                            local has_def
                            has_def="$(echo "$ps_effect_param" | jq 'has("defaultValue")')"
                            if [[ "$has_def" == "true" ]]; then
                                effect_value="$(echo "$ps_effect_param" | jq -r '.defaultValue')"
                                effect_default="$effect_value"
                                effect_reason="PolicySet Default"
                            else
                                effect_reason="PolicySet No Default"
                            fi
                            local has_av
                            has_av="$(echo "$ps_effect_param" | jq 'has("allowedValues")')"
                            if [[ "$has_av" == "true" ]]; then
                                effect_allowed_values="$(echo "$ps_effect_param" | jq '.allowedValues')"
                            fi
                        else
                            epac_log_error "Policy set references unknown parameter '${ps_param_name}'"
                        fi
                    else
                        # Effect is hard-coded at policy set level
                        policy_set_level_effect_param_name=""
                        effect_value="$effect_raw_value"
                        effect_default="$effect_raw_value"
                        effect_reason="PolicySet Fixed"
                    fi
                fi
            fi
        fi

        # Process surfaced parameters
        local surfaced_parameters="{}"
        local pips_keys
        pips_keys="$(echo "$pips_parameters" | jq -r 'keys[]')"
        while IFS= read -r param_key; do
            [[ -z "$param_key" ]] && continue
            local param_val
            param_val="$(echo "$pips_parameters" | jq --arg k "$param_key" '.[$k]')"
            local raw_val
            raw_val="$(echo "$param_val" | jq -r '.value // empty')"
            local param_type
            param_type="$(echo "$param_val" | jq -r '.value | type')"

            if [[ "$param_type" == "string" ]]; then
                local surfaced_name
                surfaced_name="$(epac_get_parameter_name "$raw_val")"
                if [[ -n "$surfaced_name" ]]; then
                    local ps_param_def
                    ps_param_def="$(echo "$policy_set_parameters" | jq --arg p "$surfaced_name" '.[$p] // null')"
                    local multi_use="false"
                    local default_val
                    default_val="$(echo "$ps_param_def" | jq '.defaultValue // null')"
                    local is_effect="false"
                    [[ "$surfaced_name" == "$policy_set_level_effect_param_name" ]] && is_effect="true"

                    local already_covered
                    already_covered="$(echo "$parameters_already_covered" | jq --arg k "$surfaced_name" 'has($k)')"
                    if [[ "$already_covered" == "true" ]]; then
                        multi_use="true"
                    else
                        parameters_already_covered="$(echo "$parameters_already_covered" | jq --arg k "$surfaced_name" '.[$k] = true')"
                    fi

                    local already_in_surfaced
                    already_in_surfaced="$(echo "$surfaced_parameters" | jq --arg k "$surfaced_name" 'has($k)')"
                    if [[ "$already_in_surfaced" != "true" ]]; then
                        surfaced_parameters="$(echo "$surfaced_parameters" | jq \
                            --arg k "$surfaced_name" \
                            --argjson mu "$multi_use" \
                            --argjson ie "$is_effect" \
                            --argjson dv "$default_val" \
                            --argjson pdef "$ps_param_def" \
                            '.[$k] = {multiUse: $mu, isEffect: $ie, value: $dv, defaultValue: $dv, definition: $pdef}')"
                    fi
                fi
            fi
        done <<< "$pips_keys"

        # Group names
        local group_names
        group_names="$(echo "$policy_in_set" | jq '.groupNames // []')"

        local policy_def_ref_id
        policy_def_ref_id="$(echo "$policy_in_set" | jq -r '.policyDefinitionReferenceId // empty')"

        # Build policy-in-policy-set detail entry
        local pips_detail
        pips_detail="$(jq -n \
            --arg id "$policy_id" \
            --arg name "$(echo "$policy_detail" | jq -r '.name')" \
            --arg dn "$(echo "$policy_detail" | jq -r '.displayName')" \
            --arg desc "$(echo "$policy_detail" | jq -r '.description')" \
            --arg pt "$(echo "$policy_detail" | jq -r '.policyType')" \
            --arg cat "$(echo "$policy_detail" | jq -r '.category')" \
            --arg epn "$policy_set_level_effect_param_name" \
            --arg ev "$effect_value" \
            --arg ed "$effect_default" \
            --argjson eav "$effect_allowed_values" \
            --argjson eao "$effect_allowed_overrides" \
            --arg er "$effect_reason" \
            --argjson params "$surfaced_parameters" \
            --arg pdrid "$policy_def_ref_id" \
            --argjson gn "$group_names" \
            '{
                id: $id, name: $name, displayName: $dn, description: $desc,
                policyType: $pt, category: $cat,
                effectParameterName: $epn, effectValue: $ev, effectDefault: $ed,
                effectAllowedValues: $eav, effectAllowedOverrides: $eao,
                effectReason: $er, parameters: $params,
                policyDefinitionReferenceId: $pdrid, groupNames: $gn
            }')"

        policy_in_set_detail_list="$(echo "$policy_in_set_detail_list" | jq --argjson d "$pips_detail" '. + [$d]')"

        pi=$((pi + 1))
    done

    # Display name + description
    local display_name
    display_name="$(echo "$properties" | jq -r '.displayName // empty')"
    [[ -z "$display_name" ]] && display_name="$(echo "$policy_set_definition" | jq -r '.name // empty')"
    local description
    description="$(echo "$properties" | jq -r '.description // ""')"
    local policy_type
    policy_type="$(echo "$properties" | jq -r '.policyType // empty')"

    # Find policies with multiple reference IDs
    local policies_with_multi_refs
    policies_with_multi_refs="$(echo "$policy_in_set_detail_list" | jq '
        group_by(.id) |
        map(select(length > 1) | {key: .[0].id, value: [.[].policyDefinitionReferenceId]}) |
        from_entries
    ')"

    # Build result
    jq -n \
        --arg id "$policy_set_id" \
        --arg name "$(echo "$policy_set_definition" | jq -r '.name // empty')" \
        --arg dn "$display_name" \
        --arg desc "$description" \
        --arg pt "$policy_type" \
        --arg cat "$category" \
        --argjson params "$policy_set_parameters" \
        --argjson pds "$policy_in_set_detail_list" \
        --argjson multi "$policies_with_multi_refs" \
        '{
            id: $id, name: $name, displayName: $dn, description: $desc,
            policyType: $pt, category: $cat, parameters: $params,
            policyDefinitions: $pds,
            policiesWithMultipleReferenceIds: $multi
        }'
}

###############################################################################
# Section 4: Policy Resources to Details Orchestrator
###############################################################################

# ─── Process all policy and policy set definitions into detail objects ────────
# Replaces Convert-PolicyResourcesToDetails.ps1
# Sequential (no parallelism needed — jq is fast enough)

epac_convert_policy_resources_to_details() {
    local all_policy_definitions="$1"       # JSON object: { id: def, ... }
    local all_policy_set_definitions="$2"   # JSON object: { id: setDef, ... }

    epac_write_section "Pre-calculating Policy Parameters" 0 >&2

    # Process policy definitions
    local policy_details="{}"
    local policy_keys
    policy_keys="$(echo "$all_policy_definitions" | jq -r 'keys[]')"
    local policy_count=0
    while IFS= read -r policy_id; do
        [[ -z "$policy_id" ]] && continue
        local policy_def
        policy_def="$(echo "$all_policy_definitions" | jq --arg id "$policy_id" '.[$id]')"
        local detail
        detail="$(epac_convert_policy_to_details "$policy_id" "$policy_def")"
        if [[ -n "$detail" && "$detail" != "null" ]]; then
            policy_details="$(echo "$policy_details" | jq --arg id "$policy_id" --argjson d "$detail" '.[$id] = $d')"
        fi
        policy_count=$((policy_count + 1))
    done <<< "$policy_keys"
    epac_write_status "Processed ${policy_count} policy definitions" "success" 2 >&2

    # Process policy set definitions
    local policy_set_details="{}"
    local psd_keys
    psd_keys="$(echo "$all_policy_set_definitions" | jq -r 'keys[]')"
    local psd_count=0
    while IFS= read -r psd_id; do
        [[ -z "$psd_id" ]] && continue
        local psd_def
        psd_def="$(echo "$all_policy_set_definitions" | jq --arg id "$psd_id" '.[$id]')"
        local psd_detail
        psd_detail="$(epac_convert_policy_set_to_details "$psd_id" "$psd_def" "$policy_details")"
        if [[ -n "$psd_detail" && "$psd_detail" != "null" ]]; then
            policy_set_details="$(echo "$policy_set_details" | jq --arg id "$psd_id" --argjson d "$psd_detail" '.[$id] = $d')"
        fi
        psd_count=$((psd_count + 1))
    done <<< "$psd_keys"
    epac_write_status "Processed ${psd_count} policy set definitions" "success" 2 >&2

    jq -n --argjson p "$policy_details" --argjson ps "$policy_set_details" '{policies: $p, policySets: $ps}'
}

###############################################################################
# Section 5: Flat List Builder
###############################################################################

# ─── Convert policy resources details to flat list ───────────────────────────
# Replaces Convert-PolicyResourcesDetailsToFlatList.ps1
# Item list format: [{shortName, itemId, assignmentId?, policySetId?}, ...]

epac_convert_details_to_flat_list() {
    local item_list="$1"           # JSON array of items
    local details="$2"             # JSON object: { id: detail, ... }

    # Find policies with multiple reference IDs across all items
    local policies_with_multi_refs="{}"
    local item_count
    item_count="$(echo "$item_list" | jq 'length')"
    local ii=0
    while [[ $ii -lt $item_count ]]; do
        local item
        item="$(echo "$item_list" | jq --argjson i "$ii" '.[$i]')"
        local item_id
        item_id="$(echo "$item" | jq -r '.itemId')"
        local detail
        detail="$(echo "$details" | jq --arg id "$item_id" '.[$id] // null')"
        if [[ "$detail" != "null" ]]; then
            local multi
            multi="$(echo "$detail" | jq '.policiesWithMultipleReferenceIds // {}')"
            if [[ "$(echo "$multi" | jq 'length')" -gt 0 ]]; then
                policies_with_multi_refs="$(jq -n --argjson a "$policies_with_multi_refs" --argjson b "$multi" '$a + $b')"
            fi
        fi
        ii=$((ii + 1))
    done

    # Build flat policy list
    local flat_policy_list="{}"
    local parameters_already_covered="{}"

    ii=0
    while [[ $ii -lt $item_count ]]; do
        local item
        item="$(echo "$item_list" | jq --argjson i "$ii" '.[$i]')"
        local short_name
        short_name="$(echo "$item" | jq -r '.shortName')"
        local item_id
        item_id="$(echo "$item" | jq -r '.itemId')"
        local assignment_id
        assignment_id="$(echo "$item" | jq -r '.assignmentId // empty')"

        local detail
        detail="$(echo "$details" | jq --arg id "$item_id" '.[$id] // null')"
        [[ "$detail" == "null" ]] && { ii=$((ii + 1)); continue; }

        local policy_defs
        policy_defs="$(echo "$detail" | jq '.policyDefinitions // []')"
        local pd_count
        pd_count="$(echo "$policy_defs" | jq 'length')"
        local pi=0

        while [[ $pi -lt $pd_count ]]; do
            local pips_info
            pips_info="$(echo "$policy_defs" | jq --argjson i "$pi" '.[$i]')"
            local pol_id
            pol_id="$(echo "$pips_info" | jq -r '.id')"
            local effect_reason
            effect_reason="$(echo "$pips_info" | jq -r '.effectReason')"
            local is_effect_parameterized="false"
            if [[ "$effect_reason" == "PolicySet Default" || "$effect_reason" == "PolicySet No Default" || "$effect_reason" == "Assignment" ]]; then
                is_effect_parameterized="true"
            fi

            local flat_key="$pol_id"
            local ref_path=""
            local has_multi
            has_multi="$(echo "$policies_with_multi_refs" | jq --arg pid "$pol_id" 'has($pid)')"
            if [[ "$has_multi" == "true" ]]; then
                local pdrid
                pdrid="$(echo "$pips_info" | jq -r '.policyDefinitionReferenceId')"
                ref_path="$(echo "$detail" | jq -r '.name')\\${pdrid}"
                flat_key="${pol_id}\\${ref_path}"
            fi

            local effect_default
            effect_default="$(echo "$pips_info" | jq -r '.effectDefault // empty')"
            local effect_value
            effect_value="$(echo "$pips_info" | jq -r '.effectValue // empty')"

            # Get or create flat policy entry
            local has_entry
            has_entry="$(echo "$flat_policy_list" | jq --arg k "$flat_key" 'has($k)')"
            if [[ "$has_entry" != "true" ]]; then
                local ordinal
                ordinal="$(epac_effect_to_ordinal "$effect_default")"
                local new_entry
                new_entry="$(echo "$pips_info" | jq --arg rp "$ref_path" --argjson iep "$is_effect_parameterized" --argjson ord "$ordinal" '{
                    id: .id, name: .name, referencePath: $rp,
                    displayName: .displayName, description: .description,
                    policyType: .policyType, category: .category,
                    effectDefault: .effectDefault, effectValue: .effectValue,
                    ordinal: $ord, isEffectParameterized: $iep,
                    effectAllowedValues: {}, effectAllowedOverrides: .effectAllowedOverrides,
                    parameters: {}, policySetList: {}, groupNames: {},
                    groupNamesList: [], policySetEffectStrings: []
                }')"
                flat_policy_list="$(echo "$flat_policy_list" | jq --arg k "$flat_key" --argjson v "$new_entry" '.[$k] = $v')"
            elif [[ "$is_effect_parameterized" == "true" ]]; then
                flat_policy_list="$(echo "$flat_policy_list" | jq --arg k "$flat_key" '.[$k].isEffectParameterized = true')"
            fi

            # Build effect string
            local effect_string=""
            local effect_param_name
            effect_param_name="$(echo "$pips_info" | jq -r '.effectParameterName // empty')"

            case "$effect_reason" in
                "PolicySet Default")
                    effect_string="${effect_default} (default: ${effect_param_name})" ;;
                "PolicySet No Default")
                    effect_string="${effect_reason} (${effect_param_name})" ;;
                *)
                    effect_string="${effect_default} (${effect_reason})" ;;
            esac

            # Update ordinal if this is a more impactful effect
            local cur_ordinal
            cur_ordinal="$(echo "$flat_policy_list" | jq --arg k "$flat_key" '.[$k].ordinal')"
            local new_ordinal
            new_ordinal="$(epac_effect_to_ordinal "$effect_default")"
            if [[ $new_ordinal -lt $cur_ordinal ]]; then
                flat_policy_list="$(echo "$flat_policy_list" | jq --arg k "$flat_key" --arg ev "$effect_value" --arg ed "$effect_default" --argjson ord "$new_ordinal" '
                    .[$k].ordinal = $ord | .[$k].effectValue = $ev | .[$k].effectDefault = $ed')"
            fi

            # Add effect allowed values
            local eav
            eav="$(echo "$pips_info" | jq '.effectAllowedValues // []')"
            flat_policy_list="$(echo "$flat_policy_list" | jq --arg k "$flat_key" --argjson av "$eav" '
                .[$k].effectAllowedValues += ($av | map({key: ., value: .}) | from_entries)
            ')"

            # Add group names
            local gn
            gn="$(echo "$pips_info" | jq '.groupNames // []')"
            flat_policy_list="$(echo "$flat_policy_list" | jq --arg k "$flat_key" --argjson gn "$gn" '
                (.[$k].groupNames | keys) as $existing_keys |
                .[$k].groupNames += ($gn | map({key: ., value: .}) | from_entries) |
                .[$k].groupNamesList += [$gn[] | select(. as $g | $existing_keys | index($g) == null)]
            ')"

            # Add per-policy-set entry
            local ps_effect_string="${short_name}: ${effect_string}"
            flat_policy_list="$(echo "$flat_policy_list" | jq --arg k "$flat_key" --arg sn "$short_name" --arg es "$ps_effect_string" '
                .[$k].policySetEffectStrings += [$es]')"

            pi=$((pi + 1))
        done

        ii=$((ii + 1))
    done

    echo "$flat_policy_list"
}

###############################################################################
# Section 6: Parameter String Formatting
###############################################################################

# ─── Convert parameters to string ───────────────────────────────────────────
# output_type: "csvValues" | "csvDefinitions" | "jsonc"

epac_convert_parameters_to_string() {
    local parameters="$1"
    local output_type="$2"

    local param_count
    param_count="$(echo "$parameters" | jq 'length')"
    if [[ $param_count -eq 0 ]]; then
        echo ""
        return
    fi

    case "$output_type" in
        csvValues)
            echo "$parameters" | jq -c '
                to_entries |
                map(select(.value.multiUse != true and .value.isEffect != true)) |
                map({key: .key, value: .value.value}) |
                from_entries |
                if length > 0 then tojson else "" end
            ' | jq -r '.'
            ;;
        csvDefinitions)
            echo "$parameters" | jq -c '
                to_entries |
                map(select(.value.multiUse != true)) |
                map({key: .key, value: .value.definition}) |
                from_entries |
                if length > 0 then tojson else "" end
            ' | jq -r '.'
            ;;
        jsonc)
            local text=""
            local keys
            keys="$(echo "$parameters" | jq -r 'keys[]')"
            while IFS= read -r param_name; do
                [[ -z "$param_name" ]] && continue
                local param
                param="$(echo "$parameters" | jq --arg k "$param_name" '.[$k]')"
                local multi_use
                multi_use="$(echo "$param" | jq -r '.multiUse // false')"
                local value
                value="$(echo "$param" | jq -c '.value // null')"
                local policy_sets
                policy_sets="$(echo "$param" | jq -r '.policySets // [] | join("'"'"', '"'"'")')"
                local param_string="\"${param_name}\": ${value}, // '${policy_sets}'"
                local no_default
                no_default="$(echo "$param" | jq 'if .value == null and .defaultValue == null then true else false end')"

                if [[ "$multi_use" == "true" ]]; then
                    text+=$'\n'"    // Multi-use: (${param_string})"
                elif [[ "$no_default" == "true" ]]; then
                    text+=$'\n'"    // No-default: (${param_string})"
                else
                    text+=$'\n'"    ${param_string},"
                fi
            done <<< "$keys"
            echo "$text"
            ;;
        *)
            epac_log_error "Unknown output type: ${output_type}"
            return 1
            ;;
    esac
}
