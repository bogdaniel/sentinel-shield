# Sentinel Shield — Release Authorization Policy

This document is the authority on **who may authorize a production release** and how the
enforced two-person control is handled while the project has a single maintainer.

## The enforced control

Publishing a production tag/release is gated by a governed **authorization record**
(`schemas/release-authorization.schema.json`), consumed by
`scripts/authorize-production-release.sh authorize`. The record must:

- match the verified candidate's `version`, `stage`, `release_scope`, `source_commit`,
  `tag`, and reproducible `candidate_hash`;
- carry **distinct** `requested_by` and `approved_by` GitHub logins — **self-approval is
  refused** (`release-authz.sh` `ra_authorization_binds`);
- be **unexpired** (`expires_at`); and
- for `interactive` method, re-supply the confirmation nonce via `--confirm-token`.

The tooling **never** creates a tag or GitHub Release; it emits a decision and prints the
exact operator commands. Publishing additionally requires an explicit destructive step
(`--execute`, or a manual signed `git tag` + `gh release create`).

## Sole-maintainer reality (current)

The repository currently has **one** admin/collaborator (`bogdaniel`) and no second human
login. The two-person `requested_by ≠ approved_by` control is therefore **structurally
unsatisfiable** — it cannot be met honestly, and it must **not** be met by fabricating a
second identity or by misusing an automation account (e.g. `dependabot[bot]`) as a
"requester". Doing so would defeat the exact control the record exists to enforce.

## Sanctioned sole-maintainer authorization path

Until a second maintainer exists, a production release MAY be published under an explicit,
recorded **sole-maintainer authorization waiver** of the two-person control, decided by the
release owner. This mirrors the existing soak-waiver precedent
(`evidence/releases/*-soak-waiver.json`): the deviation is **governed and recorded**, never
silent.

Requirements for the waiver:

1. The release owner (repo admin) explicitly authorizes the specific candidate
   (`version`, `stage`, `scope`, `source_commit`, `tag`, `candidate_hash`).
2. `verify-candidate` for that candidate is **READY** and every other gate is green
   (this waiver covers **only** the two-person identity control — no other gate).
3. The tag is an **SSH/GPG-signed** tag at the CI-proven source commit.
4. The deviation is recorded in the CHANGELOG entry and (recommended) as an
   `evidence/releases/<version>-authorization-waiver.json` artifact.

What the waiver does **not** do: it does not waive candidate verification, security
acceptance, compatibility, adopter, upgrade/rollback, or manifest self-consistency. Those
are re-derived and must be green regardless.

## Applied: v2.0.1

`v2.0.1` (engine-only maintenance, tag target `32812ed`) was published **2026-07-09** under
this sole-maintainer authorization path. `verify-candidate stage=ga scope=engine-only` was
**READY**; `framework-validated` / `full-platform` were **BLOCKED**. The two-person identity
control was waived by the release owner because no second approver exists; the SSH-signed tag
was created and pushed by the owner directly.

## Upgrade path (when a second maintainer exists)

Add a second admin/collaborator, then revert to the full governed flow:
`authorize-production-release.sh authorize` with a real, distinct `requested_by` /
`approved_by`, `--confirm-token`, followed by `print-tag-commands` and the destructive tag
step. At that point the sole-maintainer waiver is no longer applicable.
