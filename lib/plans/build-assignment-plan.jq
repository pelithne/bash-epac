#!/usr/bin/env jq -f
# lib/plans/build-assignment-plan.jq
# Monolithic jq script for assignment plan building.
# Replaces ~3000 bash+jq subprocess forks with a single jq invocation.
#
# Inputs (via --slurpfile):
#   $af   — assignment files: [ [content1, content2, ...] ]
#   $pp   — policy params: [ { policies: {id: {parameters}}, policySets: {...} } ]
#   $pdi  — policy def index: [ { id: null, ... } ]
#   $psdi — policy set def index: [ { id: null, ... } ]
#   $pri  — policy role IDs: [ { policyId: [roleDefIds], ... } ]
#   $stl  — scope table lower: [ { scope: {scope, notScopesList}, ... } ]
#   $da   — deployed assignments: [ { managed: {...}, readOnly: {...} } ]
#
# Inputs (via --argjson):
#   $pacEnv       — pac environment config
#   $replaceDefs  — replaced definitions: { id: def, ... }
#   $roleDefs     — role definitions: { roleDefId: displayName, ... }
#   $deployedRoles — deployed role assignments by principal: { principalId: [...] }
#
# Output: JSON with assignments plan, roleAssignments, diagnostics

# ─── Helpers ─────────────────────────────────────────────────────────────────

# Resolve pac-selector-qualified value
def pac_value($sel):
  if . == null then null
  elif type != "object" then .
  elif has($sel) then .[$sel]
  elif has("*") then .["*"]
  else null
  end;

# Resolve pac-selector-qualified array
def pac_array($sel):
  if . == null then []
  elif type == "array" then .
  elif type == "object" then
    (if has($sel) then .[$sel]
     elif has("*") then .["*"]
     else null end) as $v |
    if $v == null then []
    elif ($v | type) == "array" then $v
    else [$v]
    end
  else [.]
  end;

# Normalize for deep equality comparison (sort object keys recursively)
def normalize:
  if type == "object" then to_entries | sort_by(.key) | map(.value |= normalize) | from_entries
  elif type == "array" then map(normalize)
  else .
  end;

# Check valid policy resource name
def valid_name:
  test("^[a-zA-Z0-9_. ()-]+$");

# ─── Resolve Definition Entry ───────────────────────────────────────────────

