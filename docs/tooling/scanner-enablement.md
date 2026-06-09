# Scanner Enablement by Stack (v0.1.12; maturity v0.1.16)

> Maturity labels for every tool below are canonical in [`product-status.md`](../product-status.md).
> Enabling a tool does not make it `proven` — most main/nightly tools are `experimental` until
> live-validated on a consumer.

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

## Semgrep configuration (v0.1.15, validated)
Use the **curated Sentinel Shield app rules** for the app SAST scan:
`semgrep --config <SENTINEL_SHIELD_PATH>/semgrep/app` with the project `.semgrepignore`
(honored via `-w /src`). **Do NOT use `--config=auto`** — validated on zenchron-tools
(run 27170148123) to be noisy (7 critical / 16 high false-positives + 341 scan errors vs
0/0 + 118 with curated rules). The pr-fast workflow template uses curated rules by default.

## Semgrep image (v0.1.18)
Default `semgrep/semgrep:1.165.0` (was 1.90.0, which emitted 118 PartialParsing errors on modern
PHP application code — see [`../remediation/semgrep-parser-errors.md`](../remediation/semgrep-parser-errors.md)).
Override with **`SENTINEL_SHIELD_SEMGREP_IMAGE`**; **pin by digest** before production. Always use
curated `<SS>/semgrep/app` rules — **never `--config=auto`**.
