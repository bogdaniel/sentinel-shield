# Operations runbook — production health & operational observability

Sentinel Shield ships two production observability surfaces, both **read-only**,
both **offline by default**, and both engineered to leak **no secret and no
repo-local absolute path**:

1. **`scripts/health.sh`** — a single operational-health command that returns a
   rolled-up verdict (`healthy | degraded | unhealthy | unknown`) plus a
   per-check breakdown with **stable reason codes**, as a machine-readable
   report on `stdout` and a human summary on `stderr`.
2. **Opt-in JSONL operational events** (`scripts/lib/operational-events.sh`) — a
   normalized, correlated event stream every long-running or mutating operation
   can emit so an operator (or a collector) can reconstruct exactly what
   happened across an operation **and its recovery**.

Both are additive. Neither mutates the target, runs scanners, or touches the
network unless you explicitly ask.

---

## 1. Health command — `scripts/health.sh`

```
sh scripts/health.sh [--target <dir>] [--check-network] \
                     [--format json|text] [--report <path>] [--quiet]
```

`stdout` carries the health report (`schemas/health-report.schema.json`);
`stderr` carries a readable summary. The **process exit code encodes the
verdict**:

| Exit | Verdict     | Meaning |
| ---- | ----------- | ------- |
| `0`  | `healthy`   | every check healthy or not-applicable |
| `1`  | `degraded`  | at least one degraded condition; usable but review it |
| `2`  | `unhealthy` | at least one unhealthy condition; needs intervention |
| `3`  | `unknown`   | at least one check was indeterminate (and nothing worse) |
| `64` | usage       | invalid invocation (distinct from any health verdict) |

Rollup precedence is **`unhealthy` > `degraded` > `unknown` > `healthy`** — a
concrete actionable signal always outranks an indeterminate one.

### Checks and reason codes

Every check reports one of `healthy | degraded | unhealthy | unknown | skipped`
(a `skipped` check is not-applicable/not-configured/not-requested and never
contributes to the rollup) plus a stable reason code:

| Check | Healthy | Degraded | Unhealthy | Unknown |
| --- | --- | --- | --- | --- |
| `metadata_consistency` | `metadata_ok` | — | `metadata_missing`, `metadata_invalid` | — |
| `operation_state` | `operation_clean` | `operation_in_progress`, `operation_completed_unreleased` | `operation_stale`, `operation_incomplete`, `operation_lock_torn` | `operation_state_unknown` |
| `journal_integrity` | `journal_ok`, `journal_absent` | — | `journal_tampered` | `journal_unverifiable` |
| `tool_availability` | `tools_ok` | — | `required_tool_missing` | — |
| `scanner_health` | `scanner_ok` (or `scanner_not_configured`) | `scanner_db_stale`, `scanner_provenance_invalid` | — | — |
| `report_freshness` | `report_fresh` (or `report_not_configured`) | `report_stale` | — | — |
| `ref_immutability` | `ref_immutable` (or `ref_absent`) | `ref_moving` | — | `ref_unknown` |
| `source_verification` | `source_verified` (or `source_not_configured`) | — | `source_ref_mismatch` | `source_unverifiable` |
| `managed_file_drift` | `managed_clean` | `managed_file_drift`, `managed_manifest_invalid` | — | — |
| `package_manager_state` | `package_manager_ok` (or `..._not_configured`) | `package_manager_unsupported`, `package_manager_ambiguous` | — | — |
| `disk_space` | `disk_ok` | — | `disk_space_low` | `disk_space_unknown` |
| `write_permissions` | `write_ok` | — | `write_permission_denied` | — |
| `time_sync` | `time_ok` (or `time_unknown`) | `time_skew_future` | — | — |
| `github_connectivity` | `network_ok` (or `network_not_requested`) | — | `network_unreachable`, `network_timeout` | `network_probe_invalid` |

The report's top-level `reason_codes[]` is the de-duplicated set of the
**actionable** (degraded/unhealthy/unknown) reason codes, in evaluation order —
empty when the target is healthy.

### Offline vs. network

- **By default the command is fully OFFLINE.** No check touches the network; the
  `github_connectivity` check reports `network_not_requested` / `skipped`, and
  `mode.offline` is `true`.
- Pass **`--check-network`** to probe required GitHub reachability. The probe is
  the **only** network operation and is **bounded** (via the Task 1
  bounded-process primitive): a probe that outlives its timeout reports the
  **distinct** `network_timeout` reason code, never a generic failure.

### Inputs it reads (all under `<target>/.sentinel-shield/`)

| File | Drives |
| --- | --- |
| `installation.json` | `metadata_consistency`, `managed_file_drift`, `time_sync` |
| `operation-lock.json`, `operation-lock.d/` | `operation_state`, `time_sync` |
| `transaction-journal.jsonl` | `journal_integrity` (via the Task 2 verifier) |
| `scanner-provenance.json` (`.vulnerability_db.built_epoch`) | `scanner_health` |
| `reports/` | `report_freshness` |
| `source.json` (`.ref`, `.pinned_commit`, `.resolved_commit`) | `ref_immutability`, `source_verification` |
| `managed-manifest.json` (`{rel: sha256}`) | `managed_file_drift` |
| `package-manager.json` (`.status`) | `package_manager_state` |

