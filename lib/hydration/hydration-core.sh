#!/usr/bin/env bash
# lib/hydration/hydration-core.sh — Core hydration helpers (logging, UI, prompts)
[[ -n "${_EPAC_HYDRATION_CORE_LOADED:-}" ]] && return 0
_EPAC_HYDRATION_CORE_LOADED=1

SCRIPT_DIR_HC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR_HC}/../epac.sh"

# Terminal width detection
hydration_terminal_width() {
    local w
    w="$(tput cols 2>/dev/null || echo 80)"
    [[ "$w" -lt 80 ]] && w=80
    echo "$w"
}

# ══════════════════════════════════════════════════════════════════════════════
# Logging
# ══════════════════════════════════════════════════════════════════════════════

# Write a timestamped log entry
# Usage: hydration_log <entry_type> <message> <log_file> [--utc] [--silent] [--color <color>]
hydration_log() {
    local entry_type="$1" message="$2" log_file="$3"
    shift 3
    local use_utc=false silent=false color=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --utc) use_utc=true; shift ;;
            --silent) silent=true; shift ;;
            --color) color="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local timestamp
    if [[ "$use_utc" == "true" ]]; then
        timestamp="$(date -u '+%Y-%m-%d_%H:%M:%S')"
    else
        timestamp="$(date '+%Y-%m-%d_%H:%M:%S')"
    fi

    # Format the output string
    local output_string
    case "$entry_type" in
        newStage)       output_string="Stage Initiated: $message" ;;
        commandStart)   output_string="Command Run: $message" ;;
        testStart)      output_string="Beginning Test $message" ;;
        testResult)     output_string="Test Result Data: $message" ;;
        answerRequested) output_string="Requesting response to: $message" ;;
        answerSetProvided) output_string="Response(s) Provided: $message" ;;
        *)              output_string="$message" ;;
    esac

    # Display unless silent
    if [[ "$silent" == "false" ]]; then
        local color_code=""
        case "$color" in
            red)     color_code="\033[31m" ;;
            green)   color_code="\033[32m" ;;
            yellow)  color_code="\033[33m" ;;
            blue)    color_code="\033[34m" ;;
            magenta) color_code="\033[35m" ;;
            cyan)    color_code="\033[36m" ;;
            *)       color_code="" ;;
        esac
        if [[ -n "$color_code" ]]; then
            echo -e "${color_code}${output_string}\033[0m"
        else
            echo "$output_string"
        fi
    fi

    # Append to log file
    if [[ -n "$log_file" ]]; then
        mkdir -p "$(dirname "$log_file")"
        if [[ ! -f "$log_file" ]]; then
            echo "EPAC Hydration Kit Log File==========" > "$log_file"
            echo "$timestamp -- Log File Created" >> "$log_file"
        fi
        echo "$timestamp -- $output_string" >> "$log_file"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# UI Separator Blocks
# ══════════════════════════════════════════════════════════════════════════════

# Display a separator block with centered title
# Usage: hydration_separator <text> <location> [width] [large_char] [small_char]
hydration_separator() {
    local text="$1" location="$2"
    local width="${3:-80}" large_char="${4:-=}" small_char="${5:--}"

    local large_row small_row text_row
    large_row="$(printf '%*s' "$width" '' | tr ' ' "$large_char")"
    small_row="$(printf '%*s' "$width" '' | tr ' ' "$small_char")"

    local modified=" $text "
    local total_pad=$((width - ${#modified}))
    [[ $total_pad -lt 0 ]] && total_pad=0
    local front=$((total_pad / 2))
    local back=$((total_pad - front))

    text_row="$(printf '%*s' "$front" '' | tr ' ' "$small_char")${modified}$(printf '%*s' "$back" '' | tr ' ' "$small_char")"

    case "$location" in
        Top)
            echo ""
            echo -e "\033[32m${large_row}\033[0m"
            echo -e "\033[33m${text_row}\033[0m"
            echo ""
            ;;
        Middle)
            echo ""
            echo -e "\033[32m${small_row}\033[0m"
            echo -e "\033[33m${text_row}\033[0m"
            echo -e "\033[32m${small_row}\033[0m"
            echo ""
            ;;
        Bottom)
            echo ""
            echo -e "\033[33m${text_row}\033[0m"
            echo -e "\033[32m${large_row}\033[0m"
            echo ""
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════════════════════
# Prompts & Menus
# ══════════════════════════════════════════════════════════════════════════════

# Continue prompt (interactive waits for Enter, non-interactive sleeps)
hydration_continue_prompt() {
    local interactive="${1:-false}" sleep_time="${2:-5}"
    if [[ "$interactive" == "true" ]]; then
        read -rp "Press Enter to continue..."
    else
        sleep "$sleep_time"
    fi
}

# Display a numbered menu and capture selection
# Usage: hydration_menu_response <prompt> <option1> <option2> ...
# Returns: selected option value
hydration_menu_response() {
    local prompt="$1"
    shift
    local options=("$@")
    local count=${#options[@]}
    local i

    echo ""
    for i in $(seq 0 $((count - 1))); do
        echo "  $((i + 1)). ${options[$i]}"
    done
    echo ""

    local choice
    while true; do
        read -rp "$prompt [1-$count]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$count" ]]; then
            echo "${options[$((choice - 1))]}"
            return 0
        fi
        echo "  Invalid selection. Please enter a number between 1 and $count."
    done
}

# Multiple-choice prompt
# Usage: result=$(hydration_multiple_choice "Question?" "opt1" "opt2" "opt3")
hydration_multiple_choice() {
    local prompt="$1"
    shift
    hydration_menu_response "$prompt" "$@"
}

# Free text prompt with optional default
# Usage: result=$(hydration_text_prompt "Enter value" "default")
hydration_text_prompt() {
    local prompt="$1" default="${2:-}"
    local response
    if [[ -n "$default" ]]; then
        read -rp "$prompt [$default]: " response
        echo "${response:-$default}"
    else
        read -rp "$prompt: " response
        echo "$response"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Answer File Management
# ══════════════════════════════════════════════════════════════════════════════

# Save answers to JSON file
hydration_save_answers() {
    local answer_file="$1" answers_json="$2"
    mkdir -p "$(dirname "$answer_file")"
    echo "$answers_json" | jq '.' > "$answer_file"
}

# Load answers from JSON file
hydration_load_answers() {
    local answer_file="$1"
    if [[ -f "$answer_file" ]]; then
        cat "$answer_file"
    else
        echo "{}"
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
# Management Group Name Validation
# ══════════════════════════════════════════════════════════════════════════════

# Validate MG name format (alphanumeric, hyphens, underscores, periods; max 90 chars)
hydration_validate_mg_name() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "Name cannot be empty"
        return 1
    fi
    if [[ ${#name} -gt 90 ]]; then
        echo "Name exceeds 90 character limit"
        return 1
    fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        echo "Name can only contain alphanumeric characters, hyphens, underscores, and periods"
        return 1
    fi
    return 0
}
