# Profile Tool Policy — the canonical contract

This is the human + machine contract for how a Sentinel Shield **profile** declares
the tools it expects, how those tools are detected, installed, configured, executed,
and finally **gated**. It is the source of truth that every downstream agent and
script (installer, sync, runners, `build-security-summary.sh`, `enforce-gates.sh`)
aligns to.

Machine schemas:

- `schemas/tool-policy.schema.json` — the per-tool policy object and the profile-level
  `tools` map (`$defs.toolPolicy`, `$defs.toolsMap`).
- `profiles/profile.manifest.schema.json` — adds optional `tools`, `extends`,
  `tool_policy_version` to a profile manifest.
- `schemas/installation.schema.json` — `.sentinel-shield/installation.json`.
- `schemas/tool-policy-override.schema.json` — project `.sentinel-shield/tool-policy.yaml`.
- `schemas/security-summary.schema.json` — per-tool `status` enum (the result states).

Tool **keys** are the keys of `TOOL_TABLE` in `scripts/build-security-summary.sh`
(e.g. `phpstan`, `psalm`, `tests`, `gitleaks`, `third-party-semgrep`).

---

## 1. Vocabulary

### Policies (what the profile *demands* of a tool)

| policy        | meaning                                                                                          |
| ------------- | ------------------------------------------------------------------------------------------------ |
| `required`    | Must be present, configured, and pass. Absence/error **fails the build**.                         |
| `recommended` | Should be present. Absence **warns**, does not fail.                                              |
| `optional`    | Nice to have. Absence is **informational** only.                                                 |
| `one-of`      | Satisfies a requirement *together with* its `alternatives` (e.g. `pest`|`phpunit`). At least one of the set must be present and pass. |
| `disabled`    | Deliberately turned off for this profile/project. Never run; never gates.                         |
| `external`    | Provided/run outside Sentinel Shield (results may be imported). Not installed or executed by us.  |

**Precedence** (when a project override or `extends` merge conflicts), as ranked by
the canonical resolver (`scripts/lib/effective-profile.sh`):
`required > one-of > recommended > optional > external > disabled`.

### States (what actually *happened* to a tool — per-tool `status` in the summary)

| state             | meaning                                                            |
| ----------------- | ----------------------------------------------------------------- |
| `pass`            | Ran successfully, zero findings.                                   |
| `findings`        | Ran successfully, found issues (the JSON carries the counts).      |
| `fail`            | Ran, and the result fails the gate for its policy.                 |
| `unavailable`     | Tool not detected / no valid report produced. **Not** zero.       |
| `not-configured`  | Tool present but no config file where one is required.             |
| `not-applicable`  | The stack this tool targets is absent (e.g. no Dockerfile).       |
| `execution-error` | Tool crashed or produced invalid output.                          |
| `disabled`        | Turned off by policy; intentionally not run.                      |

(`skipped` and `warn` remain valid legacy values for backward compatibility.)

### `missing_behavior` (per-tool override of the absence reaction)

`fail` / `warn` / `info` / `skip`. Defaults follow policy: `required→fail`,
`recommended→warn`, `optional→info`, `disabled`/`external`→`skip`.

---

## 2. Lifecycle

A tool moves through these stages; each stage can short-circuit to a state:

```
declared → detected → compatible → installed → configured → executed → reported → gate-enforced
```

1. **declared** — present in the profile `tools` map (and any `extends` bases).
2. **detected** — one of `executable[]` is found (first match wins), e.g.
   `vendor/bin/phpstan` then `phpstan`. Not found ⇒ `unavailable`.
3. **compatible** — package `compatibility` (`auto` or a constraint) resolves
   against the project runtime. Incompatible ⇒ `unavailable` (with a reason).
4. **installed** — `packages[]` are installed in the right `scope` (dev/prod).
5. **configured** — the `config.path` exists per its `classification`. Required
   tool with no usable config ⇒ `not-configured`.
6. **executed** — the `runner` runs the tool **without mutating the project** and
   writes the normalized report to `report` (under `reports/raw/`). A crash or
   invalid output ⇒ `execution-error`. The runner still **exits 0** — the JSON is
   the signal — and on absence leaves the report **absent** (never a fake clean 0).
7. **reported** — `build-security-summary.sh` reads `reports/raw/<tool>.json`,
   folds counts into the `summary`, and records the per-tool `status`.
