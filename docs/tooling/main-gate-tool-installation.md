# Main-Gate Tool Installation (v0.1.18)

For main-gate tools that were **unavailable** on the pilot (binary/image absent). Sentinel
Shield never fakes a clean report — a missing binary yields `unavailable`. To get real coverage,
install/run them one of these ways. None of these belong in the **PR fast gate** (too slow /
network-heavy); they run on the **main gate**, **nightly**, or via the branch-safe harness
(`scripts/run-main-gate-validation.sh`).

| Tool | Preferred execution | Required setup | Raw report | Pin | Mark unavailable honestly | Fixture validation |
|---|---|---|---|---|---|---|
| **Grype** | GitHub Action `anchore/scan-action` **or** container `anchore/grype` | none (pulls DB) | `reports/raw/grype.json` | action SHA / image digest | wrapper `audits/grype.sh` no-ops when `grype` absent | `scanner-matrix` self-test fixture |
| **OWASP Dependency-Check** | container `owasp/dependency-check` (mount project) | NVD data (slow first run; cache) | `reports/raw/dependency-check.json` | image digest | wrapper `audits/dependency-check.sh` no-ops | `scanner-matrix` fixture |
| **Dockle** | container `goodwithtech/dockle` against a **built image** | a built image ref (`SENTINEL_SHIELD_IMAGE`) | `reports/raw/dockle.json` | image digest | wrapper `audits/dockle.sh` no-ops without image | `scanner-matrix` fixture |

## Example (container-backed, main gate — not PR fast)
```sh
# Grype (filesystem / SBOM)
docker run --rm -v "$PWD:/src" anchore/grype:<digest> dir:/src -o json > reports/raw/grype.json || true
# Dependency-Check
docker run --rm -v "$PWD:/src" owasp/dependency-check:<digest> --scan /src --format JSON --out /src/reports/raw || true
# Dockle (needs a built image)
docker run --rm goodwithtech/dockle:<digest> -f json "$SENTINEL_SHIELD_IMAGE" > reports/raw/dockle.json || true
```
Then `scripts/build-security-summary.sh` consumes the raw reports as usual. Run via
`scripts/run-main-gate-validation.sh` (branch-safe) or `sentinel-shield-main.yml`.

## Honest-unavailable contract
If the binary/image is absent, the wrapper logs `unavailable` and writes **no** file; the
collector then reports `status: unavailable` (counts 0). This is NOT a clean result — it means
"not scanned." Promote a tool to live-validated only via `main-gate-live-evidence.md`.
