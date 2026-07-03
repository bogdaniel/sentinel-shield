# External-adopter validation

Sentinel Shield ships **two** external-adopter validation harnesses plus a consolidated
**usability scorecard**. Both harnesses start from an empty workspace with **no internal
repo knowledge** (published docs only), acquire an immutable source ref, verify source
identity, and drive the documented lifecycle under a **constrained, observable**
environment. Neither records a secret or an absolute local path.

| Harness | Scope | Output |
| --- | --- | --- |
| `tests/adopter/black-box-install.sh` | A single documented install session | one `adopter-session` record |
| `tests/adopter/adopter-scenarios.sh` | A reproducible **multi-environment** suite | one `adopter-session` record **per scenario** + a scorecard |
| `scripts/report-adopter-usability.sh` | Folds sessions into a **blocking scorecard** | `adopter-scorecard` JSON + Markdown |

- Session records conform to [`schemas/adopter-session.schema.json`](../schemas/adopter-session.schema.json).
- Scorecards conform to [`schemas/adopter-scorecard.schema.json`](../schemas/adopter-scorecard.schema.json).
- The generator and its schemas are covered by the deterministic
  [`tests/prod/244-adopter-scorecard.sh`](../tests/prod/244-adopter-scorecard.sh)
  (positive, negative-per-criterion, failure-injection, fail-closed, redaction).
- CI: [`.github/workflows/ci-adopter-validation.yml`](../.github/workflows/ci-adopter-validation.yml)
  runs the scorecard unit tests and the multi-environment suite and **fails closed** unless
  the scorecard is green.

---

## Multi-environment adopter suite (`adopter-scenarios.sh`)

The suite runs a set of **isolated, offline, deterministic** scenarios. Each scenario, from
a clean workspace: drives the documented flow (acquire → verify → dry-run → install →
doctor → local pipeline as applicable), **injects at least one understandable failure**,
**performs recovery**, verifies the expected post-state, and emits one schema-valid session
record (tagged with its `scenario`, host `platform`, per-step `budget_seconds`, and a
`recovery` object). Every engine command runs under `env -i` with stdin from `/dev/null`
and a **bounded timeout with a distinct result code (124)**.

| Scenario | Environment covered | Injected failure → recovery |
| --- | --- | --- |
| `clean-linux` | Clean baseline install | unknown pipeline stage → re-run with a documented stage |
| `minimal-posix` | Minimal POSIX shell/PATH | doctor against a missing target → re-run against the installed target |
| `managed-file-conflict` | Pre-existing managed-file conflict | a managed file is tampered (mutation) → `install --apply --force` restores it **byte-for-byte** |
| `read-only-project` | Read-only project portions | install into a read-only dir fails → restore permission + re-install |
| `interrupted-recovery` | Interrupted install then recovery | the transaction journal is corrupted → `recover-operation --inspect` **fails closed (rc 4)**; restoring the journal recovers |
| `proxy-configured` | Proxy-configured host | the offline flow runs with a black-hole `http(s)_proxy` set, proving no network dependency |
| `offline-restricted` | Offline / restricted network | a network clone fails → the documented `--repository <path>` offline acquire (with `--verify`) recovers |

Scenarios that genuinely cannot run offline are recorded as **explicit, reasoned skips** on
the scorecard (a skip is **never** a pass): `update-from-beta.1` (needs the published
`v2.0.0-beta.1` ref over the network) and `uninstall` (no engine uninstall command is
published; rollback is instead proven by the recovery scenarios above). macOS shell
coverage is attributable through each session's `platform` field (the suite runs under the
host shell).

Run it standalone:

```sh
sh tests/adopter/adopter-scenarios.sh                     # sessions + scorecard -> temp dir
sh tests/adopter/adopter-scenarios.sh --out-dir out --keep
```

## Adopter usability scorecard (`report-adopter-usability.sh`)

The generator folds one or more session records into a single verdict against a **fixed set
of BLOCKING criteria**, each derived deterministically from the evidence. Every criterion
**fails closed** on missing/malformed/ambiguous evidence, and every failed criterion carries
a copy-pasteable **reproduction command**.

| Criterion | Blocks release when… |
| --- | --- |
| `undocumented-prerequisites` | a scenario hit a hidden prerequisite / interactive prompt, or skipped without a reason |
| `unexplained-failures` | a failed step carries no explanatory message |
| `unrecoverable-mutations` | a mutation-bearing failure was not recovered (`recovery.required` but not `restored`) |
| `errors-have-next-actions` | a failed step carries no safe `next_action` |
| `bounded-durations` | a mandatory step ran longer than its `budget_seconds` |
| `files-attributable` | a generated file is not attributable to a redacted root (`<target>`, `<workspace>`, `<engine-src>`, `~`) |
| `recovery-restores-state` | a performed recovery did not verifiably restore state |
| `no-secrets-no-abs-paths` | any session string leaks a secret shape or an absolute local path |

```sh
sh scripts/report-adopter-usability.sh --sessions-dir <dir> \
    --json-out scorecard.json --md-out scorecard.md
```

Exit code: `0` when the scorecard `result=pass`, `1` when a blocking criterion failed, `2`
on invalid invocation, `3` on **no/invalid evidence** (fail-closed). A redaction guard
refuses to emit a scorecard that would leak a secret shape or an absolute local path.

---

## Black-box install harness (`black-box-install.sh`)

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

## Relationship to the scorecard

The single black-box session above is one input the scorecard can consume. The
multi-environment suite (`adopter-scenarios.sh`) is the primary producer of the scored,
release-blocking adopter-experience rubric described earlier in this document. Richer
per-failure error objects (beyond the `message` + `next_action` the scorecard already
requires on every failed step) remain a future refinement.
