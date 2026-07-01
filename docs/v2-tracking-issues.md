# v2 Tracking Issues (Prepared Bodies)

This document contains prepared GitHub issue bodies for 12 v2 tracking items.

> **Status:** These are prepared bodies only. As of this writing, the repository
> has **no GitHub issues filed** for these items. Paste each block into a new
> issue when filing.

Several items are already substantially addressed by the current v2 work; where
that is the case, current status is noted honestly along with any residual
follow-up. Items 9 and 10 (Laravel/Symfony consumer validation) are explicitly
**deferred** — not required for the engine-only release, but required before a
framework-validated release can be claimed. They are not won't-fix.

---

## 1. v2 documentation and version reconciliation

**Labels:** `documentation`, `v2`, `release`

**Context:**
v2 documentation and version references must be reconciled with reality. No `v2`
tag is published (highest published tag is `v1.9.2`); `v2.0.0-alpha.1` is a
candidate, not a published release. Docs must not imply a shipped v2.

**Acceptance criteria:**
- [ ] All docs distinguish "candidate" from "published" for v2 artifacts.
- [ ] Version references agree with the actual tag state (`v1.9.2` highest published).
- [ ] Release-scope wording (engine-only vs framework-validated vs full-platform) is consistent across docs.

**Current status:** Largely addressed — see `docs/v2-merge-commit-ci-evidence.md`
and the evidence files under `evidence/releases/`. Residual follow-up: keep
version wording in sync as candidates progress.

---

## 2. CI timeout and concurrency hardening

**Labels:** `ci`, `hardening`, `v2`

**Context:**
CI workflows need explicit timeouts and concurrency controls to prevent hung or
overlapping runs.

**Acceptance criteria:**
- [ ] Workflow-level timeouts are enforced and tested.
- [ ] Concurrency groups prevent redundant overlapping runs.
- [ ] Coverage exists in the deterministic test suite.

**Current status:** Largely addressed — see `tests/prod/110-workflows.sh` and
`tests/prod/111-workflow-timeouts.sh`. Residual follow-up: extend coverage as
new workflows are added.

---

## 3. engine-only release-scope policy

**Labels:** `policy`, `release`, `v2`

**Context:**
The release-scope model has three levels: engine-only (this cycle),
framework-validated, and full-platform. Under engine-only, Laravel/Symfony
real-consumer runs are deferred and not required, `required_evidence` flags stay
false, and the release cannot claim framework-validated status.

**Acceptance criteria:**
- [ ] Release-scope levels are documented and machine-checkable.
- [ ] Under engine-only, `required_evidence` flags remain false and no framework-validated claim is emitted.
- [ ] Scope is recorded in the release evidence artifacts.

**Current status:** Largely addressed — see the release evidence under
`evidence/releases/` (`v2.0.0-alpha.1.json`, `v2.0.0-beta.1.json`) and
`scripts/validate-release-evidence.sh`. Residual follow-up: promote scope when
framework validation lands.

---

## 4. Composer rollback evidence

**Labels:** `testing`, `rollback`, `php`, `v2`

**Context:**
Composer-managed projects must roll back byte-for-byte after an aborted or
reverted operation.

**Acceptance criteria:**
- [ ] Composer rollback is verified byte-for-byte.
- [ ] Failure paths restore original state deterministically.

**Current status:** Largely addressed — see `tests/prod/60-rollback.sh`
(Composer/npm/pnpm/Yarn byte-for-byte rollback) with fixtures under
`tests/fixtures/projects`. Residual follow-up: none beyond regression upkeep.

---

## 5. npm/pnpm/Yarn rollback matrix

**Labels:** `testing`, `rollback`, `node`, `v2`

**Context:**
Node package managers (npm, pnpm, Yarn) must each roll back byte-for-byte.

**Acceptance criteria:**
- [ ] npm, pnpm, and Yarn are each covered in the rollback matrix.
- [ ] Each restores original lockfile/state byte-for-byte.

**Current status:** Largely addressed — see `tests/prod/60-rollback.sh` and the
`node-react` fixture under `tests/fixtures/projects`. Residual follow-up: none
beyond regression upkeep.

---

## 6. PHP-library validation

**Labels:** `testing`, `php`, `v2`

**Context:**
The PHP-library profile must be validated against a representative fixture.

**Acceptance criteria:**
- [ ] PHP-library profile passes engine and fixture tests.
- [ ] Command contract (docs↔CLI) holds for PHP-library flows.

