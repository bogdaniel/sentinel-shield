# Evidence Contribution Guide (v1.7.0 — Agent C)

Rules for contributing scanner evidence to Sentinel Shield. The goal is **honest, reproducible**
evidence — never volume, never theater. See [`evidence-platform.md`](evidence-platform.md) for the
platform model and [`scanner-maturity-policy.md`](scanner-maturity-policy.md) for what each label means.

## What qualifies as acceptable evidence

- A **real scanner run** (binary/action/pip), real version recorded.
- A **CI run ID** (preferred) or a **reproducible command** anyone can re-run.
- A **raw artifact** that is valid and parseable.
- The **Sentinel Shield collector** run against that artifact, with the mapped summary key + pass/fail.
- Explicit **caveats**.

## What disqualifies evidence (hard NO)

- **Fabricated/hand-edited scanner output.** Never write a `*.json` "result" by hand.
- **Faked-clean reports** (asserting `pass`/0 when the scanner did not actually run → must be `unavailable`).
- **Engineered findings presented as incidental** (an intentionally-insecure fixture cannot justify
  `live-validated` — only `ci-validated (evidence-fixture)`).
- **Local-only runs claimed as CI/consumer evidence.**
- **Suppressed/remediated findings** to force a `pass`.
- **Deploying infrastructure** or using **real cloud credentials** in an evidence fixture.

## Private repo artifact handling

- Raw artifacts from **private** consumers are **never committed**. Record **aggregate counts** + the
  run ID only; keep the raw file local/gitignored.
- Public-consumer artifacts may be committed **only after sanitization** (below).

## Sanitized fixture rules

Committed fixtures (`tests/fixtures/<area>-v<rel>/`) must be **derived** from a real artifact and:
no absolute/runner paths (`/home/runner`, `/Users`, `/Volumes`), no account IDs, no credentials, no
secrets, no private class/path data (e.g. deptrac `.files` stripped). Add a `README.md` citing the
source run ID. Validate JSON. Add a `self-test` guard that the fixture maps through its collector.

## Required evidence fields (checklist)

- [ ] tool name + exact version
- [ ] repo/context + category (evidence-fixture / real-consumer / private-aggregate)
- [ ] CI run ID **or** reproducible command
- [ ] raw artifact name + validity (size)
- [ ] collector result + mapped summary key
- [ ] pass/fail behavior shown (violation **and** clean path where possible)
- [ ] caveats (severity coarseness, binary counts, surface scope, engineered findings)

## Reviewer checklist

- [ ] Run ID resolves; artifact downloadable; collector reproduces the cited mapping.
- [ ] Maturity label matches the evidence category (no `live-validated` from a fixture).
- [ ] No secrets / credentials / private raw data / absolute paths in committed files.
- [ ] No gate weakened, no finding suppressed, no STABLE script changed.
- [ ] Registry + `product-status.md` updated consistently; self-test guard added.

## No-fake-output & no-deploy policy

Evidence must come from a tool that actually ran. A scanner that cannot run reports `unavailable`
(not a fake clean). Evidence fixtures are **static-scan only** — no `terraform apply`, no
`kubectl apply`, no credentials, ever.
