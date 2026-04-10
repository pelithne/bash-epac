#!/usr/bin/env bash
# lib/epac.sh — Main entry point: sources all EPAC libraries in dependency order
# Equivalent of Add-HelperScripts.ps1 and EnterprisePolicyAsCode.psm1
#
# Usage from any script:
#   source "$(dirname "$0")/../lib/epac.sh"

[[ -n "${_EPAC_LOADED:-}" ]] && return 0
readonly _EPAC_LOADED=1

_EPAC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Load libraries in dependency order ──────────────────────────────────────

# Layer 1: Core (no dependencies)
# shellcheck source=core.sh
source "${_EPAC_LIB_DIR}/core.sh"

# Layer 2: JSON utilities (depends on core)
# shellcheck source=json.sh
source "${_EPAC_LIB_DIR}/json.sh"

# Layer 3: String/array/path utilities (depends on core)
# shellcheck source=utils.sh
source "${_EPAC_LIB_DIR}/utils.sh"

# Layer 4: Themed output (depends on core, json)
# shellcheck source=output.sh
source "${_EPAC_LIB_DIR}/output.sh"

# ─── Source additional libraries if they exist ────────────────────────────────
# Future WIs will add more libraries here. We conditionally source them so
# the entry point works incrementally as features are added.

_epac_source_if_exists() {
    local lib_path="${_EPAC_LIB_DIR}/$1"
    if [[ -f "$lib_path" ]]; then
        # shellcheck source=/dev/null
        source "$lib_path"
    fi
}

# Layer 5: Azure auth & config (WI-02, WI-03)
_epac_source_if_exists "azure-auth.sh"
_epac_source_if_exists "config.sh"

# Layer 6: REST API wrappers (WI-04)
for f in "${_EPAC_LIB_DIR}"/rest/*.sh; do
    [[ -f "$f" ]] && source "$f"
done

# Layer 7: Resource retrieval (WI-05)
_epac_source_if_exists "azure-resources.sh"

# Layer 8: Transforms & validators (WI-06, WI-07)
_epac_source_if_exists "transforms.sh"
_epac_source_if_exists "validators.sh"

# Layer 9: Scope management (WI-08)
_epac_source_if_exists "scope.sh"

# Layer 10: Plan builders (WI-09, WI-10, WI-11)
for f in "${_EPAC_LIB_DIR}"/plans/*.sh; do
    [[ -f "$f" ]] && source "$f"
done

# Layer 11: Hydration helpers (WI-17)
for f in "${_EPAC_LIB_DIR}"/hydration/*.sh; do
    [[ -f "$f" ]] && source "$f"
done

# Layer 12: Export helpers (WI-13)
for f in "${_EPAC_LIB_DIR}"/exports/*.sh; do
    [[ -f "$f" ]] && source "$f"
done

# ─── Startup banner (debug mode only) ────────────────────────────────────────

epac_log_debug "EPAC bash libraries loaded from ${_EPAC_LIB_DIR}"
epac_log_debug "EPAC root: ${EPAC_ROOT_DIR}"
