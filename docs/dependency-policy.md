# Dependency Policy (v0.1.12)

## Vulnerability scanners → severity keys
composer audit, npm audit, Trivy, **OSV-Scanner, Grype, OWASP Dependency-Check** all map to
the existing severity keys `critical_vulnerabilities / high_vulnerabilities /
medium_vulnerabilities`. Baseline blocks critical+high; strict+ also blocks medium. Multiple
scanners summing into the same keys is intentional (defense in depth).

**Severity caveat:** OSV-Scanner severity is coarse — the collector counts all OSV
vulnerabilities as `high` unless given a normalized `{critical,high,medium}`. Grype and
Dependency-Check are severity-mapped from their native fields.

## `dependency_policy_violations` (reserved)
A distinct gate for **policy** breaches (disallowed license, banned package, min-version
floor) — not CVE severity. Gated in baseline+ by default, but has **no default emitter** in
v0.1.12: wire a project dependency-policy tool to emit
`reports/raw/<tool>.json` with `{"dependency_policy_violations": N}` (a custom collector
or `ss_emit_collector` override). Until then it stays 0.
