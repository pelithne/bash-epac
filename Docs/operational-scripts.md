# Operational Scripts

The scripts are detailed in the [reference page](operational-scripts-reference.md) including syntax, descriptions and parameters.

## Batch Creation of Remediation Tasks

The script `new-az-remediation-tasks.sh` creates remediation tasks for all non-compliant resources for EPAC environments in the `global-settings.jsonc` file.

This script executes all remediation tasks in a Policy as Code environment specified with parameter `--pac-environment-selector`. The script will interactively prompt for the value if the parameter is not supplied. The script will recurse the Management Group structure and subscriptions from the defined starting point.

* Find all Policy assignments with potential remediation capable resources
* Query Policy Insights for non-complaint resources
* Start remediation task for each Policy with non-compliant resources
* Flag `--only-check-managed-assignments` includes non-compliance data only for Policy assignments owned by this Policy as Code repo.
* Flag `--only-default-enforcement-mode` to only run remediation tasks against policy assignments that have enforcement mode set to 'Default'.

#### Links

* [Guidance: Implementing an Azure Policy Based Remediation Solution](./guidance-remediation.md)
* [Remediate non-compliant resources with Azure Policy](https://learn.microsoft.com/en-us/azure/governance/policy/how-to/remediate-resources?tabs=azure-portal)

## Documenting Policy

`build-policy-documentation.sh` builds documentation from instructions in the `policyDocumentations` folder reading the deployed Policy Resources from the EPAC environment. It is also used to generate parameter/effect CSV files for Policy Assignment files. See usage documentation in [Documenting Policy](operational-scripts-documenting-policy.md).

## Policy Resources Exports

<div style="margin: 30px 0; position: relative; padding-bottom: 56.25%; height: 0; overflow: hidden; max-width: 100%; height: auto;">
  <iframe src="https://www.youtube.com/embed/--I-hPQfLvo" 
          style="position: absolute; top:0; left:0; width:100%; height:100%;" 
          frameborder="0" 
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" 
          allowfullscreen>
  </iframe>
</div>

* `export-az-policy-resources.sh` exports Azure Policy resources in EPAC. See usage documentation in [Extract existing Policy Resources](start-extracting-policy-resources.md).
* `get-az-exemptions.sh` retrieves Policy Exemptions from an EPAC environment and saves them to files.
* `get-az-policy-alias-output-csv.sh` exports Policy Aliases to CSV format.

## Hydration Kit

The Hydration Kit is a set of scripts that can be used to deploy an EPAC environment from scratch. The scripts are documented in the [Hydration Kit](operational-scripts-hydration-kit.md) page.

## CI/CD Helpers

The scripts `new-azure-devops-bug.sh` and `new-github-issue.sh` create a Bug or Issue when there are one or multiple failed Remediation Tasks.

## Export Policy To EPAC

The script `export-policy-to-epac.sh` creates for you the policyAssignments, policyDefinitions, and policySetDefinitions based on the provided definition/set ID into an Output folder under 'Export'.

Parameters:

* **--policy-definition-id**: URL of the policy or policy set from AzAdvertizer.

* **--policy-set-definition-id**: URL of the policy or policy set from AzAdvertizer.

* **--alz-policy-definition-id**: URL of the ALZ policy from AzAdvertizer.

* **--alz-policy-set-definition-id**: URL of the ALZ policy set from AzAdvertizer.

* **--output-folder**: Output Folder. Defaults to the path 'Output'.

* **--auto-create-parameters**: Automatically create parameters for Azure Policy Sets and Assignment Files.

* **--use-built-in**: Default to using builtin policies rather than local versions.

* **--pac-selector**: Used to set PacEnvironment for each assignment file based on the pac selector provided. This pulls from global-settings.jsonc, therefore it must exist or an error will be thrown.

* **--overwrite-scope**: Used to overwrite scope value on each assignment file.

* **--overwrite-pac-selector**: Used to overwrite PacEnvironment for each assignment file.

* **--overwrite-output**: Used to overwrite the contents of the output folder with each run.

## Non-compliance Reports

`export-non-compliance-reports.sh` exports non-compliance reports for EPAC environments. It outputs the reports in the `$OutputFolder/non-compliance-reports` folder.

* `summary-by-policy.csv` contains the summary of the non-compliant resources by Policy definition. The columns contain the resource counts.
* `summary-by-resource.csv` contains the summary of the non-compliant resources. The columns contain the number of Policies causing the non-compliance.
* `details-by-policy.csv` contains the details of the non-compliant resources by Policy definition including the non-compliant resource ids. Assignments are combined by Policy definition.
* `details-by-resource.csv` contains the details of the non-compliant resources sorted by Resource id. Assignments are combined by Resource id.
* `full-details-by-assignment.csv` contains the details of the non-compliant resources sorted by Policy Assignment id.
* `full-details-by-resource.csv` contains the details of the non-compliant resources sorted by Resource id including the Policy Assignment details.

### Sample `summary-by-policy.csv`

| Category | Policy Name | Policy Id | Non Compliant | Unknown | Not Started | Exempt | Conflicting | Error | Assignment Ids | Group Names |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| General | Audit usage of custom RBAC roles | /providers/microsoft.authorization/policydefinitions/a451c1ef-c6ca-483d-87ed-f49761e3ffb5 | 9 | 0 | 0 | 0 | 0 | 0 | /providers/microsoft.management/managementgroups/pac-heinrich-dev-dev/providers/microsoft.authorization/policyassignments/dev-nist-800-53-r5,/providers/microsoft.management/managementgroups/pac-heinrich-dev-dev/providers/microsoft.authorization/policyassignments/dev-asb | azure_security_benchmark_v3.0_pa-7,nist_sp_800-53_r5_ac-6(7),nist_sp_800-53_r5_ac-2(7),nist_sp_800-53_r5_ac-6,nist_sp_800-53_r5_ac-2 |

### Sample `summary-by-resource.csv`

| Resource Id | Subscription Id | Subscription Name | Resource Group | Resource Type | Resource Name | Resource Qualifier | Non Compliant | Unknown | Not Started | Exempt | Conflicting | Error |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| /subscriptions/******************************** | ******************************** | PAC-DEV-001 |  | subscriptions |  |  | 25 | 481 | 0 | 0 | 0 | 0 |
