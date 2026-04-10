#!/usr/bin/env bash
# build.sh — Package EPAC bash distribution
# Creates a distributable tarball with all scripts and libraries
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && pwd)"

usage() {
    cat <<'EOF'
Usage: build.sh [OPTIONS]

Build an EPAC bash distribution package.

Options:
  --version VERSION     Version string (default: from TAG_NAME env or 'dev')
  --output-dir DIR      Output directory (default: ./dist)
  --help                Show this help message
EOF
    exit 0
}

version="${TAG_NAME:-dev}"
version="${version#v}"  # strip leading v
output_dir="${REPO_ROOT}/dist"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --version) version="$2"; shift 2 ;;
        --output-dir) output_dir="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

echo "Building EPAC bash v${version}..."

# Create clean build directory
build_dir="${output_dir}/epac-${version}"
rm -rf "$build_dir"
mkdir -p "$build_dir"

# Copy library files
echo "  Copying library files..."
cp -r "${REPO_ROOT}/lib" "${build_dir}/"

# Copy scripts
echo "  Copying scripts..."
cp -r "${REPO_ROOT}/scripts" "${build_dir}/"

# Copy schemas
echo "  Copying schemas..."
cp -r "${REPO_ROOT}/Schemas" "${build_dir}/"

# Copy StarterKit
echo "  Copying StarterKit..."
cp -r "${REPO_ROOT}/StarterKit" "${build_dir}/"

# Copy examples
if [[ -d "${REPO_ROOT}/Examples" ]]; then
    echo "  Copying Examples..."
    cp -r "${REPO_ROOT}/Examples" "${build_dir}/"
fi

# Copy install script
cp "${REPO_ROOT}/install.sh" "${build_dir}/"
chmod +x "${build_dir}/install.sh"

# Generate version file
cat > "${build_dir}/VERSION" << VEOF
${version}
VEOF

# Generate manifest
cat > "${build_dir}/epac.json" << MEOF
{
    "name": "enterprise-azure-policy-as-code",
    "version": "${version}",
    "description": "Enterprise Policy as Code — Bash Edition",
    "author": "Microsoft Corporation",
    "license": "MIT",
    "dependencies": {
        "bash": ">=5.1",
        "jq": ">=1.6",
        "az": ">=2.50.0",
        "curl": ">=7.0",
        "git": ">=2.0"
    },
    "entrypoints": {
        "deploy": {
            "build-deployment-plans": "scripts/deploy/build-deployment-plans.sh",
            "deploy-policy-plan": "scripts/deploy/deploy-policy-plan.sh",
            "deploy-roles-plan": "scripts/deploy/deploy-roles-plan.sh"
        },
        "operations": {
            "build-policy-documentation": "scripts/operations/build-policy-documentation.sh",
            "export-az-policy-resources": "scripts/operations/export-az-policy-resources.sh",
            "new-az-remediation-tasks": "scripts/operations/new-az-remediation-tasks.sh"
        },
        "caf": {
            "new-alz-policy-default-structure": "scripts/caf/new-alz-policy-default-structure.sh",
            "sync-alz-policy-from-library": "scripts/caf/sync-alz-policy-from-library.sh"
        }
    }
}
MEOF

# Make all scripts executable
find "${build_dir}/scripts" -name "*.sh" -type f -exec chmod +x {} \;

# Count contents
lib_count="$(find "${build_dir}/lib" -name "*.sh" -type f | wc -l)"
script_count="$(find "${build_dir}/scripts" -name "*.sh" -type f | wc -l)"
echo "  Library files: ${lib_count}"
echo "  Script files:  ${script_count}"

# Create tarball
echo "  Creating tarball..."
tar_file="${output_dir}/epac-${version}.tar.gz"
(cd "$output_dir" && tar czf "epac-${version}.tar.gz" "epac-${version}/")
echo "  Package: ${tar_file}"

# Calculate checksum
checksum="$(sha256sum "$tar_file" | awk '{print $1}')"
echo "$checksum  epac-${version}.tar.gz" > "${tar_file}.sha256"
echo "  SHA256:  ${checksum}"

echo ""
echo "Build complete: epac-${version}"
echo "  Package:  ${tar_file}"
echo "  Checksum: ${tar_file}.sha256"