def resolve_entry($pdi; $psdi; $pds; $node_name):
  (.policyName // "") as $pn |
  (.policyId // "") as $pid |
  ((.policySetName // .initiativeName) // "") as $psn |
  ((.policySetId // .initiativeId) // "") as $psid |
  (.displayName // "") as $dn |
  (.append // false) as $append |

  ([if $pn != "" then 1 else empty end,
    if $pid != "" then 1 else empty end,
    if $psn != "" then 1 else empty end,
    if $psid != "" then 1 else empty end] | length) as $count |

  if $count != 1 then
    {valid: false, error: "Node \($node_name): exactly one of policyName, policyId, policySetName, policySetId required (found \($count))"}
  elif $pn != "" then
    (reduce $pds[] as $scope (null;
      if . != null then .
      else ($scope + "/providers/Microsoft.Authorization/policyDefinitions/" + $pn) as $fid |
           if $pdi | has($fid) then $fid else null end
      end
    )) as $rid |
    if $rid != null then
      {valid: true, id: $rid, isPolicySet: false, displayName: $dn, append: $append,
       policyName: $pn, policyId: "", policySetName: "", policySetId: ""}
    else {valid: false, error: "Node \($node_name): Policy name '\($pn)' not found"} end
  elif $pid != "" then
    if $pdi | has($pid) then
      {valid: true, id: $pid, isPolicySet: false, displayName: $dn, append: $append,
       policyName: "", policyId: $pid, policySetName: "", policySetId: ""}
    else {valid: false, error: "Node \($node_name): Policy '\($pid)' not found"} end
  elif $psn != "" then
    (reduce $pds[] as $scope (null;
      if . != null then .
      else ($scope + "/providers/Microsoft.Authorization/policySetDefinitions/" + $psn) as $fid |
           if $psdi | has($fid) then $fid else null end
      end
    )) as $rid |
    if $rid != null then
      {valid: true, id: $rid, isPolicySet: true, displayName: $dn, append: $append,
       policyName: "", policyId: "", policySetName: $psn, policySetId: ""}
    else {valid: false, error: "Node \($node_name): PolicySet name '\($psn)' not found"} end
  elif $psid != "" then
    if $psdi | has($psid) then
      {valid: true, id: $psid, isPolicySet: true, displayName: $dn, append: $append,
       policyName: "", policyId: "", policySetName: "", policySetId: $psid}
    else {valid: false, error: "Node \($node_name): PolicySet '\($psid)' not found"} end
  else
    {valid: false, error: "Node \($node_name): no policy identifier found"}
  end;

# ─── Build Parameter Object ─────────────────────────────────────────────────
# Filter assignment params to only those defined in the policy, skip defaults

def build_param_object($ap; $dp):
  if $dp == null or $dp == {} or $ap == null or $ap == {} then {}
  else
    reduce ($dp | keys[]) as $pname (
      {};
      if ($ap | has($pname)) then
        ($ap[$pname]) as $val |
        ($dp[$pname].defaultValue // null) as $dv |
        if $dv == null then .[$pname] = $val
        elif $dv == $val then .
        else .[$pname] = $val
        end
      else . end
    )
  end;

# ─── Confirm PAC owner ──────────────────────────────────────────────────────

def confirm_pac_owner($pacOwnerId):
  (if .properties then .properties else . end) as $p |
  ($p.metadata.pacOwnerId // null) as $ap |
  if $ap == $pacOwnerId then "ownedByThisPac"
  elif $ap != null then "ownedByOtherPac"
  else "unknownOwner"
  end;

# ─── Confirm delete for strategy ────────────────────────────────────────────

def confirm_delete($class; $strategy):
  if $strategy == "full" then
    ($class == "ownedByThisPac" or $class == "unknownOwner")
  elif $strategy == "ownedOnly" then
    $class == "ownedByThisPac"
  else false end;

# ─── Compare Parameters ─────────────────────────────────────────────────────
# Case-insensitive key matching, handle .value wrapping

def params_match($existing; $defined):
  (if $existing == null then {} else $existing end) as $e |
  (if $defined == null then {} else $defined end) as $d |
  ($e | keys | length) as $eCount |
  ($d | keys | length) as $dCount |
  if $eCount != $dCount then false
  elif $eCount == 0 then true
  else
    ([($e | keys[]), ($d | keys[])] | map(ascii_downcase) | unique | length) as $uCount |
    if $uCount != $eCount then false
    else
      reduce ($e | keys[]) as $k (true;
        if . == false then false
        else
          ($e[$k] | if type == "object" and has("value") then .value else . end) as $ev |
          ([$d | to_entries[] | select(.key | ascii_downcase == ($k | ascii_downcase))] | first // null) as $dEntry |
          if $dEntry == null then false
          else
            ($dEntry.value | if type == "object" and has("value") then .value else . end) as $dv |
            ($ev | normalize) == ($dv | normalize)
          end
        end
      )
    end
  end;

# ─── Compare Metadata ───────────────────────────────────────────────────────

def metadata_match($existing; $defined):
  if $existing == null then {match: false, changePacOwnerId: true}
  else
    (["createdBy","createdOn","updatedBy","updatedOn","lastSyncedToArgOn"]) as $sys |
    ($existing | reduce $sys[] as $p (.; del(.[$p]))) as $eClean |
    ($eClean.pacOwnerId // "") as $ePac |
    ($defined.pacOwnerId // "") as $dPac |
    ($ePac != $dPac) as $pacChanged |
    ($eClean | del(.pacOwnerId) | normalize) as $em |
    ($defined | del(.pacOwnerId) | normalize) as $dm |
    {match: ($em == $dm), changePacOwnerId: $pacChanged}
  end;

# ─── Build Identity Changes ─────────────────────────────────────────────────

def _mkRoleEntry($d):
  {
    assignmentId: $d.id,
    assignmentDisplayName: ($d.displayName // ""),
    roleDisplayName: (.roleDisplayName // "Unknown"),
    scope: .scope,
    properties: {
      roleDefinitionId: .roleDefinitionId,
      principalId: null,
      principalType: "ServicePrincipal",
      description: (.description // ""),
      crossTenant: (.crossTenant // false)
    }
  };

def build_identity_changes($existing; $desired; $replaced; $deployedRoles):
  # Extract existing identity
  (if $existing != null and $existing != "null" then
    ($existing.identity // null) as $ei |
    (if $ei != null then ($ei.type // "None") else "None" end) as $et |
    if $ei != null and $et != "None" then
      {
        has: true, type: $et,
        location: ($existing.location // "global"),
        pid: (if $et == "UserAssigned" then
          ($ei.userAssignedIdentities | keys[0] // null) as $k |
          if $k then ($ei.userAssignedIdentities[$k].principalId // null) else null end
        else ($ei.principalId // null) end),
        uai: (if $et == "UserAssigned" then ($ei.userAssignedIdentities | keys[0] // null) else null end)
      }
    else {has: false, type: "None", location: "global", pid: null, uai: null}
    end
  else {has: false, type: "None", location: "global", pid: null, uai: null}
  end) as $ex |

  # Extract desired identity
  (if $desired != null and $desired != "null" then
    if ($desired.identityRequired // false) then
      ($desired.identity // null) as $di |
      {
        req: true,
        type: (if $di then ($di.type // "SystemAssigned") else "SystemAssigned" end),
        location: ($desired.managedIdentityLocation // "global"),
        uai: (if $di and ($di.type // "") == "UserAssigned" then
          ($di.userAssignedIdentities | keys[0] // null) else null end)
      }
    else {req: false, type: "None", location: "global", uai: null}
    end
  else {req: false, type: "None", location: "global", uai: null}
  end) as $des |

  (if $ex.has and $ex.pid != null then $deployedRoles[$ex.pid] // [] else [] end) as $existRoles |
  (if $desired != null and $desired != "null" then $desired.requiredRoleAssignments // [] else [] end) as $reqRoles |

  {replaced: $replaced, strings: [], added: [], updated: [], removed: []} |

  if ($ex.has or $des.req) then
    if ($existing != null and $existing != "null" and $desired != null and $desired != "null") then
      # Update scenario
      if ($ex.has != $des.req) then
        (if $ex.has then .strings += ["removedIdentity"] else .strings += ["addedIdentity"] end) |
        .replaced = true
      else
        (if $ex.location != $des.location then
          .strings += ["identityLocation \($ex.location)->\($des.location)"] | .replaced = true
        else . end) |
        (if $ex.type != $des.type then
          .strings += ["identityType \($ex.type)->\($des.type)"] | .replaced = true
        elif ($ex.type == "UserAssigned" and $ex.uai != $des.uai) then
          .strings += ["changed userAssignedIdentity"] | .replaced = true
        else . end)
      end |

      if .replaced then
        (if $ex.has and $ex.type != "UserAssigned" and ($existRoles | length) > 0 then
          .removed = $existRoles else . end) |
        (if $des.req and $des.type != "UserAssigned" then
          .added = [$reqRoles[] | _mkRoleEntry($desired)] else . end)
      else
        if $ex.type != "UserAssigned" then
          reduce ($reqRoles[]) as $rr (.;
            ([$existRoles[] | select(((.properties.scope // .scope) | ascii_downcase) == ($rr.scope | ascii_downcase) and ((.properties.roleDefinitionId // .roleDefinitionId) | ascii_downcase) == ($rr.roleDefinitionId | ascii_downcase))] | first // null) as $m |
            ($rr | _mkRoleEntry($desired)) as $entry |
            if $m != null then
              if ($m.description // $m.properties.description // "") != ($rr.description // "") then
                .updated += [$entry | .id = $m.id | .properties.principalId = ($m.principalId // $m.properties.principalId)]
              else . end
            else .added += [$entry] end
          ) |
          reduce ($existRoles[]) as $er (.;
            ([$reqRoles[] | select(($er.properties.scope // $er.scope | ascii_downcase) == (.scope | ascii_downcase) and (($er.properties.roleDefinitionId // $er.roleDefinitionId) | ascii_downcase) == (.roleDefinitionId | ascii_downcase))] | length > 0) as $needed |
            if $needed | not then .removed += [$er] else . end
          )
        else . end
      end
    else
      # New or delete scenario
      (if $ex.has and $ex.type != "UserAssigned" and ($existRoles | length) > 0 then
        .removed = $existRoles else . end) |
      (if $des.req and $des.type != "UserAssigned" then
        .added = [$reqRoles[] | _mkRoleEntry($desired)] else . end)
    end
  else . end |

  if (.added | length) > 0 then .strings += ["addedRoleAssignments"] else . end |
  if (.updated | length) > 0 then .strings += ["updatedRoleAssignments"] else . end |
  if (.removed | length) > 0 then .strings += ["removedRoleAssignments"] else . end;

# ─── Build Leaf ──────────────────────────────────────────────────────────────
# Build final assignment objects at leaf node for each scope.

def build_leaf($adef; $pp; $pri; $roleDefs; $pacOwnerId; $deployedBy):
  ($adef.nodeName // "") as $nodeName |
  ($adef.definitionEntryList // []) as $entries |
  ($adef.scopeCollection // {}) as $scopeCol |
  ($entries | length) as $entryCount |
  ($scopeCol | length) as $scopeCount |

  if $entryCount == 0 then
    {hasErrors: true, assignments: [], diagnostics: [{level: "error", message: "Node \($nodeName): no definitionEntryList"}]}
  elif $scopeCount == 0 then
    {hasErrors: false, assignments: [], diagnostics: []}
  else
    ($entryCount > 1) as $isMulti |
    reduce (range($entryCount)) as $ei (
      {hasErrors: false, assignments: [], diagnostics: []};

      $entries[$ei] as $entry |
      $entry.id as $entryId |
      $entry.isPolicySet as $isPolicySet |
      ($entry.displayName // "") as $entryDn |
      ($entry.append // false) as $appendEntry |

      # Build assignment name
      ($adef.assignment.name // "") as $baseName |
      ($adef.assignment.displayName // "") as $baseDn |
      ($adef.assignment.description // "") as $baseDesc |

      (if $isMulti then
        ($entry |
          (if .policySetName != "" then .policySetName
           elif .policySetId != "" then (.policySetId | split("/") | last)
           elif .policyName != "" then .policyName
           elif .policyId != "" then (.policyId | split("/") | last)
           else "" end)) as $shortName |
        if $appendEntry then
          {name: ($baseName + $shortName), displayName: (if $entryDn != "" then $baseDn + " - " + $entryDn else $baseDn end), description: $baseDesc}
        else
          {name: ($shortName + $baseName), displayName: (if $entryDn != "" then $entryDn + " - " + $baseDn else $baseDn end), description: $baseDesc}
        end
      else
        {name: $baseName, displayName: $baseDn, description: $baseDesc}
      end) as $names |

      $names.name as $aName |

      if $aName == "" then
        .hasErrors = true | .diagnostics += [{level: "error", message: "Node \($nodeName): empty assignment name"}]
      elif ($aName | valid_name | not) then
        .hasErrors = true | .diagnostics += [{level: "error", message: "Node \($nodeName): invalid name '\($aName)'"}]
      else
        # Metadata
        (($adef.metadata // {}) | .pacOwnerId = $pacOwnerId |
         if $deployedBy != "" then .deployedBy = $deployedBy else . end) as $meta |
        (($pri[$entryId] // null) as $roles |
         if $roles != null then $meta | .roles = $roles else $meta end) as $meta |

        # Get definition parameters
        (if $isPolicySet then $pp.policySets[$entryId].parameters // {}
         else $pp.policies[$entryId].parameters // {} end
         | to_entries | map({key, value: {defaultValue: .value.defaultValue}}) | from_entries) as $defParams |

        # Filter params
        build_param_object(($adef.parameters // {}); $defParams) as $finalParams |

        ($adef.enforcementMode // "Default") as $em |
        ($adef.definitionVersion // null) as $defVer |

        # Identity
        (($pri[$entryId] // []) | length) as $roleCount |
        (($adef.additionalRoleAssignments // []) | length) as $addRoleCount |
        ($roleCount > 0 or $addRoleCount > 0) as $identReq |
        (if $identReq then
          ($adef.userAssignedIdentity // null) as $uai |
          if $uai != null and $uai != "" then
            {type: "UserAssigned", userAssignedIdentities: {($uai): {}}}
          else {type: "SystemAssigned"} end
        else null end) as $identObj |

        ($adef.managedIdentityLocation // "global") as $mil |

        # Base assignment
        {
          name: $aName,
          displayName: $names.displayName,
          description: $names.description,
          policyDefinitionId: $entryId,
          enforcementMode: $em,
          metadata: $meta,
          parameters: $finalParams,
          nonComplianceMessages: ($adef.nonComplianceMessages // []),
          overrides: ($adef.overrides // []),
          resourceSelectors: ($adef.resourceSelectors // []),
          identityRequired: $identReq,
          identity: $identObj,
          managedIdentityLocation: $mil,
          definitionVersion: $defVer
        } as $base |

        # Per scope
        reduce ($scopeCol | keys[]) as $sk (.;
          ($scopeCol[$sk]) as $se |
          ($se.scope // $sk) as $sv |
          ($sv + "/providers/Microsoft.Authorization/policyAssignments/" + $aName) as $aid |

          ($base | .id = $aid | .scope = $sv | .notScopes = ($se.notScopesList // [])) as $sa |

          # Required role assignments
          (if $identReq then
            (reduce range($roleCount) as $ri ([];
              ($pri[$entryId][$ri]) as $rdid |
              . + [{
                scope: $sv, roleDefinitionId: $rdid,
                roleDisplayName: ($roleDefs[$rdid] // "Unknown"),
                description: "Policy Assignment '\($aid)': Role required by Policy, deployed by: '\($deployedBy)'",
                crossTenant: false
              }]
            )) +
            [($adef.additionalRoleAssignments // [])[] |
              {
                scope: .scope, roleDefinitionId: .roleDefinitionId,
                roleDisplayName: ($roleDefs[.roleDefinitionId] // "Unknown"),
                description: "Policy Assignment '\($aid)': additional Role Assignment deployed by: '\($deployedBy)'",
                crossTenant: (.crossTenant // false)
              }
            ]
          else [] end) as $rr |

          ($sa | if ($rr | length) > 0 then .requiredRoleAssignments = $rr else . end) as $final |
          .assignments += [$final]
        )
      end
    )
  end;

# ─── Process Node (recursive tree builder) ───────────────────────────────────
# Accumulates definition state while walking down the tree.

def process_node($adef; $pdi; $psdi; $pp; $pri; $stl; $roleDefs; $pds; $sel; $pid; $dby):
  . as $node |

  # Accumulate nodeName
  ($node.nodeName // "") as $npart |
  (if $npart != "" then
    $adef | .nodeName = ((.nodeName // "") + "/" + $npart)
  else $adef end) as $adef |
  ($adef.nodeName // "") as $nodeName |

  # Enforcement mode
  (($node.enforcementMode // null) as $em |
   if $em != null then
     if ($em != "Default" and $em != "DoNotEnforce") then
       null  # signal error
     else $adef | .enforcementMode = $em end
   else $adef end) as $defOrErr |

  if $defOrErr == null then
    {hasErrors: true, assignments: [], diagnostics: [{level: "error", message: "Node \($nodeName): enforcementMode must be Default or DoNotEnforce"}]}
  else
  $defOrErr as $adef |

  # Assignment name/displayName/description
  (($node.assignment // null) as $an |
   if $an != null then
     $adef
     | if ($an.name // "") != "" then .assignment.name = ((.assignment.name // "") + $an.name) else . end
     | if ($an.displayName // "") != "" then .assignment.displayName = ((.assignment.displayName // "") + $an.displayName) else . end
     | if ($an.description // "") != "" then .assignment.description = ((.assignment.description // "") + $an.description) else . end
   else $adef end) as $adef |

  # Definition entry / list
  ($node.definitionEntry // null) as $defEntry |
  ($node.definitionEntryList // null) as $defEntryList |

  (if ($defEntry != null and $defEntryList != null) then
    {err: true, hasErrors: true, assignments: [], diagnostics: [{level: "error", message: "Node \($nodeName): cannot have both definitionEntry and definitionEntryList"}]}
  elif $defEntry != null then
    ($defEntry | resolve_entry($pdi; $psdi; $pds; $nodeName)) as $r |
    if $r.valid then {err: false, def: ($adef | .definitionEntryList = [$r])}
    else {err: true, hasErrors: true, assignments: [], diagnostics: [{level: "error", message: $r.error}]} end
  elif $defEntryList != null then
    reduce ($defEntryList[]) as $e (
      {err: false, list: []};
      if .err then .
      else
        ($e | resolve_entry($pdi; $psdi; $pds; $nodeName)) as $r |
        if $r.valid then .list += [$r]
        else {err: true, hasErrors: true, assignments: [], diagnostics: [{level: "error", message: $r.error}]} end
      end
    ) | if .err then . else {err: false, def: ($adef | .definitionEntryList = .list)} end
  else {err: false, def: $adef}
  end) as $step |

  if ($step.err // false) then {hasErrors: $step.hasErrors, assignments: ($step.assignments // []), diagnostics: ($step.diagnostics // [])}
  else
  ($step.def // $adef) as $adef |

  # Metadata (shallow merge)
  (if $node.metadata != null then $adef | .metadata = ((.metadata // {}) + $node.metadata)
   else $adef end) as $adef |

  # Parameters (union, deeper wins)
  (if $node.parameters != null then $adef | .parameters = ((.parameters // {}) + $node.parameters)
   else $adef end) as $adef |

  # Non-compliance messages (accumulate)
  (if $node.nonComplianceMessages != null then
    $adef | .nonComplianceMessages = ((.nonComplianceMessages // []) + $node.nonComplianceMessages)
   else $adef end) as $adef |

  # Overrides (accumulate)
  (if $node.overrides != null then
    $adef | .overrides = ((.overrides // []) + $node.overrides)
   else $adef end) as $adef |

  # Resource selectors (accumulate)
  (if $node.resourceSelectors != null then
    $adef | .resourceSelectors = ((.resourceSelectors // []) + $node.resourceSelectors)
   else $adef end) as $adef |

  # Definition version (deeper wins)
  (if ($node.definitionVersion // "") != "" then
    $adef | .definitionVersion = $node.definitionVersion
   else $adef end) as $adef |

  # Additional role assignments (pac-selector aware, accumulate)
  (if $node.additionalRoleAssignments != null then
    $adef | .additionalRoleAssignments = ((.additionalRoleAssignments // []) + ($node.additionalRoleAssignments | pac_array($sel)))
   else $adef end) as $adef |

  # Managed identity location (pac-selector-aware)
  (if $node.managedIdentityLocations != null then
    ($node.managedIdentityLocations | pac_value($sel)) as $v |
    if $v != null and $v != "null" then $adef | .managedIdentityLocation = (if ($v | type) == "string" then $v else ($v | tostring) end)
    else $adef end
   else $adef end) as $adef |

  # User assigned identity (pac-selector-aware)
  (if $node.userAssignedIdentity != null then
    ($node.userAssignedIdentity | pac_value($sel)) as $v |
    if $v != null and $v != "null" then $adef | .userAssignedIdentity = (if ($v | type) == "string" then $v else ($v | tostring) end)
    else $adef end
   else $adef end) as $adef |

  # Scope processing
  (if ($node.scope // null) != null then
    ($node.scope | pac_value($sel)) as $sv |
    if $sv != null then
      ([if ($sv | type) == "array" then $sv[] else $sv end | ascii_downcase] | unique) as $sids |
      (reduce $sids[] as $sid ({};
        ($stl[$sid] // null) as $entry |
        if $entry != null then .[$sid] = $entry else . end
      )) as $sc |
      $adef | .scopeCollection = $sc
    else $adef end
   else $adef end) as $adef |

  # Not-scopes
  (if ($node.notScope // null) != null then
    ($node.notScope | pac_array($sel)) as $nsList |
    if ($nsList | length) > 0 then
      reduce (($adef.scopeCollection // {}) | keys[]) as $sk ($adef;
        reduce $nsList[] as $ns (.;
          ($ns | ascii_downcase) as $nsL |
          if ($nsL | test("\\*")) then
            reduce ($stl | keys[] | select(test($nsL | gsub("\\*"; ".*")))) as $match (.;
              .scopeCollection[$sk].notScopesList = ((.scopeCollection[$sk].notScopesList // []) + [$match]) |
              .scopeCollection[$sk].notScopesList |= unique
            )
          elif ($nsL | startswith($sk)) then
            .scopeCollection[$sk].notScopesList = ((.scopeCollection[$sk].notScopesList // []) + [$nsL]) |
            .scopeCollection[$sk].notScopesList |= unique
          elif ($stl[$nsL] // null) != null then
            # notScope is a known scope in the hierarchy (e.g. child MG or subscription under MG)
            .scopeCollection[$sk].notScopesList = ((.scopeCollection[$sk].notScopesList // []) + [$nsL]) |
            .scopeCollection[$sk].notScopesList |= unique
          else . end
        )
      )
    else $adef end
   else $adef end) as $adef |

  # Process children or leaf
  if $node.children != null then
    reduce ($node.children[]) as $child (
      {hasErrors: false, assignments: [], diagnostics: []};
      ($child | process_node($adef; $pdi; $psdi; $pp; $pri; $stl; $roleDefs; $pds; $sel; $pid; $dby)) as $cr |
      .hasErrors = (.hasErrors or ($cr.hasErrors // false)) |
      .assignments += ($cr.assignments // []) |
      .diagnostics += ($cr.diagnostics // [])
    )
  else
    build_leaf($adef; $pp; $pri; $roleDefs; $pid; $dby)
  end

  end  # definition entry check
  end; # enforcement mode check

# ─── Main ────────────────────────────────────────────────────────────────────

($af[0]) as $assignFiles |
($pp[0]) as $policyParams |
($pdi[0]) as $policyDefIndex |
($psdi[0]) as $policySetDefIndex |
($pri[0]) as $policyRoleIds |
($stl[0]) as $scopeTableLower |
($da[0]) as $deployedAssignments |
($replaceDefs[0]) as $replaceDefs |
($deployedRoles[0]) as $deployedRoles |
($pacEnv[0]) as $pacEnv |
($roleDefs[0]) as $roleDefs |

($pacEnv.pacOwnerId) as $pacOwnerId |
($pacEnv.deployedBy // "") as $deployedBy |
($pacEnv.pacSelector // "*") as $pacSelector |
($pacEnv.desiredState.strategy // "full") as $strategy |
($pacEnv.desiredState.keepDfcSecurityAssignments // false) as $keepDfc |
($pacEnv.policyDefinitionsScopes // []) as $policyDefScopes |

# Root definition template
{
  nodeName: "",
  assignment: {name: "", displayName: "", description: ""},
  enforcementMode: "Default",
  metadata: {},
  parameters: {},
  nonComplianceMessages: [],
  overrides: [],
  resourceSelectors: [],
  additionalRoleAssignments: [],
  definitionEntryList: [],
  scopeCollection: {},
  managedIdentityLocation: "global",
  userAssignedIdentity: null,
  definitionVersion: null
} as $rootDef |

# Phase 1: Process all assignment files → build desired assignments
(reduce ($assignFiles[]) as $fileContent (
  {hasErrors: false, allDesired: [], diagnostics: []};

  (try ($fileContent | process_node($rootDef;
    $policyDefIndex; $policySetDefIndex; $policyParams; $policyRoleIds;
    $scopeTableLower; $roleDefs; $policyDefScopes;
    $pacSelector; $pacOwnerId; $deployedBy))
  catch {hasErrors: true, assignments: [], diagnostics: [{level: "error", message: .}]}) as $result |

  .hasErrors = (.hasErrors or ($result.hasErrors // false)) |
  .allDesired += ($result.assignments // []) |
  .diagnostics += ($result.diagnostics // [])
)) as $phase1 |

# Phase 2: Compare desired vs deployed
($deployedAssignments.managed // {}) as $managed |

(reduce ($phase1.allDesired[]) as $desired (
  {new: {}, update: {}, replace: {}, delete: {},
   unchanged: 0, ra_added: [], ra_updated: [], ra_removed: [],
   deleteKeys: ($managed | keys), diagnostics: []};

  $desired.id as $assignId |
  .deleteKeys -= [$assignId] |

  ($managed[$assignId] // ($deployedAssignments.readOnly[$assignId] // null)) as $deployed |

  if $deployed == null then
    ($desired.displayName // $desired.name) as $display |
    .new[$assignId] = $desired |
    .diagnostics += [{level: "new", message: "New: \($display)"}] |
    (build_identity_changes(null; $desired; false; $deployedRoles)) as $ic |
    .ra_added += $ic.added
  else
    ($deployed | if .properties then .properties else . end) as $dp |

    (($dp.displayName // "") == ($desired.displayName // "")) as $dnM |
    (($dp.description // "") == ($desired.description // "")) as $descM |
    (($dp.enforcementMode // "Default") == ($desired.enforcementMode // "Default")) as $emM |
    metadata_match($dp.metadata; $desired.metadata) as $metaR |
    params_match($dp.parameters; $desired.parameters) as $paramM |
    ((($dp.notScopes // []) | normalize) == (($desired.notScopes // []) | normalize)) as $nsM |
    (([($dp.nonComplianceMessages // [])[] | with_entries(select(.value != null))] | normalize) ==
     ([($desired.nonComplianceMessages // [])[] | with_entries(select(.value != null))] | normalize)) as $ncmM |
    ((($dp.overrides // []) | normalize) == (($desired.overrides // []) | normalize)) as $ovrM |
    ((($dp.resourceSelectors // []) | normalize) == (($desired.resourceSelectors // []) | normalize)) as $rselM |
    (($dp.definitionVersion // "") == ($desired.definitionVersion // "")) as $verM |
    ($dp.policyDefinitionId // "") as $depDid |
    ($desired.policyDefinitionId) as $desDid |
    ($replaceDefs | has($desDid)) as $defReplaced |

    build_identity_changes($deployed; $desired; $defReplaced; $deployedRoles) as $ic |

    .ra_added += $ic.added |
    .ra_updated += $ic.updated |
    .ra_removed += $ic.removed |

    ([
      if $dnM | not then "displayName" else empty end,
      if $descM | not then "description" else empty end,
      if $emM | not then "enforcementMode" else empty end,
      if ($metaR.match | not) or $metaR.changePacOwnerId then "metadata" else empty end,
      if $paramM | not then "parameters" else empty end,
      if $nsM | not then "notScopes" else empty end,
      if $ncmM | not then "nonComplianceMessages" else empty end,
      if $ovrM | not then "overrides" else empty end,
      if $rselM | not then "resourceSelectors" else empty end,
      if $verM | not then "version" else empty end,
      if $depDid != $desDid then "policyDefinitionId" else empty end,
      if $ic.replaced then "replace" else empty end,
      $ic.strings[]
    ]) as $changes |

    if ($changes | length) == 0 then
      .unchanged += 1
    else
      ($changes | join(",")) as $cs |
      ($desired.displayName // $desired.name) as $display |
      if $ic.replaced then
        .replace[$assignId] = $desired |
        .diagnostics += [{level: "replace", message: "Replace (\($cs)): \($display)"}]
      else
        .update[$assignId] = $desired |
        .diagnostics += [{level: "update", message: "Update (\($cs)): \($display)"}]
      end
    end
  end
)) as $phase2 |

# Phase 3: Process delete candidates
(reduce ($phase2.deleteKeys[]) as $delId ($phase2;
  ($managed[$delId]) as $da2 |
  ($da2 | confirm_pac_owner($pacOwnerId)) as $class |
  if confirm_delete($class; $strategy) then
    ($da2 | if .properties then .properties else . end) as $dp |
    ($dp.displayName // "") as $dd |
    .delete[$delId] = $da2 |
    .diagnostics += [{level: "delete", message: "Delete: \($dd)"}] |
    (build_identity_changes($da2; null; false; $deployedRoles)) as $dic |
    .ra_removed += $dic.removed
  else . end
)) as $final |

# Assemble result
(($final.new | length) + ($final.update | length) + ($final.replace | length) + ($final.delete | length)) as $numChanges |
(($final.ra_added | length) + ($final.ra_updated | length) + ($final.ra_removed | length)) as $raChanges |

{
  assignments: {
    new: $final.new,
    update: $final.update,
    replace: $final.replace,
    delete: $final.delete,
    numberUnchanged: $final.unchanged,
    numberOfChanges: $numChanges
  },
  roleAssignments: {
    added: $final.ra_added,
    updated: $final.ra_updated,
    removed: $final.ra_removed,
    numberOfChanges: $raChanges
  },
  numberTotalChanges: ($numChanges + $raChanges),
  diagnostics: ($phase1.diagnostics + $final.diagnostics),
  hasErrors: $phase1.hasErrors
}
