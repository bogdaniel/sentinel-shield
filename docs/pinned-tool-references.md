# Pinned Tool References (v0.1.13)

All GitHub Actions / images used by Sentinel Shield workflows + templates. SHAs below were
**resolved from upstream** on 2026-06-09 (not invented). `ci-self-test.yml` (the blocking
self-gate) is **pinned**. Other internal `.github/workflows/*` and all `templates/workflows/*`
keep readable tags and are marked **template-only — must pin before production**.

## GitHub Actions (resolved SHAs)

> **HISTORICAL — superseded.** The table(s) in this section are a point-in-time record and
> are **not enforced**: no audit reads this document. The authoritative inventory is
> ["Regenerated from the workflows (audit)"](#regenerated-from-the-workflows-audit)
> below, which is generated from the current tree. Do not copy pins from here.

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

## v0.1.19 — Semgrep 1.165.0 fixture-verified
`semgrep/semgrep:1.165.0` was run (via Docker, output `.version`=1.165.0) against the modern-PHP
fixture by `scripts/verify-semgrep-image.sh` → **0 parser errors**. Pin by digest before prod;
override via `SENTINEL_SHIELD_SEMGREP_IMAGE`. Live consumer re-validation still required.

## v0.1.21 — validated scanner image digests (resolved, not invented)
Digests resolved with `docker buildx imagetools inspect` on **2026-06-10** (multi-arch manifest-list
digests). These are the validated images from the v0.1.20 evidence run; see
[`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) for verify/update/rollback.

| Image | Tag (validation) | Resolved digest (2026-06-10) | Status |
|---|---|---|---|
| semgrep/semgrep | 1.165.0 | `sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b` | consumer-verified (run 27239206382); pin in consumer |
| anchore/grype | v0.114.0 | `sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28` | live-validated (run 27239206382); pin in consumer |
| goodwithtech/dockle | v0.4.15 | `sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9` | live-validated (run 27239206382); pin in consumer |

Override env vars (templates keep readable tags; pin by digest in the consumer before production):
`SENTINEL_SHIELD_SEMGREP_IMAGE`, `SENTINEL_SHIELD_GRYPE_IMAGE`, `SENTINEL_SHIELD_DOCKLE_IMAGE`.
**OWASP Dependency-Check is deliberately NOT digest-pinned** — *attempted, not live-validated*; no
digest is resolved for an unvalidated image (see [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md)).

## Regenerated from the workflows (audit)

The table(s) above were **stale and are not enforced**: neither
`scripts/audit-github-actions-pins.sh` nor `scripts/audits/workflow-runtime-audit.sh`
ever reads this document — both inspect the workflows directly. Several documented SHAs
appeared in no workflow, and several real pins were undocumented, while the header claimed the
list was "asserted by two fail-closed gates". Treat the workflows as the source of truth.

The following is generated from the current tree (18 pinned `uses:` refs, deduplicated):

| Action | Pinned SHA |
| --- | --- |
| `actions/cache` | `0057852bfaa89a56745cba8c7296529d2fc39830` |
| `actions/checkout` | `34e114876b0b11c390a56381ad16ebd13914f8d5` |
| `actions/checkout` | `9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0` |
| `actions/download-artifact` | `3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c` |
| `actions/setup-node` | `48b55a011bda9f5d6aeb4c2d9c7362e8dae4041e` |
| `actions/setup-node` | `49933ea5288caeca8642d1e84afbd3f7d6820020` |
| `actions/upload-artifact` | `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` |
| `actions/upload-artifact` | `ea165f8d65b6e75b540449e92b4886f43607fa02` |
| `anchore/sbom-action` | `e22c389904149dbc22b58101806040fa8d37a610` |
| `anchore/scan-action` | `e1165082ffb1fe366ebaf02d8526e7c4989ea9d2` |
| `aquasecurity/trivy-action` | `ed142fd0673e97e23eac54620cfb913e5ce36c25` |
| `github/codeql-action/analyze` | `54f647b7e1bb85c95cddabcd46b0c578ec92bc1a` |
| `github/codeql-action/autobuild` | `8aad20d150bbac5944a9f9d289da16a4b0d87c1e` |
| `github/codeql-action/init` | `54f647b7e1bb85c95cddabcd46b0c578ec92bc1a` |
| `gitleaks/gitleaks-action` | `e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e` |
| `google/osv-scanner-action/osv-scanner-action` | `9a498708959aeaef5ef730655706c5a1df1edbc2` |
| `shivammathur/setup-php` | `f3e473d116dcccaddc5834248c87452386958240` |
| `zizmorcore/zizmor-action` | `192e21d79ab29983730a13d1382995c2307fbcaa` |

**Verified:** every `uses:` line in `.github/workflows/` and `templates/workflows/` — 140 of
140 — is pinned to a full 40-hex commit SHA.
