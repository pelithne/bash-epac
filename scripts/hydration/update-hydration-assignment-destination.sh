#!/usr/bin/env bash
# scripts/hydration/update-hydration-assignment-destination.sh
# Update management group references in assignment files
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(cd "$SCRIPT_DIR/../.." && pwd)/lib/hydration/hydration-definitions.sh"

usage() {
    cat <<'EOF'
Usage: update-hydration-assignment-destination.sh --pac-selector <NAME> --file <PATH> --old-mg <NAME> [OPTIONS]

Update the management group destination in an assignment file.

Required:
  --pac-selector   PAC selector name to update
  --file           Path to the assignment file
  --old-mg         Current management group name

At least one of:
  --new-mg         New management group name (static replacement)
  --new-prefix     Prefix for the new MG name (dynamic)
  --new-suffix     Suffix for the new MG name (dynamic)

Options:
  --output         Output directory (default: ./Output)
  --suppress-file  Suppress file output
  --help           Show this help message
EOF
    exit 0
}

pac_selector="" assignment_file="" old_mg="" new_mg="" new_prefix="" new_suffix=""
output="./Output" suppress_file=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help) usage ;;
        --pac-selector) pac_selector="$2"; shift 2 ;;
        --file) assignment_file="$2"; shift 2 ;;
        --old-mg) old_mg="$2"; shift 2 ;;
        --new-mg) new_mg="$2"; shift 2 ;;
        --new-prefix) new_prefix="$2"; shift 2 ;;
        --new-suffix) new_suffix="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        --suppress-file) suppress_file=true; shift ;;
        *) epac_log_error "Unknown option: $1"; exit 1 ;;
    esac
done

[[ -z "$pac_selector" ]] && { epac_log_error "Missing --pac-selector"; exit 1; }
[[ -z "$assignment_file" ]] && { epac_log_error "Missing --file"; exit 1; }
[[ -z "$old_mg" ]] && { epac_log_error "Missing --old-mg"; exit 1; }

if [[ -z "$new_mg" && -z "$new_prefix" && -z "$new_suffix" ]]; then
    epac_log_error "Must provide --new-mg, --new-prefix, or --new-suffix"
    exit 1
fi

if [[ ! -f "$assignment_file" ]]; then
    epac_log_error "Assignment file not found: $assignment_file"
    exit 1
fi

# Build the effective new name
if [[ -z "$new_mg" ]]; then
    new_mg="${new_prefix}${old_mg}${new_suffix}"
fi

old_provider="/providers/Microsoft.Management/managementGroups/${old_mg}"
new_provider="/providers/Microsoft.Management/managementGroups/${new_mg}"

# Read and transform with jq
content="$(epac_read_jsonc "$assignment_file")"

# Update scope references for the pac selector
updated="$(echo "$content" | jq --arg pac "$pac_selector" --arg old "$old_provider" --arg new "$new_provider" '
    walk(
        if type == "object" and has("scope") and (.scope | has($pac)) then
            .scope[$pac] = (.scope[$pac] | map(if . == $old then $new else . end))
        elif type == "object" and has("children") then
            .children = (.children // [] | map(
                if has("scope") and (.scope | has($pac)) then
                    .scope[$pac] = (.scope[$pac] | map(if . == $old then $new else . end))
                else .
                end
            ))
        else .
        end
    )
')"

if [[ "$suppress_file" == "true" ]]; then
    echo "$updated"
else
    # Write to output directory preserving relative path
    rel_path=""
    if [[ "$assignment_file" == *policyAssignments* ]]; then
        rel_path="${assignment_file#*policyAssignments}"
    else
        rel_path="/$(basename "$assignment_file")"
    fi
    output_file="${output}/UpdatedAssignmentDestination/Definitions/policyAssignments${rel_path}"
    mkdir -p "$(dirname "$output_file")"
    echo "$updated" | jq '.' > "$output_file"
    echo "Updated assignment written to: $output_file"
fi
