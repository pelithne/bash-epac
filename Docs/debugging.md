# Debugging EPAC

This is the process used to debug EPAC scripts during troubleshooting that the maintainers follow. You can use this in your own environment to help with finding faults.

## Environment Setup

- Clone the repository locally
- Use any text editor or VS Code to examine the scripts
- Run the deployment planning script with the appropriate flags pointing to your definitions:

```bash
# The cloned repository is in the epac-github folder
../epac-github/scripts/deploy/build-deployment-plans.sh \
    --definitions-root-folder ./Definitions \
    --output-folder Output
```

- Add `set -x` at the top of the script or before the section you are debugging to enable trace output
- Use `bash -x script.sh` to run any script with full trace output
- Insert `echo` statements or use `trap 'echo "LINE $LINENO: $BASH_COMMAND"' DEBUG` for detailed flow tracing

Use the dependency map below for a high level view of `build-deployment-plans.sh`

```
build-deployment-plans.sh
├── Initialization & Configuration
│   ├── lib/epac.sh (loads all library functions)
│   ├── epac_select_pac_environment (determines PAC environment)
│   └── epac_set_az_cloud_tenant_subscription (Azure authentication)
│
├── Azure Resource Discovery
│   ├── epac_build_scope_table (scope hierarchy)
│   └── epac_get_az_policy_resources (retrieves deployed resources)
│       └── Returns: Policy/PolicySet definitions, Assignments, Exemptions, Role assignments
│
├── Plan Building (Conditional based on folder presence)
│   ├── epac_build_policy_plan (Policy Definitions)
│   ├── epac_build_policy_set_plan (Policy Set Definitions)
│   ├── epac_build_assignment_plan (Policy Assignments + Role Assignments)
│   └── epac_build_exemptions_plan (Policy Exemptions)
│
├── Supporting Functions
│   ├── epac_get_policy_resource_properties (extract resource properties)
│   └── epac_convert_policy_resources_to_details (convert to detailed info)
│
└── Output & Reporting
    ├── epac_write_header (visual headers)
    ├── epac_write_section (section headers)
    ├── epac_write_status (status messages)
    ├── epac_write_count_summary (change summaries)
    └── epac_submit_telemetry (telemetry, optional)
```

## Notes

- This process needs to be done locally, you should try and ensure when debugging that you have the same permissions as the identity running EPAC in your CI/CD process.
- Create a small subset of your deployment to reduce time processing large amounts of definitions and assignments.
- Use the `--build-exemptions-only` flag when troubleshooting exemptions.
- EPAC is a large codebase - becoming familiar with the code takes a long time but we always welcome contributors to the project!
