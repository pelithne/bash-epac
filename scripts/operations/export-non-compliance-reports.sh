#!/usr/bin/env bash
# scripts/operations/export-non-compliance-reports.sh
# Replaces: Export-NonComplianceReports.ps1
# Exports Non-Compliance Reports in CSV format: 6 reports covering
# summary/details by policy, resource, and full assignment detail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

# ─── Argument parsing ──────────────────────────────────────────────────────
pac_selector=""
definitions_root=""
output_folder=""
interactive=true
only_managed=false
policy_def_filter=""
policy_set_def_filter=""
policy_assignment_filter=""
policy_effect_filter=""
exclude_manual=false
remediation_only=false
windows_newline=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pac-selector|-p) pac_selector="$2"; shift 2 ;;
        --definitions-root|-d) definitions_root="$2"; shift 2 ;;
        --output-folder|-o) output_folder="$2"; shift 2 ;;
        --non-interactive) interactive=false; shift ;;
        --only-managed) only_managed=true; shift ;;
        --policy-definition-filter) policy_def_filter="$2"; shift 2 ;;
        --policy-set-definition-filter) policy_set_def_filter="$2"; shift 2 ;;
        --policy-assignment-filter) policy_assignment_filter="$2"; shift 2 ;;
        --policy-effect-filter) policy_effect_filter="$2"; shift 2 ;;
        --exclude-manual) exclude_manual=true; shift ;;
        --remediation-only) remediation_only=true; shift ;;
        --windows-newline-cells) windows_newline=true; shift ;;
        --help|-h)
            echo "Usage: $(basename "$0") [options]"
            echo "  --pac-selector <env>                    PAC environment"
            echo "  --definitions-root <path>               Definitions folder"
            echo "  --output-folder <path>                  Output folder"
            echo "  --non-interactive                       Non-interactive mode"
            echo "  --only-managed                          Only managed assignments"
            echo "  --policy-definition-filter <names>      Comma-separated filter"
            echo "  --policy-set-definition-filter <names>  Comma-separated filter"
            echo "  --policy-assignment-filter <names>      Comma-separated filter"
            echo "  --policy-effect-filter <effects>        Comma-separated filter"
            echo "  --exclude-manual                        Exclude Manual effect"
            echo "  --remediation-only                      Only DINE/Modify + NonCompliant"
            echo "  --windows-newline-cells                 Use CRLF in multi-value CSV cells"
            exit 0
            ;;
        *) shift ;;
    esac
done

# ─── Init ───────────────────────────────────────────────────────────────────
pac_env="$(epac_select_pac_environment "$pac_selector" "$definitions_root" "$output_folder" "" "$interactive")"
epac_set_cloud_tenant_subscription "$pac_env"

pac_output_folder="$(echo "$pac_env" | jq -r '.outputFolder')"
tenant_id="$(echo "$pac_env" | jq -r '.tenantId')"

# Portal URL base
portal_url_base="https://portal.azure.com/#@${tenant_id}/resource"

# ─── Query non-compliant resources ─────────────────────────────────────────
raw_non_compliant="$(epac_find_non_compliant_resources \
    "$pac_env" \
    "$remediation_only" \
    "$exclude_manual" \
    "$policy_effect_filter" \
    "")"

epac_write_header "Exporting Non-Compliance Reports" "Collating resources into simplified lists"
epac_write_section "Processing Compliance Data"

total="$(echo "$raw_non_compliant" | jq 'length')"
if [[ "$total" -eq 0 ]]; then
    epac_write_status "No non-compliant resources found" "success" 2
    exit 0
fi
epac_write_status "Processing $total non-compliant records" "info" 2

# Build scope table for subscription name lookup
scope_table="$(epac_build_scope_table "$pac_env")"

# Separator for multi-value cells
separator=","
if $windows_newline; then
    separator=$',\r\n'
fi

# ─── Collate into 3 views using jq ─────────────────────────────────────────
# We process all records in a single jq pass for efficiency
report_data="$(echo "$raw_non_compliant" | jq --arg portal "$portal_url_base" --arg sep "$separator" --argjson scope_table "$scope_table" '

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

    # Process all entries into categorized lists
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

        # Full details entry
        .fullDetails += [{
            assignmentName: $aname, assignmentScope: $ascope, assignmentId: $aid,
            referenceId: $refId, category: $cat, policyName: $pdname, policyId: $pdid,
            resourceId: $rid, subscriptionId: $subId, subscriptionName: $subName,
            resourceGroup: $parsed.resourceGroup, resourceType: $parsed.resourceType,
            resourceName: $parsed.resourceName, resourceQualifier: $parsed.resourceQualifier,
            managementPortalUrl: $portalUrl, effect: $action, state: $state,
            groupNames: ($gnames | join($sep))
        }] |

        # By Policy collation
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

        # By Resource collation
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

# ─── Output CSV files ──────────────────────────────────────────────────────
report_dir="${pac_output_folder}/non-compliance-report"
mkdir -p "$report_dir"

epac_write_section "Output CSV files"

_csv_esc() {
    # Escape a field for CSV: quote if contains comma, quote, or newline
    local val="$1"
    if [[ "$val" == *","* || "$val" == *'"'* || "$val" == *$'\n'* ]]; then
        val="${val//\"/\"\"}"
        echo "\"${val}\""
    else
        echo "$val"
    fi
}

# Helper: write a jq-generated CSV array to file
_write_csv() {
    local csv_path="$1"
    local csv_data="$2"
    echo "$csv_data" > "$csv_path"
    epac_write_status "Wrote $csv_path" "success" 4
}

