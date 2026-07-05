# Security Policy

Sentinel Shield is a security-engineering toolkit; we hold its own supply chain and
release process to the same production security acceptance gate it ships to adopters
(`config/production-security-policy.json`, enforced by `scripts/enforce-security-policy.sh`).

## Reporting a vulnerability

Please **report** suspected vulnerabilities privately. Do not open a public issue for an
unfixed security defect.

- Email the security contact listed in `config/production-security-policy.json`
  (`incident_response.disclosure_contact`). The value in the repository is a REDACTED
  placeholder; operators substitute their real, monitored intake address at deployment.
- Alternatively, use the repository's private vulnerability reporting channel if the host
  forge provides one.

Include, where possible: affected component/version, a minimal reproduction, observed vs.
expected behaviour, and any known mitigations. Never paste live credentials, tokens, or
signing-key material into a report — redact them first.

## Coordinated disclosure

We follow a **coordinated disclosure** policy:

1. We **acknowledge** your report within the window in
   `incident_response.acknowledge_within_hours` (default 24h).
2. We **triage** and confirm within `incident_response.triage_within_hours` (default 72h).
3. We agree a remediation and disclosure timeline with you and credit reporters who wish to
   be named.
4. Public disclosure happens after a fix (or documented mitigation) is available, per the
   incident runbook.

Please give us a reasonable window to remediate before any public disclosure.

## Supported versions

Security fixes are delivered on the currently supported release line (see
`docs/support-policy.md`). Unsupported lines receive fixes only at maintainer discretion.

## How the gate protects releases

Every production release must pass the security acceptance gate, which blocks on: source,
dependency, workflow and container/image findings; leaked secrets (never waivable); stale
scanner databases; scanner failures / crashes; malformed or missing scanner reports; missing
applicable scanners; unverifiable provenance where required; and unexplained regressions in
finding counts or scan coverage. Suppressions are only honoured as narrowly-scoped, owned,
approved, issue-linked, unexpired accepted-risk records — never blanket package/scanner
suppression.

See `docs/security-policy.md` for the full policy and `docs/security-incident-response.md`
for the incident-response and emergency-release runbook.
