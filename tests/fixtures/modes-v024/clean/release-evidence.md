# Release Evidence — clean fixture

This file exists so that `scripts/build-security-summary.sh` resolves
`missing_release_evidence = false` for the **clean** scenario.

- Release: v1.0.0 (fixture)
- Approver: release-captain (fixture)
- Date: 2026-06-10
- SBOM: present (`sbom.spdx.json` alongside this file)
- Tests: green (fixture)
- Provenance: documented (fixture)

> The gate is driven purely by the **presence** of this file in the build output
> directory (see `build-security-summary.sh` ~lines 194-197). Content is illustrative.
