# Trusted cross-workflow evidence handoff (opt-in)

> **The recommended topology has not changed.** Run the release gate in the **same workflow run**
> as the scanners, wired with `needs:`, so the summary artifact is in-run. That is what
> `templates/workflows/sentinel-shield.yml` does and what `install-baseline.sh` installs. If that
> works for you, stop reading — you do not need anything on this page.

## The gap this closes

Organisations that separate scanner workflows from a **protected** release/deploy workflow could
not use Sentinel Shield's gate at all: `actions/download-artifact` retrieves artifacts from the
current run, so a standalone release-gate workflow found no summary and failed closed. Correct,
but it left every such adopter to design artifact discovery themselves — and that is exactly
where untrusted-run and wrong-commit mistakes happen.

**"Download the latest successful artifact" is not a trust rule.** That run can be a fork pull
request, a different branch, a different commit, a re-run of an older commit, a cancelled run, or
a workflow nobody meant to trust. The artifact itself can be substituted.

## What is verified

`scripts/verify-evidence-handoff.sh` consumes **explicit producer metadata** and rejects
everything else. Every rule is mandatory; there is no advisory mode:

| # | Rule |
| --- | --- |
| 1 | the producer run belongs to the **exact** expected repository |
| 2 | head repository == producer repository (**a fork run is never evidence**) |
| 3 | the producer workflow name is on the caller's **allowlist** |
| 4 | when an expected run id is given, it must match exactly |
| 5 | the run is `completed` |
| 6 | the run concluded `success` (failure / cancelled / skipped rejected) |
| 7 | the triggering event is allowlisted (**never** `pull_request` / `pull_request_target`) |
| 8 | the run's ref/branch is on the trusted-ref allowlist |
| 9 | `head_sha` equals the **exact commit being gated** |
| 10 | the run is not older than `--max-age-seconds` (default 24h) |
| 11 | **exactly one** producer run survives; zero or several is a rejection |
| 12 | the artifact declares an allowlisted identity (from its manifest) |
| 13 | a checksum manifest exists, covers **every** file, and every digest matches |
| 14 | the summary's **own** `source.commit` / `source.branch` / `source.workflow` match |

Run `sh scripts/verify-evidence-handoff.sh explain` to print this list from the implementation.

Exit codes: `0` verified · `1` rejected · `2` invalid invocation / malformed input · `3` required
tool unavailable.

## Producer side

The scanner workflow must bind its evidence to the run that produced it:

```yaml
- name: Bind the evidence to this run (checksum manifest)
  run: |
    sh "$SENTINEL_SHIELD_PATH/scripts/build-evidence-manifest.sh" \
      --dir reports --repository "$GITHUB_REPOSITORY" --run-id "$GITHUB_RUN_ID" \
      --commit "$GITHUB_SHA" --workflow "$GITHUB_WORKFLOW"
- uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02 # v4
  with:
    name: sentinel-shield-security-summary
    path: |
      reports/security-summary.json
      reports/sentinel-shield-artifact-manifest.json
    if-no-files-found: error
```

Without the manifest the consumer rejects the handoff: an artifact name proves nothing, because
names are not unique across runs and contents are not bound to a commit.

## Consumer side

Install `templates/workflows/sentinel-shield-evidence-handoff.yml`. It ships **disabled** — its
`workflow_run` trigger is commented out — so nothing changes until you enable it and name your
producer workflow and trusted branches.

* It runs on `workflow_run`, i.e. in the context of the **default branch**, and never checks out
  or executes the producer's head code.
* Permissions are `contents: read` + `actions: read`. **No write scope.**
* It verifies **before** it enforces, and it does **not** fall back to the example summary: this
  topology exists to consume real evidence.

## Retention, replay, reruns and superseded runs

| Situation | Behaviour |
| --- | --- |
| **Retention expired** | the artifact download fails; the gate fails closed |
| **Replay of an old run** | rejected by rule 10 (freshness) and rule 9 (commit) |
| **Duplicate producer runs** | rejected as ambiguous (rule 11) unless one is named explicitly |
| **Re-run of the same run** | accepted — same run id, same commit, and the manifest still binds the artifact to that run id |
| **Superseded run** (newer run for the same commit) | name the run you intend to trust with `--expected-run-id`; the verifier never picks "latest" for you |
| **Artifact from another run** | rejected: the manifest's `run_id` must equal the trusted run |

## Migration for split pipelines

1. Add the manifest step + artifact upload to the scanner workflow (producer side above).
2. Install the handoff template, set `SENTINEL_SHIELD_TRUSTED_WORKFLOW` and
   `SENTINEL_SHIELD_TRUSTED_REF`, and enable the `workflow_run` trigger.
3. Run it once with `workflow_dispatch` against a known-good producer run and read the
   verification record artifact.
4. Only then make the handoff job a required check.
5. Keep the same-run gate wherever you can: it needs no trust decision at all.

Regression coverage: [`tests/prod/287-cross-workflow-handoff.sh`](../tests/prod/287-cross-workflow-handoff.sh).
