# Fail-Closed Evidence and Gate Integrity (v2.0.2 security hotfix)

> **Version note.** The remediation plan called this `v2.0.1`, but that tag is already
> published (2026-07-09, engine-only maintenance). This hotfix is therefore **v2.0.2**. The
> branch keeps its original name; the released version is what matters. `v2.0.0` and `v2.0.1`
> remain immutable.

## The invariant

```txt
Absent, malformed, partial, skipped, unrecognized, negative or non-integer evidence
must fail closed.
```

"The scanner did not run" and "the scanner output could not be parsed" must never read as
"we are clean". This document records where that invariant was broken, what now enforces it,
and — stated plainly — what is still open.

Everything here is proven by `tests/prod/266-fail-closed-evidence-integrity.sh`. Each check in
that suite fails against the pre-hotfix code; 28 of them did when it was written.

## What was broken

### 1. An empty `reports/raw/` passed `regulated`

The most serious defect, and the one that invalidated the product claim: the engine's
highest-assurance mode certified a run in which **no scanner executed at all**.

`build-security-summary.sh` invokes every collector even when its raw report is absent.
`ss_collector_guard` returns `status=unavailable` together with a **fully zeroed summary**, and
the merge sums those zeros. The result is a document that is indistinguishable, to every
downstream gate, from a clean scan. Nothing consulted `.tools[].status` unless the builder had
been run with `--profile`.

Reproduction (pre-fix): empty `reports/raw/`, a stub SBOM and release-evidence file, then
`resolve-gates --mode regulated` + `enforce-gates` → **exit 0, Result: PASS**.

**Now:** in `strict`/`regulated`, `enforce-gates.sh` refuses a summary whose `.tools` is
populated but in which **not one** entry carries an evidence-bearing status
(`pass`/`findings`/`fail`/`warn`). The error is `NO_EVIDENCE_FOR_STRICT` /
`NO_EVIDENCE_FOR_REGULATED` and it exits 2.

