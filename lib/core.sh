#!/usr/bin/env bash
# lib/core.sh — Core utilities: error handling, logging, environment detection
# This is the foundational library that all other EPAC bash libraries depend on.

set -euo pipefail

# ─── Guard against double-sourcing ───────────────────────────────────────────
[[ -n "${_EPAC_CORE_LOADED:-}" ]] && return 0
readonly _EPAC_CORE_LOADED=1

# ─── Determine library root directory ────────────────────────────────────────
EPAC_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EPAC_ROOT_DIR="$(cd "${EPAC_LIB_DIR}/.." && pwd)"
export EPAC_LIB_DIR EPAC_ROOT_DIR

# ─── Global state ────────────────────────────────────────────────────────────
declare -g EPAC_HAS_ERRORS=false
declare -g EPAC_ERROR_COUNT=0
declare -g EPAC_INFO_STREAM=""

# ─── CI/CD environment detection ─────────────────────────────────────────────
# Cache the result so we only detect once
_EPAC_IS_CICD=""

epac_is_cicd() {
    if [[ -n "${_EPAC_IS_CICD}" ]]; then
        [[ "${_EPAC_IS_CICD}" == "true" ]]
        return
    fi

    if [[ "${GITHUB_ACTIONS:-}" == "true" ]] ||
       [[ "${TF_BUILD:-}" == "true" ]] ||
       [[ "${GITLAB_CI:-}" == "true" ]] ||
       [[ "${CI:-}" == "true" ]] ||
       [[ -n "${BUILD_ID:-}" ]] ||
       [[ "${CIRCLECI:-}" == "true" ]]; then
        _EPAC_IS_CICD="true"
    else
        _EPAC_IS_CICD="false"
    fi

    [[ "${_EPAC_IS_CICD}" == "true" ]]
}

# ─── Logging ──────────────────────────────────────────────────────────────────

# Log levels: debug, info, warning, error
# Only messages at or above EPAC_LOG_LEVEL are shown.
EPAC_LOG_LEVEL="${EPAC_LOG_LEVEL:-info}"

_epac_log_level_num() {
    case "${1,,}" in
        debug)   echo 0 ;;
        info)    echo 1 ;;
        warning) echo 2 ;;
        error)   echo 3 ;;
        *)       echo 1 ;;
    esac
}

_epac_should_log() {
    local msg_level="$1"
    local current_level="${EPAC_LOG_LEVEL}"
    [[ "$(_epac_log_level_num "$msg_level")" -ge "$(_epac_log_level_num "$current_level")" ]]
}

epac_log_debug() {
    _epac_should_log "debug" && echo "[DEBUG] $*" >&2 || true
}

epac_log_info() {
    _epac_should_log "info" && echo "$*" >&2 || true
}

epac_log_success() {
    _epac_should_log "info" && echo -e "\033[32m$*\033[0m" >&2 || true
}

epac_log_warning() {
    _epac_should_log "warning" && echo "[WARNING] $*" >&2 || true
}

epac_log_error() {
    _epac_should_log "error" && echo "[ERROR] $*" >&2 || true
    EPAC_HAS_ERRORS=true
    EPAC_ERROR_COUNT=$((EPAC_ERROR_COUNT + 1))
}

# ─── Error info structure ────────────────────────────────────────────────────
# Bash doesn't have hashtables with named fields like PowerShell, so we use
# a temp file per error-info to collect error strings, and variables for state.

# Creates an error info "object" — actually a temp file + env var prefix.
# Usage: local ei; ei=$(epac_new_error_info "myfile.json")
#        epac_add_error "$ei" "something went wrong"
#        epac_write_errors "$ei"
#        epac_cleanup_error_info "$ei"

_EPAC_ERROR_INFO_DIR=""

_epac_ensure_error_dir() {
    if [[ -z "${_EPAC_ERROR_INFO_DIR}" ]]; then
        _EPAC_ERROR_INFO_DIR="$(mktemp -d "${TMPDIR:-/tmp}/epac-errors.XXXXXX")"
    fi
}

