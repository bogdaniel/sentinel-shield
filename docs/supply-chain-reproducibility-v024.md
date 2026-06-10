# Supply-Chain Reproducibility — v0.1.24 Addendum

This is the **v0.1.24 supply-chain reproducibility addendum** (Lane J, tasks 181–200). It does
**not** restate or replace [`supply-chain-reproducibility.md`](supply-chain-reproducibility.md),
[`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md), or
[`pinned-tool-references.md`](pinned-tool-references.md) — those remain the single sources of truth
for the digest tables, the Action SHA table, and the verify/update/rollback narrative. This
addendum adds (a) a **fresh live re-verification** of the three validated digests for the v0.1.24
sprint, (b) a recorded **Dependency-Check digest-resolution attempt** that explicitly stays a
not-validated placeholder, and (c) the **operational policies and self-test specifications** the
release captain wires for v0.1.24.

> **Honesty rule (unchanged):** every digest in this repo is **resolved with Docker, never
> invented**. We do **not** pin a digest for an image we have not live-validated, and we **never**
> recommend `latest` for production.

---

## 1. Live re-verification of the three validated digests (Tasks 181–183)

`docker` **was available** in this environment — `docker version` reported server
**`29.4.0`** — so on **2026-06-10** the three pinned digests from
[`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) were **re-verified live**
with:

```sh
docker buildx imagetools inspect <image>:<tag> --format '{{.Manifest.Digest}}'
```

Raw command outputs (copied verbatim from the terminal):

```text
$ docker buildx imagetools inspect semgrep/semgrep:1.165.0 --format '{{.Manifest.Digest}}'
sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b

$ docker buildx imagetools inspect anchore/grype:v0.114.0 --format '{{.Manifest.Digest}}'
sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28

$ docker buildx imagetools inspect goodwithtech/dockle:v0.4.15 --format '{{.Manifest.Digest}}'
sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9
```

| # | Image | Tag | Expected digest (baseline) | Resolved 2026-06-10 | Match |
|---|---|---|---|---|---|
| 181 | `semgrep/semgrep` | `1.165.0` | `sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b` | `sha256:f4791a54c891eabe1188248135574e6e03dfc31dfd3f3b747c7bec7079bfed1b` | ✅ match |
| 182 | `anchore/grype` | `v0.114.0` | `sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28` | `sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28` | ✅ match |
| 183 | `goodwithtech/dockle` | `v0.4.15` | `sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9` | `sha256:eade932f793742de0aa8755406c7677cd7696f8675b6180926f7eeffa7abe6b9` | ✅ match |

**Result:** all three tags still resolve to their pinned multi-arch manifest-list digests — **no
tag has been re-pushed** since the v0.1.21/v0.1.23 baselines. The pinned baselines remain
trustworthy for v0.1.24. No digest was edited; these values were copied from the command output
above and compared against the baseline table.

> If `docker` is **unavailable** in your environment, do not guess: mark the result
> "verification deferred — commands documented" and re-run the three commands above once Docker is
> present.

---

## 2. Dependency-Check digest resolution attempt — stays a NOT-validated placeholder (Tasks 184–185)

### 2.1 The attempt (Task 184)

For completeness, the Dependency-Check image tag was also resolved on **2026-06-10**:

```text
$ docker buildx imagetools inspect owasp/dependency-check:latest --format '{{.Manifest.Digest}}'
sha256:ad169904106250816059f113d374d63a49a7cb0fd2c5e476d05c4fb814cc77b9
```

So `owasp/dependency-check:latest` **resolved** to
`sha256:ad169904106250816059f113d374d63a49a7cb0fd2c5e476d05c4fb814cc77b9` at the moment of
inspection.

### 2.2 Why it stays a placeholder — do NOT pin it (Task 185)

This resolved digest is **recorded, not adopted**. It is **not** promoted into the validated digest
table in [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md), and it must **not**
be pinned in production, for two independent reasons:

1. **The tag is `latest` — a moving target.** A digest resolved from `latest` is only the bytes
   `latest` pointed at *this minute*; the tag can advance tomorrow. Resolving a digest from a
   floating tag does **not** make the image validated.
2. **Dependency-Check is *attempted, not live-validated*.** Per the v0.1.23 changelog and
   [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md), no consumer run
   has yet produced a real `dependency-check.json` artifact that the collector parsed. Without a
   live-validated artifact, we have no evidence the image behaves as required — so we honestly do
   **not** pin its digest.

