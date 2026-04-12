# lib/jq/calculated-assignments.jq
# Build calculated policy assignments lookup tables for exemption resolution.
# Input: all_assignments JSON { id: assignment }
# Slurpfile: $details (combined_policy_details with .policies and .policySets)
# Output: { byAssignmentId: {}, byPolicySetId: {}, byPolicyId: {} }

$details[0] as $cpd |

# Helper function to build refs data from policy set details
def get_refs_data($psid):
  ($cpd.policySets[$psid] // null) as $detail |
  if $detail == null then
    {policyDefinitionIds: [], policyDefinitionReferenceIds: [], perPolicyRefTable: {}}
  else
    ($detail.policyDefinitions // []) |
    reduce .[] as $pd (
      {policyDefinitionIds: [], policyDefinitionReferenceIds: [], perPolicyRefTable: {}};
      .policyDefinitionIds += [$pd.id] |
      .policyDefinitionReferenceIds += [$pd.policyDefinitionReferenceId] |
      (if .perPolicyRefTable[$pd.id] then
        .perPolicyRefTable[$pd.id].referenceIds += [$pd.policyDefinitionReferenceId]
      else
        .perPolicyRefTable[$pd.id] = {referenceIds: [$pd.policyDefinitionReferenceId]}
      end)
    )
  end;

# Helper to build a calc entry
def make_calc($aid; $scope; $name; $dn; $defId; $notScopes; $pid; $isPol; $allowRef; $pdIds; $pdRefIds; $pprt):
  {
    id: $aid, scope: $scope, name: $name, displayName: $dn,
    assignedPolicyDefinitionId: $defId,
    policyDefinitionId: $pid,
    isPolicyAssignment: $isPol,
    allowReferenceIdsInRow: $allowRef,
    policyDefinitionReferenceIds: $pdRefIds,
    policyDefinitionIds: $pdIds,
    perPolicyReferenceIdTable: $pprt,
    notScopes: $notScopes
  };

# Helper to append to a lookup table
def add_to_lookup($key; $val):
  if has($key) then .[$key] += [$val] else .[$key] = [$val] end;

# Main: iterate over all assignments
reduce (to_entries[]) as $e (
  {byAssignmentId: {}, byPolicySetId: {}, byPolicyId: {}};

  $e.key as $aid |
  $e.value as $asgn |
  ($asgn | if .properties then .properties else . end) as $props |
  ($props.policyDefinitionId // "") as $defId |
  ($asgn.scope // $props.scope // "") as $scope |
  ($asgn.name // "") as $name |
  ($props.displayName // "") as $dn |
  ($props.notScopes // []) as $notScopes |
  ($defId | ascii_downcase) as $defIdLower |

  if ($defIdLower | test("/providers/microsoft.authorization/policydefinitions/")) then
    # Direct policy assignment
    make_calc($aid; $scope; $name; $dn; $defId; $notScopes; $defId; true; false; []; []; {}) as $calc |
    .byAssignmentId |= add_to_lookup($aid; $calc) |
    .byPolicyId |= add_to_lookup($defId; $calc)

  elif ($defIdLower | test("/providers/microsoft.authorization/policysetdefinitions/")) then
    # Policy set assignment
    get_refs_data($defId) as $refs |
    ($refs.policyDefinitionIds) as $pdIds |
    ($refs.policyDefinitionReferenceIds) as $pdRefIds |
    ($refs.perPolicyRefTable) as $pprt |

    make_calc($aid; $scope; $name; $dn; $defId; $notScopes; null; false; true; $pdIds; $pdRefIds; $pprt) as $calcSet |
    .byAssignmentId |= add_to_lookup($aid; $calcSet) |
    .byPolicySetId |= add_to_lookup($defId; $calcSet) |

    # Per-policy entries
    reduce ($pdIds[]) as $pid (.;
      ($pprt[$pid].referenceIds // []) as $thisRefs |
      make_calc($aid; $scope; $name; $dn; $defId; $notScopes; $pid; false; false; $thisRefs; []; $pprt) as $calcPol |
      .byPolicyId |= add_to_lookup($pid; $calcPol)
    )

  else .
  end
)
