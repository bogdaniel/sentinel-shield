# Dependency Advisory Triage (v0.1.14)

For findings from composer audit, npm audit, OSV-Scanner, Grype, Trivy, OWASP Dependency-Check
(→ `critical/high/medium_vulnerabilities`) and the lockfile policy (→ `dependency_policy_violations`).

1. **Confirm reachability** — is the vulnerable package actually used/loaded? Dev-only?
2. **Upgrade narrowly** — bump the single advisory'd package; avoid unrelated major jumps.
3. **No fix yet** — file a time-boxed accepted-risk (owner + expiry) for medium where allowed;
   never accept-risk `secrets`. Critical/high should be fixed, not accepted, in strict+.
4. **Lockfile missing** (dependency_policy_violations) — commit the lockfile; do not suppress.
5. Record in `docs/security/security-debt-register.md` + [`templates/dependency-risk-review.md`](../../templates/dependency-risk-review.md).
