#!/usr/bin/env bash
# scripts/hydration/new-hydration-assignment-pac-selector.sh
# Clone assignment files for a new PAC selector with scope remapping
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-definitions.sh"

usage() {
    cat <<'EOF'
Usage: new-hydration-assignment-pac-selector.sh --source <SELECTOR> --new <SELECTOR> [OPTIONS]

Clone assignment files from a source PAC selector to a new one,
remapping management group scopes with optional prefix/suffix.

Required:
  --source       Source PAC selector name
  --new          New PAC selector name

Options:
  --definitions  Path to Definitions folder (default: ./Definitions)
  --output       Path to Output folder (default: ./Output)
  --prefix       MG hierarchy prefix for the new selector
  --suffix       MG hierarchy suffix for the new selector
  --help         Show this help message

Note: Subscription and resource group scopes cannot be duplicated
      due to GUID uniqueness requirements.
EOF
    exit 0
}

source_pac="" new_pac="" definitions="./Definitions" output="./Output" prefix="" suffix=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --source) source_pac="$2"; shift 2 ;;
        --new) new_pac="$2"; shift 2 ;;
        --definitions) definitions="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --prefix) prefix="$2"; shift 2 ;;
        --suffix) suffix="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$source_pac" ]] && { epac_log_error "Missing --source"; exit 1; }
[[ -z "$new_pac" ]] && { epac_log_error "Missing --new"; exit 1; }

hydration_clone_assignments "$source_pac" "$new_pac" "$definitions" "$output" "$prefix" "$suffix"
echo "Assignment files cloned from '$source_pac' to '$new_pac'."
