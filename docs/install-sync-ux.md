# Install / Sync Advanced UX (v1.8.0 — A09)

Closes documented install/sync UX gaps **without changing STABLE behavior** — no flag changes, no
exit-code changes. Builds on [`install-sync-guide.md`](install-sync-guide.md) and
[`install-sync-quickstart.md`](install-sync-quickstart.md).

## Listing available profiles (no new flag needed)

Profiles are discoverable on disk:

```sh
ls -d profiles/*/ profiles/combinations/*.manifest.json
# single-stack: laravel, react, node, docker, php-library, symfony, hardened-enterprise
# combinations: laravel-react-docker, node-react
```
Each has a `profile.manifest.json` (single) or `<name>.manifest.json` (combination).

## Dry-run (default; writes nothing)

```sh
sh scripts/install-baseline.sh --target <dir> --profile <name>
# -> "would write [create-if-missing]: ..." ; SUMMARY: created/would-create=N
```
Dry-run is the default — re-run with `--apply` to write.

## Apply

```sh
sh scripts/install-baseline.sh --target <dir> --profile <name> --apply --mode report-only
```
`create-if-missing` files are written once; project-local files in `never_touch` are skipped.

## Drift detect + resolve (sync)

```sh
sh scripts/sync-baseline.sh --target <dir> --profile <name>            # detect (reports managed drift)
sh scripts/sync-baseline.sh --target <dir> --profile <name> --apply --force   # resolve managed files
```
Managed-file drift is reported as `manual-review-needed (managed drift ...)`; `--force` updates managed
files. **Unmanaged and `never_touch` files are never overwritten.**

## `--force` behavior

`--force` updates **managed** files (e.g. the workflow) to the shipped version. It does **not** touch
project-local files. Use after reviewing the drift.

## `sync-managed-block` (reserved)

The `sync-managed-block` mode is **reserved** (declared in the schema; no in-place block updater ships
yet). Today, managed files are whole-file `overwrite-if-force`. Tracked in [`roadmap.md`](roadmap.md).

## Accepted-risks preservation

`.sentinel-shield/accepted-risks.json` is in every profile's `never_touch` — install/sync **never**
creates, overwrites, or prunes it. Verified across all profiles (`self-test install-matrix`,
[`install-sync-scale-v140.md`](install-sync-scale-v140.md)).

## Not changed (STABLE)

Flags, exit codes, and the four modes are unchanged. This doc is UX guidance only; the `profile list`
convenience remains documented-manual rather than a new STABLE flag (deferred — see roadmap).
