#!/usr/bin/env bash
# scripts/hydration/test-hydration-mg-name.sh
# Validate management group name format
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-core.sh"

usage() {
    cat <<'EOF'
Usage: test-hydration-mg-name.sh --name <NAME>

Validate that a management group name meets Azure naming requirements:
  - Alphanumeric, hyphens, underscores, periods only
  - Maximum 90 characters

Options:
  --name    Management group name to validate (can be repeated)
  --help    Show this help message
EOF
    exit 0
}

declare -a names=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --name) names+=("$2"); shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ ${#names[@]} -eq 0 ]] && { epac_log_error "Missing --name"; exit 1; }

failures=0
for name in "${names[@]}"; do
    if hydration_validate_mg_name "$name"; then
        echo "'$name': valid"
    else
        echo "'$name': INVALID"
        failures=$((failures + 1))
    fi
done

exit "$failures"
