# Exception Policy

Not every finding can be fixed immediately. An exception is a **deliberate, owned,
time-boxed decision to accept a risk**. It is not a way to silence a scanner.

An exception is only valid with all required fields. A scanner suppression without a
corresponding exception record is itself a finding.

---

## Required fields

```txt
owner               Named individual accountable for the risk (not a team alias).
reason              Why the risk is being accepted right now.
affected component  The specific code/service/dependency in scope.
severity            Per docs/severity-policy.md.
expiry date         When this exception automatically lapses.
review date         When it will be reassessed before expiry.
mitigation          Compensating controls reducing the risk in the meantime.
approval            Who approved, and when. Role must match the severity.
```

Use the template at
[`../policies/exceptions/accepted-risk-template.md`](../policies/exceptions/accepted-risk-template.md).

---

## Approval authority

| Severity | Minimum approver |
| --- | --- |
| Critical | Security lead **and** engineering owner |
| High | Security lead or delegated approver |
| Medium | Engineering owner |
| Low | Tech lead |

`regulated` mode: critical and high exceptions additionally require compliance
sign-off and are retained as audit evidence.

---

## Lifecycle

1. **Raise.** Create the exception record with all fields. Link the finding.
2. **Approve.** The required authority reviews and approves. Without approval the
   gate stays red.
3. **Apply.** The scanner suppression (e.g. a Semgrep `nosemgrep`, a baseline entry)
   references the exception ID.
4. **Track.** The exception appears in the readiness report until resolved.
5. **Review.** On the review date, reassess: fix, extend (with new approval), or
   escalate.
6. **Expire.** On the expiry date the exception lapses automatically. The underlying
   gate re-activates and blocks until the finding is fixed or a new exception is
   approved.

There is no "permanent" exception. Maximum expiry windows are in
[`severity-policy.md`](severity-policy.md).

---

## What an exception is not

- Not a `// nosemgrep` with no record.
- Not commenting a check out of CI.
- Not lowering the gate mode to dodge a single finding.
- Not a team alias as owner — accountability must be a person.

---

## Storage

Exception records live in the consuming project under
`.sentinel-shield/exceptions/` (one Markdown file per exception, named by ID), and
are surfaced in the production readiness report. They are version-controlled so the
history of accepted risk is auditable.

---

## Example (summary form)

```yaml
id: EXC-2026-014
owner: "Dana Okoro <dana@example.com>"
reason: "Upstream fix pending; CVE not on a reachable path in our usage."
affected_component: "vendor/acme/parser 2.3.1"
severity: high
expiry_date: 2026-07-15
review_date: 2026-07-01
mitigation: "Input restricted to trusted internal callers; WAF rule added."
approval: "Security lead — approved 2026-06-04"
```
