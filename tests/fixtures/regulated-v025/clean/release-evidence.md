# Release Evidence — regulated-v025 clean fixture

This file exists so that `scripts/build-security-summary.sh` resolves
`missing_release_evidence = false` for the **clean** regulated scenario. Regulated mode is
the only built-in mode whose default `fail_on.missing_release_evidence` is `true`, so this
artifact is what keeps the clean set passing under regulated.

- Release: v1.0.0 (fixture)
- Approver: release-captain (fixture)
- Date: 2026-06-10
- SBOM: present (`sbom.spdx.json` alongside this file)
- Tests: green (fixture)
- Provenance: documented (fixture)

> The gate is driven purely by the **presence** of this file in the build output
> directory (see `scripts/build-security-summary.sh` ~lines 194-197). Content is
> illustrative and is never parsed.