epac_new_error_info() {
    local filename="${1:-(unknown)}"
    _epac_ensure_error_dir
    local id
    id="$(mktemp -u "XXXXXX")"
    local prefix="${_EPAC_ERROR_INFO_DIR}/${id}"

    echo "$filename" > "${prefix}.filename"
    : > "${prefix}.errors"
    echo "0" > "${prefix}.count"
    echo "false" > "${prefix}.has_errors"

    echo "$prefix"
}

epac_add_error() {
    local prefix="$1"
    shift
    local entry_number="${1:--1}"
    shift
    local msg="$*"

    if [[ "$entry_number" != "-1" ]]; then
        echo "${entry_number}: ${msg}" >> "${prefix}.errors"
    else
        echo "${msg}" >> "${prefix}.errors"
    fi

    local count
    count=$(cat "${prefix}.count")
    echo "$((count + 1))" > "${prefix}.count"
    echo "true" > "${prefix}.has_errors"
}

epac_has_errors() {
    local prefix="$1"
    [[ "$(cat "${prefix}.has_errors")" == "true" ]]
}

epac_error_count() {
    local prefix="$1"
    cat "${prefix}.count"
}

epac_write_errors() {
    local prefix="$1"
    if epac_has_errors "$prefix"; then
        local filename count
        filename="$(cat "${prefix}.filename")"
        count="$(cat "${prefix}.count")"
        epac_log_info "File '${filename}' has ${count} errors:"
        while IFS= read -r line; do
            epac_log_info "    ${line}"
        done < "${prefix}.errors"
        epac_log_error "File '${filename}' with ${count} errors (end of list)."
    fi
}

epac_cleanup_error_info() {
    local prefix="$1"
    rm -f "${prefix}".{filename,errors,count,has_errors} 2>/dev/null || true
}

# Clean up all error info temp files on exit
_epac_cleanup_all_errors() {
    if [[ -n "${_EPAC_ERROR_INFO_DIR}" && -d "${_EPAC_ERROR_INFO_DIR}" ]]; then
        rm -rf "${_EPAC_ERROR_INFO_DIR}" 2>/dev/null || true
    fi
}
trap _epac_cleanup_all_errors EXIT

# ─── Fatal error handling ─────────────────────────────────────────────────────

epac_die() {
    epac_log_error "$@"
    exit 1
}

# ─── Assertions ───────────────────────────────────────────────────────────────

epac_require_file() {
    local filepath="$1"
    local description="${2:-File}"
    if [[ ! -f "$filepath" ]]; then
        epac_die "${description} not found: ${filepath}"
    fi
}

# ─── Info stream (captures output for DevOps variable setting) ────────────────

epac_info_stream_append() {
    EPAC_INFO_STREAM+="$*"$'\n'
}

# ─── Temp file management ────────────────────────────────────────────────────

_EPAC_TEMP_FILES=()

_epac_cleanup_temp_files() {
    for f in "${_EPAC_TEMP_FILES[@]}"; do
        rm -f "$f" 2>/dev/null || true
    done
}
# Append to existing EXIT trap
trap '_epac_cleanup_temp_files; _epac_cleanup_all_errors' EXIT

# ─── GUID generation ─────────────────────────────────────────────────────────

epac_generate_guid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        # Fallback: generate from /dev/urandom
        od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}' | tr '[:upper:]' '[:lower:]'
    fi
}

epac_is_guid() {
    local value="$1"
    [[ "$value" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# ─── Version comparison ──────────────────────────────────────────────────────

epac_compare_semver() {
    local v1="$1" v2="$2"
    # Strip leading 'v' if present
    v1="${v1#v}"
    v2="${v2#v}"

    local IFS='.'
    read -ra parts1 <<< "$v1"
    read -ra parts2 <<< "$v2"

    for i in 0 1 2; do
        local p1="${parts1[$i]:-0}"
        local p2="${parts2[$i]:-0}"
        if (( p1 > p2 )); then
            echo 1; return
        elif (( p1 < p2 )); then
            echo -1; return
        fi
    done
    echo 0
}
