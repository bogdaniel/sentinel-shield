# Production Release Runbook

Operator procedure for taking a Sentinel Shield engine-only release from a verified candidate
to a published, verified tag. The tooling is **read-only and fail-closed**: it verifies,
records a governed authorization, and prints the exact commands — it **never** creates, moves,
or deletes a tag or GitHub Release. Publishing is a deliberate manual step you perform with an
explicit destructive command **and** a valid authorization token.

Where this runbook and prose disagree, [`product-status.md`](product-status.md) is the
canonical maturity source and [`sentinel-shield-release-process.md`](sentinel-shield-release-process.md)
is the canonical process source.

## Stages

`beta` → `rc` → `ga`. Gates compose upward. This cycle ships **engine-only** (see
[`v2-release-scope.md`](v2-release-scope.md)); **framework-validated / full-platform GA is
BLOCKED** by design because the engine cannot prove framework live-validation.

## What an engine-only GA candidate must prove

`scripts/authorize-production-release.sh verify-candidate` re-derives **every** gate below from
the referenced evidence artifacts and fails closed on the first that is missing, malformed, or
not green:

1. Exact default-branch **source commit** (evidence `engine_commit`), proven by a successful
   `push`/`workflow_dispatch` engine CI run — a `pull_request` run is **never** release proof.
2. Required workflows green; **artifact content verification**; artifact **digest
   reproducibility** against the release manifest; manifest **self-consistency**.
3. Production **security acceptance** (no unresolved critical/high; no expired waivers).
4. **Compatibility matrix** complete and green; **adopter scorecard** pass.
5. **Upgrade** validation and **rollback** validation pass.
6. Published **limitations**; **support** + **incident-response** readiness documents present.

## Procedure

```sh
WT=.   # repo root

# 1) Assemble a candidate descriptor (schemas/release-candidate.schema.json).
scripts/authorize-production-release.sh prepare \
  --version 2.0.0 --stage ga --scope engine-only \
  --source-commit <40hex> --tag v2.0.0 \
  --evidence evidence/releases/v2.0.0.json --manifest release/2.0.0-manifest.json \
  --artifacts release/2.0.0-artifacts.json --security-acceptance release/2.0.0-acceptance.json \
  --compat-matrix release/2.0.0-compat.json --adopter-scorecard release/2.0.0-scorecard.json \
  --upgrade-validation release/2.0.0-upgrade.json --rollback-validation release/2.0.0-rollback.json \
  --limitations docs/v2-release-scope.md --support-policy docs/support-policy.md \
  --incident-response docs/security-incident-response.md \
  --output release/2.0.0-candidate.json

# 2) Verify the candidate (READY only if every gate passes).
scripts/authorize-production-release.sh verify-candidate --candidate release/2.0.0-candidate.json

# 3) Record a governed authorization (two-person, unexpired, bound to the manifest hash).
#    schemas/release-authorization.schema.json. Interactive method additionally needs --confirm-token.
scripts/authorize-production-release.sh authorize \
  --candidate release/2.0.0-candidate.json \
  --authorization release/2.0.0-authorization.json \
  --output release/2.0.0-decision.json

# 4) Print the EXACT manual publish commands (the tool does not run them).
scripts/authorize-production-release.sh print-tag-commands \
  --candidate release/2.0.0-candidate.json \
  --authorization release/2.0.0-authorization.json
```

`print-tag-commands` emits a signed-tag + push + `gh release create` sequence targeting the
CI-proven source commit. Run those yourself, holding the authorization.

## Post-publication verification

```sh
scripts/verify-published-release.sh verify-tag --repo-root "$WT" --tag v2.0.0 --commit <40hex>
scripts/verify-published-release.sh verify-github-release --tag v2.0.0 --stage ga \
  --repo <owner/name> --expected-commit <40hex>
scripts/verify-published-release.sh smoke --manifest release/2.0.0-manifest.json \
  --artifacts release/2.0.0-artifacts.json
```

`verify-tag` fails closed if the tag peels to a different commit (a moved/mis-targeted tag) or
if its signature is unverifiable. `smoke` re-confirms the published artifact digests still
reproduce the manifest fingerprint.

## Exit codes (both tools)

| Code | Meaning |
| --- | --- |
| 0 | ok / READY / authorized / verified |
| 1 | NOT READY / rejected / BLOCKED |
| 2 | invalid invocation / malformed input / **refused destructive op** |
| 3 | required tool unavailable |
| 4 | bounded operation timed out |

## Never

The tool refuses `--delete-tag`, `--move-tag`, `--force-tag`, `--retag`, `--delete-release`,
`--force-push` (and similar) in **every** mode. Released tags are immutable. To fix a bad
release you roll **forward** — see [`rollback-policy.md`](rollback-policy.md).

## Production-readiness candidate + independent evidence review

Before a candidate is even assembled, the whole engine-only surface is gated by the
production-readiness harness `scripts/run-production-readiness.sh`
(schema: [`schemas/production-readiness-report.schema.json`](../schemas/production-readiness-report.schema.json))
and its CI wiring `.github/workflows/ci-production-readiness.yml`. It has four modes:

```sh
# 1) Orchestrate every local gate (shell syntax, shellcheck, actionlint, schema validation,
#    self-tests, prod tests, adopter scenarios, consumer validation, security acceptance,
#    release-authorization negative+positive, archive/artifact adversarial, evidence+manifest
#    reproducibility) and emit the report. Each gate is bounded; a hung gate yields a DISTINCT
#    exit code 4.
scripts/run-production-readiness.sh run \
  --source-commit <40hex> --workflow ci-production-readiness --event push \
  --default-branch master --changed-files changed.txt \
  --out-json integration/production-readiness-report.json \
  --out-md integration/production-readiness-report.md

# 2) INDEPENDENTLY review that report as UNTRUSTED evidence. review re-derives EVERY trust
#    decision — source commit, workflow identity, default branch, event type, freshness,
#    changed-file inventory, summary consistency, skipped/failed required gates, tag-target
#    policy, scanner health, compatibility coverage, adopter score, security acceptance,
#    published limitations, artifact ownership+content — and FAILS CLOSED on any mismatch.
#      --profile ci-gate proves what CI can prove (identity/gates/freshness/tag-policy/title);
#      --profile release (default) additionally proves the compat/adopter/security/artifact
#      evidence and the soak window.
scripts/run-production-readiness.sh review \
  --report integration/production-readiness-report.json \
  --expected-commit <40hex> --expected-workflow ci-production-readiness \
  --expected-default-branch master --profile release

# 3) Version-decision helper — beta.3 (material blockers), rc.1 (behavior complete,
#    soak/evidence remains), or 2.0.0 (all engine-only GA criteria pass). --strict falls back
#    to the beta.3 floor unless independent review passes.
scripts/run-production-readiness.sh version-decision \
  --report integration/production-readiness-report.json \
  --strict --expected-commit <40hex> --expected-workflow ci-production-readiness

# 4) Emit the structure-only integration report skeleton (real values filled at integration).
scripts/run-production-readiness.sh emit-template
```

The emitted report title **must** state engine-only until the framework tracks
(Laravel/Symfony live-validation) are independently validated on their own track; `review`
fails closed if it does not. The report carries no secrets, tokens, signing-key paths, or
repo-local absolute paths.
