# beta.2 Integration — Conflict-Resolution Log

Branch: `macro-beta2/integration` · Base: `master` · Range: `master..HEAD` (21 commits)
Head at time of writing: `439f8a59bf1d743ed8501a803dc121b9e71a76a6`

This log records every merge/integration decision made while assembling the beta.2
release candidate: the two-stack merge, the one regression caught by macro-regression
and its fix, and the consumer-validation schema unification performed before integration.

---

## 1. Two-stack merge (Stack 1 + Stack 2) — clean

The 21 commits were assembled as two independent stacks landed onto the integration
branch, then reconciled:

- **Stack 1 — `e8f419d` `integrate: Stack 1 — consumers + installer + adopter/output (waves A, D-05)`**
  Waves A (php-library + node/react real-consumer harnesses, installer hardening) and
  D-05 (adopter/output). Underlying feature commits: `f2cdc3d`, `25499e5`, `3d4e1f9`,
  `d196f4b`, `d67f950`, `813ffd8`, `3f8eff8`, `dfcecda`, `ea8d048`, `8f4df63`.
- **Stack 2 — `076680f` `integrate: Stack 2 — CI/scanners/governance + release evidence (waves B, C)`**
  Waves B (CI workflow-runtime audit, scanner version bumps + provenance/health gate,
  required-checks/merge-safety governance) and C (engine_ci collection, artifact
  download/verification, reproducible release manifest, two-commit finalization).
  Underlying feature commits: `e4b2956`, `a6c2c62`, `15ce9d2`, `7d67319`, `63ee2e7`,
  `415e5ad`, `c5e0f83`.

### Overlap analysis

The two stacks touched **disjoint** subsystems, so the merge was clean:

| Subsystem | Stack 1 | Stack 2 |
|---|---|---|
| `scripts/lib/transaction.sh`, `source-verification.sh`, `recover-operation.sh` | ✔ | |
| `scripts/lib/output-contract.sh`, `report-consumer-validation.sh`, `package-manager-resolver.sh` | ✔ | |
| consumer harnesses + fixtures (`tests/consumers/**`, `tests/prod/200/201`) | ✔ | |
| `scripts/collectors/*`, `scripts/audits/*`, release tooling (`collect/verify/finalize/generate-release-*`) | | ✔ |
| governance/release schemas, `.github/workflows/ci-security.yml`, `ci-workflow-lint.yml` | | ✔ |

### `scripts/lib/sentinel-shield-common.sh` — non-overlapping shared edits

The one file with a plausible collision risk was the shared `common.sh` helper library.
Stack 1 kept its new shared logic in **new files** (`scripts/lib/transaction.sh`,
`output-contract.sh`, `source-verification.sh`, `package-manager-resolver.sh`) rather than
editing `common.sh`, avoiding contention entirely. Stack 2 appended provenance/collector
helpers to `common.sh` across two commits (`a6c2c62`, `7d67319`) as **pure additions**
(`+60/-0` over the range — zero deleted lines, so no existing line range was rewritten).
Because the only writer to `common.sh` was Stack 2 and its edits are append-only, the merge
had **no overlapping hunks** and required no manual resolution. Verified: no conflict
markers anywhere in the range —

```sh
git diff master..HEAD | grep -nE '^(<<<<<<<|=======|>>>>>>>)'   # → (no output)
```

Result: **clean merge, zero manual conflict resolution required** on the shared library.

---

## 2. Regression caught by macro-regression, and its fix — `d214c8a`

`fix(security): restore fail-closed exit 2 on unparseable scanner output`

**What broke.** Wave B's grype/osv collector health rework (part of `a6c2c62`) introduced
a `health=parser-error` state but returned **exit 0** when scanner output was unparseable.
That silently violated the historical **fail-closed** contract (self-test
`v023-regression`: invalid JSON → exit 2): a corrupted/garbage scanner report would have
been treated as a clean result.

**How it was caught.** The macro-regression sweep (`self-test all`) flagged the exit-code
regression in the collectors — the report body was correct (`health=parser-error`) but the
process exit code no longer signalled failure.

**The fix (`d214c8a`, 3 files, +10/-3).**
- `scripts/collectors/grype.sh` — on unparseable input, still emit the
  `execution-error/parser-error` report, then `exit 2` (was `exit 0`).
- `scripts/collectors/osv-scanner.sh` — identical fail-closed restore.
- `tests/prod/221-scanner-provenance-health.sh` — assert the exit-code contract directly:
  `parser-error → exit 2`, all other health states → `exit 0`, and the report is still
  produced. This locks the contract so the regression cannot silently return.

```diff
-	exit 0
+	# fail-closed: unparseable scanner output is an error, not a clean result
+	exit 2
```

**Verification.** `tests/prod/221` and `self-test all` are green post-fix. This is the one
regression introduced during integration; it is fixed and guarded by an explicit
exit-code assertion.

---

## 3. Consumer-validation schema unification (pre-integration) — `813ffd8` + `3f8eff8`

Waves A shipped two independently-authored consumer harnesses (php-library from agent 03,
node/react from agent 04) that each defined their **own divergent** "shared" consumer
validation schema + reporter. Left as-is they would collide on the same canonical
filenames with incompatible shapes.

Resolution, done **before** the stacks were integrated:

1. **`813ffd8` `merge(wave-a): node/react consumer harness (agent 04); namespace divergent
   shared schema/reporter as node-consumer-*`** — the node/react variant's shared schema and
   reporter were **namespaced** to `node-consumer-*` to break the filename collision, so both
   harnesses could coexist while the reconciliation was designed.
2. **`3f8eff8` `refactor(consumer): unify divergent consumer-validation schema+reporter into
   one canonical per-check contract`** (6 files, +241/-588 — a net **deletion**) — the two
   divergent schemas/reporters were collapsed into a single canonical **per-check contract**:
   `schemas/consumer-validation.schema.json` + `scripts/report-consumer-validation.sh`. Both
   the php-library and node/react harnesses now emit the one contract; the namespaced
   `node-consumer-*` duplicates were removed.

Result: a single source of truth for consumer-validation evidence, exercised by
`tests/prod/200-php-consumer.sh` and `tests/prod/201-node-consumers.sh`.

---

## Net integration state

- Clean two-stack merge; disjoint subsystems; `common.sh` additions non-overlapping.
- One regression (grype/osv fail-closed exit-2) caught by macro-regression and fixed in `d214c8a`.
- Consumer-validation schema unified to one canonical per-check contract pre-integration.
- Post-integration: `self-test all` PASS, production-readiness 33/33, shellcheck (`-S error`)
  + actionlint clean. See `integration/release-candidate-report.md` for the captured evidence.
