# Severity Policy

Severity must be decided by policy, not by mood or by the loudest reviewer. This
document defines the levels, how to assign them, and what each level implies for
release gates.

Severity considers two factors: **impact** (what happens if exploited) and
**likelihood / exploitability** (how easy it is to reach and trigger).

---

## Levels

### Critical

Immediate, severe, and easily reachable impact. Blocks in `baseline`, `strict`, and
`regulated`.

Examples:

- Remote code execution.
- Authentication bypass on a production endpoint.
- SQL injection reachable from an unauthenticated route.
- Hardcoded production credentials or a leaked active secret.
- Unauthenticated access to PII / payment data.

### High

Serious impact, or critical impact behind a modest barrier. Blocks in `baseline`+.

Examples:

- Stored XSS in an authenticated area.
- Broken object-level authorization (IDOR) exposing other users' data.
- SSRF reachable by authenticated users.
- Privilege escalation requiring an existing low-privilege account.
- A critical-rated dependency CVE that is reachable in the running code path.

### Medium

Real but limited impact, or high impact requiring significant preconditions.
Tracked; blocks in `strict`/`regulated` only.

Examples:

- Reflected XSS requiring user interaction.
- Missing security headers.
- Verbose error messages leaking framework/version detail.
- A high-rated CVE in a dependency not on a reachable path.

### Low

Minor impact or hard-to-exploit issues. Tracked and burned down opportunistically.

Examples:

- Missing rate limiting on a low-value endpoint.
- Outdated but unaffected dependency.
- Weak but non-default configuration that is hard to reach.

### Informational

No direct security impact. Hygiene, style, or hardening suggestions. Never blocks.

Examples:

- Suggestion to add a healthcheck.
- A TODO to adopt a stricter cookie policy already mitigated elsewhere.

---

## Assigning severity

1. Start from the tool's rating (CVSS, scanner severity) as input, not as gospel.
2. Adjust for **reachability**: an unreachable critical CVE may be downgraded;
   document why.
3. Adjust for **exposure**: unauthenticated/internet-facing raises severity;
   internal-only with strong network controls may lower it.
4. Adjust for **data sensitivity**: payment, auth, and PII data raise severity.
5. When in doubt, round up. Under-rating is the more dangerous error.

Severity downgrades must be justified in writing and, in `regulated` mode, approved
and recorded as an exception.

---

## Mapping to gates

| Severity | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| Critical | report | block (new) | block | block |
| High | report | block (new) | block | block |
| Medium | report | report | block | block |
| Low | report | report | report | track |
| Informational | report | report | report | report |

"new" = introduced by the change under review (baseline comparison). See
[`../RELEASE-GATES.md`](../RELEASE-GATES.md).

---

## SLAs for remediation (recommended)

| Severity | Production fix target | Exception expiry max |
| --- | --- | --- |
| Critical | 24–72 hours | 7 days |
| High | 7 days | 30 days |
| Medium | 30 days | 90 days |
| Low | best effort | 180 days |

These are defaults. `regulated` projects should align them with their compliance
obligations.
