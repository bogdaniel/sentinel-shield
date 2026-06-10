# Supply-Chain Reproducibility — v0.1.25

Builds on [`supply-chain-reproducibility-v024.md`](supply-chain-reproducibility-v024.md) and
[`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md). Lane M's original agent run
was interrupted by an API error; this doc is the captain recovery and carries the **re-verified
digests** plus the retention/threat-model/update-process material.

## 1. Scanner image digests — RE-VERIFIED live (2026-06-10, docker 29.4.0)

```
docker buildx imagetools inspect <image>:<tag> --format '{{.Manifest.Digest}}'
```

| Image | Tag | Digest (re-verified) | Status |
|---|---|---|---|
| semgrep/semgrep | 1.165.0 | `sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b` | **MATCH** baseline |
| anchore/grype | v0.114.0 | `sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28` | **MATCH** baseline |
| goodwithtech/dockle | v0.4.15 | `sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9` | **MATCH** baseline |

All three are unchanged since v0.1.21 (no tag re-push). This sprint additionally **ran two of these
images for real** (Grype v0.114.0, and Checkov via `bridgecrew/checkov`) — see
[`live-evidence-v025.md`](live-evidence-v025.md).

**OWASP Dependency-Check is deliberately NOT pinned** — `owasp/dependency-check:latest` is a moving
tag and the tool is *attempted, NOT live-validated* (its real run failed on NVD HTTP 429 this sprint).
Pin it by digest only after a real validated run.

## 2. Digest verification self-test (spec for the captain)
A `v025-live` self-test asserts the pinned digests appear in `scanner-image-digest-pinning.md` and
that no production doc recommends `:latest` for the three validated scanners (the
`owasp/dependency-check:latest` placeholder is the single documented, pin-before-prod exception).

## 3. Artifact retention policy
- CI artifacts (`reports/**`) upload with `if: always()` and `retention-days: 30` in every template.
- Evidence artifacts (real scanner outputs) live under `tests/fixtures/live-evidence/` and are
  versioned in git (immutable via the release tag).
- Audit-trail: the live-evidence registry + CHANGELOG record every promotion with a cited run/artifact.

## 4. Artifact naming standard
- Workflow artifacts: `sentinel-shield-<gate>` (pr-fast/main/scheduled/dast/ai-review/dependency-check).
- Raw reports: `reports/raw/<tool>.json`; SBOM: `reports/sbom.spdx.json`.
- Evidence fixtures: `tests/fixtures/live-evidence/<tool>-real.json`.

## 5. Artifact integrity notes
- Real scanner artifacts record the producing tool version (e.g. checkov 3.3.0, grype 0.114.0,
  deptrac 4.6.1) so a reviewer can reproduce.
- Digest-pinned images make a scanner run bit-reproducible given the same inputs + DB snapshot.

## 6. SBOM reproducibility
Syft SBOM (`reports/sbom.spdx.json`) is the deterministic input to Grype SBOM-first scanning; the
same SBOM + same Grype DB snapshot → same matches. Pin Syft + Grype by digest for reproducibility.

## 7. Scanner image UPDATE checklist
1. Bump the tag; `docker buildx imagetools inspect <image>:<newtag> --format '{{.Manifest.Digest}}'`.
2. Run the relevant validation (verify-semgrep-image.sh / a real scan); confirm collector parses.
3. Update the digest tables here + `scanner-image-digest-pinning.md` + `pinned-tool-references.md`.
4. Record in CHANGELOG + `main-gate-live-evidence.md` if it changes a promotion.

## 8. Scanner image ROLLBACK checklist
Revert the env override to the previous known-good digest (immutable → deterministic rollback);
re-run the gate; file the regression upstream; keep the old digest pinned until fixed.

## 9. GitHub Action pinning standard + update process
Pin actions to a full commit SHA before production (`pinned-tool-references.md`). To update: resolve
the new tag's SHA (`gh api repos/<o>/<r>/commits/<tag> --jq .sha`), replace `@<sha> # <tag>`, re-run
`self-test workflow-sanity`, record date+SHA.

## 10. Version compatibility table
| Tool | Pinned version | SS contract |
|---|---|---|
| Semgrep | 1.165.0 | curated `semgrep/app` rules; PHP parser fixed |
| Grype | v0.114.0 | SBOM-first / fs; `*_vulnerabilities` mapping |
| Dockle | v0.4.15 | built-image; `container_image_violations` |
| Checkov | 3.3.0 (run this sprint) | `iac_violations` |
| Deptrac | 4.6.1 (run this sprint) | `architecture_violations` |

## 11. Reproducibility threat model
- **Mutable tags** → mitigated by digest pinning.
- **Tag re-push** → detected by the digest verification step (mismatch ⇒ treat as update + re-validate).
- **Mirror/registry drift** → use a trusted registry or mirror the exact digest.
- **Scanner DB drift** (NVD/Grype DB) → results vary over time; record the DB version in evidence.
- **Mirror registries**: when using a mirror, verify the mirrored image's digest equals the upstream.

## 12. Digest mismatch / version drift
A digest mismatch on a pinned tag means the tag was re-pushed — do NOT auto-adopt; treat as an
update (§7) and re-validate. Scanner-version drift (new CVEs over time) is expected; nightly/scheduled
runs catch it; the gate decides, not the scanner exit code.

## 13. Retention (evidence + audit trail)
- Evidence fixtures: retained in git, immutable per tag.
- CI artifacts: 30 days (configurable per consumer compliance needs).
- Audit trail: CHANGELOG + live-evidence registry are append-only history.

Product-readiness-checklist and v1-readiness updates are captain-owned (done in this release).
