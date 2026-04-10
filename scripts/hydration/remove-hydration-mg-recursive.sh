#!/usr/bin/env bash
# scripts/hydration/remove-hydration-mg-recursive.sh
# Recursively remove a management group hierarchy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-mg.sh"

usage() {
    cat <<'EOF'
Usage: remove-hydration-mg-recursive.sh --name <MG_NAME> [--force]

Recursively remove a management group and all children.

Required:
  --name    Management group name to remove

Options:
  --force   Skip confirmation prompt
  --help    Show this help message

WARNING: This is destructive and cannot be undone.
EOF
    exit 0
}

mg_name="" force=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --name) mg_name="$2"; shift 2 ;;
        --force) force=true; shift ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$mg_name" ]] && { epac_log_error "Missing --name"; exit 1; }

if [[ "$force" != "true" ]]; then
    echo "WARNING: This will recursively delete management group '$mg_name' and ALL children."
    read -r -p "Type the management group name to confirm: " confirm
    if [[ "$confirm" != "$mg_name" ]]; then
        echo "Confirmation failed. Aborting."
        exit 1
    fi
fi

hydration_remove_mg_recursive "$mg_name"
echo "Management group '$mg_name' and children removed."
