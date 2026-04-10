#!/usr/bin/env bash
# scripts/hydration/new-filtered-exception-file.sh
# Filter exemptions CSV by relevant policy assignments
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-definitions.sh"

usage() {
    cat <<'EOF'
Usage: new-filtered-exception-file.sh --exemptions-csv <PATH> [OPTIONS]

Filter an exemptions CSV to only include exemptions for relevant
policy assignments found in the Definitions folder.

Required:
  --exemptions-csv    Path to the exemptions CSV file

Options:
  --definitions       Path to Definitions folder (default: ./Definitions)
  --output            Path to Output folder (default: ./Output)
  --help              Show this help message
EOF
    exit 0
}

csv="" definitions="./Definitions" output="./Output"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --exemptions-csv) csv="$2"; shift 2 ;;
        --definitions) definitions="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$csv" ]] && { epac_log_error "Missing --exemptions-csv"; exit 1; }
[[ ! -f "$csv" ]] && { epac_log_error "File not found: $csv"; exit 1; }

hydration_filter_exemptions "$csv" "$definitions" "$output"
