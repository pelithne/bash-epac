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

    # ── Step 1: Combine per-environment flat lists (bulk jq) ──
    # Build a single JSON object mapping env-category → flatPolicyList for all envs
    local _tmp_env_flats
    _tmp_env_flats="$(mktemp)"
    echo "$assignments_by_env" | jq --argjson cats "$env_categories" '
        . as $abe |
        reduce ($cats[]) as $ec ({};
            if $abe[$ec] != null then
                . + {($ec): ($abe[$ec].flatPolicyList // {})}
            else . end
        )
    ' > "$_tmp_env_flats"

    local flat_across
    flat_across="$(jq -n --argjson include_manual "$( [[ "$include_manual" == "true" ]] && echo "true" || echo "false")" \
        --slurpfile env_flats "$_tmp_env_flats" '
        $env_flats[0] as $env_data |
        ($env_data | keys) as $env_cats |
        # Collect all unique policy table IDs across all envs
        reduce ($env_cats[]) as $ec ({};
            ($env_data[$ec] // {}) as $flat |
            reduce ($flat | keys[]) as $ptid (.;
                $flat[$ptid] as $fe |
                (if $fe.effectValue != null and $fe.effectValue != "" then $fe.effectValue else $fe.effectDefault end) as $ev |
                if ($ev == "Manual" and $include_manual == false) then .
                elif has($ptid) then
                    # Merge into existing
                    .[$ptid].ordinal = (if ($fe.ordinal // 99) < .[$ptid].ordinal then ($fe.ordinal // 99) else .[$ptid].ordinal end) |
                    .[$ptid].isEffectParameterized = (.[$ptid].isEffectParameterized or $fe.isEffectParameterized) |
                    .[$ptid].effectAllowedValues += ($fe.effectAllowedValues // {}) |
                    .[$ptid].groupNames = (.[$ptid].groupNames + ($fe.groupNamesList // []) | unique) |
                    .[$ptid].environmentList[$ec] = {
                        environmentCategory: $ec,
                        effectValue: $ev,
                        parameters: $fe.parameters
                    }
                else
                    # Create new entry
                    .[$ptid] = {
                        policyTableId: $ptid,
                        name: $fe.name,
                        referencePath: ($fe.referencePath // ""),
                        displayName: (($fe.displayName // "") | gsub("\n"; " ") | gsub("\r"; " ")),
                        description: (($fe.description // "") | gsub("\n"; " ") | gsub("\r"; " ")),
                        policyType: $fe.policyType,
                        category: $fe.category,
                        isEffectParameterized: $fe.isEffectParameterized,
                        ordinal: ($fe.ordinal // 99),
                        effectDefault: $fe.effectDefault,
                        effectAllowedValues: ($fe.effectAllowedValues // {}),
                        effectAllowedOverrides: ($fe.effectAllowedOverrides // []),
                        environmentList: {($ec): {environmentCategory: $ec, effectValue: $ev, parameters: $fe.parameters}},
                        groupNames: ($fe.groupNamesList // []),
                        policySetEffectStrings: ($fe.policySetEffectStrings // []),
                        isReferencePathMatch: false
                    }
                end
            )
        )
    ')"
    rm -f "$_tmp_env_flats"

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

    # Environment details sections — generate per-env markdown in bulk
    local _env_cats_arr=()
    readarray -t _env_cats_arr < <(echo "$env_categories" | jq -r '.[]')

    for ec in "${_env_cats_arr[@]}"; do
        local per_env
        per_env="$(echo "$assignments_by_env" | jq --arg ec "$ec" '.[$ec] // null')"
        [[ "$per_env" == "null" ]] && continue

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

        # Generate all assignment detail tables in one jq pass
        local _assignment_md
        _assignment_md="$(echo "$per_env" | jq -r --arg lh "$leading_hashtag" '
            (.itemList // []) as $items |
            (.assignmentsDetails // {}) as $details |
            $items[] |
            .assignmentId as $aid |
            ($details[$aid] // null) |
            select(. != null) |
            . as $ad |
            (.assignment.properties.displayName // .displayName // "") as $dn |
            (.policySetId // "") as $ps_id |
            (.policyDefinitionId // "") as $pd_id |
            "",
            ($lh + "## Assignment: `" + $dn + "`"),
            "",
            "| Property | Value |",
            "| :------- | :---- |",
            "| Assignment Id | " + $aid + " |",
            (if $ps_id != "" then
                "| Policy Set | `" + .displayName + "` |",
                "| Policy Set Id | " + $ps_id + " |"
             elif $pd_id != "" then
                "| Policy | `" + .displayName + "` |",
                "| Policy Definition Id | " + $pd_id + " |"
             else empty end),
            "| Type | " + (.policyType // "") + " |",
            "| Category | `" + (.category // "") + "` |",
            "| Description | " + (.description // "") + " |"
        ')"
        if [[ -n "$_assignment_md" ]]; then
            while IFS= read -r line; do
                _md_add "$line"
            done <<< "$_assignment_md"
        fi
    done

    # Build column headers from env categories array
    local added_header="" added_divider="" added_divider_params=""
    for ec in "${_env_cats_arr[@]}"; do
        added_header+=" ${ec} |"
        added_divider+=" :-----: |"
        added_divider_params+=" :----- |"
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

    # Per-category sub-page tracking (bash associative array)

    # Write flat_across to temp file for bulk jq processing
    local _tmp_flat_across
    _tmp_flat_across="$(mktemp)"
    echo "$flat_across" > "$_tmp_flat_across"

    # Generate all effects table rows + sub_pages in one jq pass
    local _tmp_effects_output
    _tmp_effects_output="$(mktemp)"
    jq -r --arg in_table_break "$in_table_break" \
           --arg in_table_after_dn_break "$in_table_after_dn_break" \
           --argjson env_cats "$env_categories" \
           --argjson include_compliance "$( [[ "$include_compliance" == "true" ]] && echo "true" || echo "false")" '
        # Sort entries by category, displayName
        [to_entries[] | select(.value.isReferencePathMatch != true)]
        | sort_by(.value.category, .value.displayName)
        | .[] |
        .value as $e |
        # Build per-env effect columns
        ($env_cats | map(
            . as $ec |
            if $e.environmentList[$ec] != null then
                $e.environmentList[$ec].effectValue as $raw_ev |
                (if ($raw_ev | test("\\[if\\(contains\\(parameters")) then "SetByParameter" else $raw_ev end) as $ev |
                ($e.effectAllowedValues | keys) as $allowed |
                # Inline epac_effect_to_markdown_string
                (if $ev == null or $ev == "" then ""
                 else
                    "**" + $ev + "**" +
                    ($allowed | map(select(. != $ev)) | map($in_table_break + .) | join(""))
                 end) as $text |
                " " + $text + " |"
            else " |"
            end
        ) | join("")) as $effect_cols |
        # Build group names column if needed
        (if $include_compliance then
            if ($e.groupNames | length) > 0 then
                "| " + ($e.groupNames | sort | unique | join($in_table_break)) + " "
            else "| " end
         else "" end) as $gn_col |
        # Build the line
        "| " + $e.category + " | **" + $e.displayName + "**" + $in_table_after_dn_break + $e.description + " " + $gn_col + "|" + $effect_cols
    ' "$_tmp_flat_across" > "$_tmp_effects_output"

    # Read effects rows into md_lines and build sub_pages using bash associative array
    declare -A _sub_pages_arr
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _md_add "$line"
        # Extract category (first field after |)
        local cat="${line#| }"
        cat="${cat%% |*}"
        if [[ -n "${_sub_pages_arr[$cat]+x}" ]]; then
            _sub_pages_arr[$cat]+=$'\n'"$line"
        else
            _sub_pages_arr[$cat]="$line"
        fi
    done < "$_tmp_effects_output"
    rm -f "$_tmp_effects_output"

    # Parameters section — single jq pass
    if [[ "$suppress_params" != "true" ]]; then
        _md_add ""
        _md_add "${leading_hashtag}# Policy Parameters by Policy"
        _md_add ""
        _md_add "| Category | Policy |${added_header}"
        _md_add "| :------- | :----- |${added_divider_params}"

        local _tmp_params_output
        _tmp_params_output="$(mktemp)"
        jq -r --arg in_table_break "$in_table_break" \
               --arg in_table_after_dn_break "$in_table_after_dn_break" \
               --argjson env_cats "$env_categories" \
               --argjson max_len "$max_param_len" '
            [to_entries[] | select(.value.isReferencePathMatch != true)]
            | sort_by(.value.category, .value.displayName)
            | .[] |
            .value as $e |
            # Build per-env param columns and check if any params exist
            ($env_cats | map(
                . as $ec |
                if $e.environmentList[$ec] != null then
                    ($e.environmentList[$ec].parameters // {}) as $params |
                    [$params | to_entries[] | select(.value.isEffect != true)] as $non_effect |
                    ($non_effect | map(
                        .key as $pname |
                        .value as $pval |
                        # Truncate param name
                        (if ($pname | length) > $max_len then ($pname[:($max_len - 3)] + "...") else $pname end) as $display_name |
                        # Get value
                        (if $pval.value != null then ($pval.value | if type == "string" then . else tojson end)
                         elif $pval.defaultValue != null then ($pval.defaultValue | if type == "string" then . else tojson end)
                         else "null" end) as $raw_value |
                        # Add spaces after commas, truncate
                        ($raw_value | gsub("\",\""; "\", \"")) as $spaced |
                        (if ($spaced | length) > $max_len then ($spaced[:($max_len - 3)] + "...") else $spaced end) as $value |
                        $display_name + " = **`" + $value + "`**"
                    ) | join($in_table_break)) as $text |
                    {text: (" " + $text + " |"), has_params: ($non_effect | length > 0)}
                else {text: " |", has_params: false}
                end
            )) as $cols |
            # Only output row if at least one env has params
            if ($cols | any(.has_params)) then
                "| " + $e.category + " | **" + $e.displayName + "**" + $in_table_after_dn_break + $e.description + " |" + ($cols | map(.text) | join(""))
            else empty
            end
        ' "$_tmp_flat_across" > "$_tmp_params_output"

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            _md_add "$line"
        done < "$_tmp_params_output"
        rm -f "$_tmp_params_output"
    fi

    rm -f "$_tmp_flat_across"

    # Write main markdown
    output_path="${output_path%/}"
    mkdir -p "$output_path"
    printf '%s' "$md_lines" > "${output_path}/${file_name_stem}.md"
    epac_write_status "Wrote ${output_path}/${file_name_stem}.md" "success" 2

    # Write per-category sub-pages using bash associative array
    output_path_services="${output_path_services%/}"
    mkdir -p "$output_path_services"
    for cat in "${!_sub_pages_arr[@]}"; do
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
        sub_content+="${_sub_pages_arr[$cat]}"$'\n'
        printf '%s' "$sub_content" > "$cat_file"
    done
    epac_write_status "Wrote per-category sub-pages to ${output_path_services}" "success" 2

    # ── CSV Generation ──
    _epac_generate_assignment_csv "$output_path" "$file_name_stem" \
        "$flat_across" "$env_categories" "$include_manual" "$pac_environments" "$assignments_by_env"

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
    local include_manual="$5"
    local pac_environments="$6"
    local assignments_by_env="$7"

    local csv_file="${output_path}/${file_name_stem}.csv"

    # Write flat_across to temp file for bulk processing
    local _tmp_csv_flat
    _tmp_csv_flat="$(mktemp)"
    echo "$flat_across" > "$_tmp_csv_flat"

    # Generate entire CSV (header + rows) in a single jq pass
    jq -r --argjson env_cats "$env_categories" '
        # Effect order for sorting
        ["Modify","Append","DenyAction","Deny","Audit","Manual","DeployIfNotExists","AuditIfNotExists","Disabled"] as $effect_order |

        # CSV escaping helper (jq 1.6 compatible — defined at top level)
        # Build header
        ($env_cats | map(. + "Effect") | join(",")) as $effect_headers |
        ($env_cats | map(. + "Parameters") | join(",")) as $param_headers |
        ("\"name\",\"referencePath\",\"policyType\",\"category\",\"displayName\",\"description\",\"groupNames\",\"policySets\",\"allowedEffects\"," + $effect_headers + "," + $param_headers),

        # Rows: sorted by category, displayName, skip duplicates
        ([to_entries[] | select(.value.isReferencePathMatch != true)]
         | sort_by(.value.category, .value.displayName)
         | .[].value) as $e |

        # Build allowed effects string
        (($e.effectAllowedValues | keys) as $eav |
         ($e.effectAllowedOverrides // []) as $eao |
         (if $e.isEffectParameterized == true and ($eav | length) > 1 then
            {prefix: "parameter", list: $eav}
          elif ($eao | length) > 1 then
            {prefix: "override", list: $eao}
          elif ($e.effectDefault // "") != "" and $e.effectDefault != "null" then
            {prefix: "default", list: [$e.effectDefault]}
          else
            {prefix: "none", list: ["No effect allowed", "Error"]}
          end) as $ae |
         # Sort by effect order
         ([$effect_order[] as $candidate | $ae.list[] as $eff |
           select(($eff | ascii_downcase) == ($candidate | ascii_downcase)) | $candidate] | unique) as $sorted_effects |
         $ae.prefix + ": " + ($sorted_effects | join(","))
        ) as $allowed_str |

        # Build per-env effect columns
        ($env_cats | map(
            . as $ec |
            if $e.environmentList[$ec] != null then
                $e.environmentList[$ec].effectValue as $ev |
                # Map effect name to canonical form
                (($ev | ascii_downcase) as $lev |
                 if $lev == "modify" then "Modify"
                 elif $lev == "append" then "Append"
                 elif $lev == "denyaction" then "DenyAction"
                 elif $lev == "deny" then "Deny"
                 elif $lev == "audit" then "Audit"
                 elif $lev == "manual" then "Manual"
                 elif $lev == "deployifnotexists" then "DeployIfNotExists"
                 elif $lev == "auditifnotexists" then "AuditIfNotExists"
                 elif $lev == "disabled" then "Disabled"
                 else "Error" end) as $mapped |
                "\"" + $mapped + "\""
            else "\"\""
            end
        ) | join(",")) as $effect_cols |

        # Build per-env parameter columns
        ($env_cats | map(
            . as $ec |
            if $e.environmentList[$ec] != null then
                ($e.environmentList[$ec].parameters // {}) |
                to_entries |
                map(select(.value.multiUse != true and .value.isEffect != true)) |
                map({key: .key, value: .value.value}) |
                from_entries |
                if length > 0 then
                    tojson | gsub("\""; "\"\"") |
                    "\"" + . + "\""
                else "\"\""
                end
            else "\"\""
            end
        ) | join(",")) as $param_cols |

        # Build the row — csv-escape each base field
        [$e.name, $e.referencePath, $e.policyType, $e.category, $e.displayName, $e.description,
         ($e.groupNames | sort | unique | join(",")),
         ($e.policySetEffectStrings | join(",")),
         $allowed_str] |
        map(tostring | if test("[,\"\n]") then "\"" + gsub("\""; "\"\"") + "\"" else . end) |
        join(",") |
        . + "," + $effect_cols + "," + $param_cols
    ' "$_tmp_csv_flat" > "$csv_file"

    rm -f "$_tmp_csv_flat"
    epac_write_status "Wrote ${csv_file}" "success" 2
}