### Tuning (environment overrides)

| Variable | Default | Effect |
| --- | --- | --- |
| `SENTINEL_SHIELD_HEALTH_DISK_MIN_KB` | `51200` | minimum free KB before `disk_space_low` |
| `SENTINEL_SHIELD_HEALTH_SCANNER_MAX_AGE_DAYS` | `14` | scanner-db staleness window |
| `SENTINEL_SHIELD_HEALTH_REPORT_MAX_AGE_DAYS` | `7` | report-freshness window |
| `SENTINEL_SHIELD_HEALTH_REQUIRED_TOOLS` | `jq git` | required tools to check |
| `SENTINEL_SHIELD_HEALTH_NET_TIMEOUT` | `15` | bounded connectivity-probe timeout (s) |
| `SENTINEL_SHIELD_HEALTH_GITHUB_URL` | a github.com ref-listing URL | probe target |
| `SENTINEL_SHIELD_HEALTH_NET_PROBE` | `git ls-remote …` | override the probe command |

### Redaction

The report never contains a raw path or a secret. The target is identified by a
**non-reversible** `target:<12-hex>` sha256 prefix, and every check `detail`
string is passed through the unified redaction library (Task 4).

---

## 2. Opt-in JSONL operational events

`scripts/lib/operational-events.sh` defines one normalized event object
(`schemas/operational-event.schema.json`) that any operation can emit — a
**correlated** stream you can group by incident and split by operation.

### Turning it on

Emission is **off by default**. It happens only when BOTH are set:

```
export SENTINEL_SHIELD_EVENTS=1
export SENTINEL_SHIELD_EVENTS_FILE=/path/to/events.jsonl   # appended, never truncated
```

When either is unset, every emit is a zero-cost no-op — commands behave exactly
as before. Like the transaction journal, emission is a best-effort **audit
trail**: a failed write degrades to a visible warning and never aborts the host
operation. An event that violates the closed vocabulary, by contrast, is
**refused** (fail closed) rather than written malformed.

### The event object

Each line carries: `schema` + `schema_version`, `ts`, `command`, `phase`,
`event_type`, `severity`, a stable `reason_code`, `status`, `component`,
`retryability`, a `correlation_id`, an `operation_id`, a redacted `target`
identity, a best-effort `elapsed_ms` (monotonic where available), and an
optional redacted `next_action`.

Covered `command` values: `acquisition`, `install`, `sync`, `migration`,
`bootstrap`, `doctor`, `pipeline`, `recovery`, `security-scan`,
`evidence-collection`, `artifact-verification`, `release-finalization`,
`health`, `engine`.

### Correlation across an operation and its recovery

Set `SENTINEL_SHIELD_CORRELATION_ID` before invoking an operation and the
operation **and any recovery it triggers** share one correlation id, while each
still gets a distinct `operation_id`. This is what lets you reconstruct a failed
install and its rollback as a single incident:

```
export SENTINEL_SHIELD_EVENTS=1 SENTINEL_SHIELD_EVENTS_FILE=/tmp/ev.jsonl
export SENTINEL_SHIELD_CORRELATION_ID="incident-$(date +%s)"
sh scripts/install-baseline.sh --target ./app        # (may fail)
sh scripts/recover-operation.sh --target ./app --resume-rollback
jq -c 'select(.correlation_id==env.SENTINEL_SHIELD_CORRELATION_ID)' /tmp/ev.jsonl
```

### Wired commands

`scripts/health.sh`, `scripts/doctor.sh`, and `scripts/recover-operation.sh`
emit a `start` event and a fail-safe terminal event whose status is derived from
the real exit code (the terminal emitter runs in an EXIT trap that captures and
re-returns `$?`, so it can never perturb a command's exit contract). The other
listed operations can adopt the same guarded pattern; the event model and the
opt-in gate are identical for all of them.

### Validating a stream

```
# structural, jq-based (no ajv): validate every line
sh -c '. scripts/lib/sentinel-shield-common.sh
       . scripts/lib/redaction.sh
       . scripts/lib/operational-events.sh
       oe_validate_file /tmp/ev.jsonl'
```

---

## 3. Suggested cadence

- **Pre-deploy / CI gate:** `sh scripts/health.sh --target . --format json` and
  fail the step on exit `≥ 1` (or only `≥ 2` if you tolerate degraded).
- **Scheduled ops probe:** `sh scripts/health.sh --check-network` on a timer;
  alert on `unhealthy`, ticket on `degraded`.
- **Incident forensics:** enable the JSONL event stream with a per-incident
  `SENTINEL_SHIELD_CORRELATION_ID`, then group the stream by correlation.
