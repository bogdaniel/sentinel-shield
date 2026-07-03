# Automation interface — the `--output json` command-result contract

Sentinel Shield's CLI is human-first: every command prints a readable report and
uses a documented exit code. For automation (CI steps, bots, dashboards, other
tools) each of the primary commands also accepts an **opt-in** `--output json`
flag that emits a single, uniform **command-result envelope** on `stdout`.

The flag is strictly additive:

- Without `--output json`, nothing changes — same human output, same exit code.
- With `--output json`, `stdout` carries **exactly one JSON object** (the
  envelope) and nothing else; the human report is forwarded to `stderr`; the
  process exit code is **unchanged** (the envelope only classifies it).

Envelope shape is defined by
[`schemas/command-result.schema.json`](../schemas/command-result.schema.json)
and is stable across commands.

## Commands that support `--output json`

| Command | Purpose |
| --- | --- |
| `scripts/doctor.sh` | environment + adoption preflight |
| `scripts/install-baseline.sh` | install the baseline into a project |
| `scripts/sync-baseline.sh` | drift report / update managed files |
| `scripts/plan-upgrade.sh` | read-only upgrade plan |
| `scripts/bootstrap-profile-tools.sh` | provision a profile's required tools |
| `scripts/run-local-pipeline.sh` | run the canonical local gate |
| `scripts/check-release-readiness.sh` | release-promotion readiness gate |

## Envelope fields

```json
{
  "command": "doctor",
  "version": "2.0.0",
  "status": "warn",
  "exit_category": "warnings",
  "reason_codes": ["degraded_conditions", "has_warnings"],
  "warnings": ["no .github/workflows — wire the PR-fast gate"],
  "artifacts": [],
  "next_actions": ["docs/troubleshooting.md ; share diagnostics safely with scripts/support-bundle.sh"],
  "timestamp": "2026-07-02T20:05:44Z"
}
```

| Field | Meaning |
| --- | --- |
| `command` | canonical command name (e.g. `doctor`, `run-local-pipeline`). |
| `version` | engine version (`SENTINEL_SHIELD_VERSION`, default `2.0.0`). |
| `status` | `ok` \| `warn` \| `error` — coarse outcome. |
| `exit_category` | stable bucket for the exit code (see table below). |
| `reason_codes` | ordered stable machine tokens; primary reason first, then derived signals (`has_warnings`, `has_failures`). Never free text. |
| `warnings` | user-facing warnings, redacted. May be empty. |
| `artifacts` | paths of files the command wrote, redacted/relativized. May be empty. |
| `next_actions` | redacted next-step guidance surfaced by the run. May be empty. |
| `timestamp` | ISO-8601 UTC time the envelope was produced (optional). |

### `status` / `exit_category` mapping

`exit_category` is uniform across commands; each command maps its own exit codes
onto it. `status` is `ok` for `success`/`warnings` at exit 0, `warn` for a
non-blocking warning outcome, and `error` for any blocking condition.

| `exit_category` | Meaning | Typical exit codes |
| --- | --- | --- |
| `success` | clean | 0 |
| `warnings` | succeeded with non-blocking warnings | doctor 1 |
| `invalid_input` | bad invocation / config | 2 |
| `requirements_unmet` | a required tool / dependency is absent | 3 |
| `execution_error` | an operation / runner failed or was interrupted | 4 |
| `not_ready` | a promotion gate is unmet | check-release-readiness 1 |
| `findings` | security findings blocked the gate | run-local-pipeline 1 |

Consumers should branch on `status` (coarse) or `exit_category` (precise), and
use `reason_codes` for stable programmatic decisions. **Do not** parse the human
text on `stderr`.

## Redaction guarantees

Everything placed into the envelope is redacted before emission:

- `$HOME` is relativized to `~`.
- The run's `--target` root is relativized to `<target>`.
- Common secret shapes are masked: AWS access keys, GitHub tokens, JWTs, bearer
  tokens, and `NAME=VALUE` pairs whose `NAME` ends in
  `_KEY`/`_TOKEN`/`_SECRET`/`_PASSWORD`/`_PASSWD`/`_PWD`.

The envelope therefore carries **no absolute local paths and no secret values**,
so it is safe to log, attach to CI artifacts, or paste into an issue.

## Reconciliation notes (backward compatibility)

- `scripts/plan-upgrade.sh` already had `--format text|markdown|json` (the report
  format) and `--output <path>` (a file destination). Both are unchanged:
  `--format json` still prints the **raw plan**, and `--output <path>` still
  writes the report to a file. Only the exact token **`--output json`** selects
  the command-result envelope. (Writing a report to a bare file literally named
  `json` is the one sacrificed edge case; use `--output ./json` if you truly need
  it.)
- Other reporters that carry their own `--format json` (resolve-gates, enforce-gates,
  maturity-report, …) are unchanged; the envelope is an additional, orthogonal layer.

## Example: gate a CI step on the envelope

```sh
env=$(sh scripts/run-local-pipeline.sh --profile laravel --target . --stage pr --output json)
status=$(printf '%s' "$env" | jq -r .status)
category=$(printf '%s' "$env" | jq -r .exit_category)
case "$category" in
  success)            echo "gate passed" ;;
  findings)           echo "findings blocked the build"; exit 1 ;;
  requirements_unmet) echo "install scanners first (bootstrap-profile-tools)"; exit 1 ;;
  *)                  echo "pipeline problem: $status/$category"; exit 1 ;;
esac
```

