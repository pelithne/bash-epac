#!/usr/bin/env bash
# scripts/hydration/test-hydration-rbac.sh
# Test RBAC permissions at a given scope
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-tests.sh"

usage() {
    cat <<'EOF'
Usage: test-hydration-rbac.sh --scope <SCOPE> [--role <ROLE>] [--log-file <PATH>]

Test RBAC permissions at a given Azure scope.

Required:
  --scope      Azure resource scope to check

Options:
  --role       Specific role to verify
  --log-file   Log file path
  --help       Show this help message
EOF
    exit 0
}

scope="" role="" log_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --scope) scope="$2"; shift 2 ;;
        --role) role="$2"; shift 2 ;;
        --log-file) log_file="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$scope" ]] && { epac_log_error "Missing --scope"; exit 1; }

hydration_test_rbac "$scope" "$role" "$log_file"
