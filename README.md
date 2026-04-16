# Enterprise Azure Policy as Code (Bash)

This repository contains the Bash implementation of the Enterprise Azure Policy as Code (EPAC) solution. EPAC allows you to manage Azure Policy as code in a git repository using Bash scripts with Azure CLI and jq.

**Requirements:** Bash 5.1+, Azure CLI 2.50+, jq 1.6+, curl, git

For an overview of the EPAC concept see the upstream [EPAC documentation](https://aka.ms/epac). The docs in this repository ([`Docs/`](Docs/index.md)) have been adapted for the Bash implementation — use those for anything command- or script-specific.

## Documentation

The full documentation is in [`Docs/`](Docs/index.md) and is organized into the following sections (matching [`mkdocs.yml`](mkdocs.yml)):

### Getting Started
- [Overview and Prerequisites](Docs/start-implementing.md)
- [Hydration Kit](Docs/start-hydration-kit.md)
- [Manual Configuration](Docs/manual-configuration.md)
- [Extracting Policy Resources](Docs/start-extracting-policy-resources.md)
- [Forking the GitHub Repo](Docs/start-forking-github-repo.md)
- [Advanced Configuration](Docs/advanced-configuration.md)
- [Changes in v11.0.0](Docs/start-changes.md)
- [Debugging EPAC](Docs/debugging.md)

### Settings and Desired State
- [Global Settings](Docs/settings-global-setting-file.md)
- [Desired State](Docs/settings-desired-state.md)
- [Defender for Cloud Assignments](Docs/settings-dfc-assignments.md)
- [Output Themes](Docs/settings-output-themes.md)

### Azure Landing Zones
- [ALZ Overview](Docs/integrating-with-alz-overview.md)
- [ALZ Policy Integration](Docs/integrating-with-alz-library.md)

### Define Policy Resources
- [Policy Definitions](Docs/policy-definitions.md)
- [Policy Set Definitions](Docs/policy-set-definitions.md)
- [Policy Assignment Files](Docs/policy-assignments.md)
- [CSV Assignment Parameters](Docs/policy-assignments-csv-parameters.md)
- [Policy Exemptions](Docs/policy-exemptions.md)

### CI/CD Integration
- [CI/CD Overview](Docs/ci-cd-overview.md)
- [App Registrations Setup](Docs/ci-cd-app-registrations.md)
- [Branching Flows](Docs/ci-cd-branching-flows.md)
- [Azure DevOps Pipelines](Docs/ci-cd-ado-pipelines.md)
- [GitHub Actions](Docs/ci-cd-github-actions.md)

### Operational Scripts
- [Scripts Overview](Docs/operational-scripts.md)
- [Documenting Policy](Docs/operational-scripts-documenting-policy.md)
- [Reference](Docs/operational-scripts-reference.md)

### Operator Guidance
- [Remediation Enforcement](Docs/guidance-remediation.md)
- [Exclusion Management](Docs/guidance-scope-exclusions.md)
- [Exemption Updates](Docs/guidance-exemptions.md)
- [Lighthouse Subscription Management](Docs/guidance-lighthouse.md)

## Repository Layout

- [`lib/`](lib/) — Bash library modules (core helpers, JSON handling, validators, plans, documentation, exports, hydration, etc.)
- [`scripts/`](scripts/) — Entry-point scripts grouped by area (`deploy/`, `operations/`, `hydration/`, `caf/`)
- [`tests/`](tests/) — Test suite (run via `./tests/run_all_tests.sh`)
- [`Docs/`](Docs/index.md) — User documentation (rendered by MkDocs)
- [`StarterKit/`](StarterKit/), [`Examples/`](Examples/), [`Schemas/`](Schemas/) — Starter files, examples and JSON schemas
- `Scripts/`, `Module/` — Upstream PowerShell EPAC source, kept as reference only

## Contributing

This project welcomes contributions and suggestions.  Contributions require you to agree to a
Contributor License Agreement (CLA) declaring that you have the right to, and actually do, grant us
the rights to use your contribution. For details, visit <https://cla.opensource.microsoft.com>.

When you submit a pull request, a CLA bot will automatically determine whether you need to provide
a CLA and decorate the PR appropriately (e.g., status check, comment). Simply follow the instructions
provided by the bot. You will only need to do this once across all repos using our CLA.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow
[Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/en-us/legal/intellectualproperty/trademarks/usage/general).
Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those third-party's policies.
