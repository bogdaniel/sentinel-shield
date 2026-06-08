# Scanner Enablement by Stack (v0.1.12)

Safe defaults: PR-fast tools enabled; DAST + Nuclei **off** unless a target+allowlist is
configured; AI review **off / non-gating**. See docs/enterprise-scanner-matrix.md for the
full matrix and per-tool gate categories.

## Laravel / PHP (profiles/laravel)
- PR: php -l (`runners/php-syntax.sh`), PHPStan/Larastan, Psalm (opt-in), Pint/PHP-CS-Fixer
  (`php-style`), composer audit, Deptrac.
- MAIN: OSV-Scanner, Dependency-Check, Grype, CodeQL, architecture tests → deptrac.
- Enable Psalm: emit `reports/raw/psalm.json` (maps to type_errors). Pint/PHP-CS-Fixer →
  `reports/raw/php-style.json` (style_violations; strict+).

## Symfony (profiles/symfony) — same PHP tools as Laravel.

## Node / React (profiles/node, profiles/react)
- PR: ESLint, tsc --noEmit, npm audit.
- Tests → Vitest/Jest adapters.

## Docker (profiles/docker)
- PR: Hadolint, base-digest. NIGHT: Trivy image, Dockle (`container_image_violations`,
  needs `SENTINEL_SHIELD_IMAGE`).

## IaC (any stack with terraform/k8s/cloudformation)
- MAIN: Checkov, Conftest/OPA, Terrascan → `iac_violations` (strict+).

## DAST (manual) / AI (assistive)
- DAST: `sentinel-shield-dast.yml` only, with target+allowlist (docs/dast-policy.md).
- AI: `sentinel-shield-ai-review.yml`, non-gating (docs/ai-review-policy.md).
