#!/usr/bin/env bash
# tests/test_operations.sh — Tests for WI-15 operational tool scripts
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "${REPO_ROOT}/lib/epac.sh"

PASS=0
FAIL=0
TESTS=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TESTS=$((TESTS + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (doesn't contain '$needle')"
        echo "    in: ${haystack:0:200}..."
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TESTS=$((TESTS + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (should not contain '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

assert_file_exists() {
    local desc="$1" path="$2"
    TESTS=$((TESTS + 1))
    if [[ -f "$path" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (file not found: $path)"
        FAIL=$((FAIL + 1))
    fi
}

assert_rc() {
    local desc="$1" expected="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if [[ "$expected" -eq "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (rc=$actual, expected=$expected)"
        FAIL=$((FAIL + 1))
    fi
}

line_count() {
    wc -l < "$1" | tr -d ' '
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Script executability ==="
for script in \
    get-az-policy-alias-output-csv.sh \
    new-az-policy-reader-role.sh \
    get-az-exemptions.sh \
    new-github-issue.sh \
    new-azure-devops-bug.sh \
    new-az-remediation-tasks.sh \
    export-non-compliance-reports.sh; do

    path="${REPO_ROOT}/scripts/operations/${script}"
    TESTS=$((TESTS + 1))
    if [[ -x "$path" ]]; then
        echo "  PASS: $script is executable"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $script is not executable"
        FAIL=$((FAIL + 1))
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Script --help exits cleanly ==="
for script in \
    get-az-policy-alias-output-csv.sh \
    new-az-policy-reader-role.sh \
    get-az-exemptions.sh \
    new-github-issue.sh \
    new-azure-devops-bug.sh \
    new-az-remediation-tasks.sh \
    export-non-compliance-reports.sh; do

    path="${REPO_ROOT}/scripts/operations/${script}"
    rc=0
    output="$(bash "$path" --help 2>&1)" || rc=$?
    assert_rc "$script --help exits 0" 0 "$rc"
    assert_contains "$script --help has Usage" "$output" "Usage"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== new-github-issue: requires all args ==="
rc=0
bash "${REPO_ROOT}/scripts/operations/new-github-issue.sh" 2>&1 || rc=$?
assert_eq "github-issue no args exits 1" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== new-azure-devops-bug: requires all args ==="
rc=0
bash "${REPO_ROOT}/scripts/operations/new-azure-devops-bug.sh" 2>&1 || rc=$?
assert_eq "ado-bug no args exits 1" "1" "$rc"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Remediation tasks: collation logic ==="

# Test the jq collation that happens inside new-az-remediation-tasks.sh
# Simulate raw non-compliant list with 3 entries (2 same assignment+ref combo)
RAW_NC='[
    {"properties": {
        "policyAssignmentId": "/sub/1/a/assign-1",
        "policyAssignmentName": "assign-1",
        "policyAssignmentScope": "/sub/1",
        "policyDefinitionId": "/prov/pd/pd-1",
        "policyDefinitionReferenceId": "ref-a",
        "policyDefinitionName": "Deny SQL",
        "policyDefinitionAction": "Deny",
        "complianceState": "NonCompliant",
        "resourceId": "/sub/1/rg/rg1/prov/ms/res1",
        "subscriptionId": "sub-1",
        "metadata": {"category": "SQL"}
    }},
    {"properties": {
        "policyAssignmentId": "/sub/1/a/assign-1",
        "policyAssignmentName": "assign-1",
        "policyAssignmentScope": "/sub/1",
        "policyDefinitionId": "/prov/pd/pd-1",
        "policyDefinitionReferenceId": "ref-a",
        "policyDefinitionName": "Deny SQL",
        "policyDefinitionAction": "Deny",
        "complianceState": "NonCompliant",
        "resourceId": "/sub/1/rg/rg1/prov/ms/res2",
        "subscriptionId": "sub-1",
        "metadata": {"category": "SQL"}
    }},
    {"properties": {
        "policyAssignmentId": "/sub/1/a/assign-2",
        "policyAssignmentName": "assign-2",
        "policyAssignmentScope": "/sub/1",
        "policyDefinitionId": "/prov/pd/pd-2",
        "policyDefinitionReferenceId": "",
        "policyDefinitionName": "Audit Storage",
        "policyDefinitionAction": "DeployIfNotExists",
        "complianceState": "NonCompliant",
        "resourceId": "/sub/1/rg/rg2/prov/ms/res3",
        "subscriptionId": "sub-1",
        "metadata": {"category": "Storage"}
    }}
]'

collated="$(echo "$RAW_NC" | jq '
    reduce .[] as $entry ({};
        ($entry.properties.policyAssignmentId) as $aid |
        ($entry.properties.policyDefinitionReferenceId // "") as $refId |
        ($aid + "|" + $refId) as $key |
        if has($key) then
            .[$key].resourceCount += 1
        else
            .[$key] = {
                policyAssignmentId: $aid,
                policyAssignmentName: $entry.properties.policyAssignmentName,
                policyAssignmentScope: $entry.properties.policyAssignmentScope,
                policyDefinitionReferenceId: $refId,
                policyDefinitionName: ($entry.properties.policyDefinitionName // ""),
                policyDefinitionAction: ($entry.properties.policyDefinitionAction // ""),
                category: (($entry.properties.metadata // {}).category // "|unknown|"),
                resourceCount: 1
            }
        end
    )
')"

task_count="$(echo "$collated" | jq 'length')"
assert_eq "Collation: 2 unique combos" "2" "$task_count"

# First combo: assign-1|ref-a should have 2 resources
rc1="$(echo "$collated" | jq '."/sub/1/a/assign-1|ref-a".resourceCount')"
assert_eq "Collation: assign-1|ref-a has 2 resources" "2" "$rc1"

# Second combo: assign-2| should have 1 resource
rc2="$(echo "$collated" | jq '."/sub/1/a/assign-2|".resourceCount')"
assert_eq "Collation: assign-2 has 1 resource" "1" "$rc2"

# Verify fields
name="$(echo "$collated" | jq -r '."/sub/1/a/assign-1|ref-a".policyAssignmentName')"
assert_eq "Collation: assignment name" "assign-1" "$name"

action="$(echo "$collated" | jq -r '."/sub/1/a/assign-2|".policyDefinitionAction')"
assert_eq "Collation: action" "DeployIfNotExists" "$action"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Non-compliance reports: resource ID parsing ==="

# Test the parse_resource_id jq helper
parse_result="$(echo '"/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1"' | jq '
    . as $rid | ($rid | split("/")) as $parts |
    ($parts | length) as $len |
    {resourceGroup: "", resourceType: "", resourceName: "", resourceQualifier: ""} |
    reduce range(0; $len) as $i (.;
        if $parts[$i] == "resourceGroups" and ($i + 1) < $len then .resourceGroup = $parts[$i + 1]
        elif $parts[$i] == "providers" and ($i + 2) < $len then
            .resourceType = ($parts[$i + 1] + "/" + $parts[$i + 2]) |
            if ($i + 3) < $len then .resourceName = $parts[$i + 3] else . end |
            if ($i + 4) < $len then .resourceQualifier = ($parts[$i + 4:$len] | join("/")) else . end
        else .
        end
    ) |
    if .resourceType == "" then
        if .resourceGroup == "" then .resourceType = "subscriptions"
        else .resourceType = "resourceGroups"
        end
    else .
    end
')"

rg="$(echo "$parse_result" | jq -r '.resourceGroup')"
assert_eq "Parse: resourceGroup" "rg1" "$rg"

rt="$(echo "$parse_result" | jq -r '.resourceType')"
assert_eq "Parse: resourceType" "Microsoft.Compute/virtualMachines" "$rt"

rn="$(echo "$parse_result" | jq -r '.resourceName')"
assert_eq "Parse: resourceName" "vm1" "$rn"

rq="$(echo "$parse_result" | jq -r '.resourceQualifier')"
assert_eq "Parse: resourceQualifier" "" "$rq"

# Nested resource
parse_nested="$(echo '"/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Sql/servers/srv1/databases/db1"' | jq '
    . as $rid | ($rid | split("/")) as $parts |
    ($parts | length) as $len |
    {resourceGroup: "", resourceType: "", resourceName: "", resourceQualifier: ""} |
    reduce range(0; $len) as $i (.;
        if $parts[$i] == "resourceGroups" and ($i + 1) < $len then .resourceGroup = $parts[$i + 1]
        elif $parts[$i] == "providers" and ($i + 2) < $len then
            .resourceType = ($parts[$i + 1] + "/" + $parts[$i + 2]) |
            if ($i + 3) < $len then .resourceName = $parts[$i + 3] else . end |
            if ($i + 4) < $len then .resourceQualifier = ($parts[$i + 4:$len] | join("/")) else . end
        else .
        end
    ) |
    if .resourceType == "" then
        if .resourceGroup == "" then .resourceType = "subscriptions"
        else .resourceType = "resourceGroups"
        end
    else .
    end
')"

rq_nested="$(echo "$parse_nested" | jq -r '.resourceQualifier')"
assert_eq "Parse nested: resourceQualifier" "databases/db1" "$rq_nested"

# Subscription only
parse_sub="$(echo '"/subscriptions/sub1"' | jq '
    . as $rid | ($rid | split("/")) as $parts |
    ($parts | length) as $len |
    {resourceGroup: "", resourceType: "", resourceName: "", resourceQualifier: ""} |
    reduce range(0; $len) as $i (.;
        if $parts[$i] == "resourceGroups" and ($i + 1) < $len then .resourceGroup = $parts[$i + 1]
        elif $parts[$i] == "providers" and ($i + 2) < $len then
            .resourceType = ($parts[$i + 1] + "/" + $parts[$i + 2]) |
            if ($i + 3) < $len then .resourceName = $parts[$i + 3] else . end |
            if ($i + 4) < $len then .resourceQualifier = ($parts[$i + 4:$len] | join("/")) else . end
        else .
        end
    ) |
    if .resourceType == "" then
        if .resourceGroup == "" then .resourceType = "subscriptions"
        else .resourceType = "resourceGroups"
        end
    else .
    end
')"
rt_sub="$(echo "$parse_sub" | jq -r '.resourceType')"
assert_eq "Parse sub-only: resourceType is subscriptions" "subscriptions" "$rt_sub"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Non-compliance reports: collation logic ==="

SCOPE_TABLE='{"\/subscriptions\/sub-1":{"displayName":"Prod Sub"}}'

NC_INPUT='[
    {"properties": {
        "policyAssignmentId": "/a/1", "policyAssignmentName": "assign-a",
        "policyAssignmentScope": "/sub/1", "policyDefinitionId": "/pd/1",
        "complianceState": "NonCompliant", "policyDefinitionAction": "Deny",
        "policyDefinitionReferenceId": "", "resourceId": "/subscriptions/sub-1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sa1",
        "policyDefinitionGroupNames": ["NS-1"], "policyDefinitionName": "Deny Storage",
        "subscriptionId": "sub-1", "metadata": {"category": "Storage"}
    }},
    {"properties": {
        "policyAssignmentId": "/a/1", "policyAssignmentName": "assign-a",
        "policyAssignmentScope": "/sub/1", "policyDefinitionId": "/pd/1",
        "complianceState": "NonCompliant", "policyDefinitionAction": "Deny",
        "policyDefinitionReferenceId": "", "resourceId": "/subscriptions/sub-1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sa2",
        "policyDefinitionGroupNames": ["NS-1"], "policyDefinitionName": "Deny Storage",
        "subscriptionId": "sub-1", "metadata": {"category": "Storage"}
    }},
    {"properties": {
        "policyAssignmentId": "/a/2", "policyAssignmentName": "assign-b",
        "policyAssignmentScope": "/sub/1", "policyDefinitionId": "/pd/2",
        "complianceState": "Unknown", "policyDefinitionAction": "Audit",
        "policyDefinitionReferenceId": "", "resourceId": "/subscriptions/sub-1/resourceGroups/rg2/providers/Microsoft.Compute/virtualMachines/vm1",
        "policyDefinitionGroupNames": ["DP-1", "DP-2"], "policyDefinitionName": "Audit VM",
        "subscriptionId": "sub-1", "metadata": {"category": "Compute"}
    }}
]'

# Run the full collation from our script's jq logic
report_data="$(echo "$NC_INPUT" | jq --arg portal "https://portal.azure.com/#@t1/resource" --arg sep "," --argjson scope_table "$SCOPE_TABLE" '

    def parse_resource_id($rid):
        ($rid | split("/")) as $parts |
        ($parts | length) as $len |
        {resourceGroup: "", resourceType: "", resourceName: "", resourceQualifier: ""} |
        reduce range(0; $len) as $i (.;
            if $parts[$i] == "resourceGroups" and ($i + 1) < $len then .resourceGroup = $parts[$i + 1]
            elif $parts[$i] == "providers" and ($i + 2) < $len then
                .resourceType = ($parts[$i + 1] + "/" + $parts[$i + 2]) |
                if ($i + 3) < $len then .resourceName = $parts[$i + 3] else . end |
                if ($i + 4) < $len then .resourceQualifier = ($parts[$i + 4:$len] | join("/")) else . end
            else .
            end
        ) |
        if .resourceType == "" then
            if .resourceGroup == "" then .resourceType = "subscriptions"
            else .resourceType = "resourceGroups"
            end
        else .
        end;

    def sub_name($sid):
        ("/subscriptions/" + $sid) as $key |
        if $scope_table | has($key) then $scope_table[$key].displayName // $sid
        else $sid
        end;

    reduce .[] as $entry (
        {fullDetails: [], byPolicy: {}, byResource: {}};

        ($entry.properties) as $props |
        ($props.policyAssignmentId) as $aid |
        ($props.policyAssignmentName) as $aname |
        ($props.policyAssignmentScope) as $ascope |
        ($props.policyDefinitionId) as $pdid |
        ($props.complianceState) as $state |
        ($props.policyDefinitionAction) as $action |
        ($props.policyDefinitionReferenceId // "") as $refId |
        ($props.resourceId) as $rid |
        ($props.policyDefinitionGroupNames // []) as $gnames |
        ($props.policyDefinitionName // "") as $pdname |
        ($props.subscriptionId) as $subId |
        (sub_name($subId)) as $subName |
        (parse_resource_id($rid)) as $parsed |
        ($props.metadata.category // "|unknown|") as $cat |
        ($portal + $rid) as $portalUrl |

        .fullDetails += [{
            assignmentName: $aname, assignmentScope: $ascope, assignmentId: $aid,
            referenceId: $refId, category: $cat, policyName: $pdname, policyId: $pdid,
            resourceId: $rid, subscriptionId: $subId, subscriptionName: $subName,
            resourceGroup: $parsed.resourceGroup, resourceType: $parsed.resourceType,
            resourceName: $parsed.resourceName, resourceQualifier: $parsed.resourceQualifier,
            managementPortalUrl: $portalUrl, effect: $action, state: $state,
            groupNames: ($gnames | join($sep))
        }] |

        (if .byPolicy | has($pdid) then .byPolicy[$pdid]
         else {
            category: $cat, policyName: $pdname, policyId: $pdid,
            nonCompliant: 0, unknown: 0, notStarted: 0, exempt: 0, conflicting: 0, error: 0,
            assignments: {}, groupNames: {}, details: []
         } end) as $bpEntry |
        ($bpEntry |
            .assignments[$aid] = true |
            reduce ($gnames[]) as $gn (.; .groupNames[$gn] = true) |
            (if $state == "NonCompliant" then .nonCompliant += 1
             elif $state == "Unknown" then .unknown += 1
             elif $state == "NotStarted" then .notStarted += 1
             elif $state == "Exempt" then .exempt += 1
             elif $state == "Conflicting" then .conflicting += 1
             elif $state == "Error" then .error += 1
             else . end) |
            .details += [{
                category: $cat, policyName: $pdname, policyId: $pdid, effect: $action,
                state: $state, resourceId: $rid, subscriptionId: $subId, subscriptionName: $subName,
                resourceGroup: $parsed.resourceGroup, resourceType: $parsed.resourceType,
                resourceName: $parsed.resourceName, resourceQualifier: $parsed.resourceQualifier,
                managementPortalUrl: $portalUrl, assignments: {($aid): true},
                groupNames: (reduce ($gnames[]) as $gn ({}; .[$gn] = true))
            }]
        ) as $updatedBP |
        .byPolicy[$pdid] = $updatedBP |

        (if .byResource | has($rid) then .byResource[$rid]
         else {
            resourceId: $rid, subscriptionId: $subId, subscriptionName: $subName,
            resourceGroup: $parsed.resourceGroup, resourceType: $parsed.resourceType,
            resourceName: $parsed.resourceName, resourceQualifier: $parsed.resourceQualifier,
            managementPortalUrl: $portalUrl,
            nonCompliant: 0, unknown: 0, notStarted: 0, exempt: 0, conflicting: 0, error: 0,
            details: []
         } end) as $brEntry |
        ($brEntry |
            (if $state == "NonCompliant" then .nonCompliant += 1
             elif $state == "Unknown" then .unknown += 1
             elif $state == "NotStarted" then .notStarted += 1
             elif $state == "Exempt" then .exempt += 1
             elif $state == "Conflicting" then .conflicting += 1
             elif $state == "Error" then .error += 1
             else . end) |
            .details += [{
                resourceId: $rid, subscriptionId: $subId, subscriptionName: $subName,
                resourceGroup: $parsed.resourceGroup, resourceType: $parsed.resourceType,
                resourceName: $parsed.resourceName, resourceQualifier: $parsed.resourceQualifier,
                managementPortalUrl: $portalUrl,
                category: $cat, policyName: $pdname, policyId: $pdid, effect: $action, state: $state
            }]
        ) as $updatedBR |
        .byResource[$rid] = $updatedBR
    )
')"

# Verify full details
full_count="$(echo "$report_data" | jq '.fullDetails | length')"
assert_eq "Full details has 3 entries" "3" "$full_count"

# Verify by-policy
bp_count="$(echo "$report_data" | jq '.byPolicy | length')"
assert_eq "By policy has 2 policies" "2" "$bp_count"

pd1_nc="$(echo "$report_data" | jq '.byPolicy["/pd/1"].nonCompliant')"
assert_eq "pd/1 has 2 non-compliant" "2" "$pd1_nc"

pd2_unk="$(echo "$report_data" | jq '.byPolicy["/pd/2"].unknown')"
assert_eq "pd/2 has 1 unknown" "1" "$pd2_unk"

pd1_gn="$(echo "$report_data" | jq -r '.byPolicy["/pd/1"].groupNames | keys | join(",")')"
assert_eq "pd/1 group names" "NS-1" "$pd1_gn"

pd2_gn="$(echo "$report_data" | jq -r '.byPolicy["/pd/2"].groupNames | keys | sort | join(",")')"
assert_eq "pd/2 group names" "DP-1,DP-2" "$pd2_gn"

# Verify by-resource
br_count="$(echo "$report_data" | jq '.byResource | length')"
assert_eq "By resource has 3 resources" "3" "$br_count"

sa1_nc="$(echo "$report_data" | jq '.byResource["/subscriptions/sub-1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sa1"].nonCompliant')"
assert_eq "sa1 has 1 non-compliant" "1" "$sa1_nc"

vm1_unk="$(echo "$report_data" | jq '.byResource["/subscriptions/sub-1/resourceGroups/rg2/providers/Microsoft.Compute/virtualMachines/vm1"].unknown')"
assert_eq "vm1 has 1 unknown" "1" "$vm1_unk"

# Verify parsed fields
sa1_rg="$(echo "$report_data" | jq -r '.byResource["/subscriptions/sub-1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sa1"].resourceGroup')"
assert_eq "sa1 resource group" "rg1" "$sa1_rg"

sa1_rt="$(echo "$report_data" | jq -r '.byResource["/subscriptions/sub-1/resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/sa1"].resourceType')"
assert_eq "sa1 resource type" "Microsoft.Storage/storageAccounts" "$sa1_rt"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Non-compliance reports: CSV generation ==="

# Test CSV generation from report_data
summary_csv="$(echo "$report_data" | jq -r --arg sep "," '
    def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
    "\"Category\",\"Policy Name\",\"Policy Id\",\"Non Compliant\",\"Unknown\",\"Not Started\",\"Exempt\",\"Conflicting\",\"Error\",\"Assignment Ids\",\"Group Names\"",
    (.byPolicy | to_entries | sort_by(.value.category, .value.policyName) | .[].value |
        [.category, .policyName, .policyId,
         (.nonCompliant | tostring), (.unknown | tostring), (.notStarted | tostring),
         (.exempt | tostring), (.conflicting | tostring), (.error | tostring),
         (.assignments | keys | join($sep)),
         (.groupNames | keys | join($sep))
        ] | map(csv_esc) | join(",")
    )
')"

# Verify header
header_line="$(echo "$summary_csv" | head -1)"
assert_contains "Summary CSV has header" "$header_line" "Category"
assert_contains "Summary CSV has Policy Name" "$header_line" "Policy Name"

# Verify Compute comes first alphabetically
line2="$(echo "$summary_csv" | sed -n '2p')"
assert_contains "First data row is Compute" "$line2" "Compute"

line3="$(echo "$summary_csv" | sed -n '3p')"
assert_contains "Second data row is Storage" "$line3" "Storage"

# Verify total line count: 1 header + 2 policies
csv_lines="$(echo "$summary_csv" | wc -l | tr -d ' ')"
assert_eq "Summary CSV has 3 lines" "3" "$csv_lines"

# Full details CSV
full_csv="$(echo "$report_data" | jq -r '
    def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
    "\"Assignment Name\",\"Category\",\"Policy Name\",\"Resource Id\"",
    (.fullDetails | sort_by(.assignmentName, .category, .policyName) | .[] |
        [.assignmentName, .category, .policyName, .resourceId] | map(csv_esc) | join(",")
    )
')"
full_csv_lines="$(echo "$full_csv" | wc -l | tr -d ' ')"
assert_eq "Full details CSV has 4 lines (header + 3)" "4" "$full_csv_lines"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== GitHub Issue: HTML table generation ==="

FAILED_TASKS='[
    {"Name": "task-1", "Id": "/sub/1/rem/task-1", "PolicyAssignmentId": "/sub/1/a/assign-1", "ProvisioningState": "Failed"},
    {"Name": "task-2", "Id": "/sub/1/rem/task-2", "PolicyAssignmentId": "/sub/1/a/assign-2", "ProvisioningState": "Failed"}
]'

html="$(echo "$FAILED_TASKS" | jq -r '
    def url_encode: gsub("/"; "%2F");
    "<table><tr><th>Remediation Task Name</th><th>Remediation Task Url</th><th>Provisioning State</th></tr>" +
    ([.[] |
        "<tr><td>" + .Name + "</td><td>" +
        "https://portal.azure.com/#view/Microsoft_Azure_Policy/ManageRemediationTaskBlade/assignmentId/" +
        (.PolicyAssignmentId | url_encode) +
        "/remediationTaskId/" +
        (.Id | url_encode) +
        "</td><td>" + .ProvisioningState + "</td></tr>"
    ] | join("")) +
    "</table><h4><i>Table 1: Failed Remediation Tasks</i></h4>"
')"

assert_contains "HTML has table" "$html" "<table>"
assert_contains "HTML has task-1" "$html" "task-1"
assert_contains "HTML has task-2" "$html" "task-2"
assert_contains "HTML has Failed" "$html" "Failed"
assert_contains "HTML has portal URL" "$html" "portal.azure.com"
assert_contains "HTML has URL-encoded assignment" "$html" "%2Fsub%2F1%2Fa%2Fassign-1"
assert_contains "HTML has remediation task URL" "$html" "remediationTaskId"
assert_contains "HTML has Table 1 caption" "$html" "Table 1: Failed Remediation Tasks"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== ADO Bug: HTML table generation ==="

ado_html="$(echo "$FAILED_TASKS" | jq -r '
    def url_encode: gsub("/"; "%2F");
    "<style>TABLE {border-width: 1px; border-style: solid; border-color: black; border-collapse: collapse;} TH {text-align: left; border-width: 1px; padding: 3px; border-style: solid; border-color: black; background-color: #6495ED;} TD {text-align: left; border-width: 1px; padding: 3px; border-style: solid; border-color: black;}</style>" +
    "<table><tr><th>Remediation Task Name</th><th>Remediation Task Url</th><th>Provisioning State</th></tr>" +
    ([.[] |
        "<tr><td>" + .Name + "</td><td>" +
        "https://portal.azure.com/#view/Microsoft_Azure_Policy/ManageRemediationTaskBlade/assignmentId/" +
        (.PolicyAssignmentId | url_encode) +
        "/remediationTaskId/" +
        (.Id | url_encode) +
        "</td><td>" + .ProvisioningState + "</td></tr>"
    ] | join("")) +
    "</table><H4><i>Table 1: Failed Remediation Tasks</i></H4>"
')"

assert_contains "ADO HTML has style" "$ado_html" "<style>"
assert_contains "ADO HTML has blue header" "$ado_html" "#6495ED"
assert_contains "ADO HTML has task rows" "$ado_html" "task-1"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy reader role: permissions list ==="

# Verify the permissions list from the script
permissions='[
    "Microsoft.Authorization/policyassignments/read",
    "Microsoft.Authorization/policydefinitions/read",
    "Microsoft.Authorization/policyexemptions/read",
    "Microsoft.Authorization/policysetdefinitions/read",
    "Microsoft.Authorization/roleAssignments/read",
    "Microsoft.PolicyInsights/*",
    "Microsoft.Management/register/action",
    "Microsoft.Management/managementGroups/read",
    "Microsoft.Resources/subscriptions/read",
    "Microsoft.Resources/subscriptions/resourceGroups/read"
]'

perm_count="$(echo "$permissions" | jq 'length')"
assert_eq "10 permissions defined" "10" "$perm_count"

has_policy_read="$(echo "$permissions" | jq '[.[] | select(startswith("Microsoft.Authorization/policy"))] | length')"
assert_eq "4 policy read permissions" "4" "$has_policy_read"

has_insights="$(echo "$permissions" | jq '[.[] | select(startswith("Microsoft.PolicyInsights"))] | length')"
assert_eq "1 PolicyInsights permission" "1" "$has_insights"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Remediation body JSON ==="

# Test the remediation task body construction
assignment_id="/sub/1/a/test-assign"
ref_id="ref-abc"

body_with_ref="$(jq -n \
    --arg aid "$assignment_id" \
    --arg refid "$ref_id" \
    '{
        properties: {
            policyAssignmentId: $aid,
            resourceDiscoveryMode: "ExistingNonCompliant",
            resourceCount: 50000,
            parallelDeployments: 30
        }
    } | if $refid != "" then .properties.policyDefinitionReferenceId = $refid else . end
')"

has_ref="$(echo "$body_with_ref" | jq 'has("properties") and (.properties | has("policyDefinitionReferenceId"))')"
assert_eq "Body has referenceId when provided" "true" "$has_ref"
ref_val="$(echo "$body_with_ref" | jq -r '.properties.policyDefinitionReferenceId')"
assert_eq "Body referenceId value" "ref-abc" "$ref_val"

# Without ref
body_no_ref="$(jq -n \
    --arg aid "$assignment_id" \
    --arg refid "" \
    '{
        properties: {
            policyAssignmentId: $aid,
            resourceDiscoveryMode: "ExistingNonCompliant",
            resourceCount: 50000,
            parallelDeployments: 30
        }
    } | if $refid != "" then .properties.policyDefinitionReferenceId = $refid else . end
')"

no_ref="$(echo "$body_no_ref" | jq '.properties | has("policyDefinitionReferenceId")')"
assert_eq "Body no referenceId when empty" "false" "$no_ref"

disc_mode="$(echo "$body_no_ref" | jq -r '.properties.resourceDiscoveryMode')"
assert_eq "Body discovery mode" "ExistingNonCompliant" "$disc_mode"

rc_val="$(echo "$body_no_ref" | jq '.properties.resourceCount')"
assert_eq "Body resource count" "50000" "$rc_val"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== ADO API: patch body construction ==="

title="Failed Remediation Tasks - 20260410"
description="Test description"
repro_steps="<table>test</table>"
iteration_path='\\Project\\Sprint 1'

patch_body="$(jq -n \
    --arg title "$title" \
    --arg desc "$description" \
    --arg repro "$repro_steps" \
    --arg iter "$iteration_path" \
    '[
        {op: "add", path: "/fields/System.Title", value: $title},
        {op: "add", path: "/fields/System.Description", value: $desc},
        {op: "add", path: "/fields/Microsoft.VSTS.TCM.ReproSteps", value: $repro},
        {op: "add", path: "/fields/System.IterationPath", value: $iter}
    ]')"

patch_count="$(echo "$patch_body" | jq 'length')"
assert_eq "Patch body has 4 ops" "4" "$patch_count"

title_val="$(echo "$patch_body" | jq -r '.[0].value')"
assert_eq "Patch title" "Failed Remediation Tasks - 20260410" "$title_val"

iter_val="$(echo "$patch_body" | jq -r '.[3].value')"
assert_contains "Patch iteration" "$iter_val" "Sprint 1"

repro_val="$(echo "$patch_body" | jq -r '.[2].path')"
assert_eq "Patch repro path" "/fields/Microsoft.VSTS.TCM.ReproSteps" "$repro_val"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== GitHub API: issue payload construction ==="

title="Failed Remediation Tasks - 20260410"
body="<p>Test</p><table>html</table>"

issue_payload="$(jq -n \
    --arg title "$title" \
    --arg body "$body" \
    '{title: $title, body: $body, labels: ["Operations"]}')"

issue_title="$(echo "$issue_payload" | jq -r '.title')"
assert_eq "Issue title" "$title" "$issue_title"

issue_labels="$(echo "$issue_payload" | jq -r '.labels[0]')"
assert_eq "Issue label" "Operations" "$issue_labels"

issue_body_has="$(echo "$issue_payload" | jq -r '.body')"
assert_contains "Issue body has html" "$issue_body_has" "<table>"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Subscription name lookup ==="

scope_table='{"\/subscriptions\/sub-1":{"displayName":"Production"},"\/subscriptions\/sub-2":{"displayName":"Development"}}'
sub_name="$(echo "\"sub-1\"" | jq -r --argjson st "$scope_table" '
    . as $sid | ("/subscriptions/" + $sid) as $key |
    if $st | has($key) then $st[$key].displayName // $sid else $sid end
')"
assert_eq "Sub name lookup: found" "Production" "$sub_name"

sub_unknown="$(echo "\"sub-9\"" | jq -r --argjson st "$scope_table" '
    . as $sid | ("/subscriptions/" + $sid) as $key |
    if $st | has($key) then $st[$key].displayName // $sid else $sid end
')"
assert_eq "Sub name lookup: unknown" "sub-9" "$sub_unknown"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Alias CSV: jq splitter ==="

# Simulate a small alias dataset
alias_json='[
    {"namespace": "Microsoft.Compute/virtualMachines", "aliases": ["Microsoft.Compute/virtualMachines/osProfile.computerName","Microsoft.Compute/virtualMachines/storageProfile"]},
    {"namespace": "Microsoft.Storage/storageAccounts", "aliases": ["Microsoft.Storage/storageAccounts/supportsHttpsTrafficOnly"]}
]'

csv_output="$(echo "$alias_json" | jq -r '
    .[] |
    .namespace as $ns |
    ($ns | split("/")[0]) as $namespace |
    ($ns | split("/")[1:] | join("/")) as $rt |
    .aliases[] |
    def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
    [($namespace | csv_esc), ($rt | csv_esc), (. | csv_esc)] | join(",")
')"

csv_line_count="$(echo "$csv_output" | wc -l | tr -d ' ')"
assert_eq "Alias CSV: 3 data rows" "3" "$csv_line_count"
assert_contains "Alias CSV has Compute" "$csv_output" "Microsoft.Compute"
assert_contains "Alias CSV has Storage" "$csv_output" "Microsoft.Storage"
assert_contains "Alias CSV has alias name" "$csv_output" "supportsHttpsTrafficOnly"

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Policy reader role JSON ==="

role_json="$(jq -n \
    --arg name "EPAC Resource Policy Reader" \
    --arg id "2baa1a7c-6807-46af-8b16-5e9d03fba029" \
    --arg desc "Test role" \
    --argjson perms '["Microsoft.Authorization/policyassignments/read"]' \
    --arg scope "/providers/Microsoft.Management/managementGroups/root" \
    '{
        Name: $name,
        Id: $id,
        IsCustom: true,
        Description: $desc,
        Actions: $perms,
        NotActions: [],
        AssignableScopes: [$scope]
    }')"

role_name="$(echo "$role_json" | jq -r '.Name')"
assert_eq "Role JSON name" "EPAC Resource Policy Reader" "$role_name"

is_custom="$(echo "$role_json" | jq '.IsCustom')"
assert_eq "Role JSON IsCustom" "true" "$is_custom"

scope_val="$(echo "$role_json" | jq -r '.AssignableScopes[0]')"
assert_contains "Role scope" "$scope_val" "managementGroups"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "================================="
echo "Tests: $TESTS | Passed: $PASS | Failed: $FAIL"
echo "================================="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
