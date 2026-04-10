# EPAC Bash Rewrite - Work Breakdown

## Overview
Rewrite 186 PowerShell files to Bash. The project uses Azure REST APIs extensively via `Invoke-AzRestMethod`, hashtable/JSON processing, and a module packaging system.

## Key Technology Decisions
- **Azure CLI (`az`)** replaces Az PowerShell modules
- **`jq`** replaces PowerShell's JSON/hashtable operations
- **`curl`** + Azure CLI tokens for REST API calls (replacing `Invoke-AzRestMethod`)
- **JSONC** support via stripping comments before `jq` processing
- **Bash source/library pattern** replaces PowerShell module system
- **`set -euo pipefail`** + trap handlers for error handling

## Work Items (Feature Branches)

### WI-01: Project scaffolding & core utilities ✅
- Directory structure mirroring PS layout
- lib/core.sh - error handling, logging, colored output
- lib/json.sh - JSONC parsing, jq wrappers, deep merge
- lib/utils.sh - string manipulation, display formatting, array ops
- Main entry point script pattern
- Branch: feature/wi-01-core-utilities

### WI-02: Azure authentication & context management ✅
- lib/azure-auth.sh - Azure CLI login, context setting
- Cloud/tenant/subscription switching
- Token acquisition for REST calls
- Replaces: Set-AzCloudTenantSubscription.ps1, Select-PacEnvironment.ps1
- Branch: feature/wi-02-azure-auth

### WI-03: Configuration & global settings ✅
- lib/config.sh - Global settings parser
- PAC folder resolution
- PAC environment selection/switching
- Desired state strategy loading
- Replaces: Get-GlobalSettings.ps1, Get-PacFolders.ps1, Switch-PacEnvironment.ps1
- Branch: feature/wi-03-config

