# Remediation roadmap

**Current baseline:** `master` = `e49b9064d4e988e9797a905100a9c26d1a7e1b7a` · 12 blocking workflows expected on `push` · **171 open issues** = **156 remaining audit findings + 15 epics** (14 created to organise the backlog, plus #38, an audit-era tracker repurposed as the M5 epic rather than closed and re-filed).

**Original audit baseline:** `8f146d11`, 158 findings, all open. **#284 is the only one closed so far** (PR #301, 2026-08-06) — see the acceptance-evidence comment on the issue.

**Machine-readable source of truth:** [`config/remediation-plan.json`](../config/remediation-plan.json).
**Validated by:** `tests/prod/112-remediation-plan.sh`.
**Rendered by:** `scripts/backlog-report.sh`.

This document explains *why* the waves are ordered the way they are. It is prose about a data file — if the two disagree, the data file wins and this document is wrong.

---

## Status of the product

Sentinel Shield is **not fully remediated and not fully production-ready.**

The v2 stack audit (#143 → #278, 14 PRs, 32 verified issue closures) proved something narrower than it is often read as proving: **CI green is meaningful for the tests that are implemented.** It did not prove that every filed issue was fixed. **156 audit findings remain open, 129 of them P0.**

No framework-validated or full-platform production-readiness claim may be made until M5 closes on its own evidence.

---

## The waves

| Milestone | Epic | Issues | P0 | Theme |
| --- | --- | --- | --- | --- |
| M0 — CI Enablement | #286 | 1 (of 2) | 1 | Make validation cheap and merge evidence reproducible — #284 done, #285 next |
| M1 — Evidence Trust Foundation | #287 | 15 | 15 | The shared trust primitives everything else consumes |
| M2 — Mutation and Transaction Safety | #288 | 31 | 31 | Do not damage consumer repositories |
| M3 — Policy and Resolution Engine | #289 | 22 | 19 | Resolve the plan before acting on it |
| M4 — Producer Chain Correctness | #290 (+#291–#299) | 83 | 65 | Per-producer correctness, on the M1/M3 foundations |
| M5 — Documentation and External Validation | #38 | 4 | 0 | Say what it does; prove it against real consumers |

---

## Why this order

### M0 first, because everything after it is measured by CI

Two issues, and neither is a product fix:

- **#284 — DONE** (PR #301). `ci-self-test` and `ci-production-readiness` both executed the ~40-minute production suite. That is duplicate execution, not independent validation: same implementation, same oracle, so a defect in the suite is missed twice at double the cost. Removing the duplication removes an *accidental* coverage guarantee, so coverage is now an asserted static property — `ci-core ∪ production-readiness = all`, `ci-core ∩ production-readiness = ∅` — proven by `tests/prod/113-suite-topology.sh`. Measured on the `full-self-test` job: **28m 47s → 9m 59s**. The 90/75 timeout floors stay until three exact-head `ci-core` samples exist; one so far.
- **#285** — the merge-evidence oracle. Every remaining wave will be validated by CI, so what counts as "green" has to be settled first.

#285 exists because the stack collapse surfaced seven defects in how merge evidence was read. The through-line is that **every field reachable as "evidence" turned out to be a live view rather than a record.** Only run ID and `created_at` never moved. Most dangerous was `run.pull_requests[].base.sha`: it is rewritten retroactively on old runs, so runs from the previous day — never re-executed — began reporting the *new* base. Any guard resting on it would have accepted runs that tested a superseded tree.

Doing M0 last would mean re-validating five waves of work with an oracle that can launder stale runs as current.

### M1 before M4, because 83 producer fixes share about nine contracts

This is the single most important sequencing decision in the programme, and the plan data makes the case numerically:

| Blocker | Blocks | What it is |
| --- | --- | --- |
| **#182** | **65** | trusted producer identity for pre-normalized collector count objects |
| **#204** | **16** | trusted completed-producer envelopes for engineering-quality evidence |
| #146 | 8 | bounded safe-integer limits for all collector counts |
| #147 | 5 | atomic, symlink-safe publication primitive |

#182 alone gates 65 of the 83 M4 issues. Repairing collectors first means writing 65 producer-identity checks that each have to be revisited when the real contract lands — and, in the interim, ten subtly different implementations of the same trust boundary, which is how the current state was reached.

The shared-primitive rule applies concretely here. Before implementing similar fixes, they belong in one primitive: JSON parsing and duplicate-key detection, numeric validation, safe atomic publication, path containment, producer-envelope validation, status vocabulary, provenance and digest binding, profile schema validation, YAML normalisation, executable resolution, and transaction/journal handling.

Three visible instances of one root cause, not many bugs:

- **Placeholder credit** — #135, #141, #190, #192, #195, #206, #207, #209, #210. Empty objects and count-only shapes receiving evidence credit. One validator, nine call sites.
- **Atomic publication** — #147 is the primitive; #110, #129, #159, #163 are consumers. Do not hand-roll a second atomic writer in M2.
- **Zero-step Cucumber** — #95 (runner) and #125 (acceptance conversion) are the same rule in two code paths. Land them together against one shared validator or they will diverge again.

### M2 is P0 throughout, even where no false green is possible

M2 (#151–#181) covers source acquisition, installation, transactions, journals, durability, sync, migration and recovery. Much of it cannot produce a wrong verdict at all. It is still P0, because the failure mode is **damage to a consumer repository** rather than a wrong answer: overwriting unowned files, a torn journal, a partially applied migration, a validation-to-`rm` race.

M2 runs largely parallel to M1 and M3. Its only inbound dependency is #147 → #159, #163.

Throughout, treat shell word splitting, globbing, symlinks, stale files, partial writes, parser divergence and mutable API fields as **hostile conditions**, not edge cases.

### M3 before M4, because aggregation currently runs ahead of resolution

#234 — *filter summary aggregation by the resolved selected/applicable producer plan* — is the shape of the whole milestone. Today, aggregation happens before the applicable producer plan is resolved, structured JSON is flattened into shell-delimited strings, and two override engines disagree about semantics.

Fixing per-producer correctness while the wrong producer set is being aggregated validates M4 against a producer set that is not the one enforcement uses.

Internal order within M3:

```
yaml-parser-parity (#259, #260, #264)
        ↓
profile-schema (#248, #251) ──→ profile-provenance (#252, #255)
        ↓
profile-inheritance (#249, #250) · applicability (#253) · one-of-graph (#254)
        ↓
plan-resolution (#234, #239, #265)

override-engine (#258 → #256, #257, #266)      [independent chain]
fail-closed-resolution (#261, #262, #263)      [independent]
executable-resolution (#240)                   [independent]
```

Parser parity comes first because schema validation performed by an untrusted parser validates nothing. #258 (eliminate the conflicting override engines) precedes #256/#257/#266 for the same reason: hardening two engines that disagree hardens neither.

### M4 grouped by contract and channel, not one PR per issue

83 issues across nine sub-epics (#291–#299): test and acceptance adapters; test and coverage evidence; testing discipline and TDD evidence; scanner execution wrappers; dependency and vulnerability collectors; secrets/SAST/CI collectors; Docker, IaC and architecture evidence; engineering-quality and linter evidence; summary selection and aggregation.

Each PR takes one contract across its call sites — roughly 2–6 closely related issue closures.

### M5 last, because validating a consumer against a broken producer chain produces a misleading pass

README rewrite (#272), Laravel (#19) and Symfony (#20) live-consumer validation, independent adopter usability (#21).

An adopter usability test run today would exercise a chain that still grants placeholder evidence credit. The result would be a pass that means nothing, and it would be cited later as evidence.

#38 was the post-v2.0.0 planning tracker. Its first two sections completed long ago; the live remainder is exactly M5, so it was **repurposed rather than closed and re-filed** — the stale sections are retained in it as history.

---

## Execution rules

### PR sizing

The previous 14-PR deeply stacked chain cost 13 base transitions and surfaced seven oracle defects. Not repeating it:

- Independent PRs based on current `master`.
- One cohesive contract or vertical slice per PR.
- ~2–6 closely related issue closures per PR.
- **At most two dependent PRs open simultaneously.**
- Minimal overlap between active branches.
- Stack only when the child genuinely cannot compile or test without the parent — and then document the lineage and re-establish exact-head/base evidence as the stack collapses, using the #285 oracle once it exists.

### Closure evidence

An issue closes only when every acceptance criterion is demonstrably satisfied **on current code**. For each closure, record:

```
issue
→ acceptance criterion
→ implementation file/function
→ regression test
→ implementing commit/PR
→ exact-head CI result
→ residual limitation
```

Passing CI alone is insufficient. A PR description claiming a fix is insufficient. Code presence without a negative regression is insufficient.

Partial implementation uses `Refs #N`, never `Closes #N`; comment on the issue with completed and remaining criteria; leave it open.

**Acceptance criteria are never edited to make an implementation qualify as complete.**

### Regressions

For every repaired failure mode: a negative fixture reproducing the old defect, proof it fails before the fix where practical, proof the fixed implementation rejects it, a valid control case, and cross-platform/shell/backend parity tests where applicable.

The test must fail closed if aborted early — a cleanup command in an `EXIT` trap must never turn an aborted suite into a success.

### CI authority

Never call a PR green on a head-only run query, `gh pr checks`, a rerun, a run whose identity was rediscovered after the trigger, mutable `baseRefOid`, mutable `run.pull_requests[].base.sha`, success on a previous base, or a cancelled or skipped workflow.

A **cancelled** workflow is a terminal non-verdict — not success, and not necessarily a product failure. A timeout kill is reported by GitHub as cancelled, which is why an under-budgeted job looked for days like concurrency cancellation.

For normal independent PRs, exact-head completed successful CI remains authoritative. For stacked or serial-base-sensitive PRs, follow the trigger-bound contract in #285.

### Repository hygiene

Work from freshly fetched `master`; keep the tree clean before and after. Do not combine unrelated cleanup, dependency upgrades, documentation rewrites and security fixes in one PR. Do not rewrite historical tags or releases. Do not weaken a gate, schema, test or fail-closed behaviour to make CI pass — fix bad fixtures instead of weakening correct production checks. Preserve POSIX `sh` compatibility where currently required. Never create fabricated producer evidence or placeholder reports to satisfy tests.

---

## Release implications

| Claim | Unlocked by |
| --- | --- |
| Cheaper, reproducible validation | M0 |
| Evidence that cannot be laundered by a placeholder or a stale report | M1 + M4 |
| Safe to install, sync and migrate against a real consumer repository | M2 |
| Enforcement acts on the profile the operator actually configured | M3 |
| Documentation that matches shipped behaviour | M5 (#272) |
| **Framework-validated release** | M5 (#19 + #20) |
| **Full-platform production-ready** | all of the above, plus #21 |

Until then the accurate description is: *an engine with verified CI for its implemented tests, and a known, organised, machine-validated backlog of 158 outstanding audit findings.*

---

## Working with the plan

```sh
scripts/backlog-report.sh          # milestone / priority / status / domain rollup + top blockers
scripts/backlog-report.sh ready    # what is actionable right now
scripts/backlog-report.sh json     # raw plan for other tooling
sh tests/prod/112-remediation-plan.sh   # validate structure + reconcile against live GitHub
```

The validator asserts that every open issue appears exactly once, that no closed issue is listed as active work, that every referenced issue exists, that milestone/domain/priority/status/type/evidence values are in vocabulary, that `blocks` is exactly the inverse of `blocked_by`, that the dependency graph is acyclic, and that no issue is marked ready while it declares a blocker. It also self-checks its own cycle detector against a known 2-node cycle, because a guard that has never rejected anything is indistinguishable from one that always passes.
