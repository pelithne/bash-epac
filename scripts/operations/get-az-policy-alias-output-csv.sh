#!/usr/bin/env bash
# scripts/operations/get-az-policy-alias-output-csv.sh
# Replaces: Get-AzPolicyAliasOutputCSV.ps1
# Exports all Azure Policy aliases to a CSV file.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/epac.sh"

# ─── Argument parsing ──────────────────────────────────────────────────────
output_file="FullAliasesOutput.csv"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-file|-o) output_file="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $(basename "$0") [--output-file <path>]"
            echo "  Exports all Azure Policy aliases to CSV."
            echo "  Default output: FullAliasesOutput.csv"
            exit 0
            ;;
        *) shift ;;
    esac
done

epac_write_section "Exporting Azure Policy Aliases"

# Query all provider aliases via Azure CLI
epac_write_status "Querying Azure Policy aliases..." "info" 2
aliases_json="$(az provider list --expand 'resourceTypes/aliases' --query '
    [].resourceTypes[].{
        namespace: (join(`/`, [providerNamespace || @, resourceType || @])),
        aliases: aliases[].name
    }
    | [?aliases]
' -o json 2>/dev/null || echo '[]')"

# Build CSV
epac_write_status "Building CSV..." "info" 2
printf '"namespace","resourcetype","propertyAlias"\n' > "$output_file"

echo "$aliases_json" | jq -r '
    .[] |
    .namespace as $ns |
    ($ns | split("/")[0]) as $namespace |
    ($ns | split("/")[1:] | join("/")) as $rt |
    .aliases[] |
    def csv_esc: tostring | if test(",|\"|\n") then "\"" + gsub("\""; "\"\"") + "\"" else . end;
    [($namespace | csv_esc), ($rt | csv_esc), (. | csv_esc)] | join(",")
' >> "$output_file"

row_count="$(tail -n +2 "$output_file" | wc -l | tr -d ' ')"
epac_write_status "Exported $row_count aliases to $output_file" "success" 2
