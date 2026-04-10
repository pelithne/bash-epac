#!/usr/bin/env bash
# scripts/hydration/build-hydration-deployment-plans.sh
# Wrapper for deployment plan building in hydration context
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/lib/hydration/hydration-core.sh"

usage() {
    cat <<'EOF'
Usage: build-hydration-deployment-plans.sh --pac-selector <NAME> [OPTIONS]

Build deployment plans for a PAC environment. This is a hydration-specific
wrapper around the core deployment plan builder.

Required:
  --pac-selector          PAC environment selector

Options:
  --definitions-root      Definitions folder (default: ./Definitions)
  --output                Output folder (default: ./Output)
  --interactive           Enable interactive prompts
  --devops-type           DevOps integration: ado|gitlab (default: none)
  --build-exemptions-only Only build exemptions plan
  --full-export           Full export for documentation file
  --help                  Show this help message
EOF
    exit 0
}

pac_selector="" definitions_root="" output="" interactive=""
devops_type="" exemptions_only="" full_export=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --pac-selector) pac_selector="$2"; shift 2 ;;
        --definitions-root) definitions_root="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --interactive) interactive="--interactive"; shift ;;
        --devops-type) devops_type="--devops-type $2"; shift 2 ;;
        --build-exemptions-only) exemptions_only="--build-exemptions-only"; shift ;;
        --full-export) full_export="--full-export"; shift ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$pac_selector" ]] && { epac_log_error "Missing --pac-selector"; exit 1; }

# Build the args for the core plan builder
args=("--pac-selector" "$pac_selector")
[[ -n "$definitions_root" ]] && args+=("--definitions-root-folder" "$definitions_root")
[[ -n "$output" ]] && args+=("--output-folder" "$output")
[[ -n "$interactive" ]] && args+=("$interactive")
[[ -n "$devops_type" ]] && args+=($devops_type)
[[ -n "$exemptions_only" ]] && args+=("$exemptions_only")
[[ -n "$full_export" ]] && args+=("$full_export")

# Delegate to the core deployment plan builder
bash "${REPO_ROOT}/scripts/deploy/build-deployment-plans.sh" "${args[@]}"
