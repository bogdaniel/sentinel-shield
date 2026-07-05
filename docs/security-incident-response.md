# Security incident-response & emergency-release runbook

This runbook is the operational companion to `SECURITY.md` and `docs/security-policy.md`. It
governs how a reported or detected security incident is handled, and how — and only how — a
release may ship while a known security finding is still open (the **emergency-release**
path). The parameters below are declared in `config/production-security-policy.json`
(`incident_response` and `emergency_release`) and are enforced, not merely documented.

All timelines are targets measured from first receipt. All artifacts must be **redacted** of
credentials, tokens, signing-key paths, and repo-local absolute paths.

## Roles

- **Incident lead** — owns the incident end to end; the accepted-risk `owner`.
- **Approver** — an independent reviewer who signs off (accepted-risk `approved_by`); must
  not be the owner (no self-approval).
- **Communications** — coordinates reporter contact and any disclosure.

## Phases

### 1. Intake

Reports arrive via the channels in `SECURITY.md`. Record the report privately. Never echo
live secrets into the tracker.

### 2. Acknowledge

**Acknowledge** the reporter within `incident_response.acknowledge_within_hours` (default
24h). Open a private tracking issue and assign an incident lead.

### 3. Triage

**Triage** within `incident_response.triage_within_hours` (default 72h): confirm or refute
the finding, assign severity (critical/high/medium/low), identify affected
versions/components, and determine whether a fix is available. Map the finding to its
scanner + category so any accepted-risk record can be scoped narrowly.

### 4. Remediate

Prefer a real fix (upgrade/patch) that clears the acceptance gate. Re-run
`scripts/enforce-security-policy.sh`; a clean run (`decision: accepted`, exit 0) is the bar
for a normal release.

### 5. Emergency release (only when remediation cannot land in time)

An **emergency** release ships with a known, still-open finding under a strict, short-lived
exception. It is the ONLY way a critical finding may pass the gate. Requirements
(`emergency_release`, enforced):

- `emergency: true` accepted-risk record, `scope: finding`, matching the finding's
  `scanner` + `category` + `finding_id`.
- **Mandatory owner** and **mandatory approver** (independent).
- **Incident reference** (`incident`) — required.
- **Follow-up issue** (`issue`) tracking the permanent fix — required.
- **Short lifetime** — `expires_at - created_at` must not exceed
  `emergency_release.max_lifetime_days` (default 3 days / 72h). The gate rejects any longer.

When these hold, the gate returns exit 0 with decision `accepted-emergency` and records the
applied emergency waiver in the acceptance report. When the emergency record is absent,
expired, over-lifetime, or missing its incident reference, the critical finding **rejects**
(exit 1) — the emergency path never becomes a silent bypass.

The emergency exception is temporary by construction: once it expires the gate blocks again,
forcing the permanent fix to land.

### 6. Disclosure

Follow **coordinated disclosure** (`incident_response.public_disclosure_policy`): disclose
publicly only after a fix or documented mitigation is available, on a timeline agreed with
the reporter. Credit reporters who wish to be named.

### 7. Post-incident review

After closure, review: root cause, why the gate did/did not catch it, whether a new scanner
or regression-baseline rule is warranted, and whether any emergency exception was closed out
by a permanent fix. File the follow-up actions.

## Validation

`.github/workflows/security-incident-validation.yml` is a fail-closed, network-free workflow
that asserts this runbook and `SECURITY.md` exist with their required sections, that the
policy declares a conforming incident-response + emergency-release contract, and that the
emergency-release path behaves exactly as specified (rejects a critical finding without the
emergency waiver; accepts it with a valid one). `tests/prod/261-production-security.sh`
covers the same emergency-release scenario deterministically.
