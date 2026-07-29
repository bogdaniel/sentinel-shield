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
if its signature is unverifiable. The publisher additionally requires GitHub to *attribute* the
signature to a registered signing identity — see
[`TAG_SIGNING_IDENTITY_UNVERIFIED`](#tag_signing_identity_unverified--publication-refused). `smoke` re-confirms the published artifact digests still
reproduce the manifest fingerprint.

Publication is also asserted in the canonical contract
([`config/release-status.json`](../config/release-status.json)) and is checked by
`check-release-readiness.sh`. A release declared `published: true` with no GitHub Release
behind it is a **non-waivable** readiness failure:

```sh
sh scripts/validate-release-status.sh published --verify-github
```

## `TAG_SIGNING_IDENTITY_UNVERIFIED` — publication refused

The publisher requires `verification.verified == true` from the GitHub API before it will
create a release. **Every** other state blocks:

| Reported state | Blocks | Why |
| --- | --- | --- |
| `verified: true` | no | the only publishing state |
| `unknown_key` | **yes** | the tag carries signature bytes GitHub cannot attribute to a registered key |
| `unknown_signature_type` | **yes** | same — the signature type is not one GitHub can attribute |
| `bad_signature`, `expired_key`, `revoked_key`, `unsigned` | **yes** | the signature itself does not verify |
| verification fields absent / `null` | **yes** | a missing verification result is not a passed one |
| malformed or empty API response | **yes** | an unreadable check is not a passed check |
| API request failure (after 3 attempts) | **yes** | an unknown integrity state is not a verified one |

**Signature material is not release authorization.** `unknown_key` means the tag is signed by
*something*; it does not establish *who*, and it does not establish that the signer may publish
Sentinel Shield releases. There is deliberately **no** bootstrap exception, owner-approved
bypass, expiring waiver, or warning-only path — publication either proves the signing identity
or does not happen.

### What the failure tells you

The diagnostic names the tag, the tag target, the published commit, GitHub's verification
reason, the signer when the API can name one, and the remediation.

### Remediation

1. **Register the public signing key** on the account that signed the tag
   (GitHub → Settings → SSH and GPG keys). This is the preferred fix: it makes the *existing*
   tag verifiable.
2. Re-run publication for the same tag:

   ```sh
   gh workflow run release-publish.yml -f tag=<tag>
   ```

   The workflow is idempotent: re-running it for an already-published tag does not fail.
3. **If the signing key cannot be registered or recovered**, cut a **new** reviewed release
   tag. Do not attempt to rescue the old one.

### What you must NOT do

An existing tag in this state is **immutable**:

- do **not** force-update, move, or delete-and-recreate it;
- do **not** re-sign it in place;
- do **not** replace it silently with a new tag of the same name;
- do **not** add an exception file, environment variable, or workflow input to get past the
  check — none exists, and adding one would defeat the control.

Such a tag stays in the repository as **tagged but unpublished / unverified**. Record it that
way in `config/release-status.json` and in the release notes; it is an honest historical fact,
not a defect to be edited away. Publication may be retried at any later time once the key is
registered.

## Recovery: a tag exists but no GitHub Release was created

A tag-push event **triggers** the publisher; it does not prove a release was published. The
release exists only once the publisher has created it and the verification step has confirmed
it. If the event never produced one — the publisher workflow was added or fixed **after** the
tag was pushed, the run failed, the signing identity was not verified, or the release notes
were not yet merged to the default branch — the repository ends up with an immutable tag and
no GitHub Release, while the documentation claims a published release. The tag is the input to
publication, never the evidence of it.

Recover with the publisher's **backfill** path. It publishes an **existing** tag and can
never create, move, or force-update one:

1. Confirm the gap (this is what fails the readiness gate):

   ```sh
   sh scripts/validate-release-status.sh published --verify-github
   gh release view <tag> --repo <owner/name>     # expect: release not found
   ```

2. Make sure `docs/<tag>-release-notes.md` exists on the default branch (or in the tagged
   commit). **Missing notes fail the job** — the publisher no longer skips silently.

3. Run the recovery dispatch (Actions → `release-publish` → *Run workflow*), or:

   ```sh
   gh workflow run release-publish.yml --repo <owner/name> -f tag=<tag>
   ```

   The job re-validates the tag name grammar, requires the tag to already exist, requires it
   to be an **annotated, signed** tag, publishes with `gh release create --verify-tag`, and
   then re-verifies the published release. It is **idempotent**: if the release already
   exists (including one created concurrently), it is left exactly as-is.

4. Re-run step 1. It must now pass.

Never "fix" a missed publication by deleting and re-pushing the tag. Released tags are
immutable; a bad release rolls **forward** ([`rollback-policy.md`](rollback-policy.md)).

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
