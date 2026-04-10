#!/usr/bin/env bash
# lib/documentation/doc-policy-sets.sh — Generate documentation for policy sets
# Replaces: Out-DocumentationForPolicySets.ps1

[[ -n "${_EPAC_DOC_POLICY_SETS_LOADED:-}" ]] && return 0
readonly _EPAC_DOC_POLICY_SETS_LOADED=1

# ─── Out-DocumentationForPolicySets equivalent ─────────────────────────────
# Generates markdown, CSV, compliance CSV, and JSONC parameter files for
# policy set documentation.
#
# Usage: epac_out_documentation_for_policy_sets \
#          --output-path <path> --doc-spec <json> --item-list <json> \
#          --env-columns-csv <json> --policy-set-details <json> \
#          --flat-policy-list <json> [--include-manual] \
#          [--wiki-clone-pat <pat>] [--wiki-spn]
epac_out_documentation_for_policy_sets() {
    local output_path=""
    local doc_spec=""
    local item_list=""
    local env_columns_csv=""
    local policy_set_details=""
    local flat_policy_list=""
    local include_manual=false
    local wiki_clone_pat=""
    local wiki_spn=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-path) output_path="$2"; shift 2 ;;
            --doc-spec) doc_spec="$2"; shift 2 ;;
            --item-list) item_list="$2"; shift 2 ;;
            --env-columns-csv) env_columns_csv="$2"; shift 2 ;;
            --policy-set-details) policy_set_details="$2"; shift 2 ;;
            --flat-policy-list) flat_policy_list="$2"; shift 2 ;;
            --include-manual) include_manual=true; shift ;;
            --wiki-clone-pat) wiki_clone_pat="$2"; shift 2 ;;
            --wiki-spn) wiki_spn=true; shift ;;
            *) shift ;;
        esac
    done

    local file_name_stem
    file_name_stem="$(echo "$doc_spec" | jq -r '.fileNameStem')"
    local title
    title="$(echo "$doc_spec" | jq -r '.title')"

    epac_write_section "Generating Policy Set documentation for '$title'"
    epac_write_status "File Name: $file_name_stem" "info" 2

    # Markdown options
    local ado_wiki
    ado_wiki="$(echo "$doc_spec" | jq -r '.markdownAdoWiki // false')"
    local add_toc
    add_toc="$(echo "$doc_spec" | jq -r '.markdownAddToc // false')"
    local no_html
    no_html="$(echo "$doc_spec" | jq -r '.markdownNoEmbeddedHtml // false')"
    local include_compliance
    include_compliance="$(echo "$doc_spec" | jq -r '.markdownIncludeComplianceGroupNames // false')"
    local suppress_params
    suppress_params="$(echo "$doc_spec" | jq -r '.markdownSuppressParameterSection // false')"
    local max_param_len
    max_param_len="$(echo "$doc_spec" | jq -r '.markdownMaxParameterLength // 42')"
    [[ "$max_param_len" -lt 16 ]] && max_param_len=42

    local in_table_break="<br/>"
    local in_table_after_dn_break="<br/>"
    if [[ "$no_html" == "true" ]]; then
        in_table_after_dn_break=": "
        in_table_break=", "
    fi

    local leading_hashtag="#"
    if [[ "$ado_wiki" == "true" ]]; then
        leading_hashtag=""
    fi

    # ── Markdown Generation ──
    local md_lines=""
    _md_add() { md_lines+="$1"$'\n'; }

    if [[ "$ado_wiki" == "true" ]]; then
        _md_add "[[_TOC_]]"
        _md_add ""
    else
        _md_add "# ${title}"
        _md_add ""
        if [[ "$add_toc" == "true" ]]; then
            _md_add "[[_TOC_]]"
            _md_add ""
        fi
    fi
    _md_add "Auto-generated Policy effect documentation for PolicySets grouped by Effect and sorted by Policy category and Policy display name."

    # Build dynamic column headers from item list
    local added_header="" added_divider="" added_divider_params=""
    local item_count
    item_count="$(echo "$item_list" | jq 'length')"

    # Policy Set List section
    _md_add ""
    _md_add "${leading_hashtag}# Policy Set (Initiative) List"
    _md_add ""

    local idx=0
    while [[ $idx -lt $item_count ]]; do
        local item
        item="$(echo "$item_list" | jq --argjson i "$idx" '.[$i]')"
        local short_name
        short_name="$(echo "$item" | jq -r '.shortName')"
        local ps_id
        ps_id="$(echo "$item" | jq -r '.policySetId // .itemId')"
        local ps_detail
        ps_detail="$(echo "$policy_set_details" | jq --arg id "$ps_id" '.[$id]')"
        local ps_dn
        ps_dn="$(echo "$ps_detail" | jq -r '.displayName // ""' | tr '\n\r' '  ' | sed 's/[[:space:]]*$//')"
        local ps_desc
        ps_desc="$(echo "$ps_detail" | jq -r '.description // ""' | tr '\n\r' '  ' | sed 's/[[:space:]]*$//')"
        local ps_type
        ps_type="$(echo "$ps_detail" | jq -r '.policyType // ""')"
        local ps_cat
        ps_cat="$(echo "$ps_detail" | jq -r '.category // ""')"

        _md_add "${leading_hashtag}## ${short_name}"
        _md_add ""
        _md_add "- Display name: ${ps_dn}"
        _md_add ""
        _md_add "- Type: ${ps_type}"
        _md_add "- Category: ${ps_cat}"
        _md_add ""
        _md_add "${ps_desc}"
        _md_add ""

        added_header+=" ${short_name} |"
        added_divider+=" :-------: |"
        added_divider_params+=" :------- |"
        idx=$((idx + 1))
    done

    # Policy Effects Table
    _md_add ""
    if [[ "$include_compliance" == "true" ]]; then
        _md_add "${leading_hashtag}# Policy Effects by Policy"
        _md_add ""
        _md_add "| Category | Policy | Compliance |${added_header}"
        _md_add "| :------- | :----- | :----------|${added_divider}"
    else
        _md_add "${leading_hashtag}# Policy Effects"
        _md_add ""
        _md_add "| Category | Policy |${added_header}"
        _md_add "| :------- | :----- |${added_divider}"
    fi

    # Sort flat policy list by category, displayName
    local sorted_keys
    sorted_keys="$(echo "$flat_policy_list" | jq -r '
        [to_entries[] | {key: .key, cat: .value.category, dn: .value.displayName}]
        | sort_by(.cat, .dn)
        | .[].key
    ')"

    while IFS= read -r flat_key; do
        [[ -z "$flat_key" ]] && continue
        local entry
        entry="$(echo "$flat_policy_list" | jq --arg k "$flat_key" '.[$k]')"
        local policy_set_list
        policy_set_list="$(echo "$entry" | jq '.policySetList // {}')"
        local ev
        ev="$(echo "$entry" | jq -r 'if .effectValue != null and .effectValue != "" then .effectValue else .effectDefault end')"
        [[ -z "$ev" ]] && ev="Unknown"

        if [[ "$ev" == "Manual" && "$include_manual" != "true" ]]; then
            continue
        fi

        local added_cols=""
        local group_names_all="[]"
        idx=0
        while [[ $idx -lt $item_count ]]; do
            local sn
            sn="$(echo "$item_list" | jq -r --argjson i "$idx" '.[$i].shortName')"
            local has_ps
            has_ps="$(echo "$policy_set_list" | jq --arg sn "$sn" 'has($sn)')"
            if [[ "$has_ps" == "true" ]]; then
                local per_ps
                per_ps="$(echo "$policy_set_list" | jq --arg sn "$sn" '.[$sn]')"
                local ps_ev
                ps_ev="$(echo "$per_ps" | jq -r '.effectValue // ""')"
                if [[ "$ps_ev" == *"[if(contains(parameters('resourceTypeList')"* ]]; then
                    ps_ev="SetByParameter"
                fi
                local ps_eav
                ps_eav="$(echo "$per_ps" | jq '.effectAllowedValues // []')"
                local text
                text="$(epac_effect_to_markdown_string "$ps_ev" "$ps_eav" "$in_table_break")"
                added_cols+=" ${text} |"

                # Gather group names
                local gn
                gn="$(echo "$per_ps" | jq '.groupNames // []')"
                group_names_all="$(jq -n --argjson a "$group_names_all" --argjson b "$gn" '$a + $b | unique')"
            else
                added_cols+="  |"
            fi
            idx=$((idx + 1))
        done

        local compliance_text=""
        if [[ "$include_compliance" == "true" ]]; then
            local gn_count
            gn_count="$(echo "$group_names_all" | jq 'length')"
            if [[ $gn_count -gt 0 ]]; then
                local gn_str
                gn_str="$(echo "$group_names_all" | jq -r --arg brk "$in_table_break" 'sort | join($brk)')"
                compliance_text="| ${gn_str} "
            else
                compliance_text="| "
            fi
        fi

        local dn
        dn="$(echo "$entry" | jq -r '.displayName // ""' | tr '\n\r' '  ' | sed 's/[[:space:]]*$//')"
        local desc
        desc="$(echo "$entry" | jq -r '.description // ""' | tr '\n\r' '  ' | sed 's/[[:space:]]*$//')"
        _md_add "| $(echo "$entry" | jq -r '.category') | **${dn}**${in_table_after_dn_break}${desc} ${compliance_text}|${added_cols}"
    done <<< "$sorted_keys"

    # Policy Parameters Table
    if [[ "$suppress_params" != "true" ]]; then
        _md_add ""
        _md_add "${leading_hashtag}# Policy Parameters by Policy"
        _md_add ""
        _md_add "| Category | Policy |${added_header}"
        _md_add "| :------- | :----- |${added_divider_params}"

        while IFS= read -r flat_key; do
            [[ -z "$flat_key" ]] && continue
            local entry
            entry="$(echo "$flat_policy_list" | jq --arg k "$flat_key" '.[$k]')"
            local policy_set_list
            policy_set_list="$(echo "$entry" | jq '.policySetList // {}')"
            local ev
            ev="$(echo "$entry" | jq -r 'if .effectValue != null and .effectValue != "" then .effectValue else .effectDefault end')"
            [[ "$ev" == *"[if(contains(parameters('resourceTypeList')"* ]] && ev="SetByParameter"

            if [[ "$ev" == "Manual" && "$include_manual" != "true" ]]; then
                continue
            fi

            local added_params_cols=""
            local has_params=false
            idx=0
            while [[ $idx -lt $item_count ]]; do
                local sn
                sn="$(echo "$item_list" | jq -r --argjson i "$idx" '.[$i].shortName')"
                local has_ps
                has_ps="$(echo "$policy_set_list" | jq --arg sn "$sn" 'has($sn)')"
                if [[ "$has_ps" == "true" ]]; then
                    local per_ps
                    per_ps="$(echo "$policy_set_list" | jq --arg sn "$sn" '.[$sn]')"
                    local params
                    params="$(echo "$per_ps" | jq '.parameters // {}')"
                    local text=""
                    local not_first=false
                    local param_keys
                    param_keys="$(echo "$params" | jq -r 'keys[]')"
                    while IFS= read -r pname; do
                        [[ -z "$pname" ]] && continue
                        local param
                        param="$(echo "$params" | jq --arg n "$pname" '.[$n]')"
                        local is_effect
                        is_effect="$(echo "$param" | jq -r '.isEffect // false')"
                        [[ "$is_effect" == "true" ]] && continue

                        has_params=true
                        local display_name="$pname"
                        if [[ ${#display_name} -gt $max_param_len ]]; then
                            display_name="${display_name:0:$((max_param_len - 3))}..."
                        fi
                        local value
                        value="$(echo "$param" | jq -r 'if .value != null then (.value | if type == "string" then . else tojson end) elif .defaultValue != null then (.defaultValue | if type == "string" then . else tojson end) else "null" end')"
                        if [[ ${#value} -gt $max_param_len ]]; then
                            value="${value:0:$((max_param_len - 3))}..."
                        fi
                        if $not_first; then
                            text+="${in_table_break}"
                        else
                            not_first=true
                        fi
                        text+="${display_name} = **\`${value}\`**"
                    done <<< "$param_keys"
                    added_params_cols+=" ${text} |"
                else
                    added_params_cols+="  |"
                fi
                idx=$((idx + 1))
            done

            if $has_params; then
                local dn
                dn="$(echo "$entry" | jq -r '.displayName // ""' | tr '\n\r' '  ' | sed 's/[[:space:]]*$//')"
                local desc
                desc="$(echo "$entry" | jq -r '.description // ""' | tr '\n\r' '  ' | sed 's/[[:space:]]*$//')"
                _md_add "| $(echo "$entry" | jq -r '.category') | **${dn}**${in_table_after_dn_break}${desc} |${added_params_cols}"
            fi
        done <<< "$sorted_keys"
    fi

    # Write markdown file
    output_path="${output_path%/}"
    mkdir -p "$output_path"
    printf '%s' "$md_lines" > "${output_path}/${file_name_stem}.md"
    epac_write_status "Wrote ${output_path}/${file_name_stem}.md" "success" 2

    # ── CSV Generation ──
    _epac_generate_policy_set_csv "$output_path" "$file_name_stem" \
        "$flat_policy_list" "$env_columns_csv" "$sorted_keys" "$include_manual"

    # ── Compliance CSV ──
    _epac_generate_compliance_csv "$output_path" "$file_name_stem" \
        "$flat_policy_list" "$sorted_keys" "$include_manual"

    # ── JSONC Parameters ──
    _epac_generate_parameters_jsonc "$output_path" "$file_name_stem" \
        "$flat_policy_list" "$item_list" "$sorted_keys"

    # ── ADO Wiki push ──
    if [[ -n "$wiki_clone_pat" || "$wiki_spn" == "true" ]]; then
        _epac_push_to_ado_wiki "$doc_spec" "$output_path" "$file_name_stem" \
            "$wiki_clone_pat" "$wiki_spn"
    fi

    epac_write_status "Complete" "success" 2
}

# ─── CSV for policy sets ──────────────────────────────────────────────────
_epac_generate_policy_set_csv() {
    local output_path="$1"
    local file_name_stem="$2"
    local flat_policy_list="$3"
    local env_columns_csv="$4"
    local sorted_keys="$5"
    local include_manual="$6"

    local csv_file="${output_path}/${file_name_stem}.csv"

    # Build header
    local header="\"name\",\"referencePath\",\"policyType\",\"category\",\"displayName\",\"description\",\"groupNames\",\"policySets\",\"allowedEffects\""
    local env_count
    env_count="$(echo "$env_columns_csv" | jq 'length')"
    local ei=0
    while [[ $ei -lt $env_count ]]; do
        local ec
        ec="$(echo "$env_columns_csv" | jq -r --argjson i "$ei" '.[$i]')"
        header+=",\"${ec}Effect\""
        ei=$((ei + 1))
    done
    ei=0
    while [[ $ei -lt $env_count ]]; do
        local ec
        ec="$(echo "$env_columns_csv" | jq -r --argjson i "$ei" '.[$i]')"
        header+=",\"${ec}Parameters\""
        ei=$((ei + 1))
    done
    printf '%s\n' "$header" > "$csv_file"

    # Content rows
    while IFS= read -r flat_key; do
        [[ -z "$flat_key" ]] && continue
        local entry
        entry="$(echo "$flat_policy_list" | jq --arg k "$flat_key" '.[$k]')"
        local ev
        ev="$(echo "$entry" | jq -r 'if .effectValue != null and .effectValue != "" then .effectValue else .effectDefault end')"
        [[ "$ev" == "Manual" && "$include_manual" != "true" ]] && continue

        local row
        row="$(echo "$entry" | jq -r '
            def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
            [.name, .referencePath, .policyType, .category, .displayName, .description,
             (.groupNamesList | join(",")),
             (.policySetEffectStrings | join(",")),
             ""] | map(csv_esc) | join(",")
        ')"

        # Append allowed effects
        local effect_default
        effect_default="$(echo "$entry" | jq -r '.effectDefault // ""')"
        local is_param
        is_param="$(echo "$entry" | jq -r '.isEffectParameterized')"
        local eav_keys
        eav_keys="$(echo "$entry" | jq '.effectAllowedValues | keys')"
        local eao
        eao="$(echo "$entry" | jq '.effectAllowedOverrides // []')"
        local allowed_str
        allowed_str="$(epac_allowed_effects_to_csv_string "$effect_default" "$is_param" "$eav_keys" "$eao" ": " ",")"
        row+=",\"${allowed_str}\""

        # Per-environment columns: effect + params
        local params
        params="$(echo "$entry" | jq '.parameters // {}')"
        local param_str
        param_str="$(epac_convert_parameters_to_string "$params" "csvValues")"
        local norm_effect
        norm_effect="$(epac_effect_to_csv_string "$effect_default")"

        ei=0
        while [[ $ei -lt $env_count ]]; do
            row+=",\"${norm_effect}\""
            ei=$((ei + 1))
        done
        ei=0
        while [[ $ei -lt $env_count ]]; do
            local escaped_params="${param_str//\"/\"\"}"
            row+=",\"${escaped_params}\""
            ei=$((ei + 1))
        done

        printf '%s\n' "$row" >> "$csv_file"
    done <<< "$sorted_keys"

    epac_write_status "Wrote ${csv_file}" "success" 2
}

# ─── Compliance CSV ──────────────────────────────────────────────────────
_epac_generate_compliance_csv() {
    local output_path="$1"
    local file_name_stem="$2"
    local flat_policy_list="$3"
    local sorted_keys="$4"
    local include_manual="$5"

    local csv_file="${output_path}/${file_name_stem}-compliance.csv"
    printf '%s\n' '"groupName","category","policyDisplayName","allowedEffects","defaultEffect","policyId"' > "$csv_file"

    # Pivot by group name
    local per_group="{}"
    while IFS= read -r flat_key; do
        [[ -z "$flat_key" ]] && continue
        local entry
        entry="$(echo "$flat_policy_list" | jq --arg k "$flat_key" '.[$k]')"
        local gn_list
        gn_list="$(echo "$entry" | jq '.groupNamesList // []')"
        local gn_count
        gn_count="$(echo "$gn_list" | jq 'length')"
        local gi=0
        while [[ $gi -lt $gn_count ]]; do
            local gn
            gn="$(echo "$gn_list" | jq -r --argjson i "$gi" '.[$i]')"
            per_group="$(echo "$per_group" | jq --arg gn "$gn" --arg k "$flat_key" \
                'if has($gn) then .[$gn] += [$k] else .[$gn] = [$k] end')"
            gi=$((gi + 1))
        done
    done <<< "$sorted_keys"

    # Sort and output
    local group_names_sorted
    group_names_sorted="$(echo "$per_group" | jq -r 'keys[]')"
    while IFS= read -r gn; do
        [[ -z "$gn" ]] && continue
        local policy_keys
        policy_keys="$(echo "$per_group" | jq -r --arg gn "$gn" '.[$gn][]')"
        local cats="" dns="" effs="" defs="" ids=""
        while IFS= read -r pk; do
            [[ -z "$pk" ]] && continue
            local pe
            pe="$(echo "$flat_policy_list" | jq --arg k "$pk" '.[$k]')"
            local cat dn ed
            cat="$(echo "$pe" | jq -r '.category')"
            dn="$(echo "$pe" | jq -r '.displayName')"
            ed="$(echo "$pe" | jq -r '.effectDefault // ""')"
            local pid
            pid="$(echo "$pe" | jq -r '.name')"

            local is_param
            is_param="$(echo "$pe" | jq -r '.isEffectParameterized')"
            local eav
            eav="$(echo "$pe" | jq '.effectAllowedValues | keys')"
            local eao
            eao="$(echo "$pe" | jq '.effectAllowedOverrides // []')"
            local allowed="$ed"
            if [[ "$is_param" == "true" && "$(echo "$eav" | jq 'length')" -gt 1 ]]; then
                allowed="param:$(echo "$eav" | jq -r 'join("|")')"
            elif [[ "$(echo "$eao" | jq 'length')" -gt 0 ]]; then
                allowed="overr:$(echo "$eao" | jq -r 'join("|")')"
            fi

            [[ -n "$cats" ]] && cats+=","
            cats+="$cat"
            [[ -n "$dns" ]] && dns+=","
            dns+="$dn"
            [[ -n "$effs" ]] && effs+=","
            effs+="$allowed"
            [[ -n "$defs" ]] && defs+=","
            defs+="$ed"
            [[ -n "$ids" ]] && ids+=","
            ids+="$pid"
        done <<< "$policy_keys"

        # CSV escape
        local row
        row="\"${gn//\"/\"\"}\",\"${cats//\"/\"\"}\",\"${dns//\"/\"\"}\",\"${effs//\"/\"\"}\",\"${defs//\"/\"\"}\",\"${ids//\"/\"\"}\""
        printf '%s\n' "$row" >> "$csv_file"
    done <<< "$group_names_sorted"

    epac_write_status "Wrote ${csv_file}" "success" 2
}

# ─── JSONC Parameters file ──────────────────────────────────────────────
_epac_generate_parameters_jsonc() {
    local output_path="$1"
    local file_name_stem="$2"
    local flat_policy_list="$3"
    local item_list="$4"
    local sorted_keys="$5"

    local jsonc_file="${output_path}/${file_name_stem}.jsonc"
    local sb="{"
    sb+=$'\n'"  \"parameters\": {"

    while IFS= read -r flat_key; do
        [[ -z "$flat_key" ]] && continue
        local entry
        entry="$(echo "$flat_policy_list" | jq --arg k "$flat_key" '.[$k]')"
        local is_param
        is_param="$(echo "$entry" | jq -r '.isEffectParameterized')"
        [[ "$is_param" != "true" ]] && continue

        local policy_set_list
        policy_set_list="$(echo "$entry" | jq '.policySetList // {}')"
        local ref_path
        ref_path="$(echo "$entry" | jq -r '.referencePath // ""')"
        local dn
        dn="$(echo "$entry" | jq -r '.displayName // ""')"
        local cat
        cat="$(echo "$entry" | jq -r '.category // ""')"

        sb+=$'\n'"    // "
        sb+=$'\n'"    // -----------------------------------------------------------------------------------------------------------------------------"
        sb+=$'\n'"    // ${cat} -- ${dn}"
        if [[ -n "$ref_path" ]]; then
            sb+=$'\n'"    //     referencePath: ${ref_path}"
        fi

        # Per policy-set comments
        local item_count
        item_count="$(echo "$item_list" | jq 'length')"
        local idx=0
        while [[ $idx -lt $item_count ]]; do
            local sn
            sn="$(echo "$item_list" | jq -r --argjson i "$idx" '.[$i].shortName')"
            local has_ps
            has_ps="$(echo "$policy_set_list" | jq --arg sn "$sn" 'has($sn)')"
            if [[ "$has_ps" == "true" ]]; then
                local per_ps
                per_ps="$(echo "$policy_set_list" | jq --arg sn "$sn" '.[$sn]')"
                local ps_dn
                ps_dn="$(echo "$per_ps" | jq -r '.displayName')"
                local ps_param
                ps_param="$(echo "$per_ps" | jq -r '.isEffectParameterized')"
                if [[ "$ps_param" == "true" ]]; then
                    local epn ed
                    epn="$(echo "$per_ps" | jq -r '.effectParameterName // ""')"
                    ed="$(echo "$per_ps" | jq -r '.effectDefault // ""')"
                    sb+=$'\n'"    //   ${ps_dn}: ${ed} (${epn})"
                else
                    local er ed
                    er="$(echo "$per_ps" | jq -r '.effectReason // ""')"
                    ed="$(echo "$per_ps" | jq -r '.effectDefault // ""')"
                    sb+=$'\n'"    //   ${ps_dn}: ${ed} (${er})"
                fi
            fi
            idx=$((idx + 1))
        done
        sb+=$'\n'"    // -----------------------------------------------------------------------------------------------------------------------------"

        # Parameter lines
        local params
        params="$(echo "$entry" | jq '.parameters // {}')"
        local param_text
        param_text="$(epac_convert_parameters_to_string "$params" "jsonc")"
        sb+="${param_text}"
    done <<< "$sorted_keys"

    sb+=$'\n'"  }"
    sb+=$'\n'"}"

    printf '%s\n' "$sb" > "$jsonc_file"
    epac_write_status "Wrote ${jsonc_file}" "success" 2
}

# ─── ADO Wiki push helper ──────────────────────────────────────────────
_epac_push_to_ado_wiki() {
    local doc_spec="$1"
    local output_path="$2"
    local file_name_stem="$3"
    local wiki_clone_pat="$4"
    local wiki_spn="$5"

    local wiki_cfg
    wiki_cfg="$(echo "$doc_spec" | jq '.markdownAdoWikiConfig // null')"
    [[ "$wiki_cfg" == "null" ]] && return

    # Normalize array to single object
    if [[ "$(echo "$wiki_cfg" | jq 'type')" == '"array"' ]]; then
        wiki_cfg="$(echo "$wiki_cfg" | jq '.[0]')"
    fi

    local ado_org ado_proj ado_wiki
    ado_org="$(echo "$wiki_cfg" | jq -r '.adoOrganization // ""')"
    ado_proj="$(echo "$wiki_cfg" | jq -r '.adoProject // ""')"
    ado_wiki="$(echo "$wiki_cfg" | jq -r '.adoWiki // ""')"

    if [[ -z "$ado_org" || -z "$ado_proj" || -z "$ado_wiki" ]]; then
        epac_write_status "Wiki push enabled but ADO config incomplete. Skipping." "warning" 2
        return
    fi

    epac_write_status "Attempting push to Azure DevOps Wiki" "info" 2

    local clone_url
    if [[ "$wiki_spn" == "true" ]]; then
        local token
        token="$(az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv 2>/dev/null)" || {
            epac_write_status "Failed to acquire ADO bearer token" "error" 4
            return 1
        }
        clone_url="https://dev.azure.com/${ado_org}/${ado_proj}/_git/${ado_wiki}.wiki"
        git -c "http.extraheader=AUTHORIZATION: bearer ${token}" clone "$clone_url" "${ado_wiki}.wiki" || return 1
    else
        clone_url="https://${wiki_clone_pat}:x-oauth-basic@dev.azure.com/${ado_org}/${ado_proj}/_git/${ado_wiki}.wiki"
        git clone "$clone_url" "${ado_wiki}.wiki" || return 1
    fi

    pushd "${ado_wiki}.wiki" > /dev/null
    local branch
    branch="$(git branch --show-current)"
    cp "../${output_path}/${file_name_stem}.md" .
    git config user.email "epac-wiki@example.com"
    git config user.name "EPAC Wiki"
    git add .
    git commit -m "Update wiki with policy set documentation" || true

    if [[ "$wiki_spn" == "true" ]]; then
        git -c "http.extraheader=AUTHORIZATION: bearer ${token}" push origin "$branch"
    else
        git push origin "$branch"
    fi
    popd > /dev/null
    rm -rf "${ado_wiki}.wiki"
    epac_write_status "Wiki push complete" "success" 2
}
