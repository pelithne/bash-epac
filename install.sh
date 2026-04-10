#!/usr/bin/env bash
# install.sh — Install EPAC bash tools
# Can be run from a distribution package or directly from the repo
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Install EPAC bash tools and verify dependencies.

Options:
  --prefix DIR          Installation prefix (default: /usr/local)
  --check-only          Only check dependencies, don't install
  --help                Show this help message

Dependencies:
  Required: bash >=5.1, jq >=1.6, az CLI >=2.50.0, curl, git
  Optional: shellcheck (for development)
EOF
    exit 0
}

prefix="/usr/local"
check_only=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --prefix) prefix="$2"; shift 2 ;;
        --check-only) check_only=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ─── Dependency checking ─────────────────────────────────────────────────────

check_errors=0

check_command() {
    local cmd="$1" min_version="$2" required="${3:-true}"
    local label="required"
    [[ "$required" == "false" ]] && label="optional"

    if ! command -v "$cmd" &>/dev/null; then
        if [[ "$required" == "true" ]]; then
            echo "  MISSING ($label): $cmd (>= $min_version)"
            check_errors=$((check_errors + 1))
        else
            echo "  MISSING ($label): $cmd (>= $min_version)"
        fi
        return 1
    fi

    local actual_version=""
    case "$cmd" in
        bash)  actual_version="$(bash --version | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1)" ;;
        jq)    actual_version="$(jq --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)" ;;
        az)    actual_version="$(az version 2>/dev/null | jq -r '."azure-cli"' 2>/dev/null || echo "unknown")" ;;
        curl)  actual_version="$(curl --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1)" ;;
        git)   actual_version="$(git --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)" ;;
        shellcheck) actual_version="$(shellcheck --version 2>/dev/null | grep 'version:' | grep -oP '\d+\.\d+\.\d+' | head -1)" ;;
    esac

    echo "  OK ($label): $cmd $actual_version (>= $min_version)"
    return 0
}

echo "Checking dependencies..."
echo ""

check_command bash   "5.1"   true
check_command jq     "1.6"   true
check_command az     "2.50.0" true
check_command curl   "7.0"   true
check_command git    "2.0"   true
check_command shellcheck "0.8" false

echo ""

if [[ "$check_errors" -gt 0 ]]; then
    echo "ERROR: $check_errors required dependency/dependencies missing."
    echo "Install missing dependencies and retry."
    exit 1
fi

echo "All required dependencies satisfied."

if [[ "$check_only" == "true" ]]; then
    exit 0
fi

# ─── Installation ─────────────────────────────────────────────────────────────

echo ""
echo "Installing EPAC to ${prefix}/share/epac..."

install_dir="${prefix}/share/epac"
bin_dir="${prefix}/bin"

mkdir -p "$install_dir" "$bin_dir"

# Copy library and scripts
cp -r "${SCRIPT_DIR}/lib" "${install_dir}/"
cp -r "${SCRIPT_DIR}/scripts" "${install_dir}/"
cp -r "${SCRIPT_DIR}/Schemas" "${install_dir}/"

if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
    cp "${SCRIPT_DIR}/VERSION" "${install_dir}/"
fi

if [[ -f "${SCRIPT_DIR}/epac.json" ]]; then
    cp "${SCRIPT_DIR}/epac.json" "${install_dir}/"
fi

# Make scripts executable
find "${install_dir}/scripts" -name "*.sh" -type f -exec chmod +x {} \;

# Create symlinks for main entry points
declare -A commands=(
    ["epac-plan"]="scripts/deploy/build-deployment-plans.sh"
    ["epac-deploy-policy"]="scripts/deploy/deploy-policy-plan.sh"
    ["epac-deploy-roles"]="scripts/deploy/deploy-roles-plan.sh"
    ["epac-remediate"]="scripts/operations/new-az-remediation-tasks.sh"
    ["epac-export"]="scripts/operations/export-az-policy-resources.sh"
    ["epac-docs"]="scripts/operations/build-policy-documentation.sh"
    ["epac-alz-sync"]="scripts/caf/sync-alz-policy-from-library.sh"
)

for cmd_name in "${!commands[@]}"; do
    target="${install_dir}/${commands[$cmd_name]}"
    if [[ -f "$target" ]]; then
        ln -sf "$target" "${bin_dir}/${cmd_name}"
        echo "  Linked: ${cmd_name} -> ${target}"
    fi
done

# Version info
if [[ -f "${install_dir}/VERSION" ]]; then
    echo ""
    echo "Installed EPAC v$(cat "${install_dir}/VERSION")"
else
    echo ""
    echo "Installed EPAC (development)"
fi

echo "Installation complete."