# ── 1. Summary by Policy ──
epac_write_status "Creating summary by Policy" "info" 2
summary_by_policy="$(echo "$report_data" | jq -r --arg sep "$separator" '
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
_write_csv "$report_dir/summary-by-policy.csv" "$summary_by_policy"

# ── 2. Summary by Resource ──
epac_write_status "Creating summary by Resource" "info" 2
summary_by_resource="$(echo "$report_data" | jq -r '
    def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
    "\"Resource Id\",\"Subscription Id\",\"Subscription Name\",\"Resource Group\",\"Resource Type\",\"Resource Name\",\"Resource Qualifier\",\"Non Compliant\",\"Unknown\",\"Not Started\",\"Exempt\",\"Conflicting\",\"Error\"",
    (.byResource | to_entries | sort_by(.value.resourceId) | .[].value |
        [.resourceId, .subscriptionId, .subscriptionName, .resourceGroup, .resourceType,
         .resourceName, .resourceQualifier,
         (.nonCompliant | tostring), (.unknown | tostring), (.notStarted | tostring),
         (.exempt | tostring), (.conflicting | tostring), (.error | tostring)
        ] | map(csv_esc) | join(",")
    )
')"
_write_csv "$report_dir/summary-by-resource.csv" "$summary_by_resource"

# ── 3. Details by Policy ──
epac_write_status "Creating details by Policy" "info" 2
details_by_policy="$(echo "$report_data" | jq -r --arg sep "$separator" '
    def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
    "\"Category\",\"Policy Name\",\"Policy Id\",\"Resource Id\",\"Subscription Id\",\"Subscription Name\",\"Resource Group\",\"Resource Type\",\"Resource Name\",\"Resource Qualifier\",\"Portal Url\",\"Effect\",\"Compliance State\",\"Assignment Ids\",\"Group Names\"",
    ([.byPolicy | to_entries[].value.details[]] | sort_by(.category, .policyName, .resourceId) | .[] |
        [.category, .policyName, .policyId, .resourceId, .subscriptionId, .subscriptionName,
         .resourceGroup, .resourceType, .resourceName, .resourceQualifier,
         .managementPortalUrl, .effect, .state,
         (.assignments | keys | join($sep)),
         (.groupNames | keys | join($sep))
        ] | map(csv_esc) | join(",")
    )
')"
_write_csv "$report_dir/details-by-policy.csv" "$details_by_policy"

# ── 4. Details by Resource ──
epac_write_status "Creating details by Resource" "info" 2
details_by_resource="$(echo "$report_data" | jq -r '
    def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
    "\"Resource Id\",\"Subscription Id\",\"Subscription Name\",\"Resource Group\",\"Resource Type\",\"Resource Name\",\"Resource Qualifier\",\"Portal Url\",\"Category\",\"Policy Name\",\"Policy Id\",\"Effect\",\"Compliance State\"",
    ([.byResource | to_entries[].value.details[]] | sort_by(.resourceId, .category, .policyName) | .[] |
        [.resourceId, .subscriptionId, .subscriptionName, .resourceGroup, .resourceType,
         .resourceName, .resourceQualifier, .managementPortalUrl,
         .category, .policyName, .policyId, .effect, .state
        ] | map(csv_esc) | join(",")
    )
')"
_write_csv "$report_dir/details-by-resource.csv" "$details_by_resource"

# ── 5. Full details by Assignment ──
epac_write_status "Creating full details by Assignment" "info" 2
full_by_assignment="$(echo "$report_data" | jq -r '
    def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
    "\"Assignment Name\",\"Assignment Scope\",\"Assignment Id\",\"Category\",\"Policy Name\",\"Policy Id\",\"Reference Id\",\"Resource Id\",\"Subscription Id\",\"Subscription Name\",\"Resource Group\",\"Resource Type\",\"Resource Name\",\"Resource Qualifier\",\"Portal Url\",\"Compliance State\",\"Effect\",\"Group Names\"",
    (.fullDetails | sort_by(.assignmentName, .assignmentScope, .category, .policyName, .referenceId, .resourceId) | .[] |
        [.assignmentName, .assignmentScope, .assignmentId, .category, .policyName, .policyId,
         .referenceId, .resourceId, .subscriptionId, .subscriptionName,
         .resourceGroup, .resourceType, .resourceName, .resourceQualifier,
         .managementPortalUrl, .state, .effect, .groupNames
        ] | map(csv_esc) | join(",")
    )
')"
_write_csv "$report_dir/full-details-by-assignment.csv" "$full_by_assignment"

# ── 6. Full details by Resource ──
epac_write_status "Creating full details by Resource" "info" 2
full_by_resource="$(echo "$report_data" | jq -r '
    def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
    "\"Resource Id\",\"Subscription Id\",\"Subscription Name\",\"Resource Group\",\"Resource Type\",\"Resource Name\",\"Resource Qualifier\",\"Portal Url\",\"Category\",\"Policy Name\",\"Policy Id\",\"Compliance State\",\"Effect\",\"Assignment Name\",\"Reference Id\",\"Assignment Scope\",\"Assignment Id\",\"Group Names\"",
    (.fullDetails | sort_by(.resourceId, .category, .policyName, .assignmentName, .referenceId, .assignmentScope) | .[] |
        [.resourceId, .subscriptionId, .subscriptionName, .resourceGroup, .resourceType,
         .resourceName, .resourceQualifier, .managementPortalUrl,
         .category, .policyName, .policyId, .state, .effect,
         .assignmentName, .referenceId, .assignmentScope, .assignmentId, .groupNames
        ] | map(csv_esc) | join(",")
    )
')"
_write_csv "$report_dir/full-details-by-resource.csv" "$full_by_resource"

epac_write_status "Non-compliance reports exported successfully" "success" 0
