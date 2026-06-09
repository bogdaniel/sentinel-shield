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

## dependency-policy emitter (v0.1.14)

`scripts/audits/dependency-policy.sh` is the first concrete emitter for
`dependency_policy_violations`. v0.1.14 implements the **lockfile detector** only: it flags an
ecosystem manifest present WITHOUT its lockfile (composer/npm/python/go/ruby/rust) — a
reproducible-build + supply-chain risk. Output `reports/raw/dependency-policy.json`
`{count, violations:[{ecosystem,manifest,reason}]}` → collector `dependency-policy.sh` →
`dependency_policy_violations` (baseline+ gating). **License/version-allowlist policy is
deferred** to a future release (doing it badly is worse than not at all). No manifests → 0
(clean, honest); not fake.

## OWASP Dependency-Check execution (v0.1.19)
Dependency-Check is **disabled by default** (slow NVD download); enable via
`SENTINEL_SHIELD_DEPENDENCY_CHECK_MODE=enabled` with a cache dir
(`SENTINEL_SHIELD_DEPENDENCY_CHECK_CACHE`). **Scheduled/nightly is the recommended home**, not
PR-fast. It maps to `*_vulnerabilities` and may duplicate OSV/Trivy/Grype CVEs. Supported, **not
live-validated**.
