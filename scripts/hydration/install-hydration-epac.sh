#!/usr/bin/env bash
# scripts/hydration/install-hydration-epac.sh
# Main entry point: Interactive EPAC deployment wizard
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "${REPO_ROOT}/lib/hydration/hydration-core.sh"
source "${REPO_ROOT}/lib/hydration/hydration-mg.sh"
source "${REPO_ROOT}/lib/hydration/hydration-definitions.sh"
source "${REPO_ROOT}/lib/hydration/hydration-tests.sh"

usage() {
    cat <<'EOF'
Usage: install-hydration-epac.sh --tenant-intermediate-root <NAME> [OPTIONS]

Interactive EPAC deployment wizard. Guides through Azure Policy as Code setup
including management group hierarchy, global settings, and pipeline configuration.

Required arguments:
  --tenant-intermediate-root  Name of the Tenant Intermediate Root management group

Options:
  --definitions-root-folder   Path to definitions directory (default: ./Definitions)
  --output                    Path to output directory (default: ./Output)
  --answer-file               Path to pre-populated answer file (JSON)
  --interactive               Enable interactive mode (wait for user input)
  --skip-tests                Skip preliminary connectivity/path tests
  --utc                       Use UTC timestamps in logs
  --help                      Show this help message
EOF
    exit 0
}

tenant_ir=""
definitions_root="./Definitions"
output_dir="./Output"
answer_file=""
interactive=false
skip_tests=false
use_utc=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --tenant-intermediate-root) tenant_ir="$2"; shift 2 ;;
        --definitions-root-folder) definitions_root="$2"; shift 2 ;;
        --output) output_dir="$2"; shift 2 ;;
        --answer-file) answer_file="$2"; shift 2 ;;
        --interactive) interactive=true; shift ;;
        --skip-tests) skip_tests=true; shift ;;
        --utc) use_utc=true; shift ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$tenant_ir" ]]; then
    epac_log_error "Missing required --tenant-intermediate-root. Use --help for usage."
    exit 1
fi

term_width="$(hydration_terminal_width)"

# Setup directories
mkdir -p "$definitions_root" "$output_dir"
definitions_root="$(cd "$definitions_root" && pwd)"
output_dir="$(cd "$output_dir" && pwd)"
repo_root="$(dirname "$definitions_root")"

log_dir="${output_dir}/Logs"
log_file="${log_dir}/install-hydration-epac.log"
mkdir -p "$log_dir"

answer_dir="${output_dir}/HydrationAnswer"
answer_file_path="${answer_file:-${answer_dir}/AnswerFile.json}"

utc_flag=""
[[ "$use_utc" == "true" ]] && utc_flag="--utc"

# ══════════════════════════════════════════════════════════════════════════════
# Header
# ══════════════════════════════════════════════════════════════════════════════
clear
hydration_separator "Enterprise Policy as Code - Hydration Kit" "Top" "$term_width"
echo -e "\033[33mWelcome to the EPAC Hydration Kit. This script guides you through the deployment process.\033[0m"
echo -e "\033[33mPlease report any issues to the EPAC team.\033[0m"
hydration_continue_prompt "$interactive" 5
hydration_log newStage "Installation Started" "$log_file" $utc_flag --silent

# ══════════════════════════════════════════════════════════════════════════════
# Preliminary Tests
# ══════════════════════════════════════════════════════════════════════════════
declare -A test_summary

