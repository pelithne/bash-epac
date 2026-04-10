#!/usr/bin/env bash
# lib/output.sh — Themed, colored output for headers, sections, status, progress
# Replaces PowerShell's Write-ModernOutput.ps1 (Write-ModernHeader, Write-ModernSection,
# Write-ModernStatus, Write-ModernCountSummary, Write-ModernProgress, Write-ColoredOutput)

[[ -n "${_EPAC_OUTPUT_LOADED:-}" ]] && return 0
readonly _EPAC_OUTPUT_LOADED=1

# shellcheck source=core.sh
source "${BASH_SOURCE[0]%/*}/core.sh"
# shellcheck source=json.sh
source "${BASH_SOURCE[0]%/*}/json.sh"

# ─── ANSI color codes ────────────────────────────────────────────────────────

declare -A _EPAC_FG_COLORS=(
    [black]=30 [darkred]=31 [darkgreen]=32 [darkyellow]=33
    [darkblue]=34 [darkmagenta]=35 [darkcyan]=36 [gray]=37
    [darkgray]=90 [red]=91 [green]=92 [yellow]=93
    [blue]=94 [magenta]=95 [cyan]=96 [white]=97
)

declare -A _EPAC_BG_COLORS=(
    [black]=40 [darkred]=41 [darkgreen]=42 [darkyellow]=43
    [darkblue]=44 [darkmagenta]=45 [darkcyan]=46 [gray]=47
    [darkgray]=100 [red]=101 [green]=102 [yellow]=103
    [blue]=104 [magenta]=105 [cyan]=106 [white]=107
)

_EPAC_ANSI_RESET=$'\033[0m'

_epac_fg_code() {
    local color="${1,,}"
    echo "${_EPAC_FG_COLORS[$color]:-97}"
}

_epac_bg_code() {
    local color="${1,,}"
    echo "${_EPAC_BG_COLORS[$color]:-40}"
}

# ─── Colored output ──────────────────────────────────────────────────────────

epac_colored() {
    local message="$1"
    local fg="${2:-white}"
    local bg="${3:-}"
    local no_newline="${4:-false}"

    local fg_code
    fg_code="$(_epac_fg_code "$fg")"

    local output
    if [[ -n "$bg" ]]; then
        local bg_code
        bg_code="$(_epac_bg_code "$bg")"
        output="\033[${fg_code};${bg_code}m${message}${_EPAC_ANSI_RESET}"
    else
        output="\033[${fg_code}m${message}${_EPAC_ANSI_RESET}"
    fi

    if [[ "$no_newline" == "true" ]]; then
        printf '%b' "$output"
    else
        printf '%b\n' "$output"
    fi
}

# ─── Theme loading ───────────────────────────────────────────────────────────

_EPAC_THEME=""

_epac_default_theme() {
    cat << 'THEME_JSON'
{
    "name": "Default Modern Theme",
    "characters": {
        "header": {
            "topLeft": "┏",
            "topRight": "┓",
            "bottomLeft": "┗",
            "bottomRight": "┛",
            "horizontal": "━",
            "vertical": "┃"
        },
        "section": {
            "arrow": "▶",
            "underline": "━"
        },
        "status": {
            "success": "✓",
            "warning": "⚠",
            "error": "✗",
            "info": "•",
            "skip": "⊘",
            "update": "⭮",
            "processing": "🔄"
        }
    },
    "colors": {
        "header": {
            "primary": "Cyan",
            "secondary": "DarkCyan"
        },
        "section": "Blue",
        "status": {
            "success": "Green",
            "warning": "Yellow",
            "error": "Red",
            "info": "White",
            "skip": "DarkGray",
            "update": "Cyan",
            "processing": "Yellow"
        }
    }
}
THEME_JSON
}

epac_reset_theme() {
    _EPAC_THEME=""
}

epac_get_theme() {
    if [[ -n "$_EPAC_THEME" ]]; then
        echo "$_EPAC_THEME"
        return
    fi

    # Try to load from .epac/theme.json
    local theme_file=""
    local search_paths=(
        ".epac/theme.json"
        "${EPAC_ROOT_DIR:-.}/.epac/theme.json"
    )

    for path in "${search_paths[@]}"; do
        if [[ -f "$path" ]]; then
            theme_file="$path"
            break
        fi
    done

    if [[ -n "$theme_file" ]]; then
        local config
        config="$(jq '.' "$theme_file" 2>/dev/null)" || config=""
        if [[ -n "$config" ]]; then
            local theme_name
            theme_name="$(echo "$config" | jq -r '.themeName // "default"')"
            _EPAC_THEME="$(echo "$config" | jq ".themes.${theme_name} // .themes.default" 2>/dev/null)" || _EPAC_THEME=""
        fi
    fi

    # Fallback to default
    if [[ -z "$_EPAC_THEME" || "$_EPAC_THEME" == "null" ]]; then
        _EPAC_THEME="$(_epac_default_theme)"
    fi

    echo "$_EPAC_THEME"
}

