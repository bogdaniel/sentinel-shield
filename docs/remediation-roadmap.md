# Remediation roadmap

**Current baseline:** `master` = `6380e3b2ff8d01d6f421397fd84dc6bee7a2795c` · 13 blocking workflows expected on `push` (12 + `ci-backlog-reconciliation`) · **176 open issues** = **161 findings + 15 epics** (14 created to organise the backlog, plus #38, an audit-era tracker repurposed as the M5 epic rather than closed and re-filed).

**Original audit baseline:** `8f146d11`, 158 findings, all open.

**Full acceptance evidence recorded for:** #310, #284, #285, #306, #326, #151, #259, #260, #264, #182 — see the closure comment on each.

**Open or reopened from findings surfaced BY the work:** #315, #316, #317, #318, #320, #323, #324, #344, #345, #348, #350. The count going up is the programme working: each is a defect the remediation exposed, not one it created.

**Partially landed, still open:** #345 is `status:partial` — ten harness-truthfulness detectors shipped, three of seven acceptance criteria satisfied and four bounded. Its remaining gaps are named in the issue and in `tests/prod/306`, and closing them is a design decision (parser-backed shell analysis versus a canonical harness syntax policy), not an outstanding patch. #204 is `status:partial` on the same basis. Neither is described here as implemented.

### #310 — closed six times; only the sixth rests on production-path evidence

The transitions, in order:

| # | how it closed | why it was wrong |
| --- | --- | --- |
| 1 | deliberate | rested on a criterion that was **false** — the enforcement gate could never fire |
| 2 | deliberate | criterion 5 audited **as a whole** rather than case by case, missing "non-zero exit with no report" |
| 3 | **accidental** | #330's body used the phrase *"I clos&#8203;ed #310 twice"*; GitHub reads that keyword-plus-reference as a directive regardless of the surrounding prose |
| 4 | **accidental** | #333, a PR **describing** trap 3, repeated the keyword and closed the issue again |
| 5 | **accidental** | #343, the PR restoring the issue as open work, wrote a hyphenated form of the keyword before the reference in its Rollback section — GitHub matched it **inside the hyphenated word** |

It is now **CLOSED, `status:verified`**, on the sixth closure and the first that rests on production-path evidence.

Closures 3, 4 and 5 were all the prose trap, and each taught a narrower rule than the last: the keyword need not be a standalone word, and a PR *describing* the trap is not exempt from it. Publication now runs a mechanical scan of the diff, commit messages, PR body and branch name for a closing keyword before an issue reference, including hyphenated and embedded forms. It refused a draft of #346's body for exactly that reason.

Closures 1 and 2 were audit failures. So was the state after them: the issue was **verified as unmet again** after closure 4, because AC6 failed on the production path — `--tool-name` set both the presentation channel and the verified provenance identity, so `osv-scanner` and `dependency-check` rejected their own observed execution records while every test passed. The producer/channel identity split repaired it, and the six-criterion audit was redone through `build-security-summary.sh` on merged master.

**What closure 4 missed — the production path failed AC6.** `build-security-summary.sh` invokes collectors with the emitted channel name, and the collectors let `--tool-name` overwrite the identity they hand to `ne_execution_verify`:

```
audits/osv-scanner.sh   ->  record producer.tool = "osv-scanner"
builder                 ->  --tool-name osv_scanner
ne_execution_verify     ->  execution-error: names tool 'osv-scanner', not 'osv_scanner'
```

Two of the four migrated collectors — `osv-scanner` and `dependency-check`, the two whose channel names change from hyphens to underscores — reject their own real execution records in production. `grype` and `codeql` do not, which is why nothing surfaced it. It is fail-CLOSED (a required scanner can fail its gate) rather than a false-clean bypass, but AC6 is not met.

**Why every audit missed it, including the item-by-item one:** every probe, and `tests/prod/117` itself, invokes the collector *directly*, where the canonical `TOOL` is retained and the record is accepted. The component was tested in the one invocation mode where the defect disappears.

The ledger ([comment 5244140836](https://github.com/bogdaniel/sentinel-shield/issues/310#issuecomment-5244140836)) remains accurate about the collector contract; it is the *integration* that was never audited.

**Criteria 4 and 6 were not met at either deliberate closure.** 4 was a gate that could never fire — `(.observed // true) == false` is unsatisfiable — repaired in #328. 6 had no regression at all, because `tests/prod/117` drove grype alone; repaired in #331.

The issue was **not** reopened in order to be re-closed. Doing so would replace a true record — *closed accidentally, subsequently ratified* — with a false one implying a deliberate closing act that never happened.

Two rules came out of this, and both are worth more than the issue itself:

- An issue reference in prose must never be preceded by close/closed/closes/fix/fixed/fixes/resolve/resolved/resolves — **including in a PR that is explaining the trap.**
- A criterion that demands a test is not satisfied by reasoning about the behaviour. Traps 1 and 2 were the same substitution, made twice.
- **A collector-level acceptance test is insufficient when production wraps that collector with identity-changing arguments.** Acceptance must exercise the highest shipped orchestration layer that materially transforms the contract. This is what the fifth reopening cost, and it is the most transferable lesson of the three.

**Machine-readable source of truth:** [`config/remediation-plan.json`](../config/remediation-plan.json).
**Validated by:** `tests/prod/112-remediation-plan.sh`.
**Rendered by:** `scripts/backlog-report.sh`.

This document explains *why* the waves are ordered the way they are. It is prose about a data file — if the two disagree, the data file wins and this document is wrong.

---

## Status of the product

Sentinel Shield is **not fully remediated and not fully production-ready.**

The v2 stack audit (#143 → #278, 14 PRs, 32 verified issue closures) proved something narrower than it is often read as proving: **CI green is meaningful for the tests that are implemented.** It did not prove that every filed issue was fixed. **161 findings remain open, 129 of them P0.** Eleven have been opened from findings surfaced *by* remediation work (#315–#318, #320, #323, #324, #344, #345, #348, #350). The newest, #350, is the backlog itself: 54 M4 records where the plan says `ready` and the label says `blocked`, surfaced the moment reconciliation began comparing semantics instead of membership. Which side is authoritative is undecided, and the more serious possibility is that the plan's `blocked_by` is incomplete — that would invalidate the wave ordering these milestones are derived from. The three before it are self-directed: #348 records an e2e harness that returned different verdicts for identical inputs, #344 records that the merge oracle has no durable finalize or re-attestation path, and #345 collects a family of five defects in this repository's own test harness — suites that reported failures while exiting zero, assertions that could never fail, and tests that exercised an invocation path production never uses. **The count rising is the programme working, not regressing** — each is a defect the work exposed, and three of them (#320 `jq //`, #323 locale-collated ranges, #324 `set -e` unsafe capture) form one family: shell/jq idioms that are correct in most uses, silently wrong in a specific class, and invisible to review. They argue for one bounded static-analysis pass rather than repeated rediscovery.

No framework-validated or full-platform production-readiness claim may be made until M5 closes on its own evidence.

---

## The waves

| Milestone | Epic | Issues | P0 | Theme |
| --- | --- | --- | --- | --- |
| M0 — CI Enablement | #286 | **0** | 0 | ✅ **COMPLETE** — #284, #285 and #306 all closed on full acceptance evidence |
| M1 — Evidence Trust Foundation | #287 | 20 | 14 | #182 **done**; #310 **done** — the producer/channel identity split landed and all six criteria were audited through the builder on merged master; **#204 partial** — all six producers emit the envelope, but that is structural compliance only; C1 + C2 outstanding |
| M2 — Mutation and Transaction Safety | #288 | 30 | 30 | Do not damage consumer repositories — #151 **done**; #152 **partial** (transport-race coverage outstanding) |
| M3 — Policy and Resolution Engine | #289 | 23 | 16 | Parser parity **done**; #248 **partial** (schema landed, AC2 outstanding); #251 **partial** (engine word-splitting removed, test harnesses remain) |
| M4 — Producer Chain Correctness | #290 (+#291–#299) | 83 | 63 | Per-producer correctness — **61 ready**, 32 still blocked on #204. The scanner evidence transaction batch (#96–#105, #135–#137, #184, #185) is **implemented and audited at 98/98 acceptance criteria**, awaiting merge — see [`m4-acceptance-audit.md`](m4-acceptance-audit.md) |
| M5 — Documentation and External Validation | #38 | 4 | 0 | Say what it does; prove it against real consumers |

---

## Why this order

### M0 first, because everything after it is measured by CI

Two issues, and neither is a product fix:

- **#284 — DONE** (PR #301). `ci-self-test` and `ci-production-readiness` both executed the ~40-minute production suite. That is duplicate execution, not independent validation: same implementation, same oracle, so a defect in the suite is missed twice at double the cost. Removing the duplication removes an *accidental* coverage guarantee, so coverage is now an asserted static property — `ci-core ∪ production-readiness = all`, `ci-core ∩ production-readiness = ∅` — proven by `tests/prod/113-suite-topology.sh`. Measured on the `full-self-test` job: **28m 47s → 9m 59s**. The 90/75 timeout floors stay until three exact-head `ci-core` samples exist; one so far.
- **#285 — DONE** (PR #303). The merge-evidence oracle. Every remaining wave is validated by CI, so what counts as "green" had to be settled first. It merged its own pull request: 11 expected workflows, 11 captured, all attempt 1 on the frozen head — while that head carried 22 runs in total, 11 of them stale. The proof manifest is committed at `evidence/merge-oracle/pr-303.json`.

#285 exists because the stack collapse surfaced seven defects in how merge evidence was read. The through-line is that **every field reachable as "evidence" turned out to be a live view rather than a record.** Only run ID and `created_at` never moved. Most dangerous was `run.pull_requests[].base.sha`: it is rewritten retroactively on old runs, so runs from the previous day — never re-executed — began reporting the *new* base. Any guard resting on it would have accepted runs that tested a superseded tree.

An **eighth** defect was found later, by the oracle refusing #327 (PR #332). The always-expected set — `pull_request:` with no `paths:` filter — was also the only *permitted* set, so a path-filtered workflow that legitimately fired was reported `unexpected:` and the round spun to its timeout. #327 touches `scripts/lib/sentinel-shield-common.sh`, a declared path trigger for `security-incident-validation`, so a correct blocking run blocked the round that should have counted it. The fix is asymmetric: such a workflow **may be absent**, but once captured it is recorded in the manifest and held to the same completed/success/attempt-1 standard as a required one. Permitting is not ignoring — #327 then merged on a **12-run** verdict, not eleven.

Doing M0 last would mean re-validating five waves of work with an oracle that can launder stale runs as current.

### M1 before M4, because 83 producer fixes share about nine contracts

This is the single most important sequencing decision in the programme, and the plan data makes the case numerically:

| Blocker | Blocks | What it is |
| --- | --- | --- |
| ~~#182~~ ✓ | ~~65~~ | trusted producer identity — **DONE**, PR #309. M4 ready work went from **10 to 61** the moment it landed |
| **#204** | **16** | trusted completed-producer envelopes for engineering-quality evidence — **the last blocker on 32 M4 issues**. It must EXTEND the #182/#310 envelope, not introduce a second one. PRs A (#321) and B (#327) have landed: all six producers emit the shared envelope — **structural** compliance. C1 and C2 are the **semantic** half, and #204 requires both |
| #146 | 8 | bounded safe-integer limits for all collector counts |
| #147 | 5 | atomic, symlink-safe publication primitive |

#### What #204's remaining half actually is

The residual has been described as the collectors "promoting unobserved execution to `completed: true`". That wording is wrong in a way that matters, and it is corrected here rather than quietly reworded. **The normalized envelope truthfully records `observed: false`, `completed: null`, `status: "unobserved"`.** Verified on `57962e8d`. The evidence record has integrity.

The defect is downstream of it. Each of the six quality collectors carries:

```sh
[ "$NE_COMPLETED" = "unobserved" ] && NE_COMPLETED=true
```

immediately before calling `ne_status_consistency`, whose contract states *completion first: nothing is clean over a producer that did not finish*. So:

```
truthful evidence            observed=false, completed=null
        ↓
collector-local conversion   completed=true          ← the fiction enters here
        ↓
consistency matrix           valid-clean
        ↓
emitted status               pass
        ↓
emitted envelope             observed=false, completed=null   (still truthful)
```

This is a **decision-input integrity** defect, not an evidence-record integrity defect. A producer that never ran can reach `pass`, while the envelope beside that verdict honestly says nobody watched it run.

The split follows from that:

- **C1** — the live false-clean route. `ne_status_consistency` stops taking a boolean and takes an explicit execution state (`observed-complete` / `observed-incomplete` / `unobserved`), so no caller can convert unobserved into complete. An unobserved zero-result report must never be `valid-clean`; an unobserved report *with* findings may surface them as a lower-bound signal without representing the scan as complete. No guesses about tool exit semantics are required, which is why it goes first.
- **C2** — observation itself. All six runners currently discard the exit status (`|| true`; `php-coverage.sh` captures it and only logs it). The record must preserve the **raw** observation — exit code, signal, timeout, duration — while a **producer-specific contract** decides whether that invocation completed a meaningful analysis. `exit_code != 0` does not mean "did not complete": PHPMD documents non-zero as the normal findings case, Infection is run with `--min-msi=0` precisely so Sentinel and not Infection's process exit decides the threshold, and PHP coverage keeps the test runner's exit code separately while still accepting a finalized Clover report. Mapping non-zero to "failed" would turn valid findings evidence into `execution-error`, and the tempting repair would be to loosen the collector.

Three facts that this codebase has historically conflated, and which C1/C2 separate:

```
process success  ≠  producer completion  ≠  policy pass
```

#182 alone gated 65 of the 83 M4 issues — **and closing it moved M4 from 10 ready to 61 ready in one step**, which is the sequencing argument settled by measurement rather than assertion. Repairing collectors first means writing 65 producer-identity checks that each have to be revisited when the real contract lands — and, in the interim, ten subtly different implementations of the same trust boundary, which is how the current state was reached.

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
yaml-parser-parity (#259, #260, #264)   ✓ DONE — PR #305, master 23129f56
        ↓
profile-schema (#248 PARTIAL, #251) ──→ profile-provenance (#252, #255)
        ↓
profile-inheritance (#249, #250) · applicability (#253) · one-of-graph (#254)
        ↓
plan-resolution (#234, #239, #265)

override-engine (#258 → #256, #257, #266)      [independent chain]
fail-closed-resolution (#261, #262, #263)      [independent]
executable-resolution (#240)                   [independent]
```

Parser parity comes first because schema validation performed by an untrusted parser validates nothing. **That foundation now exists**: one tokenizing frontend for the policy/profile surface, `yq` never consulted for meaning, duplicate detection at tokenization. #248 is unblocked and is the next M3 lane. Note the scope boundary — three other policy families (`architecture-policy`, `quality-policy`, `testing-discipline-policy`) still parse with `yq` and retain last-wins duplicate semantics; that divergence class is **not** eliminated repository-wide. #258 (eliminate the conflicting override engines) precedes #256/#257/#266 for the same reason: hardening two engines that disagree hardens neither.

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

### Backlog agreement is semantic, not membership

`ci-backlog-reconciliation` ran green for months while the plan and the live backlog disagreed, because its live half compared **membership only** — every open issue appears in the plan, no closed issue is listed as active work. It never compared a status label against the plan's `status`, so #345 could be `status:partial` live and `ready` in the plan with nothing to notice.

`config/backlog-semantics.json` is now the single declared mapping — which label prefixes are normative, which plan key each maps to, and what every `status:*` label means. `tests/prod/112` reads only that file; no label-to-plan translation lives in a shell conditional. Agreement on `status`, `priority`, `type`, `primary_domain` and `milestone` is asserted for every planned open issue.

Fifty-four M4 records disagree in one direction — the plan says `ready`, the label says `blocked` — and which side is authoritative is a release-owner decision, tracked in #350. They are carried as an enumerated `reconciliation_debt` list, keyed by `(issue, field)`, that can only shrink.

An entry is an exception with an expiry, not an allowlist line. Each names its expected plan value, its observed live value, a reason belonging to a declared class, an owner, a remediation, a creation date, a dated review boundary and a source reference — and it **fails** when the live value changes, the plan value changes, the mismatch disappears, the issue closes, the issue leaves the plan, the field stops being normative, a required field is absent, or the review boundary passes. A class whose last entry goes is removed with it, because a category with no members is a slot for the next thing that wants excusing.

That mechanism has been exercised for real, not only by fixture. Three entries recorded that #344, #345 and #348 carried no live milestone while the plan assigned them M1. Once the milestones were assigned, reconciliation **refused to pass** — naming each issue, the field, the value the entry had recorded, the value now observed, the value the plan expects, and why the exception was obsolete — until the three entries were deleted. Discharged debt cannot be left lying around.

### Assertion syntax in the evidence-critical harness

Two detector gaps in `tests/prod/306` — a both-branches-`pass` conditional written on one line, and an unsafe diagnostic hidden behind an earlier quoted expression — share one cause: the detectors must interpret arbitrary shell. Two line-oriented AWK extensions were attempted and reverted. Each flagged eight real suites; classification found **zero** genuine defects among them. Do not attempt a third.

`config/harness-assertion-policy.json` takes the other route: remove the ambiguous syntax from the assertion surface so the properties need no parser. In a **registered** suite every verdict comes from a helper in `tests/lib/assert.sh`, so no conditional can reach a verdict and the single-line form becomes unwritable; and no helper line may carry a command substitution, so no argument boundary must be resolved. Embedded `awk`/`jq` is excluded structurally — a line is assertion logic only if it begins with a helper name — which is why nothing in the policy tracks quote state.

The policy is enforced by `tests/prod/307` over the registered set only. **153 of 3,247 static verdict sites are canonical — about 4.71%.** The policy is not repository-wide. `tests/prod/306` is excluded by design, because its subject *is* bare `pass`/`fail` text; `304` and `117` are named as pending with their residual gaps. For the 95 unregistered suites the legacy detectors and their documented bypasses stand unchanged, and both bypass fixtures are retained for that reason.

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