### WI-04: Azure REST API wrappers ✅
- lib/rest/ directory with 13 REST wrappers
- Policy definitions, assignments, exemptions CRUD
- Role assignments/definitions
- Management group hierarchy
- Resource listing
- Replaces: Scripts/Helpers/RestMethods/*.ps1
- Branch: feature/wi-04-rest-api

### WI-05: Resource Graph & policy resource retrieval ✅
- lib/azure-resources.sh - Resource Graph queries with pagination
- Policy resource collection (definitions, sets, assignments, exemptions)
- Policy resource details extraction
- Replaces: Search-AzGraphAllItems.ps1, Get-AzPolicyResources.ps1, Get-AzPolicy*.ps1
- Branch: feature/wi-05-resource-retrieval

### WI-06: Data transformation utilities ✅
- lib/transforms.sh - JSON transformations via jq
- Deep clone, merge, flatten operations
- Effect/parameter/metadata conversions
- Scope ID parsing and splitting
- Replaces: Convert-*.ps1, ConvertTo-*.ps1, Get-DeepClone*.ps1, Split-*.ps1
- Branch: feature/wi-06-transforms

### WI-07: Validation & confirmation functions ✅
- lib/validators.sh - All validation functions
- Policy definition matching, parameter validation
- Effect validation, metadata comparison
- Deep equality checks, PAC ownership validation
- Replaces: All Confirm-*.ps1 files (~20 files)
- Branch: feature/wi-07-validators

### WI-08: Scope table building ✅
- Scope tables already in WI-05; added epac_set_unique_role_assignment_scopes
- Branch: feature/wi-07-validators (committed as addendum)

### WI-09: Policy & policy set plan building ✅
- lib/plans/policy-plan.sh, lib/plans/policy-set-plan.sh
- 58 tests, 584 total
- Branch: feature/wi-09-policy-plans

### WI-10: Assignment plan building ✅
- lib/plans/assignment-plan.sh (1440 lines)
- Recursive tree builder, definition entry resolution, leaf processor
- CSV parameter merge, identity change detection, role assignment tracking
- Pac-selector-aware helpers, override chunking
- 114 tests, 698 total
- Branch: feature/wi-10-assignment-plans

### WI-11: Exemptions & deployment plan orchestration ✅
- lib/plans/exemptions-plan.sh (~480 lines) - Exemptions plan building
  - _epac_get_calculated_assignments: 3 lookup tables
  - _epac_resolve_exemption_assignments: 3 resolution strategies + DoNotValidate
  - epac_build_exemptions_plan: CSV/JSON/JSONC input, scope expansion, comparison
  - _epac_parse_csv_exemptions, _epac_emit_exemptions_plan_result
- scripts/deploy/build-deployment-plans.sh (~300 lines) - CLI orchestrator
  - Argument parsing, build selections, scope table, resource discovery
  - Sequential plan building: policy→policySet→assignment→exemption
  - Output plan JSON files, ADO/GitLab pipeline variables
- tests/test_exemptions_plans.sh: 86 tests, 784 total
- Branch: feature/wi-11-deployment-plans (commit 603ba7d)

### WI-12: Policy deployment ✅
- scripts/deploy/deploy-policy-plan.sh (~224 lines) - 9-phase deployment
- scripts/deploy/deploy-roles-plan.sh (~226 lines) - Role assignments with identity resolution
- scripts/deploy/set-az-policy-exemption.sh (~102 lines) - Standalone exemption create/update
- scripts/deploy/remove-az-policy-exemption.sh (~44 lines) - Standalone exemption removal
- tests/test_deployment.sh: 76 tests, 860 total
- Branch: feature/wi-12-deployment (commit 9cec48d)

### WI-13: Export operations ✅
- lib/exports/export-nodes.sh (~500 lines) - Export tree management
- lib/exports/export-output.sh (~240 lines) - Definition/assignment/exemption output
- scripts/operations/export-az-policy-resources.sh (~480 lines) - 5-mode export orchestrator
- scripts/operations/export-policy-to-epac.sh (~350 lines) - Portal/ALZ policy converter
- tests/test_exports.sh: 103 tests, 963 total
- Branch: feature/wi-13-exports (commit d055f9f)

### WI-14: Documentation generation ✅
- lib/documentation/doc-policy-sets.sh (~480 lines) - Markdown/CSV/compliance CSV/JSONC/ADO Wiki
- lib/documentation/doc-assignments.sh (~450 lines) - Cross-env combining, dedup, sub-pages
- scripts/operations/build-policy-documentation.sh (~300 lines) - CLI orchestrator
- tests/test_documentation.sh: 67 tests, 1030 total
- Replaces: Build-PolicyDocumentation.ps1, Out-DocumentationFor*.ps1, Write-AssignmentDetails.ps1
- Branch: feature/wi-14-documentation (commit 4b92606)

### WI-15: Operational tools ✅
- scripts/operations/new-az-remediation-tasks.sh
- scripts/operations/export-non-compliance-reports.sh
- scripts/operations/get-az-exemptions.sh
- scripts/operations/get-az-policy-alias-output-csv.sh
- scripts/operations/new-az-policy-reader-role.sh
- scripts/operations/new-azure-devops-bug.sh
- scripts/operations/new-github-issue.sh
- tests/test_operations.sh — 86 tests (collation, resource ID parsing, CSV generation, HTML tables, JSON construction, arg validation)
- Bugs found and fixed: jq array-in-array for resourceQualifier parsing, jq pipe precedence in csv_esc chains
- Replaces: corresponding Operations/*.ps1 scripts
- Branch: feature/wi-15-operations

### WI-16: Scaffolding & new resource creation ✅
- scripts/operations/new-epac-global-settings.sh
- scripts/operations/new-epac-policy-assignment-definition.sh
- scripts/operations/new-epac-policy-definition.sh
- scripts/operations/new-pipelines-from-starter-kit.sh
- scripts/operations/convert-markdown-github-alerts.sh
- tests/test_scaffolding.sh — 82 tests (JSON generation, EPAC format conversion, pipeline copy, markdown alert conversion with round-trip)
- Replaces: New-EPAC*.ps1, New-PipelinesFromStarterKit.ps1, Convert-MarkdownGitHubAlerts.ps1
- Branch: feature/wi-16-scaffolding

### WI-17: Hydration Kit
- scripts/hydration/ - All 16 hydration scripts
- lib/hydration/ - ~30 hydration helper functions
- Interactive setup wizard (menus, prompts)
- Management group hierarchy management
- Replaces: Scripts/HydrationKit/*.ps1 and hydration helpers
- Branch: feature/wi-17-hydration-kit

### WI-18: Cloud Adoption Framework integration
- scripts/caf/new-alz-policy-default-structure.sh
- scripts/caf/sync-alz-policy-from-library.sh
- ALZ/AMBA/FSI/SLZ library support
- Replaces: Scripts/CloudAdoptionFramework/*.ps1
- Branch: feature/wi-18-caf-integration

### WI-19: CI/CD pipeline templates
- Update GitHub Actions workflows for bash
- Update Azure DevOps pipeline templates for bash
- Update GitLab CI templates for bash
- Update StarterKit pipeline templates
- Branch: feature/wi-19-cicd-pipelines

### WI-20: Build system & packaging
- build.sh - Module/library packaging
- install.sh - Installation script
- Dependency checking (jq, az cli, curl)
- Version management
- Replaces: Module/build.ps1, .psd1 manifests
- Branch: feature/wi-20-build-system

### WI-21: StarterKit & examples updates
- Update all StarterKit definition files if needed
- Update Examples for bash usage
- Ensure JSON/JSONC configs work with bash tooling
- Branch: feature/wi-21-starterkit

### WI-22: Documentation & README updates
- Update all Docs/*.md for bash commands
- Update README.md
- Update mkdocs.yml if needed
- Remove PowerShell-specific references
- Branch: feature/wi-22-documentation

### WI-23: Testing framework
- tests/ directory with bats (Bash Automated Testing System)
- Unit tests for core libraries
- Integration tests for Azure operations
- CI test configuration
- Branch: feature/wi-23-testing

## Status Tracking
- [x] WI-01: Project scaffolding & core utilities (66 tests)
- [x] WI-02: Azure authentication & context management (28 tests, 94 total)
- [x] WI-03: Configuration & global settings (68 tests, 162 total)
- [x] WI-04: Azure REST API wrappers (43 tests, 205 total)
- [x] WI-05: Resource Graph & policy resource retrieval (101 tests, 303 total)
- [x] WI-06: Data transformation utilities (115 tests, 418 total)
- [x] WI-07: Validation & confirmation functions (105 tests, 523 total)
- [x] WI-08: Scope table building (folded into WI-05/07)
- [x] WI-09: Policy & policy set plan building (58 tests, 584 total)
- [x] WI-10: Assignment plan building (114 tests, 698 total)
- [x] WI-11: Exemptions & deployment plan orchestration (86 tests, 784 total)
- [x] WI-12: Policy deployment (76 tests, 860 total)
- [x] WI-13: Export operations (103 tests, 963 total)
- [x] WI-14: Documentation generation (67 tests, 1030 total)
- [ ] WI-15: Operational tools
- [ ] WI-16: Scaffolding & new resource creation
- [ ] WI-17: Hydration Kit
- [ ] WI-18: Cloud Adoption Framework integration
- [ ] WI-19: CI/CD pipeline templates
- [ ] WI-20: Build system & packaging
- [ ] WI-21: StarterKit & examples updates
- [ ] WI-22: Documentation & README updates
- [ ] WI-23: Testing framework
