#!/usr/bin/env bash
# tests/test_framework.sh — Tests for the EPAC test framework infrastructure
#
# Validates:
# - test_helpers.sh shared assertion library
# - run_all_tests.sh test runner
# - Test file conventions and structure
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Self-contained assertions (can't use test_helpers for testing itself) ──
_PASS=0
_FAIL=0

_assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        _PASS=$((_PASS + 1))
    else
        echo "  FAIL: $desc (expected='$expected', got='$actual')"
        _FAIL=$((_FAIL + 1))
    fi
}

_assert_true() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then
        echo "  PASS: $desc"
        _PASS=$((_PASS + 1))
    else
        echo "  FAIL: $desc (expected true)"
        _FAIL=$((_FAIL + 1))
    fi
}

_assert_false() {
    local desc="$1"; shift
    if "$@" 2>/dev/null; then
        echo "  FAIL: $desc (expected false)"
        _FAIL=$((_FAIL + 1))
    else
        echo "  PASS: $desc"
        _PASS=$((_PASS + 1))
    fi
}

_assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  PASS: $desc"
        _PASS=$((_PASS + 1))
    else
        echo "  FAIL: $desc (doesn't contain '$needle')"
        _FAIL=$((_FAIL + 1))
    fi
}

_assert_file_exists() {
    local desc="$1" path="$2"
    if [[ -f "$path" ]]; then
        echo "  PASS: $desc"
        _PASS=$((_PASS + 1))
    else
        echo "  FAIL: $desc (file not found: $path)"
        _FAIL=$((_FAIL + 1))
    fi
}

# ═══════════════════════════════════════════════════════════════════
echo "=== Test Helpers Library ==="
# ═══════════════════════════════════════════════════════════════════

echo "--- test_helpers.sh exists and is sourceable ---"
_assert_file_exists "test_helpers.sh exists" "$SCRIPT_DIR/test_helpers.sh"

# Source test_helpers.sh in a subshell to test it without affecting our counters
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    echo "LOADED:${_EPAC_TEST_HELPERS_LOADED}"
    echo "TESTS:${TESTS}"
    echo "PASS:${PASS}"
    echo "FAIL:${FAIL}"
' 2>&1)"
_assert_contains "guard variable set" "$output" "LOADED:1"
_assert_contains "TESTS initialized to 0" "$output" "TESTS:0"
_assert_contains "PASS initialized to 0" "$output" "PASS:0"
_assert_contains "FAIL initialized to 0" "$output" "FAIL:0"

echo "--- assert_eq works ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_eq "match test" "hello" "hello"
    assert_eq "mismatch test" "hello" "world"
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
_assert_contains "assert_eq pass" "$output" "PASS: match test"
_assert_contains "assert_eq fail" "$output" "FAIL: mismatch test"
_assert_contains "counters correct" "$output" "RESULTS:1:1:2"

echo "--- assert_true works ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_true "true test" true
    assert_true "false test" false
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
_assert_contains "assert_true pass" "$output" "PASS: true test"
_assert_contains "assert_true fail" "$output" "FAIL: false test"
_assert_contains "counters correct" "$output" "RESULTS:1:1:2"

echo "--- assert_false works ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_false "false test" false
    assert_false "true test" true
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
_assert_contains "assert_false pass" "$output" "PASS: false test"
_assert_contains "assert_false fail" "$output" "FAIL: true test"
_assert_contains "counters correct" "$output" "RESULTS:1:1:2"

echo "--- assert_contains works ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_contains "has needle" "hello world" "world"
    assert_contains "no needle" "hello world" "xyz"
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
_assert_contains "assert_contains pass" "$output" "PASS: has needle"
_assert_contains "assert_contains fail" "$output" "FAIL: no needle"
_assert_contains "counters correct" "$output" "RESULTS:1:1:2"

echo "--- assert_not_contains works ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_not_contains "absent" "hello" "xyz"
    assert_not_contains "present" "hello" "ell"
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
_assert_contains "assert_not_contains pass" "$output" "PASS: absent"
_assert_contains "assert_not_contains fail" "$output" "FAIL: present"
_assert_contains "counters correct" "$output" "RESULTS:1:1:2"

echo "--- assert_rc works ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_rc "exit 0" 0 true
    assert_rc "exit 1" 1 false
    assert_rc "wrong rc" 0 false
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
_assert_contains "assert_rc pass 0" "$output" "PASS: exit 0"
_assert_contains "assert_rc pass 1" "$output" "PASS: exit 1"
_assert_contains "assert_rc fail" "$output" "FAIL: wrong rc"
_assert_contains "counters correct" "$output" "RESULTS:2:1:3"

