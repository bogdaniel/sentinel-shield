# External-adopter validation (black-box install harness)

`tests/adopter/black-box-install.sh` proves that a **first-time external adopter**
can install and run Sentinel Shield using **only** the published documentation
([`README.md`](../README.md), [`docs/ai-assisted-install.md`](ai-assisted-install.md))
and the documented prerequisites — with **no internal knowledge** of the engine,
no undocumented environment variables, and no private paths.

It is a black box: it drives the documented flow and records what actually
happened, rather than asserting how the internals work.

## What it does

Starting from an **empty** `mktemp` workspace, it drives the documented flow:

```
acquire -> verify -> dry-run -> install (temp target) -> doctor -> local pipeline
```

For every step it records the exact command, exit code, elapsed time, generated
files, and the user-facing message into a machine-readable **session record**
conforming to
[`schemas/adopter-session.schema.json`](../schemas/adopter-session.schema.json).

Run it standalone:

```sh
sh tests/adopter/black-box-install.sh                 # session -> stdout + a temp file
sh tests/adopter/black-box-install.sh --session-out session.json
```

Exit code: `0` when `result=pass`, `1` when a required step failed or an
undocumented requirement was hit, `2` on harness misuse / a missing hard
prerequisite.

## Rules it enforces

- **Documented interfaces only.** The flow uses published flags and the two
  documented env vars `SENTINEL_SHIELD_REF` and `SENTINEL_SHIELD_PATH`. If any
  step ever *requires* an undocumented env var or an internal path, it is
  recorded in `undocumented_requirements[]` and the session **fails**. A green
  run therefore evidences that the documented surface is sufficient.
- **Offline-safe, but a skip is not a pass.** The engine is acquired via the
  documented `--repository <path>` form (a local checkout) using the current
  `HEAD` commit as the immutable `--ref`, so no network is needed. A genuinely
  network-only step (cloning from GitHub) is **skipped with an explicit reason**
  and is never counted as success.
- **Honest outcomes for a bare adopter.** With no scanners installed yet,
  `doctor` and `run-local-pipeline` legitimately report *required tool
  unavailable* (exit 3). The harness records that truthfully as an expected
  pre-`bootstrap-profile-tools` state (`status: ok`), never masking it.
- **No secrets, no absolute paths.** Every recorded command, message, and file
  path is redacted: the workspace root becomes `<workspace>`, the install target
  `<target>`, the engine source `<engine-src>`, `$HOME` becomes `~`, and secret
  shapes are masked.

## Session record

Top level: `schema_version`, `harness`, `started_at`, `finished_at`, `workspace`,
`engine_source`, `documented_inputs` (the env vars and docs the flow was allowed
to use), `steps[]`, `undocumented_requirements[]`, and `result` (`pass`/`fail`).

Each step: `step`, `command` (redacted), `exit_code`, `elapsed_seconds`,
`status` (`ok`/`skip`/`fail`), `message` (redacted; a skip carries an explicit
reason), and `generated_files[]` (redacted).

`result` is `pass` only when **no step failed** and
`undocumented_requirements[]` is **empty**.

## Interpreting results

- `result: pass` — the documented flow was sufficient end to end.
- A `fail` step with a non-empty `undocumented_requirements[]` — the docs are
  missing something an adopter needed; fix the docs (or the default), not the
  harness.
- A `skip` step — read its `message`; the reason is always explicit. Network
  skips are expected offline; they are not evidence of success.

## Deferred (not covered here)

- **Failure-comprehension / error-contract overhaul** — richer, per-failure
  error objects are out of scope.
- **Usability scorecard** — a scored adopter-experience rubric is intentionally
  not produced by this harness.
