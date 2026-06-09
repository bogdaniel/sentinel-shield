# Install / Sync Status (v0.1.16)

Audit of whether `install-baseline.sh` + `sync-baseline.sh` can produce a **thin consumer** for
the four target stacks, the known gaps, and the manual steps still required. Honest: the engine
is `proven`; per-stack coverage is uneven.

## Current install/sync behavior

- **`install-baseline.sh`** — manifest-driven, **dry-run by default**, `--apply` to write,
  `--force` to update managed files. Stamps `--mode` into `profile.yaml`. Hard-protects
  `accepted-risks.json` / `phpstan-baseline.neon` / `never_touch` paths. Requires `jq`.
- **`sync-baseline.sh`** — non-destructive drift report; `--apply --force` updates **managed**
  files only; reports `created / updated / up-to-date / manual-review-needed /
  project-local-preserved`. Never touches project-local decisions or code.

## Supported profiles (validated dry-run, v0.1.16)

| Target stack | Profile to use | Manifest | Status |
| --- | --- | --- | --- |
| Laravel + React + Docker | `laravel-react-docker` (default) | `profiles/combinations/laravel-react-docker.manifest.json` | **proven** — full fixture round-trip in `self-test fixtures` |
| Node + React | `react` (stacks: react, node) | `profiles/react/profile.manifest.json` | **supported** — dry-run tested in `self-test fixtures`; no full round-trip |
| Docker-only | `docker` | `profiles/docker/profile.manifest.json` | **supported** — dry-run validated; not round-tripped in self-test |
| PHP library | `php-library` (**new v0.1.16**) | `profiles/php-library/profile.manifest.json` | **supported** — dry-run validated against the `php-library` fixture |

All four now produce a thin consumer (profile.yaml + accepted-risks.example + workflow +
stack-appropriate config). Dry-run output for each is reproducible via
`sh scripts/install-baseline.sh --target <fixture-copy> --profile <name>`.

## What v0.1.16 changed (safe fix)

- Added `profiles/php-library/profile.manifest.json` — a framework-free PHP profile (generic
  PHPStan, composer audit, PHPUnit adapter; **no** Larastan runner or Docker assumptions). This
  closes the "no php-library manifest" gap. Validated: valid JSON + clean dry-run on the fixture.

## Known gaps (not fixed — TODO / roadmap)

1. **No dedicated `node-react` *combination* manifest.** Node+React installs via the `react`
   profile today (which declares stacks `react, node`). It works but is non-obvious and does not
   install a Node-test adapter doc set. *TODO: add `profiles/combinations/node-react.manifest.json`
   and a fixture round-trip.* (Roadmap Phase 2.)
2. **docker-only / php-library lack a full install→sync→resolve→enforce round-trip** in
   `self-test fixtures` (only laravel-react-docker has one). They are dry-run validated only.
   *TODO: extend `run_fixtures()` to round-trip all four.* (Roadmap Phase 2.)
3. **No install manifest for Symfony / Go / Python.** Symfony has a *config* profile
   (`profiles/symfony/`) but no `profile.manifest.json`. *TODO if a consumer needs it.*
4. **`sync-managed-block` mode is reserved**, not implemented — managed files are whole-file
   `overwrite-if-force`, so a consumer cannot keep local edits inside a managed workflow. *TODO:
   implement an in-place marker-block updater.* (Roadmap Phase 2.)

## Manual steps still required after install

- Set `SENTINEL_SHIELD_REPOSITORY` + a **pinned** `SENTINEL_SHIELD_REF` in the installed workflow.
- Pin scanner action/image refs to digests ([`pinned-tool-references.md`](pinned-tool-references.md)).
- Review/edit `.sentinel-shield/profile.yaml` (name, type, criticality, mode).
- Copy `accepted-risks.example.json → accepted-risks.json` **only** when accepting a risk
  (owner-approved); the installer never does this.
- Add the project's real test step writing `reports/raw/tests.json`.

## Safe next improvements (small, low-risk)

- Add `node-react` combination manifest (mirrors `react` + Node adapter docs).
- Extend `self-test fixtures` to round-trip docker-only and php-library.
- Print the recommended `--profile` for a detected stack at the end of `detect-stack.sh`.

## Bigger improvements (roadmap)

- `sync-managed-block` in-place updater (Phase 2).
- Symfony/Go/Python install manifests (Phase 2 / Phase 6).
</content>