The trigger is deliberately narrow — see [Residual gaps](#residual-gaps).

### 2. Unrecognized scanner output became zero findings

`gitleaks.sh` ended its extraction with `else 0 end`; `trivy.sh` and `semgrep.sh` relied on
jq's `?` operator, which swallows type errors. A valid-JSON document whose top-level key had
been renamed upstream therefore produced `status=pass` with zero findings — a scanner version
bump could silently erase every finding.

**Now:** `ss_shape_or_fail` (in `scripts/lib/sentinel-shield-common.sh`) fails closed with
`execution-error` for any report whose shape the collector does not recognize. Applied to
`gitleaks`, `trivy`, `semgrep`, `npm-audit`, `grype`, `osv-scanner`, `composer-audit`,
`codeql`, `dependency-check` and `tests`.

`{}` is not a test report, and it is not a gitleaks report either — the empty object no longer
reads as a clean run anywhere.

### 3. Negative and non-integer counts

Counts were passed through unvalidated and the builder **sums** them across collectors, so a
report carrying `critical: -99` cancelled another scanner's real findings. Verified pre-fix: a
genuine Trivy report with 2 CRITICAL plus a crafted npm-audit report merged to
`critical_vulnerabilities: -97`; exact cancellation to `0` yields a full PASS.

Separately, `enforce-gates.sh` coerced **every** malformed value to a clean `0`
(`case "$_val" in '' | *[!0-9]*) _val=0`), so `3.5`, `-5` and `"not-a-number"` all evaluated
as `pass`.

**Now:** `ss_counts_or_fail` rejects negative, fractional and non-numeric counts at the
collector; `eval_count_gate` treats a malformed count as a configuration error. An **absent**
optional key still reads as `0` — that back-compat promise for older summaries is kept and
tested.

### 4. Gate flags failed open

`gate_flag` compared the raw environment value against the literal string `"true"`. So
`FAIL_ON_SECRETS=TRUE` — a canonical spelling everywhere else in the engine — **silently
disabled** the gate, with no warning. An absent flag also disabled its gate, meaning a
truncated or tampered `gates.env` switched gates off rather than failing.

**Now:** both are configuration errors. Parsing goes through `bool_value()`, the engine-wide
parser, which accepts `true/false`, `TRUE/FALSE`, `yes/no`, `1/0`, `on/off` and rejects
anything else.

### 5. The architecture runner executed scanned-repo shell strings

`runners/architecture-tests.sh` read `architecture.tools.architecture_tests.command` from the
**scanned project's** `architecture-policy.yaml` and passed it to `sh -c`. That is arbitrary
code execution in the gate runner, available to anyone who can open a pull request. Verified
with `command: "id > /tmp/proof; true"`.

Note the asymmetry this removes: the `--env-var` *name* was already validated against eval
injection; the command *value* went straight to a shell.

**Now:** a command whose source is the scanned project is **refused** unless the operator
passes `--allow-project-command`. Operator-supplied commands (`--command`,
`$SENTINEL_SHIELD_ARCH_TEST_CMD`) are unchanged — whoever wrote the CI workflow already
controls the runner. The refusal is recorded as `execution-error` with reason
`unsupported_project_command`.

A full allowlisted command-ID registry, as the remediation plan describes, is the durable fix;
this hotfix closes the execution path without waiting for that design.

### 6. An exit code was treated as architecture evidence

The same runner synthesised `{status:"pass", violations:0}` whenever the command exited 0
without emitting JSON. So `command: "true"` manufactured a clean architecture report that
satisfied **both** `architecture_violations` and `missing_architecture_evidence`.

**Now:** no JSON contract means `execution-error`. "It exited 0" and "it checked the
architecture and found nothing wrong" are different claims; only the second is evidence.

### 7. One-of groups were satisfied by file presence

A required one-of group (e.g. `php-tests`) counted as satisfied whenever its report existed and
was valid JSON. `printf '{}' > reports/raw/tests.json` therefore certified that a project's
tests passed without a single test having run.

**Now:** the group's **collector result** is the authority — it must have produced a real
evidence status. A failing suite still satisfies the group, because the suite *ran*; that is a
different fact from "no tests exist", and `test_failures` is the gate that judges it.

The collector is resolved by the report **filename** via `TOOL_TABLE`, not by the group key,
because group keys are abstract (`php-tests`) while the collector registers against
`tests.json`.

### 8. Collector-reported expired exceptions were discarded

`build-security-summary.sh` assembled `expired_exceptions: $ee` from `reports/exceptions.json`
**alone**, overwriting anything a collector had reported. The internal consistency check then
asserted `summary.expired_exceptions == exceptions.expired` — an assertion that could only hold
*because* the collector value was being thrown away.

**Now:** the two sources are added, and the self-check asserts `>=`.

### 9. JSON persisted secrets unredacted

The generic catch-all rule's value class was `[^[:space:]\"']+` — it **excludes the
double-quote character**, and in JSON the byte after `": "` *is* a quote. So the one rule meant
to catch unknown-shape secrets could never match JSON, which is the format
`security-summary.json`, `reports/raw/*` and the event journal are all persisted in.
`{"GITHUB_TOKEN": "…"}` passed through untouched. (Tokens with a recognizable prefix such as
`ghp_` *were* caught by their own specific rule — the gap was narrower than "redaction is
off", and is described accurately here.)

**Now:** three JSON key/value rules cover `"KEY": "value"`, `"prefix_KEY": "value"` and
camelCase `"apiKey": "value"`.

They deliberately require a **word boundary**, because over-redaction corrupts real evidence
and that is its own integrity failure: `{"monkey": "banana"}`, `{"keyboard_layout": "qwerty"}`
and `{"tokenizer": "bpe"}` must survive untouched. Both directions are tested.

The rules also skip values that already begin with `*`, so the structural stage cannot
overwrite the more specific placeholder the literal-registry stage just wrote.

## Residual gaps

Stated plainly rather than papered over. None of these is closed by this hotfix.

| Gap | Why it is still open |
| --- | --- |
| A hand-written summary with `"tools": {}` still passes strict/regulated | The evidence guard triggers only when `.tools` is populated *and* uniformly non-evidence. Refusing an empty `.tools` outright would break summaries produced by external pipelines, which is a documented capability. Closing this needs an evidence-completeness policy, not a one-line check. |
| Required tools with **no collector** are accepted unverified | `larastan`, `pint`, `php-cs-fixer`, `phpstan-symfony` and `syft` are `required` in shipped profiles but have no collector, so their reports cannot be verified and are read as a clean pass. The real remedy is to **write the collectors**; making it fail closed without them turns every profile that requires those tools red. Tracked for Wave 2. |
| Collector **severity mappings** remain wrong | `php-style`/`php-syntax` count scanned files rather than violations; `osv-scanner` collapses all severities into `high`; `codeql` can never emit a critical; `eslint` folds lint warnings into `medium_vulnerabilities`; `semgrep` maps INFO to a blocking severity; `composer-audit` yields 0 when advisories carry no severity; `trufflehog` drops unverified secrets. These produce **wrong verdicts today** and are the subject of the next PR. |
| `trivy` ignores `Misconfigurations[]` and `Secrets[]` | Only `Vulnerabilities[]` is read. Wave 2. |
| No baseline / "new findings" comparison exists | Several docs promise that `baseline` mode tolerates pre-existing findings. No such mechanism is implemented; the gates block on absolute counts. The docs are wrong and are corrected separately. |

## Modes

`report-only` and `baseline` are deliberately **unchanged**. They are visibility and migration
modes and have never claimed evidence completeness; tightening them would be a breaking change
rather than a security fix. The evidence-integrity precondition applies to `strict` and
`regulated` only.

## Related

- `tests/prod/266-fail-closed-evidence-integrity.sh` — the executable form of this document
- [`raw-report-contract.md`](raw-report-contract.md) — per-collector report contracts
- [`gate-resolution.md`](gate-resolution.md) — mode defaults
- [`severity-policy.md`](severity-policy.md) — severity mapping (Wave 2 corrections pending)