Because the exit code is preserved, you may alternatively branch on `$?` and use
the envelope purely for structured detail.

## Implementation

The envelope is produced by [`scripts/lib/output-contract.sh`](../scripts/lib/output-contract.sh)
(`oc_*` functions). A command opts in with a single line after sourcing its libs:

```sh
. "$SCRIPT_DIR/lib/output-contract.sh"
oc_intercept "<command-name>" "$0" "$@"
```

`oc_intercept` is a no-op unless `--output json` is present; when it is, it
re-runs the same script (flag stripped) in a child process, captures its
`stdout`/`stderr`/exit-code, and emits the redacted envelope — so the underlying
command runs untouched and its human output and exit code are provably unchanged.

Conformance is covered by `tests/prod/230-output-contract.sh` (run under
`sh scripts/self-test.sh production-readiness`).

## Bounded external processes (`bounded-command-result`)

Every external process the engine shells out to — `docker info` / `docker inspect`
/ `docker image inspect`, scanner version probes and scanner execution, `gh api`,
`git verify-tag`, package-manager version probes and installs, archive
inspection/extraction, and external consumer validation — runs under a hard,
bounded wall-clock timeout via [`scripts/lib/bounded-process.sh`](../scripts/lib/bounded-process.sh)
(`bp_*` functions). This eliminates indefinite execution: a wedged Docker daemon
or a stuck API can no longer freeze a gate.

`bp_run` escalates **TERM → (bounded grace) → KILL**, reaps the whole descendant
tree (no orphans), preserves the real exit code on normal completion, and
classifies the outcome. `bp_result_json` emits ONE machine-readable object
conforming to [`schemas/bounded-command-result.schema.json`](../schemas/bounded-command-result.schema.json):

```json
{
  "schema": "bounded-command-result",
  "command": "docker",
  "command_category": "docker-probe",
  "status": "timed-out",
  "exit_code": null,
  "signal": null,
  "timeout_seconds": 15,
  "duration_seconds": 15,
  "timed_out": true,
  "timestamp": "2026-07-04T00:00:00Z"
}
```

`status` is one of `success | failed | timed-out | unavailable | signalled`.
`exit_code` is `null` on `timed-out`, `unavailable`, and `signalled`; `signal`
carries the number on `signalled`. **`command` is the executable basename only —
command arguments are NEVER surfaced**, because they may carry credentials
(tokens, registry auth, `--propertyfile` paths).

### Configuration (safe defaults)

| Category | Env override | Default (s) |
| --- | --- | --- |
| generic external process | `SENTINEL_SHIELD_PROCESS_TIMEOUT_SECONDS` | 120 |
| docker probe (info/inspect) | `SENTINEL_SHIELD_DOCKER_PROBE_TIMEOUT_SECONDS` | 15 |
| GitHub API (`gh api`) | `SENTINEL_SHIELD_GITHUB_API_TIMEOUT_SECONDS` | 60 |
| scanner version probe | `SENTINEL_SHIELD_SCANNER_VERSION_TIMEOUT_SECONDS` | 30 |
| scanner execution | `SENTINEL_SHIELD_SCANNER_TIMEOUT_SECONDS` | 300 |
| git signature verify | `SENTINEL_SHIELD_GIT_VERIFY_TIMEOUT_SECONDS` | 60 |
| package-manager probe | `SENTINEL_SHIELD_PACKAGE_PROBE_TIMEOUT_SECONDS` | 30 |
| package install | `SENTINEL_SHIELD_PACKAGE_INSTALL_TIMEOUT_SECONDS` | 600 |
| archive inspect/extract | `SENTINEL_SHIELD_ARCHIVE_TIMEOUT_SECONDS` | 120 |
| consumer validation | `SENTINEL_SHIELD_CONSUMER_TIMEOUT_SECONDS` | 300 |

Scanner-specific overrides are honoured too (e.g.
`SENTINEL_SHIELD_GRYPE_TIMEOUT_SECONDS`, `SENTINEL_SHIELD_OSV_SCANNER_TIMEOUT_SECONDS`
for the version probe). The kill grace is `SENTINEL_SHIELD_PROCESS_KILL_GRACE_SECONDS`
(default 5s). The absolute upper bound is `SENTINEL_SHIELD_PROCESS_TIMEOUT_MAX_SECONDS`
(default 86400). **Invalid timeouts fail closed**: zero, negative, non-numeric, or
above-max values reject the invocation (return code 2) — nothing is silently coerced.

When GNU `timeout`/`gtimeout` is present it is used; otherwise a portable watchdog
(background command + once-per-second poll + `pgrep`-based tree reap) provides
identical semantics. Set `SENTINEL_SHIELD_BP_FORCE_PORTABLE=1` to force the portable
path (used by the test suite for deterministic escalation coverage).

Conformance is covered by `tests/prod/250-bounded-processes.sh`. The timeout state
also reaches the security audit report — see
[security-operations.md](security-operations.md).

## Deferred (not in this contract)

- **Failure-comprehension / error-contract overhaul** — a richer per-failure
  error object (codes, remediation links) is out of scope here; `reason_codes`
  is intentionally coarse for now.
- **Usability scorecard** — a scored adopter-experience rubric is not part of
  this contract.