8. **gate-enforced** — `enforce-gates.sh` applies the policy + state rules below.

---

## 3. The state machine (policy × state ⇒ outcome)

Hard rules — these MUST hold:

- `required` + `unavailable` ⇒ **config failure** (the tool was demanded but is missing).
- `required` + `not-configured` ⇒ **config failure**.
- `required` + `execution-error` ⇒ **gate failure**.
- `required` + `findings`/`fail` ⇒ **gate failure**.
- `required` + `pass` ⇒ pass.
- `recommended` + `unavailable` ⇒ **warning** (never fails).
- `recommended` + `execution-error` ⇒ **warning**.
- `optional` + `unavailable` ⇒ **info** only.
- `one-of` ⇒ evaluate the set (`self` + `alternatives`): if **none** present ⇒
  treat as `required`/`recommended` absence per the group's policy; if at least one
  present, the group passes when one passes (others may be `not-applicable`).
- `disabled` / `external` ⇒ never executed by us; never gates (`external` results
  may be imported and counted, but absence is not our failure).
- **Zero findings are legitimate ONLY after a successful execution** (`pass`).
- **NEVER convert `unavailable` (or `execution-error`) into a `0`/clean report.**
  An absent tool stays absent; the gate reasons about the policy, not a fake count.

Outcome → exit semantics live in `enforce-gates.sh`; this doc fixes the
policy/state truth table it implements.

---

## 4. Worked example

A `laravel` profile manifest fragment. `phpstan` is required, `larastan` is the
package that provides PHPStan's Laravel rules, and `php-tests` is a `one-of` over
`pest`/`phpunit`.

> **Independent test groups (v2).** PHP and JavaScript test requirements are
> **separate** one-of groups — `php-tests` (`pest`|`phpunit`, report
> `reports/raw/tests.json`) and `js-tests` (`vitest`|`jest`, report
> `reports/raw/js-tests.json`). They never share a key, so a PHP test runner can
> never satisfy a JS requirement (or vice versa). `laravel`/`symfony`/`php-library`
> require `php-tests`; `node`/`react` require `js-tests`; a combined profile such
> as `laravel-react-docker` requires **both**, independently. Both reports feed the
> `test_failures` gate.

```yaml
# profiles/laravel/profile.manifest.json  (shown as YAML for readability)
profile: laravel
tool_policy_version: 1
extends: [php-base]
tools:
  phpstan:
    policy: required
    category: static-analysis
    packages:
      - { name: phpstan/phpstan, scope: dev, compatibility: auto }
      - { name: larastan/larastan, scope: dev, compatibility: auto }
    executable: ["vendor/bin/phpstan", "phpstan"]
    runner: scripts/runners/laravel-phpstan.sh
    report: reports/raw/phpstan.json
    missing_behavior: fail
    execution: { pr: true, main: true, scheduled: false }
    config: { path: phpstan.neon, classification: never-touch }

  php-tests:                 # JS projects use a separate `js-tests` group (vitest|jest)
    policy: one-of
    category: tests
    alternatives: [pest, phpunit]
    report: reports/raw/tests.json
    execution: { pr: true, main: true, scheduled: false }

  pest:
    policy: one-of
    category: tests
    packages: [{ name: pestphp/pest, scope: dev, compatibility: auto }]
    executable: ["vendor/bin/pest"]
    alternatives: [phpunit]
    report: reports/raw/tests.json

  phpunit:
    policy: one-of
    category: tests
    packages: [{ name: phpunit/phpunit, scope: dev, compatibility: auto }]
    executable: ["vendor/bin/phpunit"]
    alternatives: [pest]
    report: reports/raw/tests.json
```

