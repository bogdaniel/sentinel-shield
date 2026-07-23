# Contributing to Sentinel Shield

Sentinel Shield is a security and engineering baseline. Contributions are held to
the same bar the baseline imposes on others: explicit, validated, and safe by
default. This guide explains how to make changes that will be accepted.

## Principles

- **Security is a release requirement, not a best-effort activity.** Changes that
  weaken a gate need a written rationale and, where they accept risk, an exception
  record (`policies/exceptions/accepted-risk-template.md`).
- **Strict, boring, explicit, predictable.** Prefer obvious code and clear errors
  over cleverness. Fail closed.
- **No fragile parsing.** Shell parses the canonical `profile.yaml` only; JSON is
  parsed with `jq`. Do not add unsafe `sed`/`eval` JSON hacks.
- **Never blind-source untrusted files.** The gates `.env` is validated line by
  line; keep it that way.

## Branch and commit conventions

- Default branch is `master` (not `main`). Branch from `master`; open PRs into it.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat:`, `fix:`, `docs:`, `chore:`, `refactor:`, `build:`, `ci:`, `test:`,
  optionally scoped (e.g. `feat(gates): ...`). Keep the subject ≤ ~72 chars and
  explain the *why* in the body.
- Use the pull request template (`templates/pull-request-template.md`) and declare a
  risk level. High-risk changes (auth, payments, compliance, data access, cron,
  infrastructure) require the security-review template.

## Shell standards

All scripts target POSIX `sh`:

- `#!/bin/sh` and `set -eu`.
- No Bash arrays, `[[ ]]`, `local`, or process substitution.
- Quote variable expansions. Avoid `test && cmd` as a standalone statement under
  `set -e` (a false test exits the script); use an `if` block.
- Reuse helpers from `scripts/lib/sentinel-shield-common.sh`
  (`log_info/warn/error`, `die`, `command_exists`, `ensure_dir`, `bool_value`,
  `timestamp_utc`).

## Adding things

- **A profile:** add `profiles/<stack>/` with configs and a `README.md`; keep
  defaults migration-friendly and document tuning.
- **A Semgrep rule:** add to the appropriate `semgrep/app/<lang>/*.yml` (or
  `semgrep/supply-chain/third-party[-experimental]/` for supply-chain rules); use a unique
  `id`, set a sensible severity, and comment where teams should tune it. Starter
  rules, not completeness proofs.
- **An OPA policy:** add to `policies/opa/`; document the expected input shape and
  return useful deny messages.
- **A gate:** gates are defined by the resolver/enforcer key set. Adding one means
  updating `resolve-gates.sh` defaults, the `security-summary.json` schema/example,
  `enforce-gates.sh`, and the docs together. Do not add a gate in one place only.

## Local validation (run before pushing)

```sh
make validate        # sh -n on all scripts + self-test of resolve/enforce
make self-test       # resolve baseline -> enforce example summary (expect pass)
```

Or directly:

```sh
sh -n scripts/*.sh scripts/lib/*.sh
sh scripts/resolve-gates.sh --mode baseline
cp templates/security-summary.example.json reports/security-summary.json
sh scripts/enforce-gates.sh --format all
```

If you change JSON/YAML/XML, validate it (the repo includes example commands in the
relevant docs). Generated artifacts under `reports/` are git-ignored — do not commit
them.

## What gets rejected

- Fabricated or unpinned-without-note third-party action SHAs in sensitive workflows.
- Secrets, even in examples (use placeholders).
- New critical/high findings introduced by the change.
- Gates weakened without a rationale and, where risk is accepted, an exception
  record.
