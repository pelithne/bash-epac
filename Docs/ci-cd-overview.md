# CI/CD Overview

EPAC is written in Bash and any CI/CD tool with the ability to execute Bash scripts with Azure CLI can be used. The starter kits currently include pipeline definitions for Azure DevOps and GitHub Actions.

This repository contains starter pipelines and instructions for can be found here:

- [Azure DevOps Pipelines](ci-cd-ado-pipelines.md)
- [GitHub Actions](ci-cd-github-actions.md)

## General EPAC Deployment Steps

EPAC has three major steps in the deployment process for each environment.
- Build Deployment Plans
- Policy Deployment
- Role Deployment

Each step can be called by using the installed EPAC scripts (recommended), or calling the script directly from the source checkout. For more details on EPAC installation options, please refer to the [Start Implementation](start-implementing.md/#install-epac) section.

> [!TIP]
> EPAC is **declarative** and **idempotent**: this means, that regardless how many times it is run, EPAC will always push all changes that were implemented in the JSON files to the Azure environment, i.e. if a JSON file is newly created/updated/deleted, EPAC will create/update/delete the Policy and/or Policy Set and/or Policy Assignments definition in Azure. If there are no changes, EPAC can be run any number of times, as it won't make any changes to Azure.

### Build Deployment Plans
Analyzes changes in Policy definition, Policy Set definition, Policy Assignment & Policy Exemption files for a given environment. It calculates and displays any deltas, while creating the deployment plan(s) to apply any changes. A "Policy Plan" will be created for use by the Policy Deployment step if any changes are found to the policy objects, assignments, or exemptions while a "Role Plan" will be created for use by the Role deployment step should there be any changes to role assignments for the deployed policies. If no changes are found, no plans are created.

**Deployment Mechanism**

|Deployment Mode | Command/Script |
|----------|-------------|
| Installed | epac-plan |
| Script | scripts/deploy/build-deployment-plans.sh | 

**Parameters**

|Parameter | Explanation |
|----------|-------------|
| `-p`, `--pac-environment-selector` | Selects the EPAC environment for this plan. If omitted, interactively prompts for the value. |
| `-d`, `--definitions-root-folder` | Definitions folder path. Defaults to environment variable `PAC_DEFINITIONS_FOLDER` or `./Definitions`. It must contain the file `global-settings.jsonc`. |
| `--interactive` | Set to enable interactive mode (prompts for pac selector if not given). |
| `-o`, `--output-folder` | Output folder path for plan files. Defaults to environment variable `PAC_OUTPUT_FOLDER` or `./Output`. |
| `--devops-type` | If set, outputs variables consumable by conditions in a DevOps pipeline. Default: not set. |
| `--build-exemptions-only` | If set, only builds the Exemptions plan. This is useful to fast-track Exemptions when utilizing [Release Flow](#advanced-cicd-with-release-flow). Default: not set. |
| `--skip-exemptions`| If set, exemptions will not be built as part of the plan. |
| `--detailed-output` | Displays detailed policy change information. |

### Policy Deployment
Deploys Policies, Policy Sets, Policy Assignments, and Policy Exemptions at their desired scope based on the plan.

**Deployment Mechanism**

|Deployment Mode | Command/Script |
|----------|-------------|
| Installed | epac-deploy-policy |
| Script | scripts/deploy/deploy-policy-plan.sh | 

**Parameters**

|Parameter | Explanation |
|----------|-------------|
| `-p`, `--pac-environment-selector` | Selects the EPAC environment for this plan. If omitted, interactively prompts for the value. |
| `-d`, `--definitions-root-folder` | Definitions folder path. Defaults to environment variable `PAC_DEFINITIONS_FOLDER` or `./Definitions`. It must contain the file `global-settings.jsonc`. |
| `--interactive` | Set to enable interactive mode. |
| `-i`, `--input-folder` | Input folder path for plan files. Defaults to environment variable `PAC_INPUT_FOLDER`, `PAC_OUTPUT_FOLDER` or `./Output`. |
| `--skip-exemptions` | If set, Policy Exemptions will not be deployed. |

### Role Deployment
Creates the role assignments for the Managed Identities required for `DeployIfNotExists` and `Modify` Policies.

**Deployment Mechanism**

|Deployment Mode | Command/Script |
|----------|-------------|
| Installed | epac-deploy-roles |
| Script | scripts/deploy/deploy-roles-plan.sh | 

**Parameters**

|Parameter | Explanation |
|----------|-------------|
| `-p`, `--pac-environment-selector` | Selects the EPAC environment for this plan. If omitted, interactively prompts for the value. |
| `-d`, `--definitions-root-folder` | Definitions folder path. Defaults to environment variable `PAC_DEFINITIONS_FOLDER` or `./Definitions`. It must contain the file `global-settings.jsonc`. |
| `--interactive` | Set to enable interactive mode. |
| `-i`, `--input-folder` | Input folder path for plan files. Defaults to environment variable `PAC_INPUT_FOLDER`, `PAC_OUTPUT_FOLDER` or `./Output`. |

## Create Azure DevOps Pipelines or GitHub Workflows from Starter Pipelines.

Starter Pipelines have been created to orchestrate the EPAC deployment steps listed above. The script `new-pipelines-from-starter-kit.sh` creates [Azure DevOps Pipelines or GitHub Workflows from the starter kit](operational-scripts-hydration-kit.md#create-azure-devops-pipeline-or-github-workflow). You select the type of pipeline to create, the branching flow to implement, and the script type to use.
- The starter kits support two branching/release strategies (`GitHub` and `Release`). More details on these branching flows refer to the [Branching Flow Guidance](ci-cd-branching-flows.md).

### Azure DevOps Pipelines

The following commands create Azure DevOps Pipelines from the starter kit; use one of the commands:

```bash
scripts/operations/new-pipelines-from-starter-kit.sh \
    --starter-kit-folder ./StarterKit \
    --pipelines-folder ./pipelines \
    --pipeline-type AzureDevOps \
    --branching-flow GitHub

scripts/operations/new-pipelines-from-starter-kit.sh \
    --starter-kit-folder ./StarterKit \
    --pipelines-folder ./pipelines \
    --pipeline-type AzureDevOps \
    --branching-flow Release
```

### GitHub Workflows

The following commands create GitHub Workflows from the starter kit; use one of the commands:

```bash
scripts/operations/new-pipelines-from-starter-kit.sh \
    --starter-kit-folder ./StarterKit \
    --pipelines-folder ./.github/workflows \
    --pipeline-type GitHubActions \
    --branching-flow GitHub

scripts/operations/new-pipelines-from-starter-kit.sh \
    --starter-kit-folder ./StarterKit \
    --pipelines-folder ./.github/workflows \
    --pipeline-type GitHubActions \
    --branching-flow Release
```

## General Hardening Guidelines

- **Least Privilege**: Use the least privilege principle when assigning roles to the SPNs used in the CI/CD pipeline. The roles should be assigned at the root or pseudo-root management group level. For more details on the SPNs to use and required permissions refer to [App Registrations Setup](ci-cd-app-registrations.md)
- Require a Pull Request for changes to the `main` branch. This ensures that changes are reviewed before deployment.
- Require additional reviewers for yml pipeline and script changes.
- Require branches to be in a folder `feature` to prevent accidental deployment of branches.
- Require an approval step between the Plan stage/job and the Deploy stage/job. This ensures that the changes are reviewed before deployment.
- [Optional] Require an approval step between the Deploy stage/job and the Role Assignments stage/job. This ensures that the role assignments are reviewed before deployment.
- For `Release Flow` only: allow only privileged users to create `releases-prod` and `releases-exemptions-only` branches and require those branches to be created from the main branch only.