**Current status:** Fixture-tested — see the `php-library` fixture under
`tests/fixtures/projects` and `tests/e2e`, plus
`tests/prod/80-command-contract.sh`. Residual follow-up: keep fixture current
with profile changes.

---

## 7. Node/React validation

**Labels:** `testing`, `node`, `v2`

**Context:**
The Node/React profile must be validated against a representative fixture.

**Acceptance criteria:**
- [ ] Node/React profile passes engine and fixture tests.
- [ ] Command contract (docs↔CLI) holds for Node/React flows.

**Current status:** Fixture-tested — see the `node-react` fixture under
`tests/fixtures/projects` and `tests/e2e`. Residual follow-up: keep fixture
current with profile changes.

---

## 8. migration and update evidence

**Labels:** `testing`, `migration`, `v2`

**Context:**
v1→v2 migration/update flows must produce recoverable, evidenced outcomes.

**Acceptance criteria:**
- [ ] v1→v2 migrate recovery is deterministically tested.
- [ ] Release evidence captures migration/update outcomes.
- [ ] Planner output for upgrades is validated.

**Current status:** Largely addressed — see `tests/prod/121-recovery.sh`
(v1→v2 migrate recovery), `tests/prod/120-installer-tx.sh`,
`tests/prod/140-planner.sh` (plan-upgrade), and
`tests/prod/90-evidence.sh` / `tests/prod/91-evidence.sh`. Residual follow-up:
none beyond regression upkeep.

---

## 9. deferred Laravel consumer validation

**Labels:** `validation`, `laravel`, `deferred`, `v2`

**Status flags:** **deferred** · **not required for engine-only release** ·
**required for framework-validated release**

**Context:**
Laravel is currently profile-supported, engine-tested, and fixture-tested (see
the `laravel-react-docker` fixture under `tests/fixtures/projects` and
`tests/e2e`), but **not independently live-validated in a real consumer
repository**. Under the engine-only scope this validation is deferred and
`required_evidence` stays false; the release cannot claim framework-validated
status until this lands.

**Acceptance criteria:**
- [ ] A real (non-fixture) Laravel consumer repository runs the full flow.
- [ ] Live consumer evidence is captured and stored as release evidence.
- [ ] `required_evidence` for Laravel is satisfied, enabling a framework-validated claim.

**Note:** This is deferred, not won't-fix. It remains open work required for a
framework-validated release.

---

## 10. deferred Symfony consumer validation

**Labels:** `validation`, `symfony`, `deferred`, `v2`

**Status flags:** **deferred** · **not required for engine-only release** ·
**required for framework-validated release**

**Context:**
Symfony is currently profile-supported, engine-tested, and fixture-tested (see
the `symfony` fixture under `tests/fixtures/projects` and `tests/e2e`), but
**not independently live-validated in a real consumer repository**. Under the
engine-only scope this validation is deferred and `required_evidence` stays
false; the release cannot claim framework-validated status until this lands.

**Acceptance criteria:**
- [ ] A real (non-fixture) Symfony consumer repository runs the full flow.
- [ ] Live consumer evidence is captured and stored as release evidence.
- [ ] `required_evidence` for Symfony is satisfied, enabling a framework-validated claim.

**Note:** This is deferred, not won't-fix. It remains open work required for a
framework-validated release.

---

## 11. external adopter usability validation

**Labels:** `validation`, `usability`, `v2`

**Context:**
Beyond automated tests, an external adopter should be able to install and
operate the engine using only the published documentation, to surface usability
gaps not caught by fixtures.

**Acceptance criteria:**
- [ ] An external adopter completes install and a core flow using docs only.
- [ ] Usability friction and doc gaps are recorded and triaged.

**Current status:** Open. Not covered by the deterministic fixture suite.

---

## 12. v2 beta/RC release checklist

**Labels:** `release`, `checklist`, `v2`

**Context:**
A repeatable checklist should gate promotion of v2 candidates (beta/RC),
including release-scope declaration, CI evidence, and evidence verification.

**Acceptance criteria:**
- [ ] Checklist enumerates required CI evidence and scope declaration.
- [ ] `sh scripts/validate-release-evidence.sh --verify-github` is a required gate.
- [ ] Framework-validated claims are blocked until items 9 and 10 are satisfied.

**Current status:** Largely addressed — see `docs/v2-merge-commit-ci-evidence.md`,
the evidence files under `evidence/releases/`, and
`scripts/validate-release-evidence.sh`. Residual follow-up: finalize the
promotion checklist and wire the framework-validated gate to items 9 and 10.