**Policy:** Dependency-Check remains pinned by the readable tag `owasp/dependency-check:latest`
**solely as a not-yet-validated placeholder**, carrying its pin-before-prod comment in
`templates/workflows/sentinel-shield-dependency-check.yml` (line 54–55) and
`templates/workflows/sentinel-shield-scheduled.yml`. Pin it by digest **only after** a real
nightly/consumer run produces a parsed artifact — at which point: resolve the digest *for that
validated version tag* (not `latest`), record the validation run, and move the row into the digest
table in `scanner-image-digest-pinning.md` via the version-update process (§3).

---

## 3. Scanner digest update process (Task 186)

Mirrors [`scanner-image-digest-pinning.md` §"How to update safely"](scanner-image-digest-pinning.md)
and [`supply-chain-reproducibility.md` §7](supply-chain-reproducibility.md). Order matters so the
digest tables and evidence never drift from reality:

1. **Bump the version tag** — pick the new tag, e.g. `anchore/grype:v0.115.0`. Never bump to a
   floating tag (`latest`) for a production pin.
2. **Resolve the new digest** —
   `docker buildx imagetools inspect <image>:<newtag> --format '{{.Manifest.Digest}}'`. Copy the
   digest **from the command output**; never hand-write it.
3. **Live-validate the new digest** with a real run:
   - Semgrep: `sh scripts/verify-semgrep-image.sh tests/fixtures/semgrep/php-modern reports/raw/semgrep-image-verify.json` (expect **0 parser errors**).
   - Grype / Dockle: run on a consumer and confirm the collector parses the produced artifact.
4. **Update the digest tables** in `scanner-image-digest-pinning.md` **and**
   `pinned-tool-references.md` (digest + date), and refresh the override examples in the workflow
   templates (readable tag stays; digest goes in the trailing comment).
5. **Update CHANGELOG** with the version bump and the new digest.
6. **Record the validation run** in
   [`main-gate-live-evidence.md`](main-gate-live-evidence.md) (run ID + result), so the digest is
   backed by a citable live run.

Only after steps 3–6 is the new digest a **validated baseline** eligible for rollback (§4).

---

## 4. Scanner digest rollback process (Task 187)

Container image digests are **immutable**: an `@sha256:…` reference always resolves to the exact
same bytes, even after the human tag has moved on. Rollback is therefore deterministic and
byte-for-byte reproducible — not best-effort. Authoritative steps live in
[`scanner-image-digest-pinning.md` §"Rollback process"](scanner-image-digest-pinning.md); summary:

1. **Identify the last known-good digest** from the validated digest table in
   `scanner-image-digest-pinning.md` (those rows are the validated baselines).
2. **Revert the override** — set the affected `SENTINEL_SHIELD_*_IMAGE` env var back to the previous
   `@sha256:…` digest.
3. **Re-run the gate**; confirm green.
4. **File the regression upstream**; keep the old digest pinned until the upstream fix is itself
   live-validated via §3.
5. Because the old digest is immutable, the exact validated image is always retrievable by its
   `@sha256:` reference — rollback restores the byte-identical scanner, not an approximation.

> Rollback target is always a **digest** from the validated table, never a tag and never a
> `latest`-resolved digest.

---

## 5. Scanner version compatibility table (Task 188)

The validated scanner versions for v0.1.24 and the wrapper defaults that consume them. Defaults are
expressed as `${SENTINEL_SHIELD_<X>_IMAGE:-<readable-tag>}`; consumers override with a digest.

| Scanner | Validated version | Readable tag (wrapper default) | Pinned digest | Reproducibility status |
|---|---|---|---|---|
| Semgrep | `1.165.0` | `semgrep/semgrep:1.165.0` | `sha256:f479…fed1b` | live-validated; digest re-verified 2026-06-10 (§1) |
| Grype | `v0.114.0` | `anchore/grype:v0.114.0` | `sha256:7a9f…1dd28` | live-validated (SBOM-first); re-verified 2026-06-10 |
| Dockle | `v0.4.15` | `goodwithtech/dockle:v0.4.15` | `sha256:eade…be6b9` | live-validated (built image); re-verified 2026-06-10 |
| Syft (SBOM producer) | per `anchore/sbom-action` SHA | n/a (Action) | n/a — SHA-pinned Action | SHA in `pinned-tool-references.md` |
| OWASP Dependency-Check | **none (attempted, not validated)** | `owasp/dependency-check:latest` | **NOT pinned** (placeholder) | placeholder only — pin after validation (§2) |

