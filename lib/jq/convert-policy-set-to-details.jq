# Converts all policy set definitions to detail objects in a single pass.
# Input: { policySetId: policySetDefinition, ... }
# Slurpfile $pd: policy_details from convert-policy-to-details.jq
# Output: { policySetId: policySetDetail, ... }

def get_param_name:
  if type == "string" and test("\\[parameters\\(['\"]") then
    capture("\\[parameters\\(['\"](?<n>[^'\"]+)['\"]\\)\\]") | .n
  else "" end;

def unwrap: if has("properties") then .properties else . end;

$pd[0] as $policy_details |

to_entries | map(
  .key as $psid | .value as $psdef |
  ($psdef | unwrap) as $p |
  ($p.metadata.category // "Unknown") as $cat |
  ($p.parameters // {}) as $ps_params |
  ($p.policyDefinitions // []) as $members |

  # Process each member policy, tracking parameters_already_covered
  (reduce range($members | length) as $i ({list: [], covered: {}};
    . as $state |
    $members[$i] as $pis |
    ($pis.policyDefinitionId) as $pid |

    if ($policy_details | has($pid)) | not then $state
    else
      $policy_details[$pid] as $pdtl |
      ($pis.parameters // {}) as $pips |

      # Effect analysis
      ($pdtl.effectParameterName // "") as $epn |
      (if ($pdtl.effectReason // "") != "Policy Fixed" and $epn != "" then
        # Check if effect parameter exists in pips (case-insensitive)
        ($pips | to_entries |
          map(select(.key | ascii_downcase == ($epn | ascii_downcase))) |
          .[0] // null) as $pmatch |
        if $pmatch then
          (($pmatch.value.value // "") | tostring) as $raw |
          ($raw | get_param_name) as $surfaced |
          if $surfaced != "" then
            # Effect surfaced to policy set parameter
            ($ps_params[$surfaced] // null) as $psep |
            if $psep then
              {
                ps_epn: $surfaced,
                ev: (if $psep | has("defaultValue") then ($psep.defaultValue | tostring) else ($pdtl.effectValue // "") end),
                ed: (if $psep | has("defaultValue") then ($psep.defaultValue | tostring) else ($pdtl.effectDefault // "") end),
                eav: ($psep.allowedValues // ($pdtl.effectAllowedValues // [])),
                eao: ($pdtl.effectAllowedOverrides // []),
                er: (if $psep | has("defaultValue") then "PolicySet Default" else "PolicySet No Default" end)
              }
            else
              {ps_epn: $surfaced, ev: ($pdtl.effectValue // ""), ed: ($pdtl.effectDefault // ""),
               eav: ($pdtl.effectAllowedValues // []), eao: ($pdtl.effectAllowedOverrides // []),
               er: ($pdtl.effectReason // "")}
            end
          else
            # Effect hard-coded at policy set level
            {ps_epn: "", ev: $raw, ed: $raw,
             eav: ($pdtl.effectAllowedValues // []), eao: ($pdtl.effectAllowedOverrides // []),
             er: "PolicySet Fixed"}
          end
        else
          {ps_epn: "", ev: ($pdtl.effectValue // ""), ed: ($pdtl.effectDefault // ""),
           eav: ($pdtl.effectAllowedValues // []), eao: ($pdtl.effectAllowedOverrides // []),
           er: ($pdtl.effectReason // "")}
        end
      else
        {ps_epn: "", ev: ($pdtl.effectValue // ""), ed: ($pdtl.effectDefault // ""),
         eav: ($pdtl.effectAllowedValues // []), eao: ($pdtl.effectAllowedOverrides // []),
         er: ($pdtl.effectReason // "")}
      end) as $ei |

      # Process surfaced parameters
      ($pips | to_entries | reduce .[] as $pe ({sp: {}, cov: $state.covered};
        if ($pe.value.value // null | type) != "string" then .
        else
          ($pe.value.value) as $raw |
          if ($raw | test("\\[parameters\\(")) then
            ($raw | get_param_name) as $sn |
            if $sn != "" then
              ($ps_params[$sn] // null) as $spdef |
              (.cov | has($sn)) as $multi |
              if (.sp | has($sn)) | not then
                .sp[$sn] = {
                  multiUse: $multi,
                  isEffect: ($sn == $ei.ps_epn),
                  value: ($spdef.defaultValue // null),
                  defaultValue: ($spdef.defaultValue // null),
                  definition: $spdef
                } | .cov[$sn] = true
              else .cov[$sn] = true end
            else . end
          else . end
        end
      )) as $surf |

      $state |
      .covered = $surf.cov |
      .list += [{
        id: $pid,
        name: $pdtl.name,
        displayName: $pdtl.displayName,
        description: $pdtl.description,
        policyType: $pdtl.policyType,
        category: $pdtl.category,
        effectParameterName: $ei.ps_epn,
        effectValue: $ei.ev,
        effectDefault: $ei.ed,
        effectAllowedValues: $ei.eav,
        effectAllowedOverrides: $ei.eao,
        effectReason: $ei.er,
        parameters: $surf.sp,
        policyDefinitionReferenceId: ($pis.policyDefinitionReferenceId // ""),
        groupNames: ($pis.groupNames // [])
      }]
    end
  )) as $result |

  # Find policies with multiple reference IDs
  ($result.list | group_by(.id) |
    map(select(length > 1) | {key: .[0].id, value: [.[].policyDefinitionReferenceId]}) |
    from_entries) as $multi_refs |

  (if ($p.displayName // "") == "" then ($psdef.name // "") else $p.displayName end) as $dn |

  {key: $psid, value: {
    id: $psid, name: ($psdef.name // ""),
    displayName: $dn, description: ($p.description // ""),
    policyType: ($p.policyType // ""), category: $cat,
    parameters: $ps_params,
    policyDefinitions: $result.list,
    policiesWithMultipleReferenceIds: $multi_refs
  }}
) | from_entries
