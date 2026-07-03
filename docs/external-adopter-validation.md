# External-adopter validation (black-box install harness)

`tests/adopter/black-box-install.sh` exercises the **documented install flow** as a
**first-time external adopter** would: from an empty workspace, using the documented
prerequisites and the published documentation
([`README.md`](../README.md), [`docs/ai-assisted-install.md`](ai-assisted-install.md)).

It is a black box: it drives the documented flow and records what actually happened,
rather than asserting how the internals work. Its determinism comes from **observable,
constrained execution** — every engine command runs under a minimal allowlisted
environment with stdin closed, so a hidden prerequisite or an interactive prompt
surfaces as a **failed step** rather than a silent pass or a hang.

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

Exit code: `0` when `result=pass`, `1` when a required step failed under the
constrained environment, `2` on harness misuse / a missing hard prerequisite.

## Rules it enforces

- **Constrained environment (deterministic).** Every engine command runs under a
  minimal allowlisted environment via `env -i` — only `PATH`, `HOME`, `TMPDIR`,
  plus the two documented env vars `SENTINEL_SHIELD_REF` and `SENTINEL_SHIELD_PATH`
  when set. Every other (undocumented) `SENTINEL_SHIELD_*` variable is therefore
  absent, so if a step depends on a hidden prerequisite it **fails** (recorded with
  the failing step and reason). The allowlist actually applied is recorded in
  `documented_environment`. This is a deterministic, observable check — it does
  **not** scan command output for variable names.
- **No interactive prompts.** Engine commands run with stdin from `/dev/null`, so a
  blocking `read` gets EOF and **fails** rather than hanging. `injected_inputs` stays
  empty (the harness feeds no answers) and `unexpected_prompt` records whether a
  prompt manifested.
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
to use), `documented_environment[]` (the environment allowlist applied to every
engine command), `injected_inputs[]` (empty — stdin is `/dev/null`),
`unexpected_prompt` (boolean), `steps[]`, and `result` (`pass`/`fail`).

Each step: `step`, `command` (redacted), `exit_code`, `elapsed_seconds`,
`status` (`ok`/`skip`/`fail`), `message` (redacted; a skip carries an explicit
reason), and `generated_files[]` (redacted).

`result` is `pass` only when **no required step failed** under the constrained
environment.

## Interpreting results

- `result: pass` — the documented flow completed end to end under the constrained
  environment (allowlisted env, stdin closed).
- A `fail` step — the recorded step and reason show where the flow broke. Because the
  environment was constrained to the documented allowlist, a break may mean a hidden
  prerequisite; fix the docs (or the default), not the harness.
- A `skip` step — read its `message`; the reason is always explicit. Network
  skips are expected offline; they are not evidence of success.

## Deferred (not covered here)

- **Failure-comprehension / error-contract overhaul** — richer, per-failure
  error objects are out of scope.
- **Usability scorecard** — a scored adopter-experience rubric is intentionally
  not produced by this harness.
