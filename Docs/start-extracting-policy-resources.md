# Start by Extracting existing Policy Resources

<div style="margin: 30px 0; position: relative; padding-bottom: 56.25%; height: 0; overflow: hidden; max-width: 100%; height: auto;">
  <iframe src="https://www.youtube.com/embed/--I-hPQfLvo" 
          style="position: absolute; top:0; left:0; width:100%; height:100%;" 
          frameborder="0" 
          allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture" 
          allowfullscreen>
  </iframe>
</div>

Script `export-az-policy-resources.sh` (operations) extracts existing Policies, Policy Sets, and Policy Assignments and Exemptions outputting them in EPAC format into subfolders in folder `$outputFolders/Definitions`. The subfolders are `policyDefinitions`, `policySetDefinitions`, `policyAssignments` and `policyExemptions`.

> [!TIP]
> The script collects information on ownership of the Policy resources into a CSV file. You can analyze this file to assist in the transition to EPAC.

The scripts creates a `Definitions` folder in the `OutputFolder` with the subfolders for `policyDefinitions`, `policySetDefinitions`, `policyAssignments` and `policyExemptions`.

> [!TIP]
> In a new EPAC instance these folders can be directly copied to the `Definitions` folder enabling an initial transition from a pre-EPAC to EPAC environment.

* `policyDefinitions`, `policySetDefinitions` have a subfolder based on `metadata.category`. If the definition has no `category` `metadata` they are put in a subfolder labeled `Unknown Category`. Duplicates when including child scopes are sorted into the `Duplicates` folder. Creates one file per Policy and Policy Set.
* `policyAssignments` creates one file per unique assigned Policy or Policy Set spanning multiple Assignments.
* `policyExemptions` creates one subfolder per EPAC environment

> [!WARNING]
> The script deletes the `$outputFolders/Definitions` folder before creating a new set of files. In interactive mode it will ask for confirmation before deleting the directory.

## Use case 1: Interactive or non-interactive single tenant

`--mode 'export'` is used to collect the Policy resources and generate the definitions file. This works for `--interactive` (the default) to extract Policy resources in single tenant or multi-tenant scenario, prompting the user to logon to each new tenant in turn.

It also works for a single tenant scenario for an automated collection, assuming that the Service Principal has read permissions for every EPAC Environment in `global-settings.jsonc`.

```bash
scripts/operations/export-az-policy-resources.sh
```

The parameter `-InputPacSelector` can be used to only extract Policy resources for one of the EPAC environments.

## Use case 2: Non-interactive multi-tenant

While this pattern can be used for interactive users too, it is most often used for multi-tenant non-interactive usage since an SPN is bound to a tenant and the script cannot prompt for new credentials.

The solution is a multi-step process:

Collect the raw information for very EPAC environment after logging into each EPAC environment (tenant):

```bash
az login --tenant $tenantIdForDev
scripts/operations/export-az-policy-resources.sh  --mode collectRawFile --input-pac-selector 'epac-dev'

az login --tenant $tenantId1
scripts/operations/export-az-policy-resources.sh  --mode collectRawFile --input-pac-selector 'tenant1'

az login --tenant $tenantId2
scripts/operations/export-az-policy-resources.sh  --mode collectRawFile --input-pac-selector 'tenant2'
```

Next, the collected raw files are used to generate the same output:

```bash
scripts/operations/export-az-policy-resources.sh  --mode exportFromRawFiles
```

## Caveats

The extractions are subject to the following assumptions and caveats:

* Assumes Policies and Policy Sets with the same name define the same properties independent of scope and EPAC environment.
* Ignores Assignments auto-assigned by Defender for Cloud. This behavior can be overridden with the switch parameter `--include-auto-assigned`.
