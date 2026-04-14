#!/usr/bin/env bash
# lib/documentation/doc-policy-sets.sh — Generate documentation for policy sets
# Replaces: Out-DocumentationForPolicySets.ps1
# Performance-optimized: uses bulk single-pass jq operations

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
    local ado_wiki add_toc no_html include_compliance suppress_params max_param_len
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

    # Write large data to temp files for slurpfile usage
    local _tmp_flat _tmp_items _tmp_ps_details
    _tmp_flat="$(mktemp)"
    _tmp_items="$(mktemp)"
    _tmp_ps_details="$(mktemp)"
    echo "$flat_policy_list" > "$_tmp_flat"
    echo "$item_list" > "$_tmp_items"
    echo "$policy_set_details" > "$_tmp_ps_details"

    # ── Markdown Generation ──
    local md_lines=""
    _md_add() { md_lines+="$1"$'\n'; }

    if [[ "$ado_wiki" == "true" ]]; then
        _md_add "[[_TOC_]]"; _md_add ""
    else
        _md_add "# ${title}"; _md_add ""
        [[ "$add_toc" == "true" ]] && { _md_add "[[_TOC_]]"; _md_add ""; }
    fi
    _md_add "Auto-generated Policy effect documentation for PolicySets grouped by Effect and sorted by Policy category and Policy display name."

    # Policy Set List section — single jq pass
    local _ps_list_md
    _ps_list_md="$(jq -n -r --arg lh "$leading_hashtag" \
        --slurpfile items "$_tmp_items" \
        --slurpfile details "$_tmp_ps_details" '
        $items[0] as $il |
        $details[0] as $psd |
        $il[] |
        .shortName as $sn |
        (.policySetId // .itemId) as $ps_id |
        ($psd[$ps_id] // {}) as $d |
        ($d.displayName // "" | gsub("\n"; " ") | gsub("\r"; " ") | gsub("\\s+$"; "")) as $dn |
        ($d.description // "" | gsub("\n"; " ") | gsub("\r"; " ") | gsub("\\s+$"; "")) as $desc |
        ($d.policyType // "") as $pt |
        ($d.category // "") as $cat |
        "",
        ($lh + "# " + $sn),
        "",
        "- Display name: " + $dn,
        "",
        "- Type: " + $pt,
        "- Category: " + $cat,
        "",
        $desc,
        ""
    ' /dev/null)"
    while IFS= read -r line; do
        _md_add "$line"
    done <<< "$_ps_list_md"

    # Build column headers
    local added_header="" added_divider="" added_divider_params=""
    local _short_names_arr=()
    readarray -t _short_names_arr < <(echo "$item_list" | jq -r '.[].shortName')
    for sn in "${_short_names_arr[@]}"; do
        added_header+=" ${sn} |"
        added_divider+=" :-------: |"
        added_divider_params+=" :------- |"
    done

    # Policy Effects Table header
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

    # Effects table rows — single jq pass
    local _tmp_effects_output
    _tmp_effects_output="$(mktemp)"
    jq -r --arg in_table_break "$in_table_break" \
           --arg in_table_after_dn_break "$in_table_after_dn_break" \
           --argjson include_manual "$( [[ "$include_manual" == "true" ]] && echo "true" || echo "false")" \
           --argjson include_compliance "$( [[ "$include_compliance" == "true" ]] && echo "true" || echo "false")" \
           --slurpfile items "$_tmp_items" '
        $items[0] as $il |
        [$il[].shortName] as $short_names |
        # Sort entries by category, displayName
        [to_entries[]]
        | sort_by(.value.category, .value.displayName)
        | .[] |
        .value as $e |
        # Determine effective value
        (if $e.effectValue != null and $e.effectValue != "" then $e.effectValue else $e.effectDefault end) as $ev |
        if ($ev == "Manual" and $include_manual == false) then empty
        else
            # Build per-policy-set columns
            ($short_names | map(
                . as $sn |
                ($e.policySetList[$sn] // null) as $per_ps |
                if $per_ps != null then
                    ($per_ps.effectValue // "") as $ps_ev |
                    (if ($ps_ev | test("\\[if\\(contains\\(parameters")) then "SetByParameter" else $ps_ev end) as $clean_ev |
                    ($per_ps.effectAllowedValues // []) as $allowed |
                    # Build markdown effect string
                    (if $clean_ev == "" or $clean_ev == null then ""
                     else
                        "**" + $clean_ev + "**" +
                        ($allowed | map(select(. != $clean_ev)) | map($in_table_break + .) | join(""))
                     end) as $text |
                    " " + $text + " |"
                else "  |"
                end
            ) | join("")) as $effect_cols |
            # Group names / compliance column
            (if $include_compliance then
                ($short_names | map(
                    . as $sn |
                    ($e.policySetList[$sn] // null) |
                    if . != null then (.groupNames // [])[] else empty end
                ) | unique | sort) as $all_gn |
                if ($all_gn | length) > 0 then
                    "| " + ($all_gn | join($in_table_break)) + " "
                else "| " end
             else "" end) as $compliance_col |
            # Description cleanup
            ($e.displayName // "" | gsub("\n"; " ") | gsub("\r"; " ") | gsub("\\s+$"; "")) as $dn |
            ($e.description // "" | gsub("\n"; " ") | gsub("\r"; " ") | gsub("\\s+$"; "")) as $desc |
            "| " + ($e.category // "") + " | **" + $dn + "**" + $in_table_after_dn_break + $desc + " " + $compliance_col + "|" + $effect_cols
        end
    ' "$_tmp_flat" > "$_tmp_effects_output"

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        _md_add "$line"
    done < "$_tmp_effects_output"
    rm -f "$_tmp_effects_output"

    # Policy Parameters Table — single jq pass
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
               --argjson max_len "$max_param_len" \
               --argjson include_manual "$( [[ "$include_manual" == "true" ]] && echo "true" || echo "false")" \
               --slurpfile items "$_tmp_items" '
            $items[0] as $il |
            [$il[].shortName] as $short_names |
            [to_entries[]]
            | sort_by(.value.category, .value.displayName)
            | .[] |
            .value as $e |
            (if $e.effectValue != null and $e.effectValue != "" then $e.effectValue else $e.effectDefault end) as $ev |
            if ($ev == "Manual" and $include_manual == false) then empty
            else
                # Build per-policy-set param columns
                ($short_names | map(
                    . as $sn |
                    ($e.policySetList[$sn] // null) as $per_ps |
                    if $per_ps != null then
                        ($per_ps.parameters // {}) |
                        to_entries |
                        map(select(.value.isEffect != true)) |
                        if length > 0 then
                            {
                                text: (map(
                                    .key as $pname |
                                    .value as $pval |
                                    (if ($pname | length) > $max_len then ($pname[:($max_len - 3)] + "...") else $pname end) as $display_name |
                                    (if $pval.value != null then ($pval.value | if type == "string" then . else tojson end)
                                     elif $pval.defaultValue != null then ($pval.defaultValue | if type == "string" then . else tojson end)
                                     else "null" end) as $raw_value |
                                    (if ($raw_value | length) > $max_len then ($raw_value[:($max_len - 3)] + "...") else $raw_value end) as $value |
                                    $display_name + " = **`" + $value + "`**"
                                ) | join($in_table_break)),
                                has_params: true
                            }
                        else
                            {text: "", has_params: false}
                        end |
                        " " + .text + " |"
                    else "  |"
                    end
                )) as $cols |
                # Only output row if at least one set has params
                ([$cols[] | select(test("\\*\\*`"))] | length > 0) as $any_params |
                if $any_params then
                    ($e.displayName // "" | gsub("\n"; " ") | gsub("\r"; " ") | gsub("\\s+$"; "")) as $dn |
                    ($e.description // "" | gsub("\n"; " ") | gsub("\r"; " ") | gsub("\\s+$"; "")) as $desc |
                    "| " + ($e.category // "") + " | **" + $dn + "**" + $in_table_after_dn_break + $desc + " |" + ($cols | join(""))
                else empty
                end
            end
        ' "$_tmp_flat" > "$_tmp_params_output"

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            _md_add "$line"
        done < "$_tmp_params_output"
        rm -f "$_tmp_params_output"
    fi

    # Write markdown file
    output_path="${output_path%/}"
    mkdir -p "$output_path"
    printf '%s' "$md_lines" > "${output_path}/${file_name_stem}.md"
    epac_write_status "Wrote ${output_path}/${file_name_stem}.md" "success" 2

    # ── CSV Generation ──
    _epac_generate_policy_set_csv "$output_path" "$file_name_stem" \
        "$_tmp_flat" "$_tmp_items" "$env_columns_csv" "$include_manual"

    # ── Compliance CSV ──
    _epac_generate_compliance_csv "$output_path" "$file_name_stem" \
        "$_tmp_flat" "$_tmp_items" "$include_manual"

    # ── JSONC Parameters ──
    _epac_generate_parameters_jsonc "$output_path" "$file_name_stem" \
        "$_tmp_flat" "$_tmp_items"

    # ── ADO Wiki push ──
    if [[ -n "$wiki_clone_pat" || "$wiki_spn" == "true" ]]; then
        _epac_push_to_ado_wiki "$doc_spec" "$output_path" "$file_name_stem" \
            "$wiki_clone_pat" "$wiki_spn"
    fi

    rm -f "$_tmp_flat" "$_tmp_items" "$_tmp_ps_details"
    epac_write_status "Complete" "success" 2
}

# ─── CSV for policy sets — single jq pass ─────────────────────────────────
_epac_generate_policy_set_csv() {
    local output_path="$1"
    local file_name_stem="$2"
    local flat_file="$3"      # temp file path
    local items_file="$4"     # temp file path
    local env_columns_csv="$5"
    local include_manual="$6"

    local csv_file="${output_path}/${file_name_stem}.csv"

    local _tmp_env_cols
    _tmp_env_cols="$(mktemp)"
    echo "$env_columns_csv" > "$_tmp_env_cols"

    jq -r --argjson include_manual "$( [[ "$include_manual" == "true" ]] && echo "true" || echo "false")" \
           --slurpfile items "$items_file" \
           --slurpfile env_cols "$_tmp_env_cols" '
        $items[0] as $il |
        $env_cols[0] as $envs |
        [$il[].shortName] as $short_names |

        # Effect order for sorting
        ["Modify","Append","DenyAction","Deny","Audit","Manual","DeployIfNotExists","AuditIfNotExists","Disabled"] as $effect_order |

        # Header
        ($envs | map(. + "Effect") | join(",")) as $effect_headers |
        ($envs | map(. + "Parameters") | join(",")) as $param_headers |
        ("\"name\",\"referencePath\",\"policyType\",\"category\",\"displayName\",\"description\",\"groupNames\",\"policySets\",\"allowedEffects\"" +
         (if ($envs | length) > 0 then "," + $effect_headers + "," + $param_headers else "" end)),

        # Rows sorted by category, displayName
        ([to_entries[]]
         | sort_by(.value.category, .value.displayName)
         | .[].value) as $e |
        (if $e.effectValue != null and $e.effectValue != "" then $e.effectValue else $e.effectDefault end) as $ev |
        if ($ev == "Manual" and $include_manual == false) then empty
        else
            # Build allowed effects string
            (($e.effectAllowedValues | if type == "object" then keys else . end) as $eav |
             ($e.effectAllowedOverrides // []) as $eao |
             (if $e.isEffectParameterized == true and ($eav | length) > 1 then
                {prefix: "parameter", list: $eav}
              elif ($eao | length) > 1 then
                {prefix: "override", list: $eao}
              elif ($e.effectDefault // "") != "" then
                {prefix: "default", list: [$e.effectDefault]}
              else
                {prefix: "none", list: []}
              end) as $ae |
             ([$effect_order[] as $candidate | $ae.list[] as $eff |
               select(($eff | ascii_downcase) == ($candidate | ascii_downcase)) | $candidate] | unique) as $sorted |
             $ae.prefix + ": " + ($sorted | join(","))
            ) as $allowed_str |

            # Build policySets string from policySetEffectStrings
            ($e.policySetEffectStrings // [] | join(",")) as $ps_str |

            # Build group names string
            (($e.groupNamesList // $e.groupNames // []) |
             if type == "object" then keys
             elif type == "array" then .
             else [] end |
             sort | unique | join(",")) as $gn_str |

            # Per-env effect columns
            ($envs | map(
                (($e.effectDefault // "") | ascii_downcase) as $lev |
                (if $lev == "modify" then "Modify"
                 elif $lev == "append" then "Append"
                 elif $lev == "denyaction" then "DenyAction"
                 elif $lev == "deny" then "Deny"
                 elif $lev == "audit" then "Audit"
                 elif $lev == "manual" then "Manual"
                 elif $lev == "deployifnotexists" then "DeployIfNotExists"
                 elif $lev == "auditifnotexists" then "AuditIfNotExists"
                 elif $lev == "disabled" then "Disabled"
                 else "" end) as $mapped |
                "\"" + $mapped + "\""
            ) | join(",")) as $effect_cols |

            # Per-env param columns (use parameters from flat entry)
            ($envs | map(
                ($e.parameters // {}) |
                to_entries | map(select(.value.isEffect != true)) |
                if length > 0 then
                    map({key: .key, value: (.value.value // .value.defaultValue // null)}) |
                    from_entries | tojson | gsub("\""; "\"\"") | "\"" + . + "\""
                else "\"\""
                end
            ) | join(",")) as $param_cols |

            # CSV-escape base fields
            [$e.name, ($e.referencePath // ""), ($e.policyType // ""), ($e.category // ""),
             ($e.displayName // ""), ($e.description // ""), $gn_str, $ps_str, $allowed_str] |
            map(tostring | if test("[,\"\n]") then "\"" + gsub("\""; "\"\"") + "\"" else . end) |
            join(",") |
            . + (if ($envs | length) > 0 then "," + $effect_cols + "," + $param_cols else "" end)
        end
    ' "$flat_file" > "$csv_file"

    rm -f "$_tmp_env_cols"
    epac_write_status "Wrote ${csv_file}" "success" 2
}

# ─── Compliance CSV — single jq pass via temp file ───────────────────────
_epac_generate_compliance_csv() {
    local output_path="$1"
    local file_name_stem="$2"
    local flat_file="$3"      # temp file path
    local items_file="$4"     # temp file path
    local include_manual="$5"

    local csv_file="${output_path}/${file_name_stem}-compliance.csv"
    local _tmp_jq
    _tmp_jq="$(mktemp)"

    cat > "$_tmp_jq" << 'JQEOF'
[to_entries[] |
 .value as $e |
 (if $e.effectValue != null and $e.effectValue != "" then $e.effectValue else $e.effectDefault end) as $ev |
 select($ev != "Manual" or $include_manual) |
 (($e.groupNamesList // $e.groupNames // []) |
  if type == "object" then keys
  elif type == "array" then .
  else [] end) as $gn_list |
 $gn_list[] as $gn |

 # Build allowed effects string
 (($e.effectAllowedValues | if type == "object" then keys else . end) as $eav |
  ($e.effectAllowedOverrides // []) as $eao |
  (if $e.isEffectParameterized == true and ($eav | length) > 1 then
     "param:" + ($eav | join("|"))
   elif ($eao | length) > 1 then
     "overr:" + ($eao | join("|"))
   else
     ($e.effectDefault // "")
   end)) as $allowed |

 {
   groupName: $gn,
   category: ($e.category // ""),
   displayName: ($e.displayName // ""),
   allowed: $allowed,
   effectDefault: ($e.effectDefault // ""),
   name: ($e.name // "")
 }
] |
sort_by(.groupName, .category, .displayName) |
(["groupName","category","policyDisplayName","allowedEffects","defaultEffect","policyId"] |
 map("\"" + . + "\"") | join(",")),
(.[] |
 [.groupName, .category, .displayName, .allowed, .effectDefault, .name] |
 map(tostring | if test("[,\"\n]") then "\"" + gsub("\""; "\"\"") + "\"" else . end) |
 join(","))
JQEOF

    jq -r --argjson include_manual "$( [[ "$include_manual" == "true" ]] && echo "true" || echo "false")" \
        -f "$_tmp_jq" "$flat_file" > "$csv_file"

    rm -f "$_tmp_jq"
    epac_write_status "Wrote ${csv_file}" "success" 2
}

# ─── JSONC Parameters file — single jq pass ──────────────────────────────
_epac_generate_parameters_jsonc() {
    local output_path="$1"
    local file_name_stem="$2"
    local flat_file="$3"      # temp file path
    local items_file="$4"     # temp file path

    local jsonc_file="${output_path}/${file_name_stem}.jsonc"

    jq -r --slurpfile items "$items_file" '
        $items[0] as $il |
        [$il[].shortName] as $short_names |

        # Collect entries that have parameterized effects
        [to_entries[]
         | select(.value.isEffectParameterized == true)
         | .value] |
        sort_by(.category, .displayName) |

        # Build JSONC output
        "{",
        "  \"parameters\": {",
        (. as $entries |
         [$entries[] |
          .category as $cat |
          .displayName as $dn |
          (.referencePath // "") as $rp |
          .policySetList as $psl |

          "    // ",
          "    // -----------------------------------------------------------------------------------------------------------------------------",
          "    // " + $cat + " -- " + $dn,
          (if $rp != "" then "    //     referencePath: " + $rp else empty end),

          # Per policy-set comments
          ($short_names[] |
           . as $sn |
           ($psl[$sn] // null) |
           if . != null then
             if .isEffectParameterized == true then
               "    //   " + (.displayName // $sn) + ": " + (.effectDefault // "") + " (" + (.effectParameterName // "") + ")"
             else
               "    //   " + (.displayName // $sn) + ": " + (.effectDefault // "") + " (" + (.effectReason // "") + ")"
             end
           else empty
           end),

          "    // -----------------------------------------------------------------------------------------------------------------------------",

          # Parameter JSON lines
          (.parameters // {} | to_entries | map(select(.value.isEffect != true)) |
           if length > 0 then
             .[] |
             .key as $pname |
             .value as $pval |
             ($pval.value // $pval.defaultValue // null) as $v |
             (if $v == null then "null"
              elif $v | type == "string" then "\"" + $v + "\""
              else ($v | tojson)
              end) as $val_str |
             "    \"" + $pname + "\": " + $val_str + ","
           else empty
           end)
         ] | .[]),
        "  }",
        "}"
    ' "$flat_file" > "$jsonc_file"

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
