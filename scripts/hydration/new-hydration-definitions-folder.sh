#!/usr/bin/env bash
# scripts/hydration/new-hydration-definitions-folder.sh
# Create the standard EPAC definitions directory structure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-definitions.sh"

usage() {
    cat <<'EOF'
Usage: new-hydration-definitions-folder.sh [--path <PATH>]

Create the standard EPAC definitions directory structure.

Options:
  --path    Path for the definitions folder (default: ./Definitions)
  --help    Show this help message
EOF
    exit 0
}

path="./Definitions"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --path) path="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

hydration_create_definitions_folder "$path"
echo "Created definitions folder structure at '$path'."
