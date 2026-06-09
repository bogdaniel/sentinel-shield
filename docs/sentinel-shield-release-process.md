# Sentinel Shield Release Process (v0.1.16)

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
