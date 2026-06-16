# Install / Sync Scale Validation (v1.4.0 — A14)

Re-validates the install/sync engine across **all 8 shipped profiles** on the v1.4.0 tree. Confirms
no regression vs the v0.1.28 breadth closure. Real local runs into isolated `mktemp` targets.

## Method (per profile)

1. `install-baseline --mode report-only` (dry-run) → must write **0 files**.
2. `install-baseline --mode report-only --apply` → writes the profile's managed files.
3. `sync-baseline` (dry-run) on the clean install → no-op.
4. Introduce drift to a managed `*.yml`, `sync-baseline` (detect), then `--apply --force` (resolve).
5. A project-local probe file is created and checked → must be **preserved** (never touched).

## Results

| Profile | dry-run files | apply files | sync dry | drift detect | sync apply | project-local preserved |
|---|---|---|---|---|---|---|
| laravel | 0 | 5 | rc0 | rc0 | rc0 | ✅ |
| react | 0 | 4 | rc0 | rc0 | rc0 | ✅ |
| node | 0 | 3 | rc0 | rc0 | rc0 | ✅ |
| docker | 0 | 5 | rc0 | rc0 | rc0 | ✅ |
| php-library | 0 | 5 | rc0 | rc0 | rc0 | ✅ |
| symfony | 0 | 5 | rc0 | rc0 | rc0 | ✅ |
| laravel-react-docker | 0 | 9 | rc0 | rc0 | rc0 | ✅ |
| node-react | 0 | 5 | rc0 | rc0 | rc0 | ✅ |

**All 8 profiles pass.** Dry-run is a true no-op (0 files); apply is deterministic; drift is
detected and resolved; project-local files are never clobbered. Matches the `install-matrix` /
`install-sync` self-test guards. No STABLE script changed (`install-baseline.sh` /
`sync-baseline.sh` byte-identical to v1.3.0).
