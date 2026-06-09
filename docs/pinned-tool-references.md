# Pinned Tool References (v0.1.13)

All GitHub Actions / images used by Sentinel Shield workflows + templates. SHAs below were
**resolved from upstream** on 2026-06-09 (not invented). `ci-self-test.yml` (the blocking
self-gate) is **pinned**. Other internal `github/workflows/*` and all `templates/workflows/*`
keep readable tags and are marked **template-only — must pin before production**.

## GitHub Actions (resolved SHAs)
| Action | Tag | Resolved SHA (2026-06-09) | Status |
|---|---|---|---|
| actions/checkout | v4.2.2 | `11bd71901bbe5b1630ceea73d27597364c9af683` | **pinned in ci-self-test.yml** |
| actions/upload-artifact | v4.6.2 | `ea165f8d65b6e75b540449e92b4886f43607fa02` | **pinned in ci-self-test.yml** |
| actions/download-artifact | v4.3.0 | `d3f86a106a0bac45b974a628896c90dbdf5c8093` | documented; pin in consumer |
| actions/setup-node | v4.4.0 | `49933ea5288caeca8642d1e84afbd3f7d6820020` | documented |
| shivammathur/setup-php | 2.32.0 | `9e72090525849c5e82e596468b86eb55e9cc5401` | documented |
| github/codeql-action | v3.29.0 | `ce28f5bb42b7a9f2c824e633a3f6ee835bab6858` | documented (init/analyze/autobuild) |
| aquasecurity/trivy-action | v0.36.0 | `ed142fd0673e97e23eac54620cfb913e5ce36c25` | documented |
| anchore/sbom-action | v0.20.7 | `d8a2c0130026bf585de5c176ab8f7ce62d75bf04` | documented |
| anchore/scan-action | v7.4.0 | `e1165082ffb1fe366ebaf02d8526e7c4989ea9d2` | documented |
| gitleaks/gitleaks-action | v2.3.9 | `ff98106e4c7b2bc287b24eaf42907196329070c7` | documented |
| google/osv-scanner-action | v1.9.0 | `19ec1116569a47416e11a45848722b1af31a857b` | documented |
| zaproxy/action-baseline | v0.14.0 | `7c4deb10e6261301961c86d65d54a516394f9aed` | template-only (manual DAST) |
| zaproxy/action-full-scan | v0.12.0 | `75ee1686750ab1511a73b26b77a2aedd295053ed` | template-only (manual DAST) |
| rhysd/actionlint (image) | v1.7.7 | `03d0035246f3e81f36aed592ffb4bebf33a03106` (git SHA) | advisory; image digest below |

## Container images — NOT pinned (resolve digests with `docker buildx imagetools inspect`)
These run as containers; pin by **digest** (not tag) before production. We do **not** invent
digests here — resolve them in your environment:
```sh
docker buildx imagetools inspect <image>:<tag> --format '{{.Manifest.Digest}}'
```
| Image | Tag in templates | Pin command target |
|---|---|---|
| semgrep/semgrep | latest | `semgrep/semgrep:<pinned>` |
| rhysd/actionlint | latest | `rhysd/actionlint:1.7.7` |
| ghcr.io/projectdiscovery/nuclei | latest | nuclei container |
| goodwithtech/dockle | latest | dockle container |
| ghcr.io/aquasecurity/trivy | latest | trivy image (image-scan mode) |
| anchore/grype | latest | grype container |

## How to update
1. `gh api repos/<owner>/<repo>/commits/<tag> --jq .sha` for actions; `docker buildx imagetools inspect` for images.
2. Replace `@<tag>` with `@<sha> # <tag>` (keep the tag as a trailing comment for readability).
3. Re-run `sh scripts/self-test.sh workflow-sanity` and the workflow.
4. Record date + SHA in this file.

## Validation status
- ci-self-test.yml actions: **pinned + validated** (workflow runs in this repo).
- All other refs: **resolved SHAs documented**, not yet applied (template-readability tags retained). Consumers MUST pin before production — the GH Actions pin audit gate flags unpinned refs.

## v0.1.15 — validated pins (used in zenchron-tools validation workflows, run 27170148123)
These action SHAs were resolved from upstream and exercised live in the consumer's validation
workflows (still tag-readable in Sentinel Shield templates — pin in the consumer before prod):
gitleaks-action v2.3.9 `ff98106e4c7b2bc287b24eaf42907196329070c7`,
github/codeql-action v3.29.0 `ce28f5bb42b7a9f2c824e633a3f6ee835bab6858`,
aquasecurity/trivy-action v0.36.0 `ed142fd0673e97e23eac54620cfb913e5ce36c25`,
anchore/sbom-action v0.20.7 `d8a2c0130026bf585de5c176ab8f7ce62d75bf04`,
google/osv-scanner-action v1.9.0 `19ec1116569a47416e11a45848722b1af31a857b`.
Semgrep image used as `semgrep/semgrep:1.90.0` (tag) — pin by digest before production.

## v0.1.18 — Semgrep image
Default bumped `semgrep/semgrep:1.90.0` → **`1.165.0`** (PHP parser fix). Overridable via
`SENTINEL_SHIELD_SEMGREP_IMAGE`; the `ci-security.yml` job `container:` is pinned to `1.165.0`
(can't shell-expand). **Pin by digest before production** (`semgrep/semgrep@sha256:…`).