Full digests are in the authoritative table in `scanner-image-digest-pinning.md`; abbreviations
above are for readability only. Compatibility note: Grype consumes a **Syft-produced SBOM**
(SBOM-first), so the Syft and Grype versions must both be pinned for a reproducible match set — see
[`supply-chain-reproducibility.md` §10](supply-chain-reproducibility.md).

---

## 6. GitHub Action pinning matrix (Task 189)

GitHub Actions are pinned to **full 40-char commit SHAs**, not tags (a tag like `@v4` is mutable).
The authoritative SHA table lives in [`pinned-tool-references.md`](pinned-tool-references.md); this
matrix is a reproducibility view of pin status (do not treat it as the source of truth — if it
disagrees with `pinned-tool-references.md`, that doc wins).

| Action | Version | Pin status |
|---|---|---|
| `actions/checkout` | v4.2.2 | **pinned + validated** in `ci-self-test.yml` |
| `actions/upload-artifact` | v4.6.2 | **pinned + validated** in `ci-self-test.yml` |
| `actions/download-artifact` | v4.3.0 | SHA documented; pin in consumer |
| `actions/setup-node` | v4.4.0 | SHA documented |
| `shivammathur/setup-php` | 2.32.0 | SHA documented |
| `github/codeql-action` | v3.29.0 | SHA documented; exercised in consumer live validation |
| `aquasecurity/trivy-action` | v0.36.0 | SHA documented; exercised in consumer live validation |
| `anchore/sbom-action` | v0.20.7 | SHA documented; exercised in consumer live validation |
| `anchore/scan-action` | v7.4.0 | SHA documented |
| `gitleaks/gitleaks-action` | v2.3.9 | SHA documented; exercised in consumer live validation |
| `google/osv-scanner-action` | v1.9.0 | SHA documented; exercised in consumer live validation |
| `zaproxy/action-baseline` | v0.14.0 | template-only (manual DAST) |
| `zaproxy/action-full-scan` | v0.12.0 | template-only (manual DAST) |

Rule: every `uses:` references a full-length commit SHA with the version as a trailing comment
(e.g. `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683  # v4.2.2`). Templates keep
readable tags and are marked **must pin before production**; the GH-Actions pin-audit gate flags
unpinned refs in consumers.

---

## 7. SBOM reproducibility documentation (Task 190)

Sentinel Shield's container-vulnerability path is **SBOM-first**: Syft produces the SBOM and Grype
scans that SBOM rather than re-walking the image. (Authoritative narrative:
[`supply-chain-reproducibility.md` §10](supply-chain-reproducibility.md).) Reproducibility
properties for v0.1.24:

- **Deterministic inputs.** The same digest-pinned image fed to the same pinned Syft version yields
  the same SBOM (same package set + versions), so Grype's output over that SBOM is reproducible.
  Pin the **image by digest** to keep the SBOM input fixed.
- **Decoupled, auditable artifact.** The SBOM is an inspectable artifact between "what's in the
  image" and "what's vulnerable" — a finding traces to a specific `package@version`, and the SBOM
  can be re-scanned later with an updated Grype DB without rebuilding.
- **Pinned producers.** Syft/Grype run as pinned, verified images/Actions (Grype `v0.114.0` digest
  `sha256:7a9fc7f89ccef78ae5a7691a115d3f0d41b1f319d589dd8cc1dcb9ab3f01dd28`; `anchore/sbom-action`
  SHA in `pinned-tool-references.md`). Updates follow §3.
- **DB-freshness caveat.** Grype's vulnerability *database* changes over time, so the **package
  set** is reproducible but the **match set** can change as new CVEs publish against the same
  packages. Expected and desirable; it changes only the matching, not the SBOM input.
- **SBOM artifact.** The SBOM is uploaded as the `sentinel-shield-sbom` artifact (see §9 naming
  policy), so the exact package set behind a gate run is retained and auditable.

---

## 8. Artifact retention policy (Task 191)

All Sentinel Shield workflow artifacts are uploaded via `actions/upload-artifact@v4` with a
**uniform `retention-days: 30`** across every template. Observed on 2026-06-10:

