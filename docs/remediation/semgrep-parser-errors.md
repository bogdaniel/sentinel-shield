# Semgrep Parser Errors — Remediation (v0.1.18)

## Symptom
Semgrep reports many **scan errors** (`PartialParsing` / `Syntax error`) while still producing
findings. On the zenchron-tools pilot, `semgrep/semgrep:1.90.0` produced **118 such errors on
application PHP** under `Modules/**/app` (e.g. on the `readonly` keyword) — **0 in vendor/build**.

## Findings vs parser errors — how to tell them apart
- **Findings** live in `.results[]` (a rule matched). These map to summary keys and gate.
- **Parser errors** live in `.errors[]` with `type: "PartialParsing"` / a `Syntax error` message
  and a `path`. They mean Semgrep's parser could not fully parse that file — they are **not**
  findings and do **not** mean the file is clean or vulnerable; coverage on that file is partial.

Quick triage:
```sh
jq '.errors | length' reports/raw/semgrep.json                 # how many parse errors
jq -r '.errors[].path' reports/raw/semgrep.json | sort -u      # which files
jq -r '.errors[].path' reports/raw/semgrep.json | grep -cE '^/?(vendor|node_modules|public/build|public/vendor|storage|dist|coverage)/'
```
If the errors are in **application source** (app/, Modules/**/app, src/, resources/js), they are
a **Semgrep version/parser limitation** — fix by upgrading the image (below).

## When to upgrade the Semgrep image
Upgrade when parser errors appear on modern language syntax in application code (PHP 8.1+
`readonly`/enums/first-class-callable, new TS syntax, etc.). Newer Semgrep ships newer
tree-sitter grammars. v0.1.18 default: **`semgrep/semgrep:1.165.0`** (1.90.0 → 1.165.0).
Override via `SENTINEL_SHIELD_SEMGREP_IMAGE`; **pin by digest** before production.
```sh
SENTINEL_SHIELD_SEMGREP_IMAGE=semgrep/semgrep@sha256:<digest>
```

## When NOT to .semgrepignore application code
**Never** add `app/`, `Modules/`, `src/`, `resources/js/`, `routes/`, `config/` to
`.semgrepignore` to silence parser errors — that excludes real code from SAST (a coverage gap
disguised as "clean"). Parser errors are fixed by the tool version, not by ignoring source.

## Tuning generated/vendor paths safely
`.semgrepignore` is for **genuinely generated/vendored/build** paths only: `vendor/`,
`node_modules/`, `public/build/`, `public/vendor/`, `storage/`, `bootstrap/cache/`, `dist/`,
`build/`, `coverage/`, `*.min.js`. This reduces scope/time and avoids vendor noise — it will
**not** reduce application-source parser errors (by design).

## Verification (v0.1.19)
`scripts/verify-semgrep-image.sh` runs the configured image against
`tests/fixtures/semgrep/php-modern` and fails (exit 1) if any `PartialParsing`/`Syntax` error
appears. **Result:** `semgrep/semgrep:1.165.0` (verified, output `.version`=1.165.0) → **0 parser
errors** on the fixture (1.90.0 produced 118 on the pilot's real code). **Fixture verification is
not live consumer validation** — re-run on the consumer's real codebase to confirm the drop.

## Consumer-verified (v0.1.20)
`semgrep/semgrep:1.165.0` was run on **real consumer code** (zenchron-tools, run 27239206382):
`semgrep.json` `.version`=1.165.0, **0 PartialParsing/Syntax errors** across `Modules/**/app`
(the same paths that produced **118** errors on 1.90.0). The parser-error fix is confirmed on
real code, not just the fixture. (25 INFO findings → medium; visible for triage, not suppressed.)
