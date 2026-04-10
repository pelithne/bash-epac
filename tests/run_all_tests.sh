#!/usr/bin/env bash
# tests/run_all_tests.sh — CI test runner for EPAC bash test suite
#
# Usage:
#   ./tests/run_all_tests.sh              # run all tests
#   ./tests/run_all_tests.sh test_core    # run specific test(s) by name
#   ./tests/run_all_tests.sh --parallel   # run tests in parallel (faster, interleaved output)
#   ./tests/run_all_tests.sh --list       # list available test files
#   ./tests/run_all_tests.sh --ci         # CI mode: no color, exit code for pass/fail
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ───────────────────────────────────────────────────
PARALLEL=false
CI_MODE=false
LIST_ONLY=false
FILTER=()

# Colors (disabled in CI mode or when not a terminal)
if [[ -t 1 ]] && [[ "${CI_MODE}" == "false" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
fi

# ── Argument Parsing ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --parallel|-p) PARALLEL=true; shift ;;
        --ci)
            CI_MODE=true
            RED='' GREEN='' YELLOW='' CYAN='' BOLD='' NC=''
            shift
            ;;
        --list|-l) LIST_ONLY=true; shift ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS] [TEST_NAMES...]"
            echo ""
            echo "Options:"
            echo "  --parallel, -p  Run tests in parallel"
            echo "  --ci            CI mode (no color, machine-readable output)"
            echo "  --list, -l      List available test files"
            echo "  --help, -h      Show this help"
            echo ""
            echo "Examples:"
            echo "  $0                         # run all tests"
            echo "  $0 test_core test_config   # run specific tests"
            echo "  $0 --ci                    # CI mode"
            exit 0
            ;;
        *)
            FILTER+=("$1")
            shift
            ;;
    esac
done

# ── Discover Test Files ─────────────────────────────────────────────
discover_tests() {
    local tests=()
    for f in "$SCRIPT_DIR"/test_*.sh; do
        local name
        name="$(basename "$f" .sh)"
        # Skip test_helpers.sh — it's a library, not a test
        [[ "$name" == "test_helpers" ]] && continue
        tests+=("$f")
    done
    echo "${tests[@]}"
}