| Template | Artifacts | Retention |
|---|---|---|
| `sentinel-shield.yml` | `sentinel-shield-gate-resolution`, `-raw-security-php`, `-raw-security-node`, `-raw-security-docker`, `-raw-security`, `-sbom`, `-security-summary`, `-raw-security-merged`, `-enforcement`, `-release-evidence` | 30 days |
| `sentinel-shield-main.yml` | `sentinel-shield-main` | 30 days |
| `sentinel-shield-pr-fast.yml` | `sentinel-shield-pr-fast` | 30 days |
| `sentinel-shield-scheduled.yml` | `sentinel-shield-scheduled`, `sentinel-shield-dependency-check` | 30 days |
| `sentinel-shield-dependency-check.yml` | `sentinel-shield-dependency-check` | 30 days |
| `sentinel-shield-dast.yml` | `sentinel-shield-dast` | 30 days |
| `sentinel-shield-ai-review.yml` | `sentinel-shield-ai-review` | 30 days |

Policy:

- **Default retention is 30 days** — long enough for audit/triage of a gate run, short enough to
  bound storage. Consumers may raise it for compliance archival but must not drop below the
  evidence window their policy requires.
- **`if-no-files-found: warn`** on every upload — a missing report **warns**, it never silently
  succeeds and never fakes an artifact.
- Reproducibility evidence (`-release-evidence`, `-sbom`, `-enforcement`) follows the same 30-day
  default; for long-term reproducibility archival, copy these to a durable store before expiry.

---

## 9. Artifact naming policy (Task 192)

Every uploaded artifact name is **prefixed `sentinel-shield-`** and describes its content, so
artifacts are unambiguous across concurrent workflows in a consumer repo.

- **Per-workflow artifacts** are named after the workflow: `sentinel-shield-main`,
  `sentinel-shield-pr-fast`, `sentinel-shield-scheduled`, `sentinel-shield-dast`,
  `sentinel-shield-ai-review`, `sentinel-shield-dependency-check`.
- **Per-stage artifacts** in the full `sentinel-shield.yml` pipeline use a
  `sentinel-shield-<stage>` form: `-gate-resolution`, `-raw-security-{php,node,docker}`,
  `-raw-security`, `-raw-security-merged`, `-sbom`, `-security-summary`, `-enforcement`,
  `-release-evidence`.
- **Consistency rule:** the SBOM artifact is always `sentinel-shield-sbom` (used identically in both
  upload sites within `sentinel-shield.yml`); the dependency-check artifact is always
  `sentinel-shield-dependency-check` (used identically in the standalone and scheduled templates).

This naming is what the self-test in §10 (Task 198) asserts: no bare/un-prefixed artifact names,
and no two semantically different artifacts sharing a name.

---

## 10. Reproducibility checklist (Task 193)

- [ ] All production scanner images pinned by **digest** (`@sha256:…`), not a mutable tag.
- [ ] The three validated digests **re-verified** with `docker buildx imagetools inspect` and still
      equal the table in `scanner-image-digest-pinning.md` (§1).
- [ ] No digest hand-written/invented — every one traces to a `docker` command output.
- [ ] Dependency-Check remains a **`latest` placeholder**, NOT pinned by digest, with its
      pin-before-prod comment intact (§2).
- [ ] No production doc or template recommends `latest` for the three validated scanners (§11.1).
- [ ] `SENTINEL_SHIELD_*_IMAGE` override env vars present in the relevant templates (§11.2).
- [ ] GitHub Actions pinned to full-length commit SHAs; matrix agrees with
      `pinned-tool-references.md` (§6).
- [ ] SBOM inputs deterministic; Grype scans SBOM-first (§7).
- [ ] Artifact retention uniform at 30 days with `if-no-files-found: warn` (§8).
- [ ] Artifact names all `sentinel-shield-` prefixed and unambiguous (§9).
- [ ] CHANGELOG carries the v0.1.24 entry (§11.6).
- [ ] Digest tables, CHANGELOG, and `main-gate-live-evidence.md` agree after any update (§3).

---

## 11. Self-test specifications for the release captain (Tasks 194–199)

The release captain wires these as executable assertions (Lane tasks 194–199 are Captain-owned;
this section **specifies** them). Each lists the assertion and the expected pass condition. None of
these are wired in this doc-only lane — they are the contract the captain implements.

### 11.1 No production doc recommends `:latest` for the 3 validated scanners (Task 194)

- **Assert:** no production doc or template contains `:latest` for `semgrep/semgrep`,
  `anchore/grype`, or `goodwithtech/dockle`.
