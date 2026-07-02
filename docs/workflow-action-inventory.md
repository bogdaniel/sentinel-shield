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

| Action | Pinned SHA | Version | Used in |
| --- | --- | --- | --- |
| `actions/cache` | `0057852bfaa89a56745cba8c7296529d2fc39830` | v4 | sentinel-shield-dependency-check.yml, sentinel-shield-scheduled.yml (templates) |
| `actions/checkout` | `11bd71901bbe5b1630ceea73d27597364c9af683` | v4.2.2 | ci-self-test.yml, ci-workflow-lint.yml |
| `actions/checkout` | `34e114876b0b11c390a56381ad16ebd13914f8d5` | v4 | ci-codeql.yml, ci-docker.yml, ci-node.yml, ci-php.yml, ci-pipeline.yml, ci-release-gate.yml, ci-security.yml, ci-zap.yml, and 7 templates |
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
| `zaproxy/action-baseline` | `66042c8e7e24680119199a017e5b0e8603bf4dae` | v0.12.0 | ci-zap.yml |
| `zaproxy/action-full-scan` | `d2a07475d467566c9a3e3c700f31f47724aa1060` | v0.10.0 | ci-zap.yml |
| `zizmorcore/zizmor-action` | `192e21d79ab29983730a13d1382995c2307fbcaa` | v0.5.7 | ci-workflow-lint.yml |

## Related runtime invariants

Beyond pinning, `scripts/audits/workflow-runtime-audit.sh` also enforces, across
the same file set: explicit per-job `permissions` (workflow- or job-level),
explicit per-job `timeout-minutes`, a workflow-level `concurrency` group, and
`if-no-files-found` on every `actions/upload-artifact` step. See
`schemas/workflow-runtime-audit.schema.json` for the report contract and
`tests/prod/220-workflow-runtime-audit.sh` for the positive/negative coverage.