echo "--- assert_file_exists / assert_dir_exists work ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_file_exists "this script" "'"$SCRIPT_DIR"'/test_framework.sh"
    assert_file_exists "nonexistent" "/tmp/nonexistent-epac-test-$$"
    assert_dir_exists "tests dir" "'"$SCRIPT_DIR"'"
    assert_dir_exists "nonexistent dir" "/tmp/nonexistent-epac-dir-$$"
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
_assert_contains "file exists pass" "$output" "PASS: this script"
_assert_contains "file exists fail" "$output" "FAIL: nonexistent"
_assert_contains "dir exists pass" "$output" "PASS: tests dir"
_assert_contains "dir exists fail" "$output" "FAIL: nonexistent dir"
_assert_contains "counters correct" "$output" "RESULTS:2:2:4"

echo "--- assert_match / assert_no_match work ---"
tmpfile="$(mktemp)"
echo "Hello World" > "$tmpfile"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_match "found" "'"$tmpfile"'" "hello"
    assert_match "not found" "'"$tmpfile"'" "xyz123"
    assert_no_match "absent" "'"$tmpfile"'" "xyz123"
    assert_no_match "present" "'"$tmpfile"'" "hello"
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
rm -f "$tmpfile"
_assert_contains "match pass" "$output" "PASS: found"
_assert_contains "match fail" "$output" "FAIL: not found"
_assert_contains "no_match pass" "$output" "PASS: absent"
_assert_contains "no_match fail" "$output" "FAIL: present"
_assert_contains "counters correct" "$output" "RESULTS:2:2:4"

echo "--- assert_json_eq works ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    json='\''{"name":"test","count":42}'\''
    assert_json_eq "string field" "$json" ".name" "test"
    assert_json_eq "number field" "$json" ".count" "42"
    assert_json_eq "wrong value" "$json" ".name" "wrong"
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
_assert_contains "json_eq pass string" "$output" "PASS: string field"
_assert_contains "json_eq pass number" "$output" "PASS: number field"
_assert_contains "json_eq fail" "$output" "FAIL: wrong value"
_assert_contains "counters correct" "$output" "RESULTS:2:1:3"

echo "--- assert_json_count works ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    json='\''{"items":["a","b","c"]}'\''
    assert_json_count "array length" "$json" ".items" "3"
    assert_json_count "wrong count" "$json" ".items" "5"
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
_assert_contains "json_count pass" "$output" "PASS: array length"
_assert_contains "json_count fail" "$output" "FAIL: wrong count"
_assert_contains "counters correct" "$output" "RESULTS:1:1:2"

echo "--- assert_valid_json works ---"
tmpjson="$(mktemp --suffix=.json)"
echo '{"valid": true}' > "$tmpjson"
tmpbadjson="$(mktemp --suffix=.json)"
echo 'not json' > "$tmpbadjson"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_valid_json "valid json" "'"$tmpjson"'"
    assert_valid_json "invalid json" "'"$tmpbadjson"'"
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
rm -f "$tmpjson" "$tmpbadjson"
_assert_contains "valid_json pass" "$output" "PASS: valid json"
_assert_contains "valid_json fail" "$output" "FAIL: invalid json"
_assert_contains "counters correct" "$output" "RESULTS:1:1:2"

echo "--- assert_valid_yaml works ---"
tmpyaml="$(mktemp --suffix=.yaml)"
printf "key: value\nlist:\n  - item1\n" > "$tmpyaml"
tmpbadyaml="$(mktemp --suffix=.yaml)"
printf "key:\tvalue\n" > "$tmpbadyaml"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_valid_yaml "valid yaml" "'"$tmpyaml"'"
    assert_valid_yaml "yaml with tabs" "'"$tmpbadyaml"'"
    echo "RESULTS:${PASS}:${FAIL}:${TESTS}"
' 2>&1)"
rm -f "$tmpyaml" "$tmpbadyaml"
_assert_contains "valid_yaml pass" "$output" "PASS: valid yaml"
_assert_contains "valid_yaml fail" "$output" "FAIL: yaml with tabs"
_assert_contains "counters correct" "$output" "RESULTS:1:1:2"

echo "--- test_summary works ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    assert_eq "test1" "a" "a"
    assert_eq "test2" "b" "b"
    test_summary
' 2>&1)" || true
_assert_contains "summary shows count" "$output" "Tests: 2"
_assert_contains "summary shows passed" "$output" "Passed: 2"
_assert_contains "summary shows failed" "$output" "Failed: 0"

echo "--- source guard prevents double loading ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    TESTS=99
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    echo "TESTS_AFTER:${TESTS}"
' 2>&1)"
_assert_contains "guard preserves state" "$output" "TESTS_AFTER:99"

echo "--- setup_test_tmp creates temp dir ---"
output="$(bash -c '
    source "'"$SCRIPT_DIR"'/test_helpers.sh"
    setup_test_tmp
    [[ -d "$TEST_TMP" ]] && echo "TMP_EXISTS:yes" || echo "TMP_EXISTS:no"
    echo "TMP_PATH:$TEST_TMP"
' 2>&1)"
_assert_contains "test_tmp created" "$output" "TMP_EXISTS:yes"
_assert_contains "test_tmp is under /tmp" "$output" "TMP_PATH:/tmp/"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test Runner ==="
# ═══════════════════════════════════════════════════════════════════

