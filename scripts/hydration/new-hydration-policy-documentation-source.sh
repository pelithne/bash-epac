#!/usr/bin/env bash
# scripts/hydration/new-hydration-policy-documentation-source.sh
# Generate a policy documentation template file
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/lib/hydration/hydration-definitions.sh"

usage() {
    cat <<'EOF'
Usage: new-hydration-policy-documentation-source.sh --pac-selector <NAME> [OPTIONS]

Generate a policy documentation source file template that can be used
to produce documentation for all assignments.

Required:
  --pac-selector              PAC environment selector

Options:
  --definitions               Definitions folder (default: ./Definitions)
  --output                    Output folder (default: ./Output)
  --report-title              Report title (default: "Azure Policy Effects")
  --file-name-stem            Output file stem (default: PrimaryTenant)
  --max-parameter-length      Max parameter length in docs (default: 42)
  --include-compliance-groups Include compliance group names
  --no-embedded-html          Exclude embedded HTML
  --add-toc                   Add table of contents
  --ado-organization          Azure DevOps organization
  --ado-project               Azure DevOps project
  --ado-wiki                  Azure DevOps wiki name
  --environment-overrides     JSON object mapping MG IDs to environment categories
  --help                      Show this help message
EOF
    exit 0
}

pac_selector="" definitions="./Definitions" output="./Output"
report_title="Azure Policy Effects" file_name_stem="PrimaryTenant"
max_param_length=42 include_compliance=false no_html=false add_toc=false
ado_org="" ado_project="" ado_wiki="" env_overrides="{}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --pac-selector) pac_selector="$2"; shift 2 ;;
        --definitions) definitions="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --report-title) report_title="$2"; shift 2 ;;
        --file-name-stem) file_name_stem="$2"; shift 2 ;;
        --max-parameter-length) max_param_length="$2"; shift 2 ;;
        --include-compliance-groups) include_compliance=true; shift ;;
        --no-embedded-html) no_html=true; shift ;;
        --add-toc) add_toc=true; shift ;;
        --ado-organization) ado_org="$2"; shift 2 ;;
        --ado-project) ado_project="$2"; shift 2 ;;
        --ado-wiki) ado_wiki="$2"; shift 2 ;;
        --environment-overrides) env_overrides="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$pac_selector" ]] && { epac_log_error "Missing --pac-selector"; exit 1; }

schema_uri="https://raw.githubusercontent.com/Azure/enterprise-azure-policy-as-code/main/Schemas/policy-documentation-schema.json"
assignments_dir="${definitions}/policyAssignments"

if [[ ! -d "$assignments_dir" ]]; then
    epac_log_error "Policy assignments directory not found: $assignments_dir"
    exit 1
fi

date_dir="$(date '+%Y-%m-%d')"
output_dir="${output}/${date_dir}/policyDocumentations"
mkdir -p "$output_dir"

# Build the documentation template
doc_template="$(jq -n \
    --arg schema "$schema_uri" \
    --arg pac "$pac_selector" \
    --arg title "$report_title" \
    --arg stem "$file_name_stem" \
    --argjson maxLen "$max_param_length" \
    --argjson compliance "$include_compliance" \
    --argjson noHtml "$no_html" \
    --argjson toc "$add_toc" \
    --argjson envOverrides "$env_overrides" \
    '{
        "$schema": $schema,
        "documentAssignments": {
            "documentAllAssignments": [
                {
                    "pacEnvironment": $pac,
                    "overrideEnvironmentCategory": $envOverrides
                }
            ],
            "documentationSpecifications": [
                {
                    "fileNameStem": $stem,
                    "environmentCategories": [],
                    "title": $title,
                    "markdownIncludeComplianceGroupNames": $compliance,
                    "markdownSuppressParameterSection": false,
                    "markdownNoEmbeddedHtml": $noHtml,
                    "markdownAddToc": $toc,
                    "markdownMaxParameterLength": $maxLen
                }
            ]
        },
        "documentPolicySets": [
            {
                "pacEnvironment": $pac,
                "fileNameStem": $stem,
                "title": $title,
                "environmentCategories": [],
                "environmentColumnsInCsv": [],
                "markdownIncludeComplianceGroupNames": $compliance,
                "markdownSuppressParameterSection": false,
                "markdownNoEmbeddedHtml": $noHtml,
                "markdownAddToc": $toc,
                "markdownMaxParameterLength": $maxLen,
                "policySets": []
            }
        ]
    }')"

# Add ADO configuration if provided
if [[ -n "$ado_org" && -n "$ado_project" && -n "$ado_wiki" ]]; then
    doc_template="$(echo "$doc_template" | jq \
        --arg org "$ado_org" --arg proj "$ado_project" --arg wiki "$ado_wiki" '
        .documentAssignments.documentationSpecifications[0].markdownAdoWiki = true |
        .documentAssignments.documentationSpecifications[0].markdownAdoWikiConfig = {
            adoOrganization: $org,
            adoProject: $proj,
            adoWiki: $wiki
        } |
        .documentPolicySets[0].markdownAdoWiki = true
    ')"
fi

# Scan policy assignments to populate policySets
policy_sets="[]"
while IFS= read -r -d '' f; do
    content="$(epac_read_jsonc "$f")"
    # Extract policyDefinitionId if it references a policySetDefinition
    def_id="$(echo "$content" | jq -r '.policyDefinitionId // empty' 2>/dev/null || true)"
    if [[ "$def_id" == *"policySetDefinitions"* ]]; then
        name="$(echo "$def_id" | sed 's|.*/||')"
        short="$(echo "$content" | jq -r '.assignment.name // .name // empty' 2>/dev/null || echo "$name")"
        if echo "$def_id" | grep -q "/providers/Microsoft.Authorization/"; then
            policy_sets="$(echo "$policy_sets" | jq --arg id "$def_id" --arg sn "$short" '. + [{"id": $id, "shortName": $sn}]')"
        else
            policy_sets="$(echo "$policy_sets" | jq --arg n "$name" --arg sn "$short" '. + [{"name": $n, "shortName": $sn}]')"
        fi
    fi
done < <(find "$assignments_dir" -type f \( -name '*.json' -o -name '*.jsonc' \) -print0 2>/dev/null)

# Deduplicate and sort
policy_sets="$(echo "$policy_sets" | jq 'unique_by(.shortName) | sort_by(.shortName)')"

if [[ "$(echo "$policy_sets" | jq 'length')" -gt 0 ]]; then
    doc_template="$(echo "$doc_template" | jq --argjson ps "$policy_sets" '.documentPolicySets[0].policySets = $ps')"
fi

# Write output
output_file="${output_dir}/${file_name_stem}.jsonc"
echo "$doc_template" | jq '.' > "$output_file"
echo "Documentation template written to: $output_file"
