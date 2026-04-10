# Scripts References

## Script `build-policy-documentation.sh`

Builds documentation from instructions in policyDocumentations folder reading the deployed Policy Resources from the EPAC environment.

```bash
scripts/operations/build-policy-documentation.sh [OPTIONS]
```

### Parameters

#### `--definitions-root-folder <path>`

Definitions folder path. Defaults to environment variable `PAC_DEFINITIONS_FOLDER` or `./Definitions`.

#### `--output-folder <path>`

Output Folder. Defaults to environment variable `PAC_OUTPUT_FOLDER` or `./Outputs`.

#### `--windows-newline-cells`

Formats CSV multi-object cells to use new lines and saves it as UTF-8 with BOM - works only for Excel in Windows. Default uses commas to separate array elements within a cell.

#### `--interactive`

Enable interactive mode.

#### `--suppress-confirmation`

Suppresses prompt for confirmation to delete an existing file in interactive mode.

#### `--include-manual-policies`

Include Policies with effect Manual. Default: do not include Policies with effect Manual.

## Script `new-az-remediation-tasks.sh`

Creates remediation tasks for all non-compliant resources in the current Entra ID tenant. If one or multiple remediation tasks fail, their respective objects are output as JSON for later use in the CI/CD pipeline.

```bash
scripts/operations/new-az-remediation-tasks.sh [OPTIONS]
```

### Parameters

#### `--pac-environment-selector <name>`, `-p <name>`

Defines which Policy as Code (PAC) environment we are using, if omitted, the script prompts for a value. The values are read from `$PAC_DEFINITIONS_FOLDER/global-settings.jsonc`.

#### `--definitions-root-folder <path>`, `-d <path>`

Definitions folder path. Defaults to environment variable `PAC_DEFINITIONS_FOLDER` or `./Definitions`.

#### `--interactive`

Enable interactive mode.

#### `--only-check-managed-assignments`

Include non-compliance data only for Policy assignments owned by this Policy as Code repo.

#### `--policy-definition-filter <names>`

Filter by Policy definition names (comma-separated) or ids.

#### `--policy-set-definition-filter <names>`

Filter by Policy Set definition names (comma-separated) or ids.

#### `--policy-assignment-filter <names>`

Filter by Policy Assignment names (comma-separated) or ids.

#### `--policy-effect-filter <effects>`

Filter by Policy effect (comma-separated).

#### `--no-wait`

Indicates that the script should not wait for the remediation tasks to complete.

#### `--test-run`

Simulates the actions of the command without actually performing them. Useful for testing.

## Script `new-azure-devops-bug.sh`

Creates a Bug on the current Iteration of a team when one or multiple Remediation Tasks fail. The Bug is formatted as an HTML table and contains information on the name and URL properties.

```bash
scripts/operations/new-azure-devops-bug.sh [OPTIONS]
```

### Parameters

#### `--failed-tasks-json <json-string>`

JSON string that contains the objects of one or multiple failed Remediation Tasks.

#### `--organization-name <name>`

Name of the Azure DevOps Organization.

#### `--project-name <name>`

Name of the Azure DevOps Project.

#### `--personal-access-token <token>`

Personal Access Token for authentication. Use a secret variable from your pipeline.

#### `--team-name <name>`

Name of the Azure DevOps team.

## Script `new-github-issue.sh`

Creates an Issue in a GitHub Repository when one or multiple Remediation Tasks fail. The Issue is formatted as an HTML table and contains information on the name and URL properties.

```bash
scripts/operations/new-github-issue.sh [OPTIONS]
```

### Parameters

#### `--failed-tasks-json <json-string>`

JSON string that contains the objects of one or multiple failed Remediation Tasks.

#### `--organization-name <name>`

Name of the GitHub Organization.

#### `--repository-name <name>`

Name of the GitHub Repository.

#### `--personal-access-token <token>`

Personal Access Token for authentication.

## Script `export-az-policy-resources.sh`

Exports Azure Policy resources in EPAC format or raw format. It also generates documentation for the exported resources (can be suppressed with `--suppress-documentation`).

```bash
scripts/operations/export-az-policy-resources.sh [OPTIONS]
```

### Parameters

#### `--definitions-root-folder <path>`, `-d <path>`

Definitions folder path. Defaults to environment variable `PAC_DEFINITIONS_FOLDER` or `./Definitions`.

#### `--output-folder <path>`, `-o <path>`

Output Folder. Defaults to environment variable `PAC_OUTPUT_FOLDER` or `./Outputs`.

#### `--interactive`

Enable interactive mode. Default is non-interactive.

#### `--include-child-scopes`

Include Policies and Policy Sets definitions in child scopes.

#### `--include-auto-assigned`

Include Assignments auto-assigned by Defender for Cloud.

#### `--exemption-files <format>`

Create Exemption files (none=suppress, csv=as a csv file, json=as a json or jsonc file). Defaults to `csv`.

#### `--file-extension <ext>`

File extension type for the output files. Defaults to `.jsonc`.

#### `--mode <mode>`

Operating mode:

- `export` exports EPAC environments in EPAC format, which should be used with `--interactive` in a multi-tenant scenario, or used with `--input-pac-selector` to limit the scope to one EPAC environment.
- `collectRawFile` exports the raw data only; Often used with `--input-pac-selector` when running non-interactive in a multi-tenant scenario to collect the raw data once per tenant into a file named after the EPAC environment.
- `exportFromRawFiles` reads the files generated with one or more runs of collectRawFile and outputs the files the same as normal `export`.
- `exportRawToPipeline` exports EPAC environments in EPAC format.
- `psrule` exports EPAC environment into a file which can be used to create policy rules for PSRule for Azure.