# Theme accessors — get character/color from theme JSON

_epac_theme_char() {
    local path="$1"
    local theme
    theme="$(epac_get_theme)"
    echo "$theme" | jq -r ".characters.${path} // empty" 2>/dev/null
}

_epac_theme_color() {
    local path="$1"
    local theme
    theme="$(epac_get_theme)"
    echo "$theme" | jq -r ".colors.${path} // empty" 2>/dev/null
}

# ─── Write-ModernHeader ──────────────────────────────────────────────────────

epac_write_header() {
    local title="$1"
    local subtitle="${2:-}"

    local top_left top_right bottom_left bottom_right horiz vert
    top_left="$(_epac_theme_char 'header.topLeft')"
    top_right="$(_epac_theme_char 'header.topRight')"
    bottom_left="$(_epac_theme_char 'header.bottomLeft')"
    bottom_right="$(_epac_theme_char 'header.bottomRight')"
    horiz="$(_epac_theme_char 'header.horizontal')"
    vert="$(_epac_theme_char 'header.vertical')"

    local primary secondary
    primary="$(_epac_theme_color 'header.primary')"
    secondary="$(_epac_theme_color 'header.secondary')"

    # Calculate max length
    local max_len=${#title}
    if [[ -n "$subtitle" && ${#subtitle} -gt $max_len ]]; then
        max_len=${#subtitle}
    fi

    # Build border
    local border=""
    for (( i=0; i<max_len+4; i++ )); do
        border+="$horiz"
    done

    echo ""
    if [[ -n "$top_left" && -n "$top_right" ]]; then
        local padded_title
        padded_title="$(printf "%-${max_len}s" "$title")"

        epac_colored "${top_left}${border}${top_right}" "$primary"
        epac_colored "${vert}  ${padded_title}  ${vert}" "$primary"

        if [[ -n "$subtitle" ]]; then
            local padded_sub
            padded_sub="$(printf "%-${max_len}s" "$subtitle")"
            epac_colored "${vert}  ${padded_sub}  ${vert}" "$secondary"
        fi

        epac_colored "${bottom_left}${border}${bottom_right}" "$primary"
    else
        # Screen reader mode — no box drawing
        epac_colored "$title" "$primary"
        if [[ -n "$subtitle" ]]; then
            epac_colored "$subtitle" "$secondary"
        fi
    fi
    echo ""

    # Append to info stream
    epac_info_stream_append "${title}"
    [[ -n "$subtitle" ]] && epac_info_stream_append "${subtitle}"
}

# ─── Write-ModernSection ─────────────────────────────────────────────────────

epac_write_section() {
    local title="$1"
    local indent="${2:-0}"

    local arrow underline_char section_color
    arrow="$(_epac_theme_char 'section.arrow')"
    underline_char="$(_epac_theme_char 'section.underline')"
    section_color="$(_epac_theme_color 'section')"

    local prefix=""
    for (( i=0; i<indent; i++ )); do
        prefix+=" "
    done

    echo ""
    epac_colored "${prefix}${arrow} ${title}" "$section_color"

    if [[ -n "$underline_char" ]]; then
        local underline=""
        for (( i=0; i<${#title}+2; i++ )); do
            underline+="$underline_char"
        done
        epac_colored "${prefix}${underline}" "$section_color"
    fi

    epac_info_stream_append "${prefix}${arrow} ${title}"
}

# ─── Write-ModernStatus ──────────────────────────────────────────────────────

epac_write_status() {
    local message="$1"
    local status="${2:-info}"
    local indent="${3:-0}"

    local status_lower="${status,,}"

    local status_char
    status_char="$(_epac_theme_char "status.${status_lower}")"
    [[ -z "$status_char" ]] && status_char="$(_epac_theme_char 'status.info')"

    local status_color
    status_color="$(_epac_theme_color "status.${status_lower}")"
    [[ -z "$status_color" ]] && status_color="$(_epac_theme_color 'status.info')"

    local prefix=""
    for (( i=0; i<indent; i++ )); do
        prefix+=" "
    done

    local line="${prefix}${status_char} ${message}"
    epac_colored "$line" "$status_color"
    epac_info_stream_append "$line"
}

# ─── Write-ModernCountSummary ────────────────────────────────────────────────

epac_write_count_summary() {
    local type_name="$1"
    local unchanged="${2:-0}"
    local total_changes="${3:-0}"
    # Remaining args are key=value pairs for changes
    shift 3

    local -A changes=()
    local orphaned=-1
    local expired=-1
    local indent=2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --orphaned=*) orphaned="${1#*=}"; shift ;;
            --expired=*)  expired="${1#*=}"; shift ;;
            --indent=*)   indent="${1#*=}"; shift ;;
            *=*)
                local key="${1%%=*}"
                local val="${1#*=}"
                changes[$key]="$val"
                shift
                ;;
            *) shift ;;
        esac
    done

    epac_write_section "${type_name} Summary" 0

    if [[ $unchanged -gt 0 ]]; then
        epac_write_status "${unchanged} resources unchanged" "info" "$indent"
    fi

    if [[ $orphaned -ge 0 && $orphaned -gt 0 ]]; then
        epac_write_status "${orphaned} orphaned resources" "warning" "$indent"
    fi

    if [[ $expired -ge 0 && $expired -gt 0 ]]; then
        epac_write_status "${expired} expired resources" "warning" "$indent"
    fi

    if [[ $total_changes -eq 0 ]]; then
        epac_write_status "No changes required" "info" "$indent"
    else
        epac_write_status "${total_changes} total changes:" "info" "$indent"

        local sub_indent=$((indent + 2))
        [[ -n "${changes[new]:-}" && "${changes[new]}" -gt 0 ]] && \
            epac_write_status "${changes[new]} new" "success" "$sub_indent"
        [[ -n "${changes[update]:-}" && "${changes[update]}" -gt 0 ]] && \
            epac_write_status "${changes[update]} updates" "update" "$sub_indent"
        [[ -n "${changes[replace]:-}" && "${changes[replace]}" -gt 0 ]] && \
            epac_write_status "${changes[replace]} replacements" "warning" "$sub_indent"
        [[ -n "${changes[delete]:-}" && "${changes[delete]}" -gt 0 ]] && \
            epac_write_status "${changes[delete]} deletions" "error" "$sub_indent"
        [[ -n "${changes[add]:-}" && "${changes[add]}" -gt 0 ]] && \
            epac_write_status "${changes[add]} additions" "success" "$sub_indent"
        [[ -n "${changes[remove]:-}" && "${changes[remove]}" -gt 0 ]] && \
            epac_write_status "${changes[remove]} removals" "error" "$sub_indent"
    fi
}

# ─── Write-ModernProgress ────────────────────────────────────────────────────

epac_write_progress() {
    local current="$1"
    local total="$2"
    local activity="$3"
    local indent="${4:-0}"

    local progress_char
    progress_char="$(_epac_theme_char 'status.processing')"
    [[ -z "$progress_char" ]] && progress_char="🔄"

    local progress_color
    progress_color="$(_epac_theme_color 'status.processing')"
    [[ -z "$progress_color" ]] && progress_color="Yellow"

    local percentage=0
    if [[ $total -gt 0 ]]; then
        percentage=$(( (current * 100) / total ))
    fi

    local prefix=""
    for (( i=0; i<indent; i++ )); do
        prefix+=" "
    done

    local line="${prefix}${progress_char} ${activity} (${current}/${total} - ${percentage}%)"
    epac_colored "$line" "$progress_color"
    epac_info_stream_append "$line"
}

# ─── Write-DetailedDiff ──────────────────────────────────────────────────────
# Shows terraform-style diff of two JSON values

epac_write_diff() {
    local label="$1"
    local old_val="$2"
    local new_val="$3"
    local indent="${4:-2}"

    local prefix=""
    for (( i=0; i<indent; i++ )); do
        prefix+=" "
    done

    epac_colored "${prefix}~ ${label}:" "Yellow"

    # Show diff using jq
    local old_pretty new_pretty
    old_pretty="$(echo "$old_val" | jq '.' 2>/dev/null || echo "$old_val")"
    new_pretty="$(echo "$new_val" | jq '.' 2>/dev/null || echo "$new_val")"

    while IFS= read -r line; do
        epac_colored "${prefix}  - ${line}" "Red"
    done <<< "$old_pretty"

    while IFS= read -r line; do
        epac_colored "${prefix}  + ${line}" "Green"
    done <<< "$new_pretty"
}