- **Expected:** zero matches. The **only** permitted `:latest` is the Dependency-Check placeholder
  (`owasp/dependency-check:latest`), which must retain its pin-before-prod comment. Suggested grep:
  `grep -rnE '(semgrep/semgrep|anchore/grype|goodwithtech/dockle):latest' docs/ templates/` → must
  be empty.

### 11.2 Templates expose digest override env vars (Task 195)

- **Assert:** each container-scanner template exposes its `SENTINEL_SHIELD_*_IMAGE` override so a
  consumer can swap the readable tag for a digest without editing the template.
- **Expected:** `SENTINEL_SHIELD_SEMGREP_IMAGE`, `SENTINEL_SHIELD_GRYPE_IMAGE`,
  `SENTINEL_SHIELD_DOCKLE_IMAGE` each appear in at least one template with a `@sha256:…` comment;
  `SENTINEL_SHIELD_DEPENDENCY_CHECK_IMAGE` appears with its pin-before-prod comment. Wrappers must
  honour the override (`${SENTINEL_SHIELD_SEMGREP_IMAGE:-semgrep/semgrep:1.165.0}` form).

### 11.3 Pinned-references doc completeness (Task 196)

- **Assert:** `docs/pinned-tool-references.md` lists every Action used by any
  `templates/workflows/*.yml` (`uses:`) with a resolved SHA and a status.
- **Expected:** for each unique `uses: <owner>/<repo>@…` in the templates, a matching row exists in
  the Action table. Suggested check: extract `uses:` owners/repos, diff against the doc's table →
  no template Action missing from the doc.

### 11.4 Scanner version table completeness (Task 197)

- **Assert:** the scanner version compatibility table (§5 here, and the digest table in
  `scanner-image-digest-pinning.md`) covers every validated scanner image used by the wrappers.
- **Expected:** Semgrep `1.165.0`, Grype `v0.114.0`, Dockle `v0.4.15` each have a row with version
  + digest; Dependency-Check has a row explicitly marked NOT pinned. No validated scanner image is
  missing a version/digest entry.

### 11.5 Artifact-upload naming consistency (Task 198)

- **Assert:** every `actions/upload-artifact` step in `templates/workflows/*.yml` uses a
  `name:` that is `sentinel-shield-`-prefixed, and no two semantically different artifacts share a
  name.
- **Expected:** all upload `name:` values match `^sentinel-shield-`; `sentinel-shield-sbom` and
  `sentinel-shield-dependency-check` are the only intentionally-reused names (same content). Any
  bare or non-prefixed name fails.

### 11.6 Changelog entry present (Task 199)

- **Assert:** `CHANGELOG.md` contains a v0.1.24 entry referencing this supply-chain
  reproducibility work.
- **Expected:** a `## [0.1.24]` (or `[Unreleased]` rolling into 0.1.24) section exists and mentions
  the digest re-verification / `docs/supply-chain-reproducibility-v024.md`. Mirrors the existing
  "changelog presence" regression assertion from the v0.1.23 suite.

---

## 12. Note for the product-readiness checklist (Task 200)

For [`product-readiness-checklist.md`](product-readiness-checklist.md) (the **captain** updates that
file — this lane does not touch it). Suggested line item:

> **Supply-chain reproducibility (v0.1.24):** three validated scanner digests (Semgrep `1.165.0`,
> Grype `v0.114.0`, Dockle `v0.4.15`) **re-verified live against Docker `29.4.0` on 2026-06-10** —
> all match baseline. Dependency-Check digest **resolved but deliberately NOT pinned** (attempted,
> not validated — `latest` placeholder with pin-before-prod comment). Update/rollback/version
> processes, retention (30d) and naming (`sentinel-shield-*`) policies, and the 194–199 self-test
> specs documented in `docs/supply-chain-reproducibility-v024.md`. **No `:latest` recommended for
> production** for any validated scanner.

---

## References

- [`supply-chain-reproducibility.md`](supply-chain-reproducibility.md) — v0.1.23 base doc
  (verify/rollback/update, SBOM, Action pinning).
- [`scanner-image-digest-pinning.md`](scanner-image-digest-pinning.md) — authoritative digest table
  + verify/update/rollback narrative.
- [`pinned-tool-references.md`](pinned-tool-references.md) — authoritative Action SHA table + image
  digests.
- [`dependency-check-nightly-strategy.md`](dependency-check-nightly-strategy.md) — why
  Dependency-Check is attempted, not validated (the `latest` exception).
- [`main-gate-live-evidence.md`](main-gate-live-evidence.md) — citable live validation runs.
