# Maturity & Doc-Consistency Audit (v0.1.24)

> **What this is.** An AUDIT REPORT produced by Lane M (tasks 241–260) for the v0.1.24 sprint.
> It records findings only — the release captain applies fixes (to avoid merge conflicts, this
> lane edits no other doc). Every finding cites `file:line` with the current text and a
> recommended fix. "No contradictions found" is reported as a validated negative where true.
>
> **Sources of truth used.** `docs/product-status.md` (maturity), `docs/main-gate-live-evidence.md`
> (live evidence). All maturity statements below are checked against those two.
>
> **Method.** `grep -n` across `docs/*.md`, `README.md`, `CHANGELOG.md`, `RELEASE-GATES.md`,
> `SECURITY-STANDARD.md`; link resolution by filesystem existence check; self-test run
> (`sh scripts/self-test.sh all` → 312 PASS, exit 0) to confirm count claims.

---

## Severity legend
- **High** — a maturity/status contradiction that could mislead a consumer about production readiness.
- **Medium** — a broken link, stale gate-category/version, or source cruft in a source-of-truth doc.
- **Low** — cosmetic staleness (header version drift) or illustrative text that reads as stale but is not.

---

## Summary of results

| Category (task) | Result |
| --- | --- |
| 241 Contradictory maturity labels | **No hard contradictions.** Maturity labels are consistent across docs; all defer to `product-status.md`. One *internal* gate-category staleness in `enterprise-scanner-matrix.md` (Dep-Check table body vs its own v0.1.21 note) — Medium. |
| 242 Dependency-Check "attempted, NOT live-validated" | **Consistent everywhere** (validated negative). 25+ references all say attempted/NOT live-validated. |
| 243 DAST status (manual / never-run) | **Consistent** (validated negative). |
| 244 AI review (non-gating) | **Consistent** (validated negative). |
| 245 Strict / regulated status | **Consistent** (validated negative). |
| 246 v1.0 (NOT reached) | **Consistent** (validated negative). No doc claims v1.0 reached. |
| 247 README links | **All resolve** (validated negative) — 0 broken in root `README.md`. |
| 248 Docs index links | **All resolve** (validated negative) — 0 broken in `docs/README.md`. |
| 249 Roadmap currency | Header stale (`v0.1.16`); body current through v0.1.23 + a v0.1.24 forward target — Low. |
| 250 Readiness checklist currency | Header stale (`v0.1.16`); body current through v0.1.23 — Low. |
| 251 Docs-consistency self-test practical? | **Yes — practical and partially already wired.** Recommendation below. |
| 252 Single-source-of-truth note | Recommendation below. |
| 253–258 Stale references | **5 broken links + 1 stale gate-category + source cruft + header drift.** Table below. |
| 259–260 Changelog / product-status updates | Captain-owned actions listed below. |

**Headline:** **0 hard maturity contradictions.** The doc set is unusually disciplined about
deferring to `product-status.md` / `main-gate-live-evidence.md`. Real defects are **6 broken/stale
references** (5 broken internal links + 1 broken example path), **stray template tags committed into
3 source-of-truth docs**, **1 stale gate-category in a table body**, and **header-version drift** in
~7 docs.

---

## 241 — Contradictory maturity labels

**No hard contradictions found.** Every doc that states a maturity label either matches
`product-status.md` or explicitly defers to it. Verified the high-risk axes:

- **Engine / PR-fast = `proven`:** consistent (`product-status.md:52-56`, `product-readiness-checklist.md:8-11`, `v1-readiness.md:41-42`).
- **CodeQL/OSV/Trivy-fs/Syft + Grype/Dockle + Semgrep 1.165.0 = live-validated/consumer-verified:** consistent across `product-status.md:80-84,151-156`, `main-gate-live-evidence.md:9-12,43-45`, `enterprise-scanner-matrix.md:105-119`, `strict-mode-readiness.md:76-78`, `regulated-mode-readiness.md:108`, `production-readiness-audit.md:102-119`.
- **Dependency-Check = experimental / attempted, NOT live-validated:** consistent (see 242).

One **internal** staleness (not a cross-doc maturity contradiction) — see finding S4 below: the
`enterprise-scanner-matrix.md` table body still lists Dependency-Check gate category `MAIN`
(`enterprise-scanner-matrix.md:57`) while the same file's v0.1.21 note says it "moves to gate
category **NIGHT** as its reliable home" (`enterprise-scanner-matrix.md:122`). Severity: **Medium**.

## 242 — Dependency-Check: "attempted, NOT live-validated"