echo "--- run_all_tests.sh exists and is executable ---"
_assert_file_exists "run_all_tests.sh exists" "$SCRIPT_DIR/run_all_tests.sh"
_assert_true "run_all_tests.sh is executable" test -x "$SCRIPT_DIR/run_all_tests.sh"

echo "--- --list flag works ---"
output="$(bash "$SCRIPT_DIR/run_all_tests.sh" --list 2>&1)"
_assert_contains "list shows test files" "$output" "test_core"
_assert_contains "list shows test_framework" "$output" "test_framework"
_assert_contains "list shows line counts" "$output" "lines)"
# Should NOT list test_helpers (it's a library, not a test)
if echo "$output" | grep -q "test_helpers "; then
    echo "  FAIL: list should exclude test_helpers"
    _FAIL=$((_FAIL + 1))
else
    echo "  PASS: list excludes test_helpers"
    _PASS=$((_PASS + 1))
fi

echo "--- --help flag works ---"
output="$(bash "$SCRIPT_DIR/run_all_tests.sh" --help 2>&1)"
_assert_contains "help shows usage" "$output" "Usage:"
_assert_contains "help shows --parallel" "$output" "--parallel"
_assert_contains "help shows --ci" "$output" "--ci"

echo "--- filter works ---"
output="$(bash "$SCRIPT_DIR/run_all_tests.sh" test_jsonc --ci 2>&1)"
_assert_contains "runs filtered test" "$output" "test_jsonc"
_assert_contains "shows passed count" "$output" "Passed: 4"
_assert_contains "shows 1 file" "$output" "Files:  1"

echo "--- --ci mode disables color ---"
output="$(bash "$SCRIPT_DIR/run_all_tests.sh" test_jsonc --ci 2>&1)"
# CI mode should not have ANSI escape codes
if echo "$output" | grep -qP '\033\['; then
    echo "  FAIL: CI mode should not have ANSI escapes"
    _FAIL=$((_FAIL + 1))
else
    echo "  PASS: CI mode has no ANSI escapes"
    _PASS=$((_PASS + 1))
fi

echo "--- invalid filter prints error ---"
output="$(bash "$SCRIPT_DIR/run_all_tests.sh" nonexistent_test_xyz 2>&1)" || true
_assert_contains "invalid filter error" "$output" "No test files matched"

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test File Conventions ==="
# ═══════════════════════════════════════════════════════════════════

echo "--- all test files have shebang ---"
for f in "$SCRIPT_DIR"/test_*.sh; do
    name="$(basename "$f")"
    [[ "$name" == "test_helpers.sh" ]] && continue
    first="$(head -1 "$f")"
    _assert_eq "$name has shebang" "#!/usr/bin/env bash" "$first"
done

echo "--- all test files are executable ---"
for f in "$SCRIPT_DIR"/test_*.sh; do
    name="$(basename "$f")"
    _assert_true "$name is executable" test -x "$f"
done

echo "--- all test files use set -euo pipefail ---"
for f in "$SCRIPT_DIR"/test_*.sh; do
    name="$(basename "$f")"
    [[ "$name" == "test_helpers.sh" ]] && continue
    if grep -q "set -euo pipefail" "$f"; then
        echo "  PASS: $name has strict mode"
        _PASS=$((_PASS + 1))
    else
        echo "  FAIL: $name missing strict mode"
        _FAIL=$((_FAIL + 1))
    fi
done

echo "--- test_helpers.sh has source guard ---"
if grep -q '_EPAC_TEST_HELPERS_LOADED' "$SCRIPT_DIR/test_helpers.sh"; then
    echo "  PASS: test_helpers.sh has source guard"
    _PASS=$((_PASS + 1))
else
    echo "  FAIL: test_helpers.sh missing source guard"
    _FAIL=$((_FAIL + 1))
fi

echo "--- run_all_tests.sh excludes test_helpers from test list ---"
if grep -q "test_helpers" "$SCRIPT_DIR/run_all_tests.sh"; then
    echo "  PASS: run_all_tests.sh handles test_helpers"
    _PASS=$((_PASS + 1))
else
    echo "  FAIL: run_all_tests.sh should reference test_helpers"
    _FAIL=$((_FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "=== Test Coverage Inventory ==="
# ═══════════════════════════════════════════════════════════════════

# Count test files (excluding helpers and runner)
test_count=0
for f in "$SCRIPT_DIR"/test_*.sh; do
    name="$(basename "$f")"
    [[ "$name" == "test_helpers.sh" ]] && continue
    test_count=$((test_count + 1))
done
_assert_true "at least 20 test files" test "$test_count" -ge 20

# Key test files must exist
for name in test_core test_config test_docs test_build_system test_framework; do
    _assert_file_exists "$name exists" "$SCRIPT_DIR/${name}.sh"
done

# ═══════════════════════════════════════════════════════════════════
echo ""
echo "================================="
echo "Tests: $((_PASS + _FAIL)) | Passed: $_PASS | Failed: $_FAIL"
echo "================================="
[[ "$_FAIL" -eq 0 ]] && exit 0 || exit 1