Equivalent JSON (what actually ships in the manifest's `tools` object):

```json
{
  "phpstan": {
    "policy": "required",
    "category": "static-analysis",
    "packages": [
      { "name": "phpstan/phpstan", "scope": "dev", "compatibility": "auto" },
      { "name": "larastan/larastan", "scope": "dev", "compatibility": "auto" }
    ],
    "executable": ["vendor/bin/phpstan", "phpstan"],
    "runner": "scripts/runners/laravel-phpstan.sh",
    "report": "reports/raw/phpstan.json",
    "missing_behavior": "fail",
    "execution": { "pr": true, "main": true, "scheduled": false },
    "config": { "path": "phpstan.neon", "classification": "never-touch" }
  },
  "tests": {
    "policy": "one-of",
    "category": "tests",
    "alternatives": ["pest", "phpunit"],
    "report": "reports/raw/tests.json",
    "execution": { "pr": true, "main": true, "scheduled": false }
  }
}
```

How it gates:

- PHPStan binary absent ⇒ `phpstan` is `unavailable` ⇒ **config failure** (required).
- `phpstan.neon` missing ⇒ `not-configured` ⇒ **config failure** (required).
- PHPStan runs, 3 errors ⇒ `findings` (count 3) ⇒ **gate failure** (required).
- PHPStan runs, 0 errors ⇒ `pass`.
- Neither Pest nor PHPUnit present ⇒ the `tests` group is `unavailable` ⇒ gate per
  the group policy. If `pest` is present and passes, the group passes even though
  `phpunit` is `not-applicable`.

### Project override

`.sentinel-shield/tool-policy.yaml` may only tune the **policy** of a declared tool:

```yaml
tools:
  scorecard: { policy: optional }     # downgrade a noisy recommended check
  # gitleaks: { policy: disabled }    # REJECTED: secrets scanners (gitleaks,
                                       # trufflehog) are non-suppressible — the
                                       # resolver fails closed (exit 2)
  # phpstan:  { policy: disabled }    # allowed only if not non-suppressible;
                                       # cannot turn an execution-error into pass
```

The resolver applies precedence
`required > one-of > recommended > optional > external > disabled`, refuses to set a
non-suppressible control (`gitleaks`, `trufflehog`) to `disabled` (fail-closed,
exit 2), and refuses to convert `execution-error` to `pass`.

### Disabling a required control (control-waiver, not `disabled_tools`)

`tool-policy.yaml` cannot silence a **required** control by flipping it to
`disabled`: a required tool recorded as disabled in `installation.json`
(`disabled_tools`) still surfaces as `status: disabled` and **fails the gate**
unless covered by an unexpired **control-waiver**. A control-waiver lives in
`.sentinel-shield/control-waivers.json` ([schema](../schemas/control-waiver.schema.json)),
is owner-bound, justified, dated, expiring, and issue-linked, and is consumed by
`enforce-gates.sh`. It only downgrades a required-tool failure
(`unavailable`/`not-configured`/`disabled`) to a **prominently-reported, time-boxed
waiver** — it does **not** suppress findings (use accepted-risks for finding gates)
and is never auto-applied. Non-suppressible secrets scanners cannot be waived this
way.

## 5. Control-waivers (`.sentinel-shield/control-waivers.json`)

A control-waiver lets a **required** tool/control be temporarily absent without
the gate failing — it never suppresses *findings* from a tool that ran (use
accepted-risks for findings). Validated by the one shared library
`scripts/lib/control-waivers.sh`, which every consumer (doctor, maturity, gate,
bootstrap, resolver) calls — the SAME file gets the SAME verdict everywhere, and
that verdict does **not** depend on `jq` being on `PATH` (absent → success;
present-but-jq-missing → fail closed; malformed → fail closed).

```json
{ "version": "1",
  "waivers": [
    { "tool": "larastan", "owner": "alice", "approved_by": "bob",
      "justification": "extension upgrade in flight", "created_at": "2026-08-09",
      "expires_at": "2026-09-08", "tracking_issue": "SEC-123" } ] }
```

Rules (fail closed on any violation):

- `version` **must** be the string `"1"` (unsupported/missing/numeric ⇒ rejected).
- `tool` must match `^[A-Za-z0-9_.-]+$` — a single shell-safe token, so a value can
  never split into multiple waived controls; whitespace/tabs/slashes/`..`/metachars
  are rejected.
- `owner` ≠ `approved_by` (no self-approval — enforced in the validator, not just schema).
- `created_at`/`expires_at` are real calendar dates (`YYYY-MM-DD`), validated with
  POSIX `/bin/sh` arithmetic (portable to `dash`; leading-zero months like `08`/`09`
  are handled). `created_at <= expires_at`.
- A waiver **applies** only while `expires_at >= today` in **UTC** (a waiver expiring
  today is valid through the end of that UTC day); expired waivers validate but do not
  downgrade the control.
