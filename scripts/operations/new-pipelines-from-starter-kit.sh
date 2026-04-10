#!/usr/bin/env bash
# scripts/operations/new-pipelines-from-starter-kit.sh
# Copy CI/CD pipeline templates from StarterKit to project folder
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/lib/epac.sh"

usage() {
    cat <<'EOF'
Usage: new-pipelines-from-starter-kit.sh [OPTIONS]

Copy pipelines and templates from starter kit to new project structure.

Options:
  --starter-kit-folder <PATH>   Source starter kit (default: ./StarterKit)
  --pipelines-folder <PATH>     Destination folder (auto-detected from pipeline type)
  --pipeline-type <TYPE>        AzureDevOps or GitHubActions (default: GitHubActions)
  --branching-flow <FLOW>       Release or GitHub (default: Release)
  --script-type <TYPE>          Module or Scripts (default: Module)
  --suppress-confirm            Skip confirmation prompt
  --help                        Show this help message
EOF
    exit 0
}

starter_kit_folder="./StarterKit"
pipelines_folder=""
pipeline_type="GitHubActions"
branching_flow="Release"
script_type="Module"
suppress_confirm=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --starter-kit-folder) starter_kit_folder="$2"; shift 2 ;;
        --pipelines-folder) pipelines_folder="$2"; shift 2 ;;
        --pipeline-type) pipeline_type="$2"; shift 2 ;;
        --branching-flow) branching_flow="$2"; shift 2 ;;
        --script-type) script_type="$2"; shift 2 ;;
        --suppress-confirm) suppress_confirm=true; shift ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate starter kit folder
if [[ ! -d "$starter_kit_folder" ]]; then
    epac_log_error "Starter kit folder not found: $starter_kit_folder"
    exit 1
fi

# Validate pipeline type
case "$pipeline_type" in
    AzureDevOps|GitHubActions) ;;
    *) epac_log_error "Invalid pipeline type '$pipeline_type'. Must be AzureDevOps or GitHubActions."; exit 1 ;;
esac

# Validate branching flow
case "$branching_flow" in
    Release|GitHub) ;;
    *) epac_log_error "Invalid branching flow '$branching_flow'. Must be Release or GitHub."; exit 1 ;;
esac

# Validate script type
case "$script_type" in
    Module|Scripts) ;;
    *) epac_log_error "Invalid script type '$script_type'. Must be Module or Scripts."; exit 1 ;;
esac

# Determine source and destination paths
starter_pipelines_folder=""
templates_folder=""
pipeline_type_text=""
template_type_text=""

case "$pipeline_type" in
    AzureDevOps)
        [[ -z "$pipelines_folder" ]] && pipelines_folder="./Pipelines"
        templates_folder="${pipelines_folder}/templates"
        starter_pipelines_folder="${starter_kit_folder}/Pipelines/AzureDevOps"
        pipeline_type_text="Azure DevOps pipelines"
        template_type_text="Azure DevOps templates"
        ;;
    GitHubActions)
        [[ -z "$pipelines_folder" ]] && pipelines_folder="./.github/workflows"
        templates_folder="$pipelines_folder"
        starter_pipelines_folder="${starter_kit_folder}/Pipelines/GitHubActions"
        pipeline_type_text="GitHub Actions workflows"
        template_type_text="GitHub Actions reusable workflows"
        ;;
esac

# Determine branching flow subfolder
case "$branching_flow" in
    Release) branching_subfolder="Release-Flow" ;;
    GitHub)  branching_subfolder="GitHub-Flow" ;;
esac
starter_pipelines_path="${starter_pipelines_folder}/${branching_subfolder}"

# Determine script type subfolder
case "$script_type" in
    Module)  templates_subfolder="templates-ps1-module" ;;
    Scripts) templates_subfolder="templates-ps1-scripts" ;;
esac
starter_templates_path="${starter_pipelines_folder}/${templates_subfolder}"

# Create destination folders
mkdir -p "$templates_folder"

# Display plan
epac_write_status "Copying $pipeline_type_text ($branching_subfolder) from '${starter_pipelines_path}/*.yml' to $pipelines_folder" "info" 2
epac_write_status "Copying $template_type_text ($script_type) from '${starter_templates_path}/*.yml' to $templates_folder" "info" 2

# Confirm
if [[ "$suppress_confirm" == "false" ]]; then
    read -rp "Press Enter to continue (Ctrl-C to cancel)..."
fi

# Copy pipeline files
if ls "${starter_pipelines_path}"/*.yml 1>/dev/null 2>&1; then
    cp "${starter_pipelines_path}"/*.yml "$pipelines_folder/"
    epac_write_status "Copied pipeline files" "success" 2
else
    epac_write_status "No pipeline .yml files found in ${starter_pipelines_path}" "warning" 2
fi

# Copy template files
if ls "${starter_templates_path}"/*.yml 1>/dev/null 2>&1; then
    cp "${starter_templates_path}"/*.yml "$templates_folder/"
    epac_write_status "Copied template files" "success" 2
else
    epac_write_status "No template .yml files found in ${starter_templates_path}" "warning" 2
fi
