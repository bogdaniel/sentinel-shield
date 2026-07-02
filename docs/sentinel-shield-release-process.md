# Sentinel Shield Release Process (v0.1.16)

> **Canonical status.** Stable line **v1.x** (latest `v1.9.2`, published) — still the latest
> stable, supported release; current development line **v2.0.0 beta** — `v2.0.0-beta.1`
> **published as a GitHub pre-release** (engine-only scope), superseding the `v2.0.0-alpha.1`
> candidate; a pre-release, not stable and not the latest release. Canonical status:
> [`product-status.md`](product-status.md).

## Release scope model (v2) — SELECTED: scoped release track

The v2 line uses the **scoped release-track** governance model (the preferred model). A release
declares a `release_scope` in its evidence file (`evidence/releases/<version>.json`) and the
readiness/evidence tooling gates against a scope-specific requirement matrix:

| `release_scope` | What beta/rc/ga require |
| --- | --- |
| `engine-only` (this cycle; set explicitly in the evidence files) | The engine's OWN green default-branch CI, recorded in `engine_ci[]` and GitHub-verified (successful `ci-self-test` + `ci-pipeline` at `engine_commit`). **No** Laravel/Symfony/consumer runs required; their `required_evidence` flags stay `false`; the release **cannot** claim framework-validated status and the validator prints `FRAMEWORK LIVE-VALIDATION NOT INCLUDED`. |
| `framework-validated` | Real Laravel + Symfony consumer evidence at beta; + `php_library`/`node_react`/`combined_profile` at rc; + `bootstrap_apply`/rollback dimensions at ga. |
| `full-platform` | Every supported-stack consumer run at beta and above. |

When `release_scope` is **absent** it defaults to **`framework-validated`** (the stricter track), so
a file that forgets to declare a scope is never silently downgraded to the weaker `engine-only` gate.
The shipped v2 evidence files set `release_scope` explicitly.

**This cycle ships under `engine-only`** (see [`v2-release-scope.md`](v2-release-scope.md)). Missing
evidence is never reinterpreted as success; an engine-only beta is still fail-closed on empty/failed
`engine_ci`. Enforced by `scripts/check-release-readiness.sh --scope <...>` and
`scripts/validate-release-evidence.sh`. Beta/GA framework promotion remains gated and deferred, not
removed — see [`consumer-validation-runbook.md`](consumer-validation-runbook.md).

## What must pass before a tag (BLOCKING)
1. **Shell syntax:** `for f in scripts/*.sh scripts/lib/*.sh scripts/collectors/*.sh scripts/runners/*.sh scripts/audits/*.sh; do sh -n "$f"; done`
2. **Self-test all:** `sh scripts/self-test.sh all` — **all suites green**. This already includes:
   - **Workflow sanity** (`workflow-sanity`): no `pull_request_target`, minimal permissions, DAST
     allowlist required, AI review non-gating.
   - **Fixture install/sync tests** (`fixtures` + `install-sync`): dry-run writes nothing, `--apply`
     creates expected files, `accepted-risks.json` never created, sync drift detected/cleared.
   - **Raw report contract tests** (`lifecycle` + `scanner-matrix`): collectors normalize
     `templates/raw/*` into a schema-valid summary; missing artifact → `unavailable`, invalid → exit 2.
3. **JSON valid:** schemas + templates + profiles (incl. all `profile.manifest.json`).
4. **YAML valid:** github + templates + examples + profiles + semgrep.
5. **Adapter syntax:** `node --check scripts/adapters/*.mjs`.
6. **Changelog updated:** a new `CHANGELOG.md` version section exists; released sections untouched.
7. **Tag immutability respected:** the new tag does not reuse/force an existing released tag.
8. `ci-self-test.yml` green on the PR (the `full-self-test` job is blocking; actionlint/zizmor advisory).

If any of 1–7 fails, do not tag. Docker/PHP/Node scanner binaries are NOT required for the
gate (collectors are fixture-validated); state "skipped" if unavailable locally. **No unstable
scanner binary run is part of the engine's own release gate** — by design.

## How to cut a release
1. Land changes on `master` via PR; ensure ci-self-test is green.
2. Update `CHANGELOG.md` (new version section; never edit released sections).
3. Run the validation block above locally.
4. `git tag -a vX.Y.Z -m "Sentinel Shield vX.Y.Z"`
5. `git push origin master && git push origin vX.Y.Z`
6. Publish the GitHub Release from the pushed tag. For a beta/RC candidate mark it
   **pre-release** and do **not** flag it as the latest stable release
   (`gh release create vX.Y.Z --verify-tag --prerelease --latest=false ...`). Lead the
   release body with the release-scope declaration (engine-only for the v2 cycle) and
   link the release evidence (`evidence/releases/<version>.json`,
   [`v2-merge-commit-ci-evidence.md`](v2-merge-commit-ci-evidence.md)) and the
   [migration guide](v2-migration-guide.md). Record the published Release page URL in the
   release evidence / tracking record.

### Published GitHub Releases (v2)

| Version | Stage | Published Release page |
| --- | --- | --- |
| `v2.0.0-beta.1` | beta (engine-only, pre-release) | <https://github.com/bogdaniel/sentinel-shield/releases/tag/v2.0.0-beta.1> |

## How to validate a tag
```sh
git checkout vX.Y.Z
sh scripts/self-test.sh all
```
The tag's tree must reproduce green self-test. Verify expected files:
`git ls-tree -r --name-only vX.Y.Z | grep -E 'collectors|templates/workflows|docs/...'`.

## Do NOT mutate old tags
Released tags (v0.1.0 … previous) are immutable. Never `git tag -f` an existing released tag
or force-push it. If a release is broken, cut a NEW patch tag. (The only acceptable retag is
fixing a tag created seconds ago in the SAME release that never shipped — document it.)

## Validate against a consuming fixture
```sh
T=$(mktemp -d); cp -R tests/fixtures/projects/laravel-react-docker/. "$T/"
sh scripts/install-baseline.sh --target "$T" --apply --mode baseline
sh scripts/sync-baseline.sh --target "$T"          # expect up-to-date / preserved
```
`sh scripts/self-test.sh fixtures` automates this offline. To promote a tool from
supported→proven, run it in a real consumer CI (e.g. zenchron-tools) and record the run.
