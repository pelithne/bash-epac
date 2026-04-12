# Converts all policy definitions to policy detail objects in a single pass.
# Input: { policyId: policyDefinition, ... }
# Output: { policyId: policyDetail, ... }

def get_param_name:
  if type == "string" and test("\\[parameters\\(['\"]") then
    capture("\\[parameters\\(['\"](?<n>[^'\"]+)['\"]\\)\\]") | .n
  else "" end;

def unwrap: if has("properties") then .properties else . end;

to_entries | map(
  .key as $id | .value as $pdef |
  ($pdef | unwrap) as $p |
  ($p.metadata.category // "Unknown") as $cat |
  ($p.policyRule.then.effect // "") as $eraw |
  ($p.parameters // {}) as $params |
  ($eraw | get_param_name) as $epn |

  # Determine effect details
  (if $epn != "" then
    # Parameterized effect - case-insensitive parameter lookup
    ($params | to_entries |
      map(select(.key | ascii_downcase == ($epn | ascii_downcase))) |
      .[0] // null) as $match |
    if $match then
      $match.value as $ep |
      {
        epn: $epn,
        ev: (if $ep | has("defaultValue") then ($ep.defaultValue | tostring) else "null" end),
        ed: (if $ep | has("defaultValue") then ($ep.defaultValue | tostring) else "null" end),
        eav: ($ep.allowedValues // []),
        eao: ($ep.allowedValues // []),
        er: (if $ep | has("defaultValue") then "Policy Default" else "Policy No Default" end)
      }
    else
      {epn: $epn, ev: "null", ed: "null", eav: [], eao: [], er: "Policy No Default"}
    end
  else
    {epn: "", ev: $eraw, ed: $eraw,
     eav: (if $eraw != "" then [$eraw] else [] end),
     eao: [], er: "Policy Fixed"}
  end) as $eff |

  # Determine allowed overrides from policy anatomy
  ($eff | if (.eao | length) > 0 then .
  else
    (($p.policyRule.then // {}) | .details) as $d |
    if $d == null then
      if .er == "Policy Fixed" then
        if (.ev | ascii_downcase) == "deny" or (.ev | ascii_downcase) == "audit"
        then .eao = ["Disabled","Audit","Deny"]
        else .eao = ["Disabled","Audit"] end
      else .eao = ["Disabled","Audit","Deny"] end
    elif ($d | type) == "array" then .eao = ["Disabled","Audit","Deny","Append"]
    elif ($d | has("actionNames")) then .eao = ["Disabled","DenyAction"]
    elif ($d | has("defaultState")) then .eao = ["Disabled","Manual"]
    elif ($d | has("existenceCondition")) and ($d | has("deployment"))
    then .eao = ["Disabled","AuditIfNotExists","DeployIfNotExists"]
    elif ($d | has("existenceCondition")) then .eao = ["Disabled","AuditIfNotExists"]
    elif ($d | has("operations")) then .eao = ["Disabled","Audit","Modify"]
    else
      if .er == "Policy Fixed" then
        if (.ev | ascii_downcase) == "deny" or (.ev | ascii_downcase) == "audit"
        then .eao = ["Disabled","Audit","Deny"]
        else .eao = ["Disabled","Audit"] end
      else .eao = ["Disabled","Audit","Deny"] end
    end
  end) as $eff2 |

  # Metadata
  (if ($p.displayName // "") == "" then ($pdef.name // "") else $p.displayName end) as $dn |
  ($p.description // "") as $desc |
  ($p.metadata.version // "0.0.0") as $ver |
  (($ver | ascii_downcase) | test("deprecated")) as $is_dep |
  ($pdef.name // "") as $name |
  ($p.policyType // "") as $pt |

  # Parameter definitions
  ($params | with_entries(.value = {
    isEffect: (.key == $eff2.epn),
    value: null,
    defaultValue: (.value.defaultValue // null),
    definition: .value
  })) as $pdefs |

  {key: $id, value: {
    id: $id, name: $name, displayName: $dn, description: $desc,
    policyType: $pt, category: $cat, version: $ver, isDeprecated: $is_dep,
    effectParameterName: $eff2.epn, effectValue: $eff2.ev, effectDefault: $eff2.ed,
    effectAllowedValues: $eff2.eav, effectAllowedOverrides: $eff2.eao,
    effectReason: $eff2.er, parameters: $pdefs
  }}
) | from_entries
