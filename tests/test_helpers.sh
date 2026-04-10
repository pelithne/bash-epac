#!/usr/bin/env bash
# tests/test_helpers.sh — Shared test assertion library for EPAC bash tests
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"
#   ... run assertions ...
#   test_summary  # prints results and exits with appropriate code
#
# Counters: TESTS, PASS, FAIL are global integers.
# Each assert_* function increments TESTS and either PASS or FAIL.

[[ -n "${_EPAC_TEST_HELPERS_LOADED:-}" ]] && return 0
_EPAC_TEST_HELPERS_LOADED=1

# ── Counters ────────────────────────────────────────────────────────
TESTS=0
PASS=0
FAIL=0

# ── Core Assertions ─────────────────────────────────────────────────

# assert_eq DESC EXPECTED ACTUAL
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected='$expected', got='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# assert_true DESC COMMAND [ARGS...]
assert_true() {
    local desc="$1"; shift
    TESTS=$((TESTS + 1))
    if "$@" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected true)"
        FAIL=$((FAIL + 1))
    fi
}

# assert_false DESC COMMAND [ARGS...]
assert_false() {
    local desc="$1"; shift
    TESTS=$((TESTS + 1))
    if "$@" 2>/dev/null; then
        echo "  FAIL: $desc (expected false)"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# assert_contains DESC HAYSTACK NEEDLE
assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TESTS=$((TESTS + 1))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (doesn't contain '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

# assert_not_contains DESC HAYSTACK NEEDLE
assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    TESTS=$((TESTS + 1))
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (should not contain '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

# assert_rc DESC EXPECTED_RC COMMAND [ARGS...]
assert_rc() {
    local desc="$1" expected_rc="$2"; shift 2
    TESTS=$((TESTS + 1))
    local rc=0
    "$@" 2>/dev/null || rc=$?
    if [[ "$rc" -eq "$expected_rc" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected rc=$expected_rc, got rc=$rc)"
        FAIL=$((FAIL + 1))
    fi
}

# ── File/Directory Assertions ───────────────────────────────────────

# assert_file_exists DESC PATH
assert_file_exists() {
    local desc="$1" path="$2"
    TESTS=$((TESTS + 1))
    if [[ -f "$path" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (file not found: $path)"
        FAIL=$((FAIL + 1))
    fi
}

# assert_dir_exists DESC PATH
assert_dir_exists() {
    local desc="$1" path="$2"
    TESTS=$((TESTS + 1))
    if [[ -d "$path" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (dir not found: $path)"
        FAIL=$((FAIL + 1))
    fi
}

# ── Pattern Matching Assertions ─────────────────────────────────────

# assert_match DESC FILE PATTERN — grep -iE match in file
assert_match() {
    local desc="$1" file="$2" pattern="$3"
    TESTS=$((TESTS + 1))
    if grep -qiE "$pattern" "$file" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (no match for '$pattern')"
        FAIL=$((FAIL + 1))
    fi
}

# assert_no_match DESC FILE PATTERN — grep -iE should NOT match
assert_no_match() {
    local desc="$1" file="$2" pattern="$3"
    TESTS=$((TESTS + 1))
    if grep -qiE "$pattern" "$file" 2>/dev/null; then
        local count
        count=$(grep -ciE "$pattern" "$file" 2>/dev/null || true)
        echo "  FAIL: $desc ($count matches of '$pattern')"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    fi
}

# ── JSON Assertions ─────────────────────────────────────────────────

# assert_json_eq DESC JSON JQ_QUERY EXPECTED
assert_json_eq() {
    local desc="$1" json="$2" query="$3" expected="$4"
    TESTS=$((TESTS + 1))
    local actual
    actual="$(echo "$json" | jq -r "$query" 2>/dev/null)" || actual="ERROR"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected='$expected', got='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

# assert_json_field DESC JSON FIELD EXPECTED (alias for assert_json_eq)
assert_json_field() {
    local desc="$1" json="$2" field="$3" expected="$4"
    local actual
    actual="$(echo "$json" | jq -r "$field" 2>/dev/null || echo "ERROR")"
    assert_eq "$desc" "$expected" "$actual"
}

# assert_json_count DESC JSON JQ_PATH EXPECTED_COUNT
assert_json_count() {
    local desc="$1" json="$2" path="$3" expected="$4"
    TESTS=$((TESTS + 1))
    local actual
    actual="$(echo "$json" | jq "$path | length" 2>/dev/null)" || actual="ERROR"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected count=$expected, got=$actual)"
        FAIL=$((FAIL + 1))
    fi
}

# assert_valid_json DESC FILE_PATH
assert_valid_json() {
    local desc="$1" path="$2"
    TESTS=$((TESTS + 1))
    if jq '.' "$path" &>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    elif type -t epac_read_jsonc &>/dev/null && epac_read_jsonc "$path" &>/dev/null; then
        echo "  PASS: $desc (JSONC)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (invalid JSON/JSONC)"
        FAIL=$((FAIL + 1))
    fi
}

# ── YAML Assertion ──────────────────────────────────────────────────

# assert_valid_yaml DESC FILE_PATH
assert_valid_yaml() {
    local desc="$1" path="$2"
    TESTS=$((TESTS + 1))
    if [[ -f "$path" ]] && [[ -s "$path" ]]; then
        if grep -Pq '\t' "$path"; then
            echo "  FAIL: $desc (contains tabs)"
            FAIL=$((FAIL + 1))
        else
            echo "  PASS: $desc"
            PASS=$((PASS + 1))
        fi
    else
        echo "  FAIL: $desc (empty or missing)"
        FAIL=$((FAIL + 1))
    fi
}

# ── Test Lifecycle ──────────────────────────────────────────────────

# test_summary — Print results and exit with code 0 (all pass) or 1 (any fail)
test_summary() {
    local label="${1:-SUMMARY}"
    echo ""
    echo "================================="
    echo "Tests: $TESTS | Passed: $PASS | Failed: $FAIL"
    echo "================================="
    [[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
}

# setup_test_tmp — Create a temporary directory and register cleanup
# Sets TEST_TMP to the created directory path
setup_test_tmp() {
    TEST_TMP="$(mktemp -d)"
    trap 'rm -rf "$TEST_TMP"' EXIT
}
