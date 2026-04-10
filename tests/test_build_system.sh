#!/usr/bin/env bash
# tests/test_build_system.sh — Tests for WI-20 build system & packaging
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TESTS=0
TEST_TMP=""

setup() {
    TEST_TMP="$(mktemp -d)"
}

teardown() {
    [[ -d "$TEST_TMP" ]] && rm -rf "$TEST_TMP"
}

trap teardown EXIT
setup

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

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

assert_rc() {
    local desc="$1" expected="$2" actual="$3"
    TESTS=$((TESTS + 1))
    if [[ "$expected" -eq "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (rc=$actual, expected=$expected)"
        FAIL=$((FAIL + 1))
    fi
}

assert_json_field() {
    local desc="$1" json="$2" field="$3" expected="$4"
    local actual
    actual="$(echo "$json" | jq -r "$field" 2>/dev/null || echo "ERROR")"
    assert_eq "$desc" "$expected" "$actual"
}

# ═══════════════════════════════════════════════════════════════════════════════
echo "=== Script executability ==="
# ═══════════════════════════════════════════════════════════════════════════════

for script in build.sh install.sh; do
    TESTS=$((TESTS + 1))
    if [[ -x "${REPO_ROOT}/${script}" ]]; then
        echo "  PASS: $script is executable"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $script is not executable"
        FAIL=$((FAIL + 1))
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Help output ==="
# ═══════════════════════════════════════════════════════════════════════════════

for script in build.sh install.sh; do
    help_output="$(bash "${REPO_ROOT}/${script}" --help 2>&1 || true)"
    assert_contains "${script} --help has Usage" "$help_output" "Usage:"
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== build.sh with default version ==="
# ═══════════════════════════════════════════════════════════════════════════════

build_out="${TEST_TMP}/build1"
rc=0
bash "${REPO_ROOT}/build.sh" --output-dir "$build_out" 2>&1 || rc=$?
assert_rc "build.sh succeeds" 0 "$rc"

assert_dir_exists "build dir created" "${build_out}/epac-dev"
assert_file_exists "tarball created" "${build_out}/epac-dev.tar.gz"
assert_file_exists "checksum created" "${build_out}/epac-dev.tar.gz.sha256"

# Check build contents
assert_dir_exists "lib/ in build" "${build_out}/epac-dev/lib"
assert_dir_exists "scripts/ in build" "${build_out}/epac-dev/scripts"
assert_dir_exists "Schemas/ in build" "${build_out}/epac-dev/Schemas"
assert_dir_exists "StarterKit/ in build" "${build_out}/epac-dev/StarterKit"
assert_file_exists "install.sh in build" "${build_out}/epac-dev/install.sh"
assert_file_exists "VERSION in build" "${build_out}/epac-dev/VERSION"
assert_file_exists "epac.json in build" "${build_out}/epac-dev/epac.json"

# Check VERSION content
version="$(cat "${build_out}/epac-dev/VERSION")"
assert_eq "VERSION is dev" "dev" "$version"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== build.sh with custom version ==="
# ═══════════════════════════════════════════════════════════════════════════════

build_out2="${TEST_TMP}/build2"
rc=0
bash "${REPO_ROOT}/build.sh" --version "1.2.3" --output-dir "$build_out2" 2>&1 || rc=$?
assert_rc "build with version succeeds" 0 "$rc"

assert_dir_exists "versioned dir" "${build_out2}/epac-1.2.3"
assert_file_exists "versioned tarball" "${build_out2}/epac-1.2.3.tar.gz"
assert_file_exists "versioned checksum" "${build_out2}/epac-1.2.3.tar.gz.sha256"

v="$(cat "${build_out2}/epac-1.2.3/VERSION")"
assert_eq "VERSION is 1.2.3" "1.2.3" "$v"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== build.sh with TAG_NAME env var ==="
# ═══════════════════════════════════════════════════════════════════════════════

build_out3="${TEST_TMP}/build3"
rc=0
TAG_NAME="v2.0.0-beta" bash "${REPO_ROOT}/build.sh" --output-dir "$build_out3" 2>&1 || rc=$?
assert_rc "build with TAG_NAME succeeds" 0 "$rc"
assert_dir_exists "TAG_NAME stripped v prefix" "${build_out3}/epac-2.0.0-beta"
assert_file_exists "TAG_NAME tarball" "${build_out3}/epac-2.0.0-beta.tar.gz"

v="$(cat "${build_out3}/epac-2.0.0-beta/VERSION")"
assert_eq "TAG_NAME version correct" "2.0.0-beta" "$v"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== build.sh manifest content ==="
# ═══════════════════════════════════════════════════════════════════════════════

manifest="$(cat "${build_out}/epac-dev/epac.json")"
assert_json_field "manifest name" "$manifest" '.name' "enterprise-azure-policy-as-code"
assert_json_field "manifest version" "$manifest" '.version' "dev"
assert_json_field "manifest bash dep" "$manifest" '.dependencies.bash' ">=5.1"
assert_json_field "manifest jq dep" "$manifest" '.dependencies.jq' ">=1.6"
assert_json_field "manifest az dep" "$manifest" '.dependencies.az' ">=2.50.0"

# Verify entrypoints reference existing files
while IFS= read -r entry_path; do
    [[ -z "$entry_path" ]] && continue
    assert_file_exists "entrypoint: $entry_path" "${build_out}/epac-dev/${entry_path}"
done < <(echo "$manifest" | jq -r '.entrypoints | .. | strings' 2>/dev/null | grep ".sh$")

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== build.sh scripts are executable in tarball ==="
# ═══════════════════════════════════════════════════════════════════════════════

non_exec="$(find "${build_out}/epac-dev/scripts" -name "*.sh" -type f ! -executable 2>/dev/null | wc -l)"
assert_eq "all scripts executable in build" "0" "$non_exec"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== build.sh checksum validates ==="
# ═══════════════════════════════════════════════════════════════════════════════

TESTS=$((TESTS + 1))
if (cd "$build_out" && sha256sum -c "epac-dev.tar.gz.sha256" &>/dev/null); then
    echo "  PASS: checksum validates"
    PASS=$((PASS + 1))
else
    echo "  FAIL: checksum validation failed"
    FAIL=$((FAIL + 1))
fi

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== build.sh tarball extracts correctly ==="
# ═══════════════════════════════════════════════════════════════════════════════

extract_dir="${TEST_TMP}/extract"
mkdir -p "$extract_dir"
tar xzf "${build_out}/epac-dev.tar.gz" -C "$extract_dir"
assert_dir_exists "extracted lib/" "${extract_dir}/epac-dev/lib"
assert_dir_exists "extracted scripts/" "${extract_dir}/epac-dev/scripts"
assert_file_exists "extracted install.sh" "${extract_dir}/epac-dev/install.sh"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== install.sh --check-only ==="
# ═══════════════════════════════════════════════════════════════════════════════

check_output="$(bash "${REPO_ROOT}/install.sh" --check-only 2>&1 || true)"
assert_contains "check lists bash" "$check_output" "bash"
assert_contains "check lists jq" "$check_output" "jq"
assert_contains "check lists curl" "$check_output" "curl"
assert_contains "check lists git" "$check_output" "git"
assert_contains "check shows dependencies" "$check_output" "dependencies"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== install.sh to custom prefix ==="
# ═══════════════════════════════════════════════════════════════════════════════

install_prefix="${TEST_TMP}/install-test"
mkdir -p "$install_prefix"
rc=0
bash "${REPO_ROOT}/install.sh" --prefix "$install_prefix" 2>&1 || rc=$?
assert_rc "install succeeds" 0 "$rc"

assert_dir_exists "epac share dir" "${install_prefix}/share/epac"
assert_dir_exists "epac lib" "${install_prefix}/share/epac/lib"
assert_dir_exists "epac scripts" "${install_prefix}/share/epac/scripts"
assert_dir_exists "epac Schemas" "${install_prefix}/share/epac/Schemas"
assert_dir_exists "bin dir" "${install_prefix}/bin"

# Check symlinks were created
for cmd in epac-plan epac-deploy-policy epac-deploy-roles epac-remediate epac-export epac-docs epac-alz-sync; do
    TESTS=$((TESTS + 1))
    if [[ -L "${install_prefix}/bin/${cmd}" || -f "${install_prefix}/bin/${cmd}" ]]; then
        echo "  PASS: symlink ${cmd} exists"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: symlink ${cmd} not found"
        FAIL=$((FAIL + 1))
    fi
done

# Check symlinks are valid
for cmd in epac-plan epac-deploy-policy epac-deploy-roles; do
    link_target="$(readlink -f "${install_prefix}/bin/${cmd}" 2>/dev/null || true)"
    TESTS=$((TESTS + 1))
    if [[ -n "$link_target" && -f "$link_target" ]]; then
        echo "  PASS: ${cmd} target exists"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${cmd} target missing (${link_target})"
        FAIL=$((FAIL + 1))
    fi
done

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== install.sh from extracted tarball ==="
# ═══════════════════════════════════════════════════════════════════════════════

install_prefix2="${TEST_TMP}/install-from-tar"
mkdir -p "$install_prefix2"
rc=0
bash "${extract_dir}/epac-dev/install.sh" --prefix "$install_prefix2" 2>&1 || rc=$?
assert_rc "install from tarball succeeds" 0 "$rc"
assert_dir_exists "tarball install has lib" "${install_prefix2}/share/epac/lib"
assert_dir_exists "tarball install has scripts" "${install_prefix2}/share/epac/scripts"

# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "=== SUMMARY ==="
echo "Tests: $TESTS | Passed: $PASS | Failed: $FAIL"

[[ $FAIL -eq 0 ]] || exit 1
