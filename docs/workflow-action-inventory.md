# Workflow Action Inventory

> **Generated-style artifact.** This table inventories every external GitHub
> Action referenced by a `uses:` across the shipped engine CI
> (`.github/workflows/*.yml`) and the consumer templates
> (`templates/workflows/*.yml`), with its immutable pin (full 40-hex commit SHA)
> and the human-readable version comment. Local (`./`) refs and container images
> are out of scope here.
>
> **Regenerate** the rows with:
> ```sh
> for f in .github/workflows/*.yml templates/workflows/*.yml; do
>   grep -hE '^[[:space:]]*-?[[:space:]]*uses:' "$f" \
>     | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//'
> done | sort -u
> ```
>
> **Enforcement.** Every pin below is asserted by two fail-closed gates:
> `scripts/audit-github-actions-pins.sh` (pin inventory / report) and
> `scripts/audits/workflow-runtime-audit.sh` (the `uses-sha-pin` check, wired
> into `.github/workflows/ci-workflow-lint.yml`). The version comments are
> bumped by Dependabot (`.github/dependabot.yml`, `github-actions` ecosystem) —
> **do not hand-bump SHAs here**; edit the workflow and let this inventory follow.

## GitHub-maintained actions (`actions/*`, `github/*`)

> **HISTORICAL — superseded.** The table(s) in this section are a point-in-time record and
> are **not enforced**: no audit reads this document. The authoritative inventory is
> ["Regenerated from the workflows (audit)"](#regenerated-from-the-workflows-audit)
> below, which is generated from the current tree. Do not copy pins from here.


| Action | Pinned SHA | Version | Used in |
| --- | --- | --- | --- |
| `actions/cache` | `0057852bfaa89a56745cba8c7296529d2fc39830` | v4 | sentinel-shield-dependency-check.yml, sentinel-shield-scheduled.yml (templates) |
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` | v4.2.2 | ci-self-test.yml, ci-workflow-lint.yml |
| `actions/checkout` | `34e114876b0b11c390a56381ad16ebd13914f8d5` | v4 | ci-codeql.yml, ci-docker.yml, ci-node.yml, ci-php.yml, ci-pipeline.yml, ci-release-gate.yml, ci-security.yml, and 7 templates |
| `actions/download-artifact` | `d3f86a106a0bac45b974a628896c90dbdf5c8093` | v4 | ci-pipeline.yml, ci-release-gate.yml |
| `actions/setup-node` | `49933ea5288caeca8642d1e84afbd3f7d6820020` | v4 | ci-node.yml, sentinel-shield.yml (template) |
| `actions/upload-artifact` | `ea165f8d65b6e75b540449e92b4886f43607fa02` | v4 | ci-docker.yml, ci-node.yml, ci-php.yml, ci-pipeline.yml, ci-release-gate.yml, ci-security.yml, and 7 templates |
| `actions/upload-artifact` | `ea165f8d65b6e75b540449e92b4886f43607fa02` | v4.6.2 | ci-self-test.yml |
| `github/codeql-action/init` | `dd903d2e4f5405488e5ef1422510ee31c8b32357` | v3.36.2 | ci-codeql.yml |
| `github/codeql-action/autobuild` | `dd903d2e4f5405488e5ef1422510ee31c8b32357` | v3.36.2 | ci-codeql.yml |
| `github/codeql-action/analyze` | `dd903d2e4f5405488e5ef1422510ee31c8b32357` | v3.36.2 | ci-codeql.yml |

> Note: `actions/checkout` and `actions/upload-artifact` each appear at two pins
> — the engine's own meta-CI (`ci-self-test.yml`, `ci-workflow-lint.yml`) tracks
> the newer patch (`v4.2.2` / `v4.6.2`) while the broader fleet tracks `v4`.
> Dependabot converges these over time; both are valid full-SHA pins.

## Third-party actions

| Action | Pinned SHA | Version | Used in |
| --- | --- | --- | --- |
| `anchore/sbom-action` | `e22c389904149dbc22b58101806040fa8d37a610` | v0 | ci-pipeline.yml, ci-security.yml, sentinel-shield.yml (template) |
| `anchore/scan-action` | `64a33b277ea7a1215a3c142735a1091341939ff5` | v4 | ci-security.yml |
| `aquasecurity/trivy-action` | `ed142fd0673e97e23eac54620cfb913e5ce36c25` | v0.36.0 | ci-docker.yml, ci-pipeline.yml, ci-security.yml, sentinel-shield.yml (template) |
| `gitleaks/gitleaks-action` | `ff98106e4c7b2bc287b24eaf42907196329070c7` | v2 | ci-security.yml |
| `google/osv-scanner-action/osv-scanner-action` | `19ec1116569a47416e11a45848722b1af31a857b` | v1.9.0 | ci-security.yml |
| `shivammathur/setup-php` | `f3e473d116dcccaddc5834248c87452386958240` | v2 | ci-php.yml, sentinel-shield.yml (template) |
| `zizmorcore/zizmor-action` | `192e21d79ab29983730a13d1382995c2307fbcaa` | v0.5.7 | ci-workflow-lint.yml |

## Related runtime invariants

Beyond pinning, `scripts/audits/workflow-runtime-audit.sh` also enforces, across
the same file set: explicit per-job `permissions` (workflow- or job-level),
explicit per-job `timeout-minutes`, a workflow-level `concurrency` group, and
`if-no-files-found` on every `actions/upload-artifact` step. See
`schemas/workflow-runtime-audit.schema.json` for the report contract and
`tests/prod/220-workflow-runtime-audit.sh` for the positive/negative coverage.

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
