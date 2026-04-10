#!/usr/bin/env bash
# scripts/operations/get-az-exemptions.sh
# Replaces: Get-AzExemptions.ps1
# Retrieves Policy Exemptions from an EPAC environment and saves them to files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

# ─── Argument parsing ──────────────────────────────────────────────────────
pac_selector=""
definitions_root=""
output_folder=""
interactive=true
file_extension="json"
active_only=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pac-selector|-p) pac_selector="$2"; shift 2 ;;
        --definitions-root|-d) definitions_root="$2"; shift 2 ;;
        --output-folder|-o) output_folder="$2"; shift 2 ;;
        --non-interactive) interactive=false; shift ;;
        --file-extension) file_extension="$2"; shift 2 ;;
        --active-only) active_only=true; shift ;;
        --help|-h)
            echo "Usage: $(basename "$0") [--pac-selector <env>] [--definitions-root <path>]"
            echo "  [--output-folder <path>] [--non-interactive] [--file-extension json|jsonc]"
            echo "  [--active-only]"
            echo ""
            echo "  Retrieves Policy Exemptions and saves them to files."
            exit 0
            ;;
        *) shift ;;
    esac
done

# ─── Init ───────────────────────────────────────────────────────────────────
pac_env="$(epac_select_pac_environment "$pac_selector" "$definitions_root" "$output_folder" "$interactive")"
epac_set_cloud_tenant_subscription "$pac_env"

pac_output_folder="$(echo "$pac_env" | jq -r '.outputFolder')"
exemptions_folder="${pac_output_folder}/policyExemptions"

epac_write_header "Retrieving Policy Exemptions" "$(echo "$pac_env" | jq -r '.displayName // .pacSelector')"

# Build scope table and get policy resources
epac_write_section "Loading Azure Policy Resources"
scope_table="$(epac_build_scope_table "$pac_env")"
deployed="$(epac_get_policy_resources "$pac_env" "$scope_table" --skip-role-assignments)"

# Extract managed exemptions
exemptions="$(echo "$deployed" | jq '.policyExemptions.managed // {}')"
exemption_count="$(echo "$exemptions" | jq 'length')"
epac_write_status "Found $exemption_count exemptions" "info" 2

# Convert to array for output
exemption_values="$(echo "$exemptions" | jq '[.[] | .properties + {name: .name, id: .id}]')"

# Output
epac_write_section "Generating Exemption Reports"

output_flags=()
output_flags+=(--json --csv --file-extension "$file_extension")
if $active_only; then
    output_flags+=(--active-only)
fi

epac_out_policy_exemptions "$exemption_values" "$pac_env" "$exemptions_folder" "${output_flags[@]}"

epac_write_status "Complete" "success" 0