filter_tests() {
    local all_tests=("$@")
    if [[ ${#FILTER[@]} -eq 0 ]]; then
        echo "${all_tests[@]}"
        return
    fi
    local filtered=()
    for t in "${all_tests[@]}"; do
        local name
        name="$(basename "$t" .sh)"
        for f in "${FILTER[@]}"; do
            # Match by name with or without test_ prefix and .sh suffix
            local match_name="${f%.sh}"
            match_name="${match_name#test_}"
            if [[ "$name" == "test_${match_name}" ]] || [[ "$name" == "$f" ]]; then
                filtered+=("$t")
                break
            fi
        done
    done
    echo "${filtered[@]}"
}

# ── List Mode ───────────────────────────────────────────────────────
if [[ "$LIST_ONLY" == "true" ]]; then
    echo "Available test files:"
    for f in $(discover_tests); do
        name="$(basename "$f" .sh)"
        lines="$(wc -l < "$f")"
        printf "  %-35s (%s lines)\n" "$name" "$lines"
    done
    exit 0
fi

# ── Run Tests ───────────────────────────────────────────────────────
ALL_TESTS=($(discover_tests))
SELECTED_TESTS=($(filter_tests "${ALL_TESTS[@]}"))

if [[ ${#SELECTED_TESTS[@]} -eq 0 ]]; then
    echo "No test files matched the filter: ${FILTER[*]}"
    exit 1
fi

echo -e "${BOLD}EPAC Bash Test Suite${NC}"
echo "════════════════════════════════════════════════════════════"
echo "Running ${#SELECTED_TESTS[@]} test file(s)..."
echo ""

# Results tracking
declare -A RESULTS       # test_name -> "PASS" or "FAIL"
declare -A TEST_COUNTS   # test_name -> "passed/total"
declare -A DURATIONS     # test_name -> seconds
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_TESTS=0
OVERALL_START=$SECONDS

run_single_test() {
    local test_file="$1"
    local name
    name="$(basename "$test_file" .sh)"

    local start=$SECONDS
    local output rc=0
    set +eo pipefail
    output="$(bash "$test_file" 2>&1)"
    rc=$?
    local duration=$((SECONDS - start))

    # Parse results from output — look for common summary patterns
    local passed=0 failed=0 total=0
    # Pattern 1: "Tests: N | Passed: N | Failed: N"
    if echo "$output" | grep -qE "Tests: [0-9]+ \| Passed: [0-9]+ \| Failed: [0-9]+"; then
        passed=$(echo "$output" | grep -oE "Passed: [0-9]+" | tail -1 | grep -oE "[0-9]+")
        failed=$(echo "$output" | grep -oE "Failed: [0-9]+" | tail -1 | grep -oE "[0-9]+")
        total=$((passed + failed))
    # Pattern 2: "Results: N passed, N failed"
    elif echo "$output" | grep -qE "Results: [0-9]+ passed, [0-9]+ failed"; then
        passed=$(echo "$output" | grep -oE "[0-9]+ passed" | tail -1 | grep -oE "[0-9]+")
        failed=$(echo "$output" | grep -oE "[0-9]+ failed" | tail -1 | grep -oE "[0-9]+")
        total=$((passed + failed))
    # Pattern 3: "Passed: N/N"
    elif echo "$output" | grep -qE "Passed: [0-9]+/[0-9]+"; then
        passed=$(echo "$output" | grep -oE "Passed: [0-9]+" | tail -1 | grep -oE "[0-9]+")
        total=$(echo "$output" | grep -oE "Passed: [0-9]+/[0-9]+" | tail -1 | grep -oE "/[0-9]+" | tr -d '/')
        failed=$((total - passed))
    # Pattern 4: "Total: N" + "Passed: N" + "Failed: N"
    elif echo "$output" | grep -qE "Total:[[:space:]]+[0-9]+"; then
        total=$(echo "$output" | grep -oE "Total:[[:space:]]+[0-9]+" | tail -1 | grep -oE "[0-9]+")
        passed=$(echo "$output" | grep -oE "Pass(ed)?:[[:space:]]+[0-9]+" | tail -1 | grep -oE "[0-9]+")
        failed=$(echo "$output" | grep -oE "Fail(ed)?:[[:space:]]+[0-9]+" | tail -1 | grep -oE "[0-9]+")
    # Fallback: count PASS/FAIL lines
    else
        passed=$(echo "$output" | grep -c "  PASS:" || true)
        failed=$(echo "$output" | grep -c "  FAIL:" || true)
        total=$((passed + failed))
    fi

    # Determine status
    local status="PASS"
    if [[ "$rc" -ne 0 ]] || [[ "$failed" -gt 0 ]]; then
        status="FAIL"
    fi

    # Output result line
    if [[ "$status" == "PASS" ]]; then
        printf "  ${GREEN}✓${NC} %-40s %3d passed              ${CYAN}(%ds)${NC}\n" "$name" "$passed" "$duration"
    else
        printf "  ${RED}✗${NC} %-40s %3d passed, ${RED}%d failed${NC}   ${CYAN}(%ds)${NC}\n" "$name" "$passed" "$failed" "$duration"
        # Show failure details
        echo "$output" | grep "  FAIL:" | head -10 | sed 's/^/      /'
    fi

    # Store results
    RESULTS[$name]="$status"
    TEST_COUNTS[$name]="${passed}/${total}"
    DURATIONS[$name]="$duration"
    TOTAL_PASS=$((TOTAL_PASS + passed))
    TOTAL_FAIL=$((TOTAL_FAIL + failed))
    TOTAL_TESTS=$((TOTAL_TESTS + total))
    set -eo pipefail
}

if [[ "$PARALLEL" == "true" ]]; then
    # Parallel mode — run all tests as background jobs and collect output
    TMPDIR_RESULTS="$(mktemp -d)"
    trap 'rm -rf "$TMPDIR_RESULTS"' EXIT

    for test_file in "${SELECTED_TESTS[@]}"; do
        name="$(basename "$test_file" .sh)"
        (
            start=$SECONDS
            output="$(bash "$test_file" 2>&1)" || true
            duration=$((SECONDS - start))
            echo "$output" > "$TMPDIR_RESULTS/${name}.out"
            echo "$duration" > "$TMPDIR_RESULTS/${name}.dur"
        ) &
    done
    wait

    # Process results
    set +eo pipefail
    for test_file in "${SELECTED_TESTS[@]}"; do
        name="$(basename "$test_file" .sh)"
        output="$(cat "$TMPDIR_RESULTS/${name}.out")"
        duration="$(cat "$TMPDIR_RESULTS/${name}.dur")"

        passed=0 failed=0 total=0
        if echo "$output" | grep -qE "Tests: [0-9]+ \| Passed: [0-9]+ \| Failed: [0-9]+"; then
            passed=$(echo "$output" | grep -oE "Passed: [0-9]+" | tail -1 | grep -oE "[0-9]+")
            failed=$(echo "$output" | grep -oE "Failed: [0-9]+" | tail -1 | grep -oE "[0-9]+")
            total=$((passed + failed))
        elif echo "$output" | grep -qE "Results: [0-9]+ passed, [0-9]+ failed"; then
            passed=$(echo "$output" | grep -oE "[0-9]+ passed" | tail -1 | grep -oE "[0-9]+")
            failed=$(echo "$output" | grep -oE "[0-9]+ failed" | tail -1 | grep -oE "[0-9]+")
            total=$((passed + failed))
        elif echo "$output" | grep -qE "Passed: [0-9]+/[0-9]+"; then
            passed=$(echo "$output" | grep -oE "Passed: [0-9]+" | tail -1 | grep -oE "[0-9]+")
            total=$(echo "$output" | grep -oE "Passed: [0-9]+/[0-9]+" | tail -1 | grep -oE "/[0-9]+" | tr -d '/')
            failed=$((total - passed))
        elif echo "$output" | grep -qE "Total:[[:space:]]+[0-9]+"; then
            total=$(echo "$output" | grep -oE "Total:[[:space:]]+[0-9]+" | tail -1 | grep -oE "[0-9]+")
            passed=$(echo "$output" | grep -oE "Pass(ed)?:[[:space:]]+[0-9]+" | tail -1 | grep -oE "[0-9]+")
            failed=$(echo "$output" | grep -oE "Fail(ed)?:[[:space:]]+[0-9]+" | tail -1 | grep -oE "[0-9]+")
        else
            passed=$(echo "$output" | grep -c "  PASS:" || true)
            failed=$(echo "$output" | grep -c "  FAIL:" || true)
            total=$((passed + failed))
        fi

        status="PASS"
        [[ "$failed" -gt 0 ]] && status="FAIL"

        if [[ "$status" == "PASS" ]]; then
            printf "  ${GREEN}✓${NC} %-40s %3d passed              ${CYAN}(%ds)${NC}\n" "$name" "$passed" "$duration"
        else
            printf "  ${RED}✗${NC} %-40s %3d passed, ${RED}%d failed${NC}   ${CYAN}(%ds)${NC}\n" "$name" "$passed" "$failed" "$duration"
            echo "$output" | grep "  FAIL:" | head -10 | sed 's/^/      /'
        fi

        TOTAL_PASS=$((TOTAL_PASS + passed))
        TOTAL_FAIL=$((TOTAL_FAIL + failed))
        TOTAL_TESTS=$((TOTAL_TESTS + total))
    done
    set -eo pipefail
else
    # Sequential mode
    for test_file in "${SELECTED_TESTS[@]}"; do
        run_single_test "$test_file"
    done
fi

# ── Summary ─────────────────────────────────────────────────────────
OVERALL_DURATION=$((SECONDS - OVERALL_START))

echo ""
echo "════════════════════════════════════════════════════════════"
if [[ "$TOTAL_FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}ALL TESTS PASSED${NC}"
else
    echo -e "${RED}${BOLD}SOME TESTS FAILED${NC}"
fi
echo "────────────────────────────────────────────────────────────"
echo "  Files:  ${#SELECTED_TESTS[@]}"
echo "  Tests:  $TOTAL_TESTS"
echo "  Passed: $TOTAL_PASS"
echo "  Failed: $TOTAL_FAIL"
echo "  Time:   ${OVERALL_DURATION}s"
echo "════════════════════════════════════════════════════════════"

# CI exit code
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
