#!/usr/bin/env bash
# scripts/hydration/test-hydration-path.sh
# Test and optionally create local filesystem paths
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-tests.sh"

usage() {
    cat <<'EOF'
Usage: test-hydration-path.sh --path <PATH> [--log-file <PATH>]

Test that a path exists or can be created.

Required:
  --path       Path to test (can be repeated)

Options:
  --log-file   Log file path
  --help       Show this help message
EOF
    exit 0
}

declare -a paths=()
log_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --path) paths+=("$2"); shift 2 ;;
        --log-file) log_file="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ ${#paths[@]} -eq 0 ]] && { epac_log_error "Missing --path"; exit 1; }

failures=0
for p in "${paths[@]}"; do
    result="$(hydration_test_path "$p" "$log_file")"
    if [[ "$result" == *"Failed"* || "$result" == *"Error"* ]]; then
        echo -e "\033[31m${p}: FAILED\033[0m"
        failures=$((failures + 1))
    else
        echo -e "\033[32m${p}: OK\033[0m"
    fi
done

exit "$failures"