**Consistent everywhere (validated negative).** 25+ references checked; no doc overclaims. Representative:
`product-status.md:160,184`, `main-gate-live-evidence.md:14,46,58,72,74`, `v1-readiness.md:44,284`,
`strict-mode-readiness.md:103`, `regulated-mode-readiness.md:95`, `product-readiness-checklist.md:89`,
`pinned-tool-references.md:84`, `scanner-image-digest-pinning.md:30`, `README.md:630`, `CHANGELOG.md:13,36,45,76,85`.
The only nuance is the gate-category staleness in S4 (the *maturity* claim is correct; the *gate home* label is stale).

## 243 — DAST status (manual / never run end-to-end)

**Consistent (validated negative).** `product-status.md:14,46,61,128,175`, `dast-policy.md:1-12`,
`enterprise-scanner-matrix.md:75-77,98-100`, `product-readiness-checklist.md:87` ("DAST still never
enabled"), `regulated-mode-readiness.md:102`. No doc claims DAST was run against a live target.

## 244 — AI review (non-gating)

**Consistent (validated negative).** `ai-review-policy.md:1-6`, `product-status.md:45,62`,
`enterprise-scanner-matrix.md:78-79,101`, `gate-promotion-policy.md:40,162`,
`strict-mode-readiness.md:46`, `regulated-mode-readiness.md:42,103`, `raw-report-contract.md:38,41`.
Non-gating-by-default-even-in-regulated is stated uniformly.

## 245 — Strict / regulated status

**Consistent (validated negative).** `strict-mode-readiness.md` and `regulated-mode-readiness.md`
both: (a) defer to `product-status.md`, (b) state the engine is production-ready but the product is
not "all scanners proven," (c) list coarse/experimental gates to run advisory first, (d) confirm no
consumer has run green in `strict` (matches `v1-readiness.md:47` OUTSTANDING #7). No contradiction.

## 246 — v1.0 NOT reached

**Consistent (validated negative).** Every v1.0 reference states NOT reached / pre-1.0:
`v1-readiness.md:7,279,281`, `product-status.md:178`, `product-readiness-checklist.md:90`,
`roadmap.md:103`, `product-contract.md:7`, `strict-mode-readiness.md:16`,
`regulated-mode-readiness.md:21`, `gate-promotion-policy.md:21`, `CHANGELOG.md:29`. **Zero** docs
claim v1.0 is reached. (`v1-readiness.md:33,200` matched a "1.0" grep but are section text, not claims.)

## 247 — README links audit

**All resolve (validated negative).** Filesystem-existence check of every relative link in the root
`README.md` → **0 broken**. Core-doc links (`product-status.md`, `roadmap.md`,
`product-readiness-checklist.md`, `product-contract.md`) present and matched by the self-test
(`scripts/self-test.sh:1471-1476`).

## 248 — Docs index links audit

**All resolve (validated negative).** Every relative link in `docs/README.md` → **0 broken**,
including `tooling/scanner-enablement.md`, `tooling/main-gate-tool-installation.md`, and the
`remediation/` and `../profiles/` targets (all confirmed to exist).

## 249 — Roadmap currency

Body content is current (covers v0.1.18–v0.1.23 plus a v0.1.24 forward target at `roadmap.md:105`).
Only defect: **header version stale** (`roadmap.md:1` = `# Roadmap (v0.1.16)`) and a stray
`</content>` tag at `roadmap.md:81` (see C1). Severity: Low (header) / Medium (stray tag).

## 250 — Readiness checklist currency

Body is current — it has a dedicated "v0.1.23 — enterprise readiness burn-down (status update)"
section (`product-readiness-checklist.md:82-90`) including the `not-reached` v1.0 row. Only defect:
**header version stale** (`product-readiness-checklist.md:1` = `(v0.1.16)`). Severity: Low.

## 251 — Is a docs-consistency self-test practical? (note for the captain)

**Yes — practical, and partially wired already.** `scripts/self-test.sh` already does grep-based doc
assertions in `v023-regression`: "README links core docs" (`self-test.sh:1471-1476`), "CHANGELOG has
0.1.23 entry" (`self-test.sh:1478-1479`), "no .claude tracked" (`self-test.sh:1482`). Extending this
is low-risk and deterministic (no network). Recommended additions the captain may wire:

1. **Link resolution** — for every `](relative/path.md)` in `docs/*.md` + `README.md`, assert the
   resolved file exists. This audit found 6 links that such a check would have caught (S1–S3, S5).
   A `docs-links` suite that walks each markdown link and `test -e` the resolved path is ~20 lines.
2. **Dependency-Check guard** — assert no doc contains `Dependency-Check.*live-validated` without a
   negation, protecting the chief-blocker invariant.
3. **No-stray-tags** — assert `docs/*.md` contain no literal `</content>`/`</invoke>` (catches C1).
4. **Header-version freshness (advisory)** — warn (not fail) when a doc's `# … (vX)` header is older
   than the newest `vY` it mentions in-body.

Caveat: the existing CHANGELOG check hardcodes `0.1.23` (`self-test.sh:1478-1479`) and the
README-link check is satisfied by substring presence, not resolution — so today's self-test would
**not** have caught the broken links in S1–S3/S5. Note: this lane does not edit `self-test.sh`.

## 252 — Single-source-of-truth recommendation (note for the captain)

The two-source model (maturity → `product-status.md`; live evidence → `main-gate-live-evidence.md`)
is already declared in both files and honored by deferring docs. **Recommendation:** add a one-line
banner at the top of every *secondary* maturity-bearing doc (the matrices, readiness guides, audit)
stating: *"Maturity defers to `product-status.md`; live-validation defers to
`main-gate-live-evidence.md`. If this file disagrees, those win."* Most already have it
(`enterprise-scanner-matrix.md:3-5`, `strict/regulated-mode-readiness.md`, `v1-readiness.md:7-12`);
`production-readiness-audit.md` and `enterprise-scanner-matrix.md` would benefit from also fixing the
stale *table-body* values (S4) so the deferral note is the only place a reader must reconcile.

## 253–258 — Stale / broken reference table (captain-actionable)

| ID | Type | File:line | Current text | Recommended fix | Severity |
| --- | --- | --- | --- | --- | --- |
| S1 | Broken link (path prefix) | `docs/adoption-guide.md:221` | `](docs/enterprise-scanner-matrix.md)` | `](enterprise-scanner-matrix.md)` — drop the `docs/` prefix (link is already inside `docs/`; resolves to `docs/docs/…`) | Medium |
| S2 | Broken link (path prefix) | `docs/docker-security-standard.md:194` | `](docs/profile-driven-adoption.md)` | `](profile-driven-adoption.md)` | Medium |
| S2 | Broken link (path prefix) | `docs/docker-security-standard.md:201` | `](docs/enterprise-scanner-matrix.md)` | `](enterprise-scanner-matrix.md)` | Medium |
| S3 | Broken link (path prefix) | `docs/github-actions-security.md:132` | `](docs/profile-driven-adoption.md)` | `](profile-driven-adoption.md)` | Medium |
| S3 | Broken link (path prefix) | `docs/github-actions-security.md:139` | `](docs/enterprise-scanner-matrix.md)` | `](enterprise-scanner-matrix.md)` | Medium |
| S4 | Stale gate-category (table body vs own note) | `docs/enterprise-scanner-matrix.md:57` | `OWASP Dependency-Check … MAIN … ✓/✓/✓ … main` | Align the table body with the v0.1.21 note at line 122 (gate home is **NIGHT**) and/or add an inline "attempted, NOT live-validated" caveat in the Notes cell so the row matches `main-gate-live-evidence.md` | Medium |
| S5 | Broken link + wrong file (example path) | `docs/node-react-normalization.md:86` | `](../examples/laravel-react-docker/scripts/sentinel/vitest-to-tests-json.mjs)` | The file does not exist in the example tree. The real adapter is `scripts/adapters/vitest-to-tests-json.mjs`. Repoint to `](../scripts/adapters/vitest-to-tests-json.mjs)` (the `scripts/sentinel/…` path in the example's `package.json` is a consumer-created path, not a shipped file) | Medium |
| S6 | Stale header version | `docs/product-status.md:1` | `# Product Status (v0.1.16)` | `# Product Status (v0.1.24)` — body already covers v0.1.18–v0.1.23 | Low |
| S6 | Stale header version | `docs/roadmap.md:1` | `# Roadmap (v0.1.16)` | bump to current (`v0.1.24`); body current | Low |
| S6 | Stale header version | `docs/product-readiness-checklist.md:1` | `# Product Readiness Checklist (v0.1.16)` | bump to current; body has a v0.1.23 update section | Low |
| S6 | Stale header version | `docs/workflow-template-inventory.md:1` | `# Workflow Template Inventory (v0.1.16)` | bump to current; body references v0.1.22 | Low |
| S6 | Stale header version | `docs/pinned-tool-references.md:1` | `# Pinned Tool References (v0.1.13)` | bump to current; body references v0.1.21 | Low |
| S6 | Stale header version | `docs/production-readiness-audit.md:1` | `# Production Readiness Audit (v0.1.13, maturity note v0.1.16)` | bump the maturity-note version; body references v0.1.21 | Low |

### Non-findings (checked, NOT stale — recorded so they are not re-flagged)
- **`anchore/grype:v0.115.0`** at `supply-chain-reproducibility.md:153` — illustrative ("pick the new
  version tag, **e.g.** `…v0.115.0`"), not a pinned-version claim. Canonical is `v0.114.0` everywhere
  else (`scanner-image-digest-pinning.md:18`, `pinned-tool-references.md:79`, templates). **Not stale.**
- **`semgrep/semgrep:1.90.0`** (13 refs) — deliberate historical contrast (118 parser errors vs
  0 on 1.165.0). **Not stale.**
- **`sentinel-shield-main-validation.yml` / `sentinel-shield-pr-fast-validation.yml`** — these are
  **consumer-side** workflow names cited as run evidence (zenchron-tools), not Sentinel Shield
  template filenames. Shipped templates are the six in `templates/workflows/`. **Not stale**, though
  `production-readiness-audit.md:95` refers to `sentinel-shield-main-validation.yml` as a file — that
  is a consumer file, acceptable in context.
- **Self-test "312 checks"** (`product-status.md:179`) — **verified accurate**: `sh scripts/self-test.sh all`
  emits exactly 312 PASS lines (exit 0). The "271" figure is the v0.1.22 historical count
  (`product-status.md:194`), also correct in context.
- **Profile names** (`laravel`, `react`, `node`, `docker`, `php-library`, `symfony`,
  `laravel-react-docker`, `node-react`) — all referenced profiles/manifests exist under `profiles/`.

### C1 — Source cruft (committed template tags) — Medium
Stray literal closing tags committed into source-of-truth docs (rendered as visible cruft):
- `docs/product-status.md:140-141` — `</content>` then `</invoke>`
- `docs/roadmap.md:81` — `</content>`
- `docs/v1-readiness.md:300-301` — `</content>` then `</invoke>`

Recommended fix: delete these stray lines. They are tool/template artifacts, not content.

## 259–260 — Changelog / product-status updates needed (captain owns these files)

- **`CHANGELOG.md`** — the `[Unreleased]` section (`CHANGELOG.md:7`) is **empty**. For the v0.1.24
  cut, add the sprint's entries (incl. this audit and the captain's fixes for S1–S6/C1). The latest
  released tag is `v0.1.23` (confirmed via `git tag`); v0.1.24 is unreleased.
- **`docs/product-status.md`** — (a) bump the header `(v0.1.16)`→`(v0.1.24)` [S6]; (b) remove stray
  tags at lines 140-141 [C1]; (c) if v0.1.24 promotes Dependency-Check, update §3/§6/§7 and the
  per-tool note (currently "attempted, NOT live-validated") — **only with a real cited artifact in
  `main-gate-live-evidence.md`**, per the graduation rule (`v1-readiness.md:260-275`). As of this
  audit, **no such artifact exists**, so Dependency-Check must stay attempted/NOT live-validated.
- **`scripts/self-test.sh`** (captain/another lane — NOT this lane) — the hardcoded `0.1.23`
  CHANGELOG assertion (`self-test.sh:1478-1479`) should track the current release version, and the
  README-link check could be upgraded to true link resolution (task 251).

---

## Validation performed (this lane)
- Doc is non-empty.
- Spot-checked >5 cited `file:line` references against real content (all confirmed):
  `product-status.md:1` (`# Product Status (v0.1.16)`); `roadmap.md:1` (`# Roadmap (v0.1.16)`);
  `adoption-guide.md:221` (`](docs/enterprise-scanner-matrix.md)`);
  `node-react-normalization.md:86` (`…/scripts/sentinel/vitest-to-tests-json.mjs`);
  `enterprise-scanner-matrix.md:57` (Dep-Check `MAIN … ✓/✓/✓`);
  `enterprise-scanner-matrix.md:122` ("moves to gate category **NIGHT**");
  `product-status.md:140-141` + `roadmap.md:81` + `v1-readiness.md:300-301` (stray `</content>`/`</invoke>`).
- Link checks done by filesystem existence (`test -e` on resolved relative paths).
- `sh scripts/self-test.sh all` → 312 PASS, exit 0 (confirms the 312-check claim).
</content>
