#!/usr/bin/env bash
# scripts/operations/convert-markdown-github-alerts.sh
# Convert Markdown alert syntax between MkDocs format (!!!) and GitHub format (> [!...])
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/lib/epac.sh"

usage() {
    cat <<'EOF'
Usage: convert-markdown-github-alerts.sh [OPTIONS]

Convert Markdown alert syntax between MkDocs admonition format and GitHub alert format.

Options:
  --input-folder <PATH>     Source markdown folder (default: $PAC_INPUT_FOLDER or "Docs")
  --output-folder <PATH>    Destination folder (default: $PAC_OUTPUT_FOLDER or "Output")
  --to-github-alerts        Convert MkDocs → GitHub alerts (default: GitHub → MkDocs)
  --help                    Show this help message

MkDocs format:     !!! note
                   <empty line>
                       Content indented 4 spaces

GitHub format:     > [!NOTE]
                   > Content
EOF
    exit 0
}

input_folder="${PAC_INPUT_FOLDER:-Docs}"
output_folder="${PAC_OUTPUT_FOLDER:-Output}"
to_github=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --input-folder) input_folder="$2"; shift 2 ;;
        --output-folder) output_folder="$2"; shift 2 ;;
        --to-github-alerts) to_github=true; shift ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ ! -d "$input_folder" ]]; then
    epac_log_error "Input folder not found: $input_folder"
    exit 1
fi

# Resolve input folder to absolute path (strip trailing slash)
input_folder_abs="$(cd "$input_folder" && pwd)"

# Map MkDocs type → GitHub alert
mkdocs_to_github() {
    local type_str="$1"
    case "$type_str" in
        note|abstract|info|success|question|example) echo "> [!NOTE]" ;;
        tip) echo "> [!TIP]" ;;
        'tip "Important"'|'success "Important"') echo "> [!IMPORTANT]" ;;
        warning) echo "> [!WARNING]" ;;
        'danger "Caution"'|danger|failure|bug) echo "> [!CAUTION]" ;;
        *) epac_log_error "Unsupported admonition type: $type_str"; exit 1 ;;
    esac
}

# Map GitHub alert → MkDocs type
github_to_mkdocs() {
    local type_str="$1"
    case "$type_str" in
        '> [!NOTE]')      echo '!!! note' ;;
        '> [!TIP]')       echo '!!! tip' ;;
        '> [!IMPORTANT]') echo '!!! tip "Important"' ;;
        '> [!WARNING]')   echo '!!! warning' ;;
        '> [!CAUTION]')   echo '!!! danger "Caution"' ;;
        *) epac_log_error "Unsupported alert type: $type_str"; exit 1 ;;
    esac
}

file_count=0

# Find all .md files recursively
while IFS= read -r -d '' md_file; do
    # Compute relative path
    relative="${md_file#"${input_folder_abs}/"}"
    out_file="${output_folder}/${relative}"
    out_dir="$(dirname "$out_file")"
    mkdir -p "$out_dir"

    if [[ "$to_github" == "true" ]]; then
        # MkDocs → GitHub
        in_alert=false
        alert_lines=0

        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "!!! "* ]]; then
                type_str="${line#!!! }"
                type_str="$(echo "$type_str" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                in_alert=true
                alert_lines=0
                mkdocs_to_github "$type_str"
            elif [[ "$in_alert" == "true" ]]; then
                if [[ $alert_lines -eq 1 ]]; then
                    if [[ "$line" == "    "* && ${#line} -gt 4 ]]; then
                        echo "> ${line:4}"
                        in_alert=false
                    else
                        epac_log_error "Invalid admonition format in $md_file; text must be indented by 4 spaces and not empty"
                        exit 1
                    fi
                else
                    alert_lines=$((alert_lines + 1))
                    if [[ $alert_lines -gt 1 ]] || [[ -n "$(echo "$line" | tr -d '[:space:]')" ]]; then
                        epac_log_error "Invalid admonition format in $md_file; exactly one empty line required between type and text"
                        exit 1
                    fi
                fi
            else
                echo "$line"
            fi
        done < "$md_file" > "$out_file"

    else
        # GitHub → MkDocs
        in_alert=false

        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "> [!"* ]]; then
                type_str="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                in_alert=true
                github_to_mkdocs "$type_str"
                echo ""
            elif [[ "$in_alert" == "true" ]]; then
                if [[ "$line" == "> "* ]]; then
                    echo "    ${line:2}"
                    in_alert=false
                else
                    epac_log_error "Invalid GitHub alert format in $md_file; content must start with '> '"
                    exit 1
                fi
            else
                echo "$line"
            fi
        done < "$md_file" > "$out_file"
    fi

    file_count=$((file_count + 1))
done < <(find "$input_folder_abs" -name '*.md' -print0)

epac_write_status "Converted $file_count .md files from $input_folder to $output_folder" "success" 2
