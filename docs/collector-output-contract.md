# Collector output contract (#145)

Every collector emits its evidence through `ss_emit_collector` in
[`scripts/lib/sentinel-shield-common.sh`](../scripts/lib/sentinel-shield-common.sh). That
function is the single trust boundary between "a script parsed a scanner report" and "this is
a Sentinel Shield evidence document", so the whole shape is judged there, once, for built-in
and custom collectors alike.

Validating downstream instead is too late. `build-security-summary.sh` **sums** collector counts
across producers before any schema runs, and several tools read a collector's stdout directly.

```
ss_emit_collector <tool> <status> <tool_report_json> <summary_overrides_json>
```

## 1. The outer status vocabulary

`<status>` must be one of, verbatim:

`pass` · `fail` · `warn` · `skipped` · `unavailable` · `findings` · `not-configured` ·
`not-applicable` · `execution-error` · `disabled`

This is `properties.tools.additionalProperties.properties.status.enum` in
[`schemas/security-summary.schema.json`](../schemas/security-summary.schema.json), mirrored in
the library as `SS_COLLECTOR_STATUSES`. A status outside the set makes the finished summary
schema-invalid, so it is refused where it is produced rather than where it is finally parsed.
The match is exact: not case-insensitive, not a prefix, not a substring.

## 2. Outer and tool-report status agree — the mapping is identity

When `<tool_report_json>` is an object carrying a **string** `status`, it must be the *same
string* as the outer status. A tool report with no `status` makes no claim and is left alone; a
non-string `status` is malformed and refused.

The finer-grained detail belongs in `tool_report.health` or `tool_report.reason`, which exist
precisely so `status` never has to disagree in order to say more:

```jq
{status: "execution-error", health: "invalid-output", reason: $r}
```

Four collectors (grype, osv-scanner, trivy, syft) previously emitted
`tool_report.status = "invalid-output"` beside an outer `execution-error` — a value that is not
in the vocabulary *and* disagreed with the status shipped alongside it. They now state
`execution-error` in both places and keep `invalid-output` in `health`.

## 3. Summary overrides: an object, canonical keys only

`<summary_overrides_json>` must be a JSON **object**. Every key must be a member of
`SS_SUMMARY_KEYS`, which is exactly
`properties.summary.properties` in the schema (which declares `additionalProperties: false`).

An unknown key is **refused**, never dropped. Silently discarding it is how #327 shipped:
`diff_coverage_violations` was merged for `changed_lines_coverage_violations`, inventing a
summary field no gate reads while the real gating key kept its zeroed default.

## 4. Summary values: bounded, typed, never coerced

The issue's acceptance criterion reads "every summary value is a bounded non-negative integer."
Taken literally that is **not satisfiable against the canonical vocabulary**, which has 50 count
fields, 9 booleans, 7 percentages and 2 numeric metrics. Forcing a boolean or a fractional
percentage into an integer would refuse valid evidence — 87.5% line coverage,
`missing_sbom: true`. This section is the authoritative interpretation of that criterion, and it
is what the code enforces:

| Class | Count | Rule |
|---|---|---|
| **count** | 50 | exact JSON integers, `0 <= v <= 2147483647` (`SS_MAX_COUNT`) |
| **percentage** (`SS_SUMMARY_RATIO_KEYS`) | 7 | finite JSON numbers, `0 <= v <= 100`; **fractional values are valid** |
| **metric** (`SS_SUMMARY_METRIC_KEYS`) | 2 | finite, non-negative JSON numbers, `0 <= v <= 2147483647`; **fractional values are valid** |
| **boolean** (`SS_SUMMARY_BOOL_KEYS`) | 9 | JSON `true` or `false` only |

In every class: **no strings, no `null`, no arrays, no objects, no NaN-like spellings, and no
coercion, rounding, clamping or flooring.** A value outside its class is a refusal, not a
correction — reading untrusted evidence as a clean `0` is the failure this exists to prevent.

The count class is judged by `ss_count_valid`, the shared #146 validator, against
`SS_MAX_COUNT`. There is exactly one numeric policy in the engine and this boundary consumes it
rather than restating it.

### The two metric keys and their ceiling

`complexity_max` and `complexity_average` are the only summary numbers that are neither counts
nor percentages: the worst-observed and the mean cyclomatic/cognitive complexity, produced by
`scripts/collectors/complexity.sh` and consumed as `QUALITY_INFO_KEYS` in `enforce-gates.sh`
(reported, never gated) and by `build-security-summary.sh`, which aggregates them with `max`
across stacks.

Both are bounded at **`SS_MAX_COUNT` = 2147483647**. That is not a constant invented for them:

- `build-security-summary.sh` **already** refuses any summary number above `SS_MAX_COUNT` at the
  aggregation boundary, on these two keys included. The schema was the half that was out of
  step, declaring them unbounded while enforcement bounded them.
- Their sibling worst-observed metrics — `max_file_lines`, `max_function_lines`,
  `architecture_context_count`, aggregated by the same `max` rule — already carry it.
- The quality policy's `max_cyclomatic_complexity` is a **threshold**, not a ceiling: an observed
  maximum is *meant* to exceed it, which is what produces a violation. It is therefore not usable
  as a representational bound and is not used as one.