if [[ "$skip_tests" == "false" ]]; then
    hydration_separator "Preliminary Tests" "Middle" "$term_width"
    hydration_log newStage "Preliminary Tests" "$log_file" $utc_flag --silent

    # Path tests
    echo -e "\033[33mRunning path tests...\033[0m"
    for test_path in "$definitions_root" "$output_dir" "$log_dir"; do
        result="$(hydration_test_path "$test_path" "$log_file")"
        test_summary["path:${test_path}"]="$result"
    done

    # Connectivity tests
    echo -e "\033[33mRunning connectivity tests...\033[0m"
    for test_host in "www.github.com" "management.azure.com" "login.microsoftonline.com"; do
        result="$(hydration_test_connection "$test_host" "$log_file" 2>/dev/null || echo "Failed")"
        test_summary["conn:${test_host}"]="$result"
    done

    # Git test
    echo -e "\033[33mChecking git installation...\033[0m"
    test_summary["git"]="$(hydration_test_git)"

    # Display results
    hydration_separator "Test Results" "Middle" "$term_width"
    local_failures=0
    for key in "${!test_summary[@]}"; do
        local status="${test_summary[$key]}"
        local pad_len=$((term_width - ${#key} - ${#status} - 2))
        [[ $pad_len -lt 1 ]] && pad_len=1
        local pad="$(printf '%*s' "$pad_len" '' | tr ' ' '-')"
        if [[ "$status" == *"Failed"* ]]; then
            echo -e "\033[31m${key} ${pad} ${status}\033[0m"
            local_failures=$((local_failures + 1))
        else
            echo -e "\033[32m${key} ${pad} ${status}\033[0m"
        fi
        hydration_log logEntryDataAsPresented "Summary: ${key} -- ${status}" "$log_file" $utc_flag --silent
    done

    if [[ $local_failures -gt 0 ]]; then
        echo ""
        echo -e "\033[31mSome tests failed. The wizard will continue but some features may be limited.\033[0m"
    else
        echo ""
        echo -e "\033[32mAll tests passed. Optimal state for EPAC installation.\033[0m"
    fi
    hydration_continue_prompt "$interactive" 5
fi

# ══════════════════════════════════════════════════════════════════════════════
# Data Gathering
# ══════════════════════════════════════════════════════════════════════════════
hydration_separator "Data Gathering" "Middle" "$term_width"
hydration_log newStage "Data Gathering" "$log_file" $utc_flag --silent

echo -e "\033[33mGathering Azure environment data...\033[0m"

# Get tenant/cloud info
tenant_id="$(az account show --query tenantId -o tsv 2>/dev/null || echo "")"
cloud="$(az cloud show --query name -o tsv 2>/dev/null || echo "AzureCloud")"

if [[ -z "$tenant_id" ]]; then
    epac_log_error "Cannot determine tenant ID. Ensure you are connected to Azure (az login)."
    exit 1
fi

if [[ "$tenant_ir" == "$tenant_id" ]]; then
    epac_log_error "Tenant Intermediate Root is the same as the Tenant ID. Choose an intermediate root that is not your Tenant Root."
    exit 1
fi

# Check if intermediate root MG exists
ir_exists=false
if az account management-group show --name "$tenant_ir" &>/dev/null; then
    ir_exists=true
    hydration_log logEntryDataAsPresented "Tenant Intermediate Root '$tenant_ir' confirmed." "$log_file" $utc_flag --color green
else
    hydration_log logEntryDataAsPresented "Tenant Intermediate Root '$tenant_ir' does not exist." "$log_file" $utc_flag --color yellow
fi

# Get location list
locations="$(az account list-locations --query "[].name" -o tsv 2>/dev/null | tr '\n' ', ' | sed 's/,$//' || echo "")"

hydration_log logEntryDataAsPresented "Data gathered: tenantId=$tenant_id, cloud=$cloud, irExists=$ir_exists" "$log_file" $utc_flag --silent
hydration_continue_prompt "$interactive" 3

# ══════════════════════════════════════════════════════════════════════════════
# Interview Process
# ══════════════════════════════════════════════════════════════════════════════
hydration_separator "Configuration Interview" "Middle" "$term_width"

# Load or build answers
if [[ -n "$answer_file" && -f "$answer_file" ]]; then
    hydration_log logEntryDataAsPresented "Loading answers from $answer_file" "$log_file" $utc_flag --color yellow
    answers="$(cat "$answer_file")"
else
    hydration_log logEntryDataAsPresented "Starting interactive interview..." "$log_file" $utc_flag --color yellow

    # Build answers interactively
    answers='{}'

    # Q1: Create intermediate root?
    if [[ "$ir_exists" == "false" ]]; then
        hydration_separator "Management Group Setup" "Middle" "$term_width"
        echo "The Tenant Intermediate Root '$tenant_ir' does not exist."
        create_ir="$(hydration_multiple_choice "Create it now?" "Yes" "No")"
        answers="$(echo "$answers" | jq --arg v "$create_ir" '.createIntermediateRoot = $v')"

        if [[ "$create_ir" == "Yes" ]]; then
            echo "Creating management group '$tenant_ir'..."
            if az account management-group create --name "$tenant_ir" --display-name "$tenant_ir" -o none 2>/dev/null; then
                echo -e "\033[32mCreated '$tenant_ir'\033[0m"
                ir_exists=true
            else
                echo -e "\033[31mFailed to create '$tenant_ir'. Continuing without it.\033[0m"
            fi
        fi
    fi

    # Q2: Create CAF3 hierarchy?
    if [[ "$ir_exists" == "true" ]]; then
        hydration_separator "CAF 3.0 Hierarchy" "Middle" "$term_width"
        echo "Would you like to create a CAF 3.0 management group hierarchy under '$tenant_ir'?"
        create_caf3="$(hydration_multiple_choice "Create CAF 3.0 hierarchy?" "Yes" "No")"
        answers="$(echo "$answers" | jq --arg v "$create_caf3" '.createCaf3Hierarchy = $v')"

        if [[ "$create_caf3" == "Yes" ]]; then
            echo "Creating CAF 3.0 hierarchy..."
            hydration_create_caf3 "$tenant_ir"
        fi
    fi

    # Q3: PAC Selector configuration
    hydration_separator "PAC Environment Configuration" "Middle" "$term_width"

    echo "Configure the main PAC selector for your production tenant."
    main_pac_selector="$(hydration_text_prompt "Main PAC selector name" "tenant01")"
    answers="$(echo "$answers" | jq --arg v "$main_pac_selector" '.mainPacSelector = $v')"

    mi_location="$(hydration_text_prompt "Managed Identity location (e.g. eastus)" "")"
    answers="$(echo "$answers" | jq --arg v "$mi_location" '.managedIdentityLocation = $v')"

    # Q4: EPAC Dev environment
    hydration_separator "EPAC Development Environment" "Middle" "$term_width"

    echo "Configure the EPAC development environment (used for CI/CD testing)."
    epac_prefix="$(hydration_text_prompt "EPAC dev MG prefix (e.g. epac-)" "epac-")"
    answers="$(echo "$answers" | jq --arg v "$epac_prefix" '.epacPrefix = $v')"

    epac_suffix="$(hydration_text_prompt "EPAC dev MG suffix (leave empty for none)" "")"
    answers="$(echo "$answers" | jq --arg v "$epac_suffix" '.epacSuffix = $v')"

    epac_pac_selector="$(hydration_text_prompt "EPAC dev PAC selector name" "epac-dev")"
    answers="$(echo "$answers" | jq --arg v "$epac_pac_selector" '.epacPacSelector = $v')"

    # Q5: Desired state strategy
    hydration_separator "Policy Strategy" "Middle" "$term_width"
    strategy="$(hydration_multiple_choice "Desired state strategy?" "full" "ownedOnly")"
    answers="$(echo "$answers" | jq --arg v "$strategy" '.strategy = $v')"

    keep_dfc="$(hydration_multiple_choice "Keep DfC Security assignments?" "false" "true")"
    answers="$(echo "$answers" | jq --arg v "$keep_dfc" '.keepDfcSecurityAssignments = $v')"

    # Q6: Pipeline choice
    hydration_separator "Pipeline Configuration" "Middle" "$term_width"
    pipeline_type="$(hydration_multiple_choice "Pipeline platform?" "GitHubActions" "AzureDevOps")"
    answers="$(echo "$answers" | jq --arg v "$pipeline_type" '.pipelineType = $v')"

    branching_flow="$(hydration_multiple_choice "Branching flow?" "Release" "GitHub")"
    answers="$(echo "$answers" | jq --arg v "$branching_flow" '.branchingFlow = $v')"

    # Save answers
    mkdir -p "$(dirname "$answer_file_path")"
    echo "$answers" | jq '.' > "$answer_file_path"
    hydration_log logEntryDataAsPresented "Answers saved to $answer_file_path" "$log_file" $utc_flag --color green
fi

# Extract values from answers
main_pac_selector="$(echo "$answers" | jq -r '.mainPacSelector // "tenant01"')"
epac_pac_selector="$(echo "$answers" | jq -r '.epacPacSelector // "epac-dev"')"
mi_location="$(echo "$answers" | jq -r '.managedIdentityLocation // ""')"
strategy="$(echo "$answers" | jq -r '.strategy // "full"')"
keep_dfc="$(echo "$answers" | jq -r '.keepDfcSecurityAssignments // "false"')"
epac_prefix="$(echo "$answers" | jq -r '.epacPrefix // ""')"
epac_suffix="$(echo "$answers" | jq -r '.epacSuffix // ""')"
pipeline_type="$(echo "$answers" | jq -r '.pipelineType // "GitHubActions"')"
branching_flow="$(echo "$answers" | jq -r '.branchingFlow // "Release"')"

# ══════════════════════════════════════════════════════════════════════════════
# Generate Definitions
# ══════════════════════════════════════════════════════════════════════════════
hydration_separator "Generating Definitions" "Middle" "$term_width"
hydration_log newStage "Generating Definitions" "$log_file" $utc_flag --silent

# Create folder structure
hydration_create_definitions_folder "$definitions_root"
echo "Created definitions folder structure."

# Generate global settings
pac_owner_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
epac_root="${epac_prefix}${tenant_ir}${epac_suffix}"

keep_dfc_flag=""
[[ "$keep_dfc" == "true" ]] && keep_dfc_flag="--keep-dfc"

gs_file="$(hydration_create_global_settings \
    --pac-owner-id "$pac_owner_id" \
    --mi-location "$mi_location" \
    --main-pac-selector "$main_pac_selector" \
    --epac-pac-selector "$epac_pac_selector" \
    --cloud "$cloud" \
    --tenant-id "$tenant_id" \
    --main-root "$tenant_ir" \
    --epac-root "$epac_root" \
    --strategy "$strategy" \
    --definitions-root "$definitions_root" \
    --log-file "$log_file" \
    $keep_dfc_flag)"

echo -e "\033[32mGenerated global settings: ${gs_file}\033[0m"

# ══════════════════════════════════════════════════════════════════════════════
# Create EPAC Dev Hierarchy
# ══════════════════════════════════════════════════════════════════════════════
if [[ -n "$epac_prefix" || -n "$epac_suffix" ]]; then
    hydration_separator "EPAC Dev Hierarchy" "Middle" "$term_width"
    echo "Creating EPAC development management group hierarchy..."

    if hydration_copy_mg_hierarchy "$tenant_ir" "$tenant_id" "$epac_prefix" "$epac_suffix" 2>/dev/null; then
        echo -e "\033[32mEPAC dev hierarchy created.\033[0m"
    else
        echo -e "\033[33mSkipped EPAC dev hierarchy (requires Azure permissions).\033[0m"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Copy Pipeline Templates
# ══════════════════════════════════════════════════════════════════════════════
hydration_separator "Pipeline Setup" "Middle" "$term_width"

if [[ -d "${repo_root}/StarterKit" ]]; then
    echo "Copying $pipeline_type pipeline templates ($branching_flow flow)..."
    bash "${REPO_ROOT}/scripts/operations/new-pipelines-from-starter-kit.sh" \
        --starter-kit-folder "${repo_root}/StarterKit" \
        --pipeline-type "$pipeline_type" \
        --branching-flow "$branching_flow" \
        --script-type Module \
        --suppress-confirm 2>/dev/null || echo "Pipeline template copy completed with warnings."
else
    echo -e "\033[33mStarterKit folder not found. Attempting to download...\033[0m"
    if hydration_get_epac_repo "$repo_root" 2>/dev/null; then
        if [[ -d "${repo_root}/temp/StarterKit" ]]; then
            cp -r "${repo_root}/temp/StarterKit" "${repo_root}/StarterKit"
            bash "${REPO_ROOT}/scripts/operations/new-pipelines-from-starter-kit.sh" \
                --starter-kit-folder "${repo_root}/StarterKit" \
                --pipeline-type "$pipeline_type" \
                --branching-flow "$branching_flow" \
                --script-type Module \
                --suppress-confirm 2>/dev/null || true
        fi
    else
        echo -e "\033[31mCannot download StarterKit. Please manually download from https://github.com/Azure/enterprise-azure-policy-as-code\033[0m"
    fi
fi

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
hydration_separator "Installation Complete" "Bottom" "$term_width"

echo "EPAC Hydration Kit setup is complete."
echo ""
echo "  Definitions:     $definitions_root"
echo "  Global Settings: ${definitions_root}/global-settings.jsonc"
echo "  Answer File:     $answer_file_path"
echo "  Log File:        $log_file"
echo ""
echo "Next steps:"
echo "  1. Review and customize the global-settings.jsonc"
echo "  2. Add policy definitions under ${definitions_root}/policyDefinitions/"
echo "  3. Add policy assignments under ${definitions_root}/policyAssignments/"
echo "  4. Run the deployment plan builder to validate"
echo ""

hydration_log newStage "Installation Complete" "$log_file" $utc_flag --silent
