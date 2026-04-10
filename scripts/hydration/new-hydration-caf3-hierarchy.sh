#!/usr/bin/env bash
# scripts/hydration/new-hydration-caf3-hierarchy.sh
# Create a CAF 3.0 management group hierarchy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-mg.sh"

usage() {
    cat <<'EOF'
Usage: new-hydration-caf3-hierarchy.sh --parent <MG_NAME> [OPTIONS]

Create a Cloud Adoption Framework 3.0 management group hierarchy.

Required:
  --parent     Parent management group name (intermediate root)

Options:
  --prefix     Prefix for each child MG name
  --suffix     Suffix for each child MG name
  --help       Show this help message
EOF
    exit 0
}

parent="" prefix="" suffix=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --parent) parent="$2"; shift 2 ;;
        --prefix) prefix="$2"; shift 2 ;;
        --suffix) suffix="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$parent" ]] && { epac_log_error "Missing --parent"; exit 1; }

hydration_create_caf3 "$parent" "$prefix" "$suffix"
echo "CAF 3.0 hierarchy created under '$parent'."