The summary declares exactly two numeric ceilings — `100` for percentages and `SS_MAX_COUNT` for
everything else — and `tests/prod/312` fails if a third appears.

A double carries 53 mantissa bits and the ceiling needs 31, so every value in the declared domain
is exact to several decimal places; `2147483646.5` and `0.125` round-trip through the emitter
unchanged. `NaN` and `Infinity` are not JSON, but `jq` accepts both and types them as numbers —
they are refused by the range test (`NaN >= 0` is false, `Infinity` exceeds the ceiling), not by
the parser, and `1e30`, `1e400` and `1e999` are refused the same way.

**Refusal is atomic.** One invalid sibling refuses the whole override object. A caller cannot
tell which of its fields survived a partial merge, so it would otherwise publish a summary built
half from its own evidence and half from zeroed defaults.

A duplicate JSON key resolves last-wins in `jq`, so the **last** value is the one judged.

## 5. A clean `pass` cannot carry a positive gating count

`SS_GATING_SUMMARY_KEYS` is every count gate `enforce-gates.sh` evaluates —
`INT_SUMMARY_KEYS`, `THIRD_PARTY_KEYS`, `ENTERPRISE_COUNT_KEYS`, `QUALITY_COUNT_KEYS`,
`TESTING_DISCIPLINE_COUNT_KEYS` — minus the census carve-out below. A collector emitting `pass`
while one of them is above zero is emitting evidence that contradicts itself: the per-tool status
says the tool is clean while the counts it shipped are summed into the aggregate the gates read.

Only `pass` is constrained. `warn`, `findings` and `fail` are already claims that something was
found, and the non-run statuses (`unavailable`, `execution-error`, `disabled`,
`not-applicable`, `not-configured`, `skipped`) carry the zeroed defaults their emit paths supply.

### The non-gating carve-out

`SS_NONGATING_COUNT_KEYS` is exactly one key: **`skipped_tests`**. It is a *census*, not a
verdict — the number of tests a runner skipped, while the suite that ran still passed. Whether
skipping is tolerable is a policy decision `enforce-gates.sh` makes per mode, not a finding the
collector declared. `scripts/collectors/tests.sh` emits it beside `pass` in ordinary, correct
operation.

The carve-out is **per key, never per tool**. A channel is non-gating for every collector or for
none; a per-tool exception would weaken the invariant wherever it was granted.

Informational metrics (`test_count`, `architecture_rule_count`, `dead_code_count`,
`max_file_lines`, the coverage percentages, …) are not gates at all and are unaffected.

## 6. Failing closed publishes nothing

Validation completes *before* the first byte of the object is produced, so a refusal leaves a
zero-byte stdout — never a partial document a consumer could read.

`ss_emit_collector` **exits** 2 on refusal rather than returning. Its own callers in this library
(`ss_shape_or_fail`, `ss_counts_or_fail`, `td_bad_count`, `arch_passthrough_status`) emit and then
`exit 0` unconditionally, so a returned refusal became a collector that exited 0 having printed
nothing — and `build-security-summary.sh` dropped it from the aggregate in silence, because its
guard used `jq -c`, which exits 0 on empty input. That guard is now `jq -ce`.

Callers that need the status run the emitter inside a command substitution, where `exit` ends the
subshell and surfaces as exit status 2.

## 7. Diagnostics

A refusal logs which invariant failed and names the offending status, key or value, passed
through `ss_redact` — control characters dropped, 60 characters kept — because a collector's
status and count values are attacker-influenced input being written to a log.

## Recorded interpretation of acceptance criterion 3 (#145)

Issue #145 states: *"Every summary value is a bounded non-negative integer."*

That wording is **not literally satisfiable** against the canonical summary vocabulary, which the
schema declares as 50 counts, 9 booleans, 7 percentages and 2 numeric metrics. Enforcing it
literally would refuse valid evidence produced by shipped collectors.

The criterion is therefore implemented under the interpretation in section 4, restated here so
closure evidence carries it rather than a claim of literal satisfaction:

- **count fields** — exact integers, `0..SS_MAX_COUNT`;
- **percentages** — finite JSON numbers, `0..100`;
- **other numeric metrics** — finite, non-negative JSON numbers with an explicit documented upper
  bound, which is `SS_MAX_COUNT`;
- **booleans** — JSON `true` or `false` only;
- **in all classes** — no strings, nulls, arrays, objects or NaN-like spellings, and no coercion,
  rounding, clamping or flooring.

Every value is bounded and non-negative, which is the criterion's intent; not every value is an
integer, because the vocabulary the criterion governs is not all integers. The per-key authority
is `schemas/security-summary.schema.json`; this document is the class contract the emitter
enforces, and `tests/prod/312-collector-contract.sh` reconciles the two mechanically.

## Adding a summary key

Add it to the schema **and** to `SS_SUMMARY_KEYS`; if it is a boolean, ratio or metric, add it to
the matching class list; if `enforce-gates.sh` gates on it, add it to `SS_GATING_SUMMARY_KEYS`.
[`tests/prod/312-collector-contract.sh`](../tests/prod/312-collector-contract.sh) reconciles every
one of those lists against the schema and the enforcer, so a half-finished addition fails CI
rather than opening a hole.
