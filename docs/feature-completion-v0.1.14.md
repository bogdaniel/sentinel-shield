# Feature Completion — v0.1.14

This release finishes **feature coverage** for the planned tool matrix. It is NOT a hardening
or live-validation pass (that is v0.1.15). "Completed" here = the Sentinel Shield-side pieces
exist (runner/audit OR documented Action integration, collector, summary mapping, raw contract,
fixture, docs). Scanner **binaries** are external; most integrations remain **supported/
experimental** per [`production-readiness-audit.md`](production-readiness-audit.md).

| Tool | Maturity (pre-v0.1.14) | Missing exec | Missing collector | Missing workflow | Missing docs | v0.1.14 adds | Left for v0.1.15 hardening |
|---|---|---|---|---|---|---|---|
| CodeQL | collector-only | runner | — | template ✓ | — | `runners/codeql-export.sh` (SARIF→raw) | live SARIF, severity fidelity |
| Psalm | collector-only | runner | — | — | triage | `runners/psalm.sh` | live run, baseline |
| PHP syntax | done | — | — | — | — | (already runner) | — |
| Pint/PHP-CS-Fixer | collector-only | runner | — | — | style policy | `runners/php-style.sh` | live, format stability |
| PHPCS | documented | runner | collector | — | — | documented under php-style (PHPCS optional) | dedicated PHPCS support if needed |
| ESLint | collector-only | runner | — | — | — | `runners/eslint.sh` | live |
| TypeScript --noEmit | collector-only | runner | — | — | — | `runners/typescript.sh` | live |
| Deptrac | collector-only | runner | — | — | arch triage | `runners/deptrac.sh` | live |
| architecture tests | partial | runner+collector | collector | — | arch policy | `runners/architecture-tests.sh` + collector | live, real arch suite |
| OSV-Scanner | audit+collector | — | — | template ✓ | dep triage | dep-policy docs | live, severity refine |
| Grype | audit+collector | — | — | template ✓ | — | (complete) | live |
| OWASP Dependency-Check | audit+collector | — | — | template ✓ | dep triage | (complete) | live, runtime |
| OpenSSF Scorecard | audit+collector | — | — | template ✓ | — | (complete) | live, repo token |
| TruffleHog | audit+collector | — | — | template ✓ | — | (complete) | live deep scan |
| Checkov | audit+collector | — | — | template ✓ | iac policy | iac docs | live |
| Conftest/OPA | audit+collector | — | — | template ✓ | iac policy | iac docs | live, policy bundle |
| Terrascan | audit+collector | — | — | template ✓ | iac policy | iac docs | live |
| Dockle | audit+collector | — | — | template ✓ | — | (complete) | live, needs image |
| ZAP baseline | runner+collector | — | — | template ✓ | dast policy | (complete; manual) | live staging, approval flow |
| ZAP full | runner+collector | — | — | template ✓ | dast policy | full-mode input flag | live, approval |
| Nuclei | runner+collector | — | — | template ✓ | dast policy | allowlist template | live, controlled templates |
| Claude Code Security Review | collector+template | — | — | template ✓ | ai policy | (complete; non-gating) | real tool wiring |
| Kuzushi | collector+template | — | — | template ✓ | ai policy | (complete; non-gating) | real tool wiring |
| Trivy fs | action+collector | audit | — | template ✓ | — | `audits/trivy-fs.sh` | live |
| Trivy image | template | audit | — | template ✓ | — | `audits/trivy-image.sh` | live, needs image |
| Syft | action | audit | (evidence) | template ✓ | — | `audits/syft.sh` | live SBOM |
| actionlint | collector (advisory) | runner | — | ✓ | — | `runners/actionlint.sh` | promote from advisory |
| zizmor | collector (advisory) | runner | — | ✓ | — | `runners/zizmor.sh` | promote from advisory |
| **dependency-policy** | reserved key (no emitter) | audit+collector | collector | — | dep policy | **`audits/dependency-policy.sh` + collector (lockfile detector)** | license/version policy |

## Net new in v0.1.14
- **First concrete `dependency_policy_violations` emitter** — `audits/dependency-policy.sh`
  flags ecosystem manifests missing their lockfile (composer/npm/python/go/ruby/rust) +
  collector + self-test. License/version-allowlist policy is **deferred** (documented future).
- **9 runners + 3 audits + 1 collector** filled in (psalm, php-style, eslint, typescript,
  actionlint, zizmor, deptrac, codeql-export, architecture-tests; syft, trivy-fs, trivy-image;
  architecture-tests collector). All honest: missing binary → unavailable, never fake.
- Policy + remediation docs for dependency / IaC / style / architecture layers.

## Still manual / template-only after v0.1.14
DAST (ZAP/Nuclei) — manual, allowlisted, fail-closed. AI review (Claude Code / Kuzushi) —
assistive, non-gating. Trivy-image / Dockle — need a built image. Everything not run on the
zenchron pilot remains **fixture-validated, not live-validated** (see v0.1.13 audit + the
zenchron live-validation doc).
