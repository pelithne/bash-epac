#!/usr/bin/env bash
# scripts/hydration/copy-hydration-mg-hierarchy.sh
# Clone an existing management group hierarchy with optional prefix/suffix
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-mg.sh"

usage() {
    cat <<'EOF'
Usage: copy-hydration-mg-hierarchy.sh --source <MG_NAME> --target-parent <MG_ID> [OPTIONS]

Clone a management group hierarchy under a new parent.

Required:
  --source          Source management group name to clone
  --target-parent   Parent MG ID (usually tenant ID) for the cloned hierarchy

Options:
  --prefix          Prefix for cloned MG names
  --suffix          Suffix for cloned MG names
  --help            Show this help message
EOF
    exit 0
}

source_mg="" target_parent="" prefix="" suffix=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --source) source_mg="$2"; shift 2 ;;
        --target-parent) target_parent="$2"; shift 2 ;;
        --prefix) prefix="$2"; shift 2 ;;
        --suffix) suffix="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$source_mg" ]] && { epac_log_error "Missing --source"; exit 1; }
[[ -z "$target_parent" ]] && { epac_log_error "Missing --target-parent"; exit 1; }

hydration_copy_mg_hierarchy "$source_mg" "$target_parent" "$prefix" "$suffix"
echo "Hierarchy cloned from '$source_mg' with prefix='$prefix' suffix='$suffix'."
