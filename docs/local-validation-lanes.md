# Local validation lanes

The engine's own suites must be run in **two** environments before a branch is considered
locally validated. A single lane is not enough, and running only the convenient one has
already let a real failure reach CI.

## Why two lanes

Several production behaviours read the platform environment directly. The clearest is the
commit: `scripts/build-security-summary.sh` resolves `COMMIT` from `GITHUB_SHA`, falling back
to `unknown`. Downstream, `ev_provenance` compares that commit against the producer manifest's
`.commit` — but **only when the commit is a real 40-hex SHA**. With `COMMIT=unknown` the
comparison is skipped entirely.

So a fixture whose manifest omits `.commit` is accepted locally and rejected in CI as
`commit-mismatch`. Both results are correct; the environments are asking different questions.
Anything touching source identity, provenance, artifact manifests, evidence handoff, run IDs,
run attempts, or attestations is environment-sensitive in the same way.

A test that passes in only one lane has not been validated. A test that passes in both, but
whose assertion is only *meaningful* in one, is weaker than it looks — prefer pinning the
inputs (see "Pinning" below) so the check is real in both.

## Lane A — no platform environment

```sh
env -u GITHUB_ACTIONS \
    -u GITHUB_REPOSITORY \
    -u GITHUB_REF \
    -u GITHUB_EVENT_NAME \
    -u GITHUB_RUN_ID \
    -u GITHUB_RUN_ATTEMPT \
    -u GITHUB_SHA \
    sh scripts/self-test.sh production-readiness
```

`env -u` is required rather than simply not exporting the variables: a shell, IDE, or previous
command may already have them set, and that is exactly the contamination the lane exists to
exclude.

## Lane B — simulated GitHub Actions

```sh
env \
    GITHUB_ACTIONS=true \
    GITHUB_REPOSITORY=bogdaniel/sentinel-shield \
    GITHUB_REF=refs/pull/<pr>/merge \
    GITHUB_EVENT_NAME=pull_request \
    GITHUB_RUN_ID=123456789 \
    GITHUB_RUN_ATTEMPT=1 \
    GITHUB_SHA="$(git rev-parse HEAD)" \
    sh scripts/self-test.sh production-readiness
```

Lane B approximates CI; it does not replace it. CI remains the authority, and a branch is
green only when both blocking workflows complete successfully on that branch's exact remote
SHA.

## Recording the result

Capture the exit status **before** the output goes anywhere else:

```sh
sh scripts/self-test.sh production-readiness > "$log" 2>&1
rc=$?
```

`cmd | grep …` reports `grep`'s status, not the suite's. A run that aborted early and printed
nothing useful will read as a pass through a pipe.

## Pinning, so a fixture does not depend on the lane

Where a suite builds a summary and its producer manifest, pin the commit on both sides instead
of letting the environment supply it. `scripts/self-test.sh` does this with `ST_FIXTURE_COMMIT`,
and `tests/prod/266-fail-closed-evidence-integrity.sh` with `FIXTURE_COMMIT`:

```sh
FIXTURE_COMMIT=0123456789abcdef0123456789abcdef01234567
sh "$BUILD" --raw-dir "$d/raw" --output "$d/s.json" --project-name t --commit "$FIXTURE_COMMIT"
# ... and the manifest names that same commit
```

Then assert the staging **before** relying on it, so a change in commit resolution reports
"the fixture failed to stage evidence" rather than "the gate under test rejected the summary":

```sh
check "fixture staging: sbom is attributed to this run" \
    "$(jq -r '.evidence.sbom.verification.provenance' "$d/s.json")" "verified"
```

Without that assertion the symptom appears at a later, unrelated check, which is how a fixture
defect reads as a defect in the gate.
