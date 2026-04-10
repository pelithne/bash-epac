#!/usr/bin/env bash
# scripts/hydration/new-hydration-global-settings.sh
# Generate a global-settings.jsonc with main + epac-dev environments
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-definitions.sh"

usage() {
    cat <<'EOF'
Usage: new-hydration-global-settings.sh [OPTIONS]

Generate a global-settings.jsonc with dual pac environments.

Required:
  --pac-owner-id         PAC owner GUID
  --tenant-id            Azure tenant ID
  --main-root            Main intermediate root MG name

Options:
  --mi-location          Managed identity location (default: "")
  --main-pac-selector    Main PAC selector name (default: tenant01)
  --epac-pac-selector    EPAC dev PAC selector name (default: epac-dev)
  --cloud                Azure cloud name (default: AzureCloud)
  --epac-root            EPAC dev root MG name
  --strategy             Desired state strategy: full|ownedOnly (default: full)
  --definitions-root     Definitions folder path (default: ./Definitions)
  --log-file             Log file path
  --keep-dfc             Keep DfC security assignments
  --help                 Show this help message
EOF
    exit 0
}

args=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        *) args+=("$1"); shift ;;
    esac
done

hydration_create_global_settings "${args[@]}"
