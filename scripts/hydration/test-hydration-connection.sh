#!/usr/bin/env bash
# scripts/hydration/test-hydration-connection.sh
# Test network connectivity to required Azure endpoints
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-tests.sh"

usage() {
    cat <<'EOF'
Usage: test-hydration-connection.sh [--host <HOSTNAME>] [--log-file <PATH>]

Test network connectivity to required Azure endpoints.

Options:
  --host       Specific host to test (can be repeated)
  --log-file   Log file path
  --help       Show this help message

If no --host is specified, tests: www.github.com, management.azure.com,
login.microsoftonline.com
EOF
    exit 0
}

declare -a hosts=()
log_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --host) hosts+=("$2"); shift 2 ;;
        --log-file) log_file="$2"; shift 2 ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ ${#hosts[@]} -eq 0 ]]; then
    hosts=("www.github.com" "management.azure.com" "login.microsoftonline.com")
fi

failures=0
for host in "${hosts[@]}"; do
    result="$(hydration_test_connection "$host" "$log_file" 2>/dev/null || echo "Failed")"
    if [[ "$result" == *"Failed"* ]]; then
        echo -e "\033[31m${host}: FAILED\033[0m"
        failures=$((failures + 1))
    else
        echo -e "\033[32m${host}: OK\033[0m"
    fi
done

exit "$failures"
