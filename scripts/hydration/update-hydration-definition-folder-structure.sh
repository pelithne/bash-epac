#!/usr/bin/env bash
# scripts/hydration/update-hydration-definition-folder-structure.sh
# Reorganize definitions into subfolders by assignment ownership
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-definitions.sh"

usage() {
    cat <<'EOF'
Usage: update-hydration-definition-folder-structure.sh --folder-order <JSON> [OPTIONS]

Reorganize policyDefinitions and policySetDefinitions folders
into subfolders based on their assignment ownership.

Required:
  --folder-order   JSON object mapping folder names to assignment categories
                   Example: '{"SecurityOperations":"security","PlatformOps":"platform"}'

Options:
  --definitions    Path to Definitions folder (default: ./Definitions)
  --output         Path to Output folder (default: ./Output)
  --help           Show this help message
EOF
    exit 0
}

folder_order="" definitions="./Definitions" output="./Output"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --folder-order) folder_order="$2"; shift 2 ;;
        --definitions) definitions="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$folder_order" ]] && { epac_log_error "Missing --folder-order"; exit 1; }

# Validate JSON
if ! echo "$folder_order" | jq '.' >/dev/null 2>&1; then
    epac_log_error "Invalid JSON for --folder-order"
    exit 1
fi

hydration_reorganize_definitions "$definitions" "$output" "$folder_order"