#### `--input-pac-selector <name>`

Limits the collection to one EPAC environment.

#### `--suppress-documentation`

Suppress documentation generation.

#### `--suppress-epac-output`

Suppress output generation in EPAC format.

#### `--psrule-ignore-full-scope`

Ignore full scope for PSRule Extraction.

## Script `export-non-compliance-reports.sh`

Exports Non-Compliance Reports in CSV format.

```bash
scripts/operations/export-non-compliance-reports.sh [OPTIONS]
```

### Parameters

#### `--pac-environment-selector <name>`, `-p <name>`

Defines which PAC environment we are using.

#### `--definitions-root-folder <path>`, `-d <path>`

Definitions folder path. Defaults to environment variable `PAC_DEFINITIONS_FOLDER` or `./Definitions`.

#### `--output-folder <path>`, `-o <path>`

Output Folder. Defaults to environment variable `PAC_OUTPUT_FOLDER` or `./Outputs`.

#### `--windows-newline-cells`

Formats CSV multi-object cells to use new lines. Default uses commas.

#### `--interactive`

Enable interactive mode.

#### `--only-check-managed-assignments`

Include non-compliance data only for Policy assignments owned by this Policy as Code repo.

#### `--policy-definition-filter <names>`

Filter by Policy definition names (comma-separated) or ids.

#### `--policy-set-definition-filter <names>`

Filter by Policy Set definition names (comma-separated) or ids.

#### `--policy-assignment-filter <names>`

Filter by Policy Assignment names (comma-separated) or ids.

#### `--policy-effect-filter <effects>`

Filter by Policy Effect (comma-separated).

#### `--exclude-manual-policy-effect`

Filter out Policy Effect Manual.

#### `--remediation-only`

Filter by Policy Effect "deployifnotexists" and "modify" and compliance status "NonCompliant".

## Script `get-az-exemptions.sh`

Retrieves Policy Exemptions from an EPAC environment and saves them to files.

```bash
scripts/operations/get-az-exemptions.sh [OPTIONS]
```

### Parameters

#### `--pac-environment-selector <name>`, `-p <name>`

Defines which PAC environment we are using.

#### `--definitions-root-folder <path>`, `-d <path>`

Definitions folder path. Defaults to environment variable `PAC_DEFINITIONS_FOLDER` or `./Definitions`.

#### `--output-folder <path>`, `-o <path>`

Output Folder. Defaults to environment variable `PAC_OUTPUT_FOLDER` or `./Outputs`.

#### `--interactive`

Enable interactive mode.

#### `--file-extension <ext>`

File extension type for the output files. Valid values are `json` or `jsonc`. Default is `json`.

#### `--active-exemptions-only`

Only generate files for active (not expired and not orphaned) exemptions. Defaults to false.

## Script `get-az-policy-alias-output-csv.sh`

Gets all aliases and outputs them to a CSV file.

```bash
scripts/operations/get-az-policy-alias-output-csv.sh
```

## Script `new-az-policy-reader-role.sh`

Creates a custom role 'Policy Reader' that provides read access to all Policy resources to plan the EPAC deployments.

```bash
scripts/operations/new-az-policy-reader-role.sh [OPTIONS]
```

### Parameters

#### `--pac-environment-selector <name>`, `-p <name>`

Defines which PAC environment we are using.

#### `--definitions-root-folder <path>`, `-d <path>`

Definitions folder path. Defaults to environment variable `PAC_DEFINITIONS_FOLDER` or `./Definitions`.

#### `--interactive`

Enable interactive mode.

## Script `new-epac-definitions-folder.sh`

Creates a definitions folder with the correct folder structure and blank global settings file.

```bash
scripts/hydration/new-hydration-definitions-folder.sh [OPTIONS]
```

### Parameters

#### `--definitions-root-folder <path>`

The folder path to create the definitions root folder (./Definitions).

## Script `new-epac-global-settings.sh`

Creates a global-settings.jsonc file with a new GUID, managed identity location and tenant information.

```bash
scripts/operations/new-epac-global-settings.sh [OPTIONS]
```

### Parameters

#### `--managed-identity-location <location>`

The Azure location to store the managed identities (e.g., `eastus2`). Use `az account list-locations --query '[].name' -o tsv` to list available locations.

#### `--tenant-id <id>`

The Azure tenant id.

#### `--definitions-root-folder <path>`

The folder path to where the definitions root folder was created.

#### `--deployment-root-scope <scope>`

The deployment root scope for the EPAC environment.

## Script `new-epac-policy-assignment-definition.sh`

Scaffolds a new Policy Assignment definition file.

```bash
scripts/operations/new-epac-policy-assignment-definition.sh [OPTIONS]
```

## Script `new-epac-policy-definition.sh`

Scaffolds a new Policy definition file.

```bash
scripts/operations/new-epac-policy-definition.sh [OPTIONS]
```

## Script `new-pipelines-from-starter-kit.sh`

Creates CI/CD pipeline files from the starter kit templates.

```bash
scripts/operations/new-pipelines-from-starter-kit.sh [OPTIONS]
```

### Parameters

#### `--starter-kit-folder <path>`

Path to the StarterKit folder.

#### `--pipelines-folder <path>`

Folder where the generated pipelines will be placed.

#### `--pipeline-type <type>`

Type of pipeline to generate: `AzureDevOps`, `GitHubActions`, or `GitLab`.

#### `--branching-flow <flow>`

Branching flow to use: `GitHub` or `Release`.
