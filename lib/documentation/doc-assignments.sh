#!/usr/bin/env bash
# lib/documentation/doc-assignments.sh — Generate documentation for policy assignments
# Replaces: Out-DocumentationForPolicyAssignments.ps1

[[ -n "${_EPAC_DOC_ASSIGNMENTS_LOADED:-}" ]] && return 0
readonly _EPAC_DOC_ASSIGNMENTS_LOADED=1

# ─── Out-DocumentationForPolicyAssignments equivalent ──────────────────────
# Generates markdown (main + per-category sub-pages) and CSV for
# policy assignment documentation across environments.
#
# Usage: epac_out_documentation_for_assignments \
#          --output-path <path> --output-path-services <path> \
#          --doc-spec <json> --assignments-by-env <json> \
#          [--include-manual] [--pac-environments <json>] \
#          [--wiki-clone-pat <pat>] [--wiki-spn]
epac_out_documentation_for_assignments() {
    local output_path=""
    local output_path_services=""
    local doc_spec=""
    local assignments_by_env=""
    local include_manual=false
    local pac_environments="{}"
    local wiki_clone_pat=""
    local wiki_spn=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-path) output_path="$2"; shift 2 ;;
            --output-path-services) output_path_services="$2"; shift 2 ;;
            --doc-spec) doc_spec="$2"; shift 2 ;;
            --assignments-by-env) assignments_by_env="$2"; shift 2 ;;
            --include-manual) include_manual=true; shift ;;
            --pac-environments) pac_environments="$2"; shift 2 ;;
            --wiki-clone-pat) wiki_clone_pat="$2"; shift 2 ;;
            --wiki-spn) wiki_spn=true; shift ;;
            *) shift ;;
        esac
    done

    local file_name_stem
    file_name_stem="$(echo "$doc_spec" | jq -r '.fileNameStem')"
    local title
    title="$(echo "$doc_spec" | jq -r '.title')"
    local env_categories
    env_categories="$(echo "$doc_spec" | jq '.environmentCategories // []')"

    epac_write_section "Generating Policy Assignment documentation for '$title'"
    epac_write_status "File Name: $file_name_stem" "info" 2

    local env_count
    env_count="$(echo "$env_categories" | jq 'length')"
    if [[ $env_count -eq 0 ]]; then
        epac_log_error "No environmentCategories specified"
        return 1
    fi

    # Markdown options
    local ado_wiki no_html include_compliance suppress_params add_toc max_param_len
    ado_wiki="$(echo "$doc_spec" | jq -r '.markdownAdoWiki // false')"
    add_toc="$(echo "$doc_spec" | jq -r '.markdownAddToc // false')"
    no_html="$(echo "$doc_spec" | jq -r '.markdownNoEmbeddedHtml // false')"
    include_compliance="$(echo "$doc_spec" | jq -r '.markdownIncludeComplianceGroupNames // false')"
    suppress_params="$(echo "$doc_spec" | jq -r '.markdownSuppressParameterSection // false')"
    max_param_len="$(echo "$doc_spec" | jq -r '.markdownMaxParameterLength // 42')"
    [[ "$max_param_len" -lt 16 ]] && max_param_len=42

    local in_table_break="<br/>"
    local in_table_after_dn_break="<br/>"
    if [[ "$no_html" == "true" ]]; then
        in_table_after_dn_break=": "
        in_table_break=", "
    fi

    local leading_hashtag="#"
    [[ "$ado_wiki" == "true" ]] && leading_hashtag=""

    # ── Step 1: Combine per-environment flat lists ──
    local flat_across="{}"
    local ei=0
    while [[ $ei -lt $env_count ]]; do
        local ec
        ec="$(echo "$env_categories" | jq -r --argjson i "$ei" '.[$i]')"
        local per_env
        per_env="$(echo "$assignments_by_env" | jq --arg ec "$ec" '.[$ec] // null')"
        if [[ "$per_env" == "null" ]]; then
            ei=$((ei + 1)); continue
        fi

        local flat_list
        flat_list="$(echo "$per_env" | jq '.flatPolicyList // {}')"
        local flat_keys
        flat_keys="$(echo "$flat_list" | jq -r 'keys[]')"

        while IFS= read -r ptid; do
            [[ -z "$ptid" ]] && continue
            local fe
            fe="$(echo "$flat_list" | jq --arg k "$ptid" '.[$k]')"
            local ev
            ev="$(echo "$fe" | jq -r 'if .effectValue != null and .effectValue != "" then .effectValue else .effectDefault end')"
            [[ "$ev" == "Manual" && "$include_manual" != "true" ]] && continue

            local is_param
            is_param="$(echo "$fe" | jq -r '.isEffectParameterized')"
            local has_existing
            has_existing="$(echo "$flat_across" | jq --arg k "$ptid" 'has($k)')"

            if [[ "$has_existing" != "true" ]]; then
                # Create new across-environments entry
                flat_across="$(echo "$flat_across" | jq --arg k "$ptid" --argjson fe "$fe" --arg ec "$ec" --argjson ev_data "$(echo "$fe" | jq --arg ec "$ec" '{($ec): {environmentCategory: $ec, effectValue: (.effectValue // .effectDefault), parameters: .parameters}}')" '
                    .[$k] = {
                        policyTableId: $k,
                        name: $fe.name,
                        referencePath: ($fe.referencePath // ""),
                        displayName: ($fe.displayName | gsub("\n"; " ") | gsub("\r"; " ")),
                        description: ($fe.description | gsub("\n"; " ") | gsub("\r"; " ")),
                        policyType: $fe.policyType,
                        category: $fe.category,
                        isEffectParameterized: $fe.isEffectParameterized,
                        ordinal: ($fe.ordinal // 99),
                        effectDefault: $fe.effectDefault,
                        effectAllowedValues: ($fe.effectAllowedValues // {}),
                        effectAllowedOverrides: ($fe.effectAllowedOverrides // []),
                        environmentList: $ev_data,
                        groupNames: ($fe.groupNamesList // []),
                        policySetEffectStrings: ($fe.policySetEffectStrings // []),
                        isReferencePathMatch: false
                    }
                ')"
            else
                # Merge into existing entry
                flat_across="$(echo "$flat_across" | jq --arg k "$ptid" --argjson fe "$fe" --arg ec "$ec" --argjson is_p "$is_param" '
                    .[$k] as $existing |
                    .[$k].ordinal = (if $fe.ordinal < $existing.ordinal then $fe.ordinal else $existing.ordinal end) |
                    .[$k].isEffectParameterized = ($existing.isEffectParameterized or ($is_p == true)) |
                    .[$k].effectAllowedValues += ($fe.effectAllowedValues // {}) |
                    .[$k].groupNames = ($existing.groupNames + ($fe.groupNamesList // []) | unique) |
                    .[$k].environmentList[$ec] = {
                        environmentCategory: $ec,
                        effectValue: ($fe.effectValue // $fe.effectDefault),
                        parameters: $fe.parameters
                    }
                ')"
            fi
        done <<< "$flat_keys"
        ei=$((ei + 1))
    done

    # ── Step 2: Deduplicate by referencePath + displayName ──
    flat_across="$(_epac_deduplicate_flat_list "$flat_across")"

    # ── Step 3: Generate Markdown ──
    local md_lines=""
    _md_add() { md_lines+="$1"$'\n'; }

    if [[ "$ado_wiki" == "true" ]]; then
        _md_add "[[_TOC_]]"; _md_add ""
    else
        _md_add "# ${title}"; _md_add ""
        [[ "$add_toc" == "true" ]] && { _md_add "[[_TOC_]]"; _md_add ""; }
    fi

    local env_names_str
    env_names_str="$(echo "$env_categories" | jq -r 'join("'"'"', '"'"'")')"
    _md_add "Auto-generated Policy effect documentation across environments '${env_names_str}' sorted by Policy category and Policy display name."

    # Environment details sections
    ei=0
    while [[ $ei -lt $env_count ]]; do
        local ec
        ec="$(echo "$env_categories" | jq -r --argjson i "$ei" '.[$i]')"
        local per_env
        per_env="$(echo "$assignments_by_env" | jq --arg ec "$ec" '.[$ec] // null')"
        if [[ "$per_env" != "null" ]]; then
            _md_add ""
            _md_add "${leading_hashtag}# Environment Category \`${ec}\`"
            _md_add ""
            _md_add "${leading_hashtag}## Scopes"
            _md_add ""
            local scopes
            scopes="$(echo "$per_env" | jq -r '.scopes // [] | .[]')"
            while IFS= read -r scope; do
                [[ -n "$scope" ]] && _md_add "- ${scope}"
            done <<< "$scopes"

            # Assignment details
            local a_items
            a_items="$(echo "$per_env" | jq '.itemList // []')"
            local a_details
            a_details="$(echo "$per_env" | jq '.assignmentsDetails // {}')"
            local ai=0
            local a_count
            a_count="$(echo "$a_items" | jq 'length')"
            while [[ $ai -lt $a_count ]]; do
                local aid
                aid="$(echo "$a_items" | jq -r --argjson i "$ai" '.[$i].assignmentId')"
                local ad
                ad="$(echo "$a_details" | jq --arg id "$aid" '.[$id] // null')"
                if [[ "$ad" != "null" ]]; then
                    local ad_dn
                    ad_dn="$(echo "$ad" | jq -r '.assignment.properties.displayName // .displayName // ""')"
                    _md_add ""
                    _md_add "${leading_hashtag}## Assignment: \`${ad_dn}\`"
                    _md_add ""
                    _md_add "| Property | Value |"
                    _md_add "| :------- | :---- |"
                    _md_add "| Assignment Id | ${aid} |"
                    local ps_id
                    ps_id="$(echo "$ad" | jq -r '.policySetId // empty')"
                    local pd_id
                    pd_id="$(echo "$ad" | jq -r '.policyDefinitionId // empty')"
                    if [[ -n "$ps_id" ]]; then
                        _md_add "| Policy Set | \`$(echo "$ad" | jq -r '.displayName')\` |"
                        _md_add "| Policy Set Id | ${ps_id} |"
                    elif [[ -n "$pd_id" ]]; then
                        _md_add "| Policy | \`$(echo "$ad" | jq -r '.displayName')\` |"
                        _md_add "| Policy Definition Id | ${pd_id} |"
                    fi
                    _md_add "| Type | $(echo "$ad" | jq -r '.policyType // ""') |"
                    _md_add "| Category | \`$(echo "$ad" | jq -r '.category // ""')\` |"
                    _md_add "| Description | $(echo "$ad" | jq -r '.description // ""') |"
                fi
                ai=$((ai + 1))
            done
        fi
        ei=$((ei + 1))
    done

    # Build column headers
    local added_header="" added_divider="" added_divider_params=""
    ei=0
    while [[ $ei -lt $env_count ]]; do
        local ec
        ec="$(echo "$env_categories" | jq -r --argjson i "$ei" '.[$i]')"
        added_header+=" ${ec} |"
        added_divider+=" :-----: |"
        added_divider_params+=" :----- |"
        ei=$((ei + 1))
    done

    # Policy Effects table
    _md_add ""
    if [[ "$include_compliance" == "true" ]]; then
        _md_add "${leading_hashtag}# Policy Effects by Policy"
        _md_add ""
        _md_add "| Category | Policy | Group Names |${added_header}"
        _md_add "| :------- | :----- | :---------- |${added_divider}"
    else
        _md_add "${leading_hashtag}# Policy Effects by Policy"
        _md_add ""
        _md_add "| Category | Policy |${added_header}"
        _md_add "| :------- | :----- |${added_divider}"
    fi

    # Per-category sub-page tracking
    local sub_pages="{}"

    local sorted_keys
    sorted_keys="$(echo "$flat_across" | jq -r '
        [to_entries[] | {key: .key, cat: .value.category, dn: .value.displayName}]
        | sort_by(.cat, .dn) | .[].key
    ')"

    while IFS= read -r flat_key; do
        [[ -z "$flat_key" ]] && continue
        local entry
        entry="$(echo "$flat_across" | jq --arg k "$flat_key" '.[$k]')"
        local is_dup
        is_dup="$(echo "$entry" | jq -r '.isReferencePathMatch')"
        [[ "$is_dup" == "true" ]] && continue

        local env_list
        env_list="$(echo "$entry" | jq '.environmentList')"
        local added_cols=""
        ei=0
        while [[ $ei -lt $env_count ]]; do
            local ec
            ec="$(echo "$env_categories" | jq -r --argjson i "$ei" '.[$i]')"
            local has_ec
            has_ec="$(echo "$env_list" | jq --arg ec "$ec" 'has($ec)')"
            if [[ "$has_ec" == "true" ]]; then
                local ec_ev
                ec_ev="$(echo "$env_list" | jq -r --arg ec "$ec" '.[$ec].effectValue')"
                [[ "$ec_ev" == *"[if(contains(parameters('resourceTypeList')"* ]] && ec_ev="SetByParameter"
                local eav
                eav="$(echo "$entry" | jq '.effectAllowedValues | keys')"
                local text
                text="$(epac_effect_to_markdown_string "$ec_ev" "$eav" "$in_table_break")"
                added_cols+=" ${text} |"
            else
                added_cols+=" |"
            fi
            ei=$((ei + 1))
        done

        local gn_text=""
        if [[ "$include_compliance" == "true" ]]; then
            local gn
            gn="$(echo "$entry" | jq '.groupNames // []')"
            local gn_count
            gn_count="$(echo "$gn" | jq 'length')"
            if [[ $gn_count -gt 0 ]]; then
                gn_text="| $(echo "$gn" | jq -r 'sort | unique | join("'"$in_table_break"'")') "
            else
                gn_text="| "
            fi
        fi

        local cat dn desc
        cat="$(echo "$entry" | jq -r '.category')"
        dn="$(echo "$entry" | jq -r '.displayName')"
        desc="$(echo "$entry" | jq -r '.description')"
        local line="| ${cat} | **${dn}**${in_table_after_dn_break}${desc} ${gn_text}|${added_cols}"
        _md_add "$line"

        # Track per-category
        sub_pages="$(echo "$sub_pages" | jq --arg cat "$cat" --arg line "$line" \
            'if has($cat) then .[$cat] += [$line] else .[$cat] = [$line] end')"
    done <<< "$sorted_keys"

    # Parameters section
    if [[ "$suppress_params" != "true" ]]; then
        _md_add ""
        _md_add "${leading_hashtag}# Policy Parameters by Policy"
        _md_add ""
        _md_add "| Category | Policy |${added_header}"
        _md_add "| :------- | :----- |${added_divider_params}"

        while IFS= read -r flat_key; do
            [[ -z "$flat_key" ]] && continue
            local entry
            entry="$(echo "$flat_across" | jq --arg k "$flat_key" '.[$k]')"
            [[ "$(echo "$entry" | jq -r '.isReferencePathMatch')" == "true" ]] && continue

            local env_list
            env_list="$(echo "$entry" | jq '.environmentList')"
            local added_params_cols=""
            local has_params=false

            ei=0
            while [[ $ei -lt $env_count ]]; do
                local ec
                ec="$(echo "$env_categories" | jq -r --argjson i "$ei" '.[$i]')"
                local has_ec
                has_ec="$(echo "$env_list" | jq --arg ec "$ec" 'has($ec)')"
                if [[ "$has_ec" == "true" ]]; then
                    local params
                    params="$(echo "$env_list" | jq --arg ec "$ec" '.[$ec].parameters // {}')"
                    local text=""
                    local not_first=false
                    local param_keys
                    param_keys="$(echo "$params" | jq -r 'keys[]')"
                    while IFS= read -r pname; do
                        [[ -z "$pname" ]] && continue
                        local param
                        param="$(echo "$params" | jq --arg n "$pname" '.[$n]')"
                        [[ "$(echo "$param" | jq -r '.isEffect // false')" == "true" ]] && continue

                        has_params=true
                        local display_name="$pname"
                        [[ ${#display_name} -gt $max_param_len ]] && display_name="${display_name:0:$((max_param_len - 3))}..."
                        local value
                        value="$(echo "$param" | jq -r 'if .value != null then (.value | if type == "string" then . else tojson end) elif .defaultValue != null then (.defaultValue | if type == "string" then . else tojson end) else "null" end')"
                        # Add spaces after commas in arrays for readability
                        value="${value//\",\"/\", \"}"
                        [[ ${#value} -gt $max_param_len ]] && value="${value:0:$((max_param_len - 3))}..."
                        $not_first && text+="${in_table_break}" || not_first=true
                        text+="${display_name} = **\`${value}\`**"
                    done <<< "$param_keys"
                    added_params_cols+=" ${text} |"
                else
                    added_params_cols+=" |"
                fi
                ei=$((ei + 1))
            done

            if $has_params; then
                local cat dn desc
                cat="$(echo "$entry" | jq -r '.category')"
                dn="$(echo "$entry" | jq -r '.displayName')"
                desc="$(echo "$entry" | jq -r '.description')"
                _md_add "| ${cat} | **${dn}**${in_table_after_dn_break}${desc} |${added_params_cols}"
            fi
        done <<< "$sorted_keys"
    fi

    # Write main markdown
    output_path="${output_path%/}"
    mkdir -p "$output_path"
    printf '%s' "$md_lines" > "${output_path}/${file_name_stem}.md"
    epac_write_status "Wrote ${output_path}/${file_name_stem}.md" "success" 2

    # Write per-category sub-pages
    output_path_services="${output_path_services%/}"
    mkdir -p "$output_path_services"
    local cat_keys
    cat_keys="$(echo "$sub_pages" | jq -r 'keys[]')"
    while IFS= read -r cat; do
        [[ -z "$cat" ]] && continue
        local cat_fn="${cat// /-}"
        local cat_file="${output_path_services}/${cat_fn}.md"
        # Build sub-page with header
        local sub_content=""
        if [[ "$include_compliance" == "true" ]]; then
            sub_content+="${leading_hashtag}# Policy Effects by Policy"$'\n\n'
            sub_content+="| Category | Policy | Group Names |${added_header}"$'\n'
            sub_content+="| :------- | :----- | :---------- |${added_divider}"$'\n'
        else
            sub_content+="${leading_hashtag}# Policy Effects by Policy"$'\n\n'
            sub_content+="| Category | Policy |${added_header}"$'\n'
            sub_content+="| :------- | :----- |${added_divider}"$'\n'
        fi
        local lines
        lines="$(echo "$sub_pages" | jq -r --arg cat "$cat" '.[$cat][]')"
        while IFS= read -r line; do
            sub_content+="${line}"$'\n'
        done <<< "$lines"
        printf '%s' "$sub_content" > "$cat_file"
    done <<< "$cat_keys"
    epac_write_status "Wrote per-category sub-pages to ${output_path_services}" "success" 2

    # ── CSV Generation ──
    _epac_generate_assignment_csv "$output_path" "$file_name_stem" \
        "$flat_across" "$env_categories" "$sorted_keys" "$include_manual" "$pac_environments" "$assignments_by_env"

    # ── ADO Wiki push ──
    if [[ -n "$wiki_clone_pat" || "$wiki_spn" == "true" ]]; then
        _epac_push_to_ado_wiki "$doc_spec" "$output_path" "$file_name_stem" \
            "$wiki_clone_pat" "$wiki_spn"
    fi

    epac_write_status "Complete" "success" 2
}

# ─── Deduplicate flat list ──────────────────────────────────────────────
_epac_deduplicate_flat_list() {
    local flat="$1"
    echo "$flat" | jq '
        . as $orig |
        reduce (keys[]) as $k ($orig;
            if .[$k].policyType != "BuiltIn" and .[$k].isReferencePathMatch == false then
                reduce (keys[]) as $k2 (.;
                    if $k != $k2
                       and .[$k2].policyType != "BuiltIn"
                       and .[$k2].isReferencePathMatch == false
                       and .[$k].referencePath == .[$k2].referencePath
                       and .[$k].displayName == .[$k2].displayName
                    then
                        .[$k2].isReferencePathMatch = true |
                        reduce (.[$k2].environmentList | keys[]) as $env (.;
                            if .[$k].environmentList | has($env) | not then
                                .[$k].environmentList[$env] = .[$k2].environmentList[$env]
                            else .
                            end
                        )
                    else .
                    end
                )
            else .
            end
        )
    '
}

# ─── Assignment CSV ────────────────────────────────────────────────────
_epac_generate_assignment_csv() {
    local output_path="$1"
    local file_name_stem="$2"
    local flat_across="$3"
    local env_categories="$4"
    local sorted_keys="$5"
    local include_manual="$6"
    local pac_environments="$7"
    local assignments_by_env="$8"

    local csv_file="${output_path}/${file_name_stem}.csv"
    local env_count
    env_count="$(echo "$env_categories" | jq 'length')"

    # Build header
    local header="\"name\",\"referencePath\",\"policyType\",\"category\",\"displayName\",\"description\",\"groupNames\",\"policySets\",\"allowedEffects\""
    local ei=0
    while [[ $ei -lt $env_count ]]; do
        local ec
        ec="$(echo "$env_categories" | jq -r --argjson i "$ei" '.[$i]')"
        header+=",\"${ec}Effect\""
        ei=$((ei + 1))
    done
    ei=0
    while [[ $ei -lt $env_count ]]; do
        local ec
        ec="$(echo "$env_categories" | jq -r --argjson i "$ei" '.[$i]')"
        header+=",\"${ec}Parameters\""
        ei=$((ei + 1))
    done
    printf '%s\n' "$header" > "$csv_file"

    # Content rows
    while IFS= read -r flat_key; do
        [[ -z "$flat_key" ]] && continue
        local entry
        entry="$(echo "$flat_across" | jq --arg k "$flat_key" '.[$k]')"
        [[ "$(echo "$entry" | jq -r '.isReferencePathMatch')" == "true" ]] && continue

        local row
        row="$(echo "$entry" | jq -r '
            def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
            [.name, .referencePath, .policyType, .category, .displayName, .description,
             (.groupNames | sort | unique | join(",")),
             (.policySetEffectStrings | join(",")),
             ""] | map(csv_esc) | join(",")
        ')"

        # Allowed effects
        local is_param effect_default eav_keys eao
        is_param="$(echo "$entry" | jq -r '.isEffectParameterized')"
        effect_default="$(echo "$entry" | jq -r '.effectDefault // ""')"
        eav_keys="$(echo "$entry" | jq '.effectAllowedValues | keys')"
        eao="$(echo "$entry" | jq '.effectAllowedOverrides // []')"
        local allowed_str
        allowed_str="$(epac_allowed_effects_to_csv_string "$effect_default" "$is_param" "$eav_keys" "$eao" ": " ",")"
        row+=",\"${allowed_str}\""

        # Per env columns
        local env_list
        env_list="$(echo "$entry" | jq '.environmentList')"
        ei=0
        while [[ $ei -lt $env_count ]]; do
            local ec
            ec="$(echo "$env_categories" | jq -r --argjson i "$ei" '.[$i]')"
            local has_ec
            has_ec="$(echo "$env_list" | jq --arg ec "$ec" 'has($ec)')"
            if [[ "$has_ec" == "true" ]]; then
                local ec_ev
                ec_ev="$(echo "$env_list" | jq -r --arg ec "$ec" '.[$ec].effectValue')"
                row+=",\"$(epac_effect_to_csv_string "$ec_ev")\""
            else
                row+=",\"\""
            fi
            ei=$((ei + 1))
        done
        ei=0
        while [[ $ei -lt $env_count ]]; do
            local ec
            ec="$(echo "$env_categories" | jq -r --argjson i "$ei" '.[$i]')"
            local has_ec
            has_ec="$(echo "$env_list" | jq --arg ec "$ec" 'has($ec)')"
            if [[ "$has_ec" == "true" ]]; then
                local params
                params="$(echo "$env_list" | jq --arg ec "$ec" '.[$ec].parameters // {}')"
                local param_str
                param_str="$(epac_convert_parameters_to_string "$params" "csvValues")"
                local escaped="${param_str//\"/\"\"}"
                row+=",\"${escaped}\""
            else
                row+=",\"\""
            fi
            ei=$((ei + 1))
        done

        printf '%s\n' "$row" >> "$csv_file"
    done <<< "$sorted_keys"

    epac_write_status "Wrote ${csv_file}" "success" 2
}
