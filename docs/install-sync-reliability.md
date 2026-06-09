# Install / Sync Reliability — Audit, Rollback, Troubleshooting, Release Checklist (v0.1.23)

Reliability companion to [`install-sync-guide.md`](install-sync-guide.md) (productization /
behavior reference) and [`install-sync-status.md`](install-sync-status.md) (per-stack coverage).
This document does **not** repeat the guide; it adds: a line-by-line **write-path audit** that
proves no overwrite risk for protected/project-local files, a **managed vs project-local table**,
a **rollback procedure**, a **troubleshooting** section, and an **install/sync release checklist**.

The executable proof for every claim here is the self-test suite:
`scripts/self-test.sh install-sync` (laravel-react-docker round-trip) and
`scripts/self-test.sh install-matrix` (docker / php-library / node-react round-trip). Every guard
quoted below is asserted by one of those suites — citations are inline.

---

## 1. Write-path audit — `install-baseline.sh`

`install-baseline.sh` is **dry-run by default**. It writes nothing unless `--apply` is passed
(`APPLY=0` default, line 22). The only function that ever writes is `do_entry()` (lines 79–102).
Every other line is argument parsing, validation, manifest resolution, or summary printing.

### 1.1 Enumerated write paths

There are exactly **two** filesystem-mutating statements in the whole script, both inside
`do_entry()` and both gated:

| # | Statement | Location | Guard that must pass first |
|---|---|---|---|
| W1 | `cp "$_src" "$_tgt"` | line 97 | not protected; source exists; mode-specific gate; `APPLY=1` |
| W2 | `awk ... > "$_tgt.tmp" && mv "$_tgt.tmp" "$_tgt"` (mode-stamp into `profile.yaml`) | line 99 | only runs after W1, i.e. only on a file the script just wrote |

`mkdir -p "$(dirname "$_tgt")"` (line 96) creates parent directories only; it never creates or
overwrites a file. W2 rewrites the file W1 just copied (`profile.yaml`) to stamp `--mode`; it
cannot reach a protected file because protected files never get past the W1 gate.

### 1.2 Proof: protected / project-local files cannot be written

**Protected set is built first** and includes hard defaults plus manifest `never_touch`:

```sh
PROTECT=" .sentinel-shield/accepted-risks.json phpstan-baseline.neon "          # line 71
for p in $(jq -r '(.never_touch // [])[]' "$MANIFEST" 2>/dev/null); do PROTECT="$PROTECT$p "; done  # line 72
is_protected() { case "$PROTECT" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }  # line 74
```

**The very first action of `do_entry()` is the protected gate**, which returns *before* reaching
either write statement:

```sh
if is_protected "$2" || [ "$(basename "$2")" = "accepted-risks.json" ]; then     # line 81
	echo "PROTECTED (project-local, never written): $2"; echo protect >> "$SUM"; return  # line 82
fi
```

This is belt-and-suspenders: a path is protected if it is in the `PROTECT` string **or** its
basename is literally `accepted-risks.json` (line 81). So `accepted-risks.json` is blocked even if
a custom manifest forgot to list it. `--force` has **no effect** here — `FORCE` is not consulted in
this branch. Asserted by `install-sync`:

> `is_check "install NEVER created accepted-risks.json" ... "no"` (self-test.sh:684)
> `is_check "install --force preserves real accepted-risks.json" "$(grep -c KEEPME ...)" "1"` (self-test.sh:689)

and by `install-matrix` for all three matrix profiles:

> `im_check "$_prof: NEVER created accepted-risks.json" ... "no"` (self-test.sh:1223)
> `im_check "$_prof: --force preserves accepted-risks.json" ... "1"` (self-test.sh:1227)

**`phpstan-baseline.neon` and `never_touch` entries** ride the same gate via the `PROTECT` string
(lines 71–72). They are never created and never overwritten regardless of `--force`.

### 1.3 Proof: create-if-missing files are never overwritten

After the protected gate and the source-exists check (line 84), the mode switch decides whether the
W1 `cp` is reachable:

```sh
create-if-missing)
	if [ -e "$_tgt" ]; then echo "skip (exists, project-owned): $2"; echo skip >> "$SUM"; return; fi ;;  # lines 87-88
```

If the target already exists, `do_entry()` returns before W1. So a `create-if-missing` file is
written **only on first install** and is project-owned thereafter — `--force` cannot reach it
(this branch never checks `FORCE`). `profile.yaml` and `accepted-risks.example.json` are
`create-if-missing`, which is why `--force` does not revert a project's edited `profile.yaml`:

> `is_check "install --force does NOT touch project-owned profile.yaml" ... "baseline"` (self-test.sh:697)

### 1.4 Proof: managed files require `--force` to overwrite

```sh
overwrite-if-force|sync-managed-block)
	if [ -e "$_tgt" ] && [ "$FORCE" -eq 0 ]; then
		echo "skip (managed, exists; use --force to update): $2"; echo managed >> "$SUM"; return  # lines 89-92
	fi ;;
```

A managed file that already exists is skipped unless `FORCE=1`. If absent, it falls through to W1
(create on first install). The managed workflow is the only thing `--force` overwrites:

> `is_check "install --force overwrites managed workflow" "$(grep -c PROJECT_EDIT ...)" "0"` (self-test.sh:696)

### 1.5 Apply gate

Even when a mode gate passes, nothing is written in dry-run:

```sh
if [ "$APPLY" -eq 0 ]; then echo "would write [$_mode]: $1 -> $2"; echo created >> "$SUM"; return; fi  # line 95
```

> `is_check "install dry-run writes no files" ... "0"` (self-test.sh:675)

**Audit conclusion (install):** every write descends from W1 (`cp`, line 97). W1 is unreachable for
(a) protected paths (line 81 returns first), (b) existing `create-if-missing` files (line 88
returns), (c) existing managed files without `--force` (line 91 returns), and (d) any path in
dry-run (line 95 returns). There is **no code path** that writes a protected/project-local file.

---

## 2. Write-path audit — `sync-baseline.sh`

`sync-baseline.sh` is a **dry-run drift report by default** (`APPLY=0`, line 19). It additionally
hard-requires an already-installed project (`.sentinel-shield/` must exist, line 47) — sync never
bootstraps. The only writing function is `sync_entry()` (lines 67–91).

### 2.1 Enumerated write paths

| # | Statement | Location | Guard that must pass first |
|---|---|---|---|
| S1 | `cp "$_src" "$_tgt"` (create a missing entry) | line 75 | not protected; source exists; target **absent**; mode≠`manual`; `APPLY=1` |
| S2 | `cp "$_src" "$_tgt"` (update a drifted managed file) | line 85 | not protected; target exists & differs; mode ∈ {overwrite-if-force, sync-managed-block}; `APPLY=1` **and** `FORCE=1` |

`mkdir -p` (line 75) only creates directories. No other line mutates the filesystem.

### 2.2 Proof: protected / project-local files are preserved

Same first-action gate as install, returning before S1/S2:

```sh
if is_protected "$2" || [ "$(basename "$2")" = "accepted-risks.json" ]; then     # line 69
	echo "project-local-preserved (protected): $2"; echo preserved >> "$SUM"; return  # line 70
fi
```

`PROTECT` is built identically (lines 61–62). `--force` is not consulted in this branch, so a
drifted `accepted-risks.json` / `phpstan-baseline.neon` / `never_touch` path is reported
`project-local-preserved` and left untouched.

> `is_check "sync preserves real accepted-risks.json" "$(grep -c KEEPME ...)" "1"` (self-test.sh:711)

### 2.3 Proof: create-if-missing drift is preserved (not overwritten)

For an existing target that differs from source, the mode switch routes `create-if-missing` to a
**preserve** branch — never to S2:

```sh
case "$_mode" in
	create-if-missing)
		echo "project-local-preserved (project owns it; NOT overwritten): $2"; echo preserved >> "$SUM" ;;  # lines 80-82
```

So an edited project-owned config (e.g. `profile.yaml`) is preserved on sync even with
`--apply --force`.

### 2.4 Managed-file drift handling — overwrite **only** with `--apply --force`

The managed branch is the **only** path to S2, and it requires both flags:

```sh
overwrite-if-force|sync-managed-block)
	if [ "$APPLY" -eq 1 ] && [ "$FORCE" -eq 1 ]; then
		cp "$_src" "$_tgt"; echo "updated (managed): $2"; echo updated >> "$SUM"          # lines 83-85
	else
		echo "manual-review-needed (managed drift; --apply --force to update): $2"; echo manual >> "$SUM"  # line 87
	fi ;;
```

- Dry-run (`APPLY=0`): managed drift is **reported only**, file unchanged.
  > `is_check "sync dry-run reports managed drift" "$_dr" "1"` (self-test.sh:702)
  > `is_check "sync dry-run does NOT modify (drift still present)" "$(grep -c DRIFT ...)" "1"` (self-test.sh:703)
- `--apply` **without** `--force`: still `manual-review-needed`, file unchanged (line 87 — the
  `else` is taken because `FORCE -eq 1` fails).
- `--apply --force`: managed file refreshed from source (S2).
  > `is_check "sync --apply --force updates managed workflow" "$(grep -c DRIFT ...)" "0"` (self-test.sh:707)

### 2.5 Creating a genuinely-missing entry (S1)

```sh
if [ ! -e "$_tgt" ]; then
	if [ "$_mode" = "manual" ]; then ... return; fi                                  # line 74
	if [ "$APPLY" -eq 1 ]; then mkdir -p "$(dirname "$_tgt")"; cp "$_src" "$_tgt"; echo "created (was missing): $2"; ...  # line 75
```

S1 only fires when the target is **absent** (so nothing is overwritten) and only in `--apply`.
Protected paths never reach here (line 69 returned). A clean install therefore reports no managed
drift on the next sync:

> `im_check "$_prof: sync reports no managed drift after install" "$_drift" "0"` (self-test.sh:1230)

**Audit conclusion (sync):** the only overwrite of an existing file is S2 (line 85), reachable
**only** for managed (`overwrite-if-force` / `sync-managed-block`) modes **and** only with
`--apply --force`. Protected paths (line 69) and `create-if-missing` drift (line 82) both route to
preserve branches before S2. There is **no code path** that overwrites a protected/project-local
file.

---

## 3. Managed-file MARKER strategy (task 18)

Sentinel Shield uses a **whole-file managed** strategy, not in-file managed blocks. A managed file
is declared `overwrite-if-force` in the profile manifest and carries a visible banner at the top so
a human knows not to hand-edit it:

```
# === MANAGED BY SENTINEL SHIELD === installed/synced via install-baseline.sh / sync-baseline.sh.
```

Verified present in the templates the manifests install:

- `templates/workflows/sentinel-shield-pr-fast.yml:2` — exact banner above.
- `templates/workflows/sentinel-shield.yml:3` — `# === MANAGED BY SENTINEL SHIELD (profile: laravel-react-docker) ===`.

**Contract:** local edits to a managed file are overwritten on `sync --apply --force` (audit §2.4).
Keep project-specific logic out of managed files; put risk decisions in the protected project-local
files (§4). The marker is documentary — the *enforcement* of "managed" is the `overwrite-if-force`
mode + the `--force` gate, not the text of the banner.

**`sync-managed-block` is RESERVED.** The manifest schema enumerates it
(`profiles/profile.manifest.schema.json`: `"enum": ["create-if-missing", "overwrite-if-force",
"sync-managed-block", "manual"]`, with the description *"sync-managed-block: managed marker block
updated in place (reserved)"*). Today both scripts treat it identically to `overwrite-if-force` —
note the shared `overwrite-if-force|sync-managed-block)` switch arms in install (line 89) and sync
(line 83). The intended future behavior — updating only an in-file marker block while preserving
surrounding local edits — is **not implemented**; until then it is whole-file managed. (Tracked in
`install-sync-status.md` Known gap #4.)

---

## 4. MANAGED vs PROJECT-LOCAL files (task 27)

The distinction is the manifest `mode` plus the hard-protected set. "Managed" = Sentinel Shield owns
the bytes and will refresh them on `--force`. "Project-local" = the consuming project owns the bytes;
the engine never overwrites them.

| File / path | Manifest mode | Category | Install behavior | Sync behavior |
|---|---|---|---|---|
| `.github/workflows/sentinel-shield.yml` | `overwrite-if-force` | **Managed** | create if absent; overwrite only with `--force` | `updated` only with `--apply --force`; else `manual-review-needed` |
| `.github/workflows/sentinel-shield-pr-fast.yml` | `overwrite-if-force` | **Managed** | same as above | same as above |
| `.sentinel-shield/profile.yaml` | `create-if-missing` | **Project-local after first write** | written once (mode stamped via line 99); never re-touched | `project-local-preserved` on drift |
| `.sentinel-shield/accepted-risks.example.json` | `create-if-missing` | **Project-local after first write** | written once | `project-local-preserved` on drift |
| `.semgrepignore` and other stack configs | `create-if-missing` | **Project-local after first write** | written once if absent | `project-local-preserved` on drift |
| `.sentinel-shield/accepted-risks.json` | hard-protected (line 71/81, 61/69) | **Project-local (protected)** | **never created** (you copy from the example when accepting a risk) | **never overwritten** — `project-local-preserved` |
| `phpstan-baseline.neon` | hard-protected (line 71, 61) | **Project-local (protected)** | **never created/overwritten** | **never overwritten** |
| manifest `never_touch` (e.g. `phpstan.neon`) | hard-protected (lines 72, 62) | **Project-local (protected)** | **never created/overwritten** | **never overwritten** |

Managed = workflow templates. Project-local = `profile.yaml` (after first write), the
accepted-risks files, and any baseline/stack config. The protected baselines/risk files are blocked
by the line-81 / line-69 gate regardless of `--force`.

---

## 5. ROLLBACK procedure (task 28)

Because install/sync only ever write (a) managed workflow templates and (b) project-local files on
their **first** creation, rollback is narrowly scoped. The protected files
(`accepted-risks.json`, baselines, `never_touch`) are **never auto-touched**, so they have nothing
to roll back.

### 5.1 Undo a managed-workflow install/update

The managed workflows live in the consuming project's git. To revert to the previous managed
content:

```sh
# inspect what changed
git -C <consumer> log --oneline -- .github/workflows/sentinel-shield.yml
# revert the install/sync commit that touched the managed workflow
git -C <consumer> revert <commit>
# or hard-restore the single file to a known-good commit
git -C <consumer> checkout <good-commit> -- .github/workflows/sentinel-shield.yml .github/workflows/sentinel-shield-pr-fast.yml
```

### 5.2 Undo a `--force` sync

A `sync --apply --force` only overwrites managed files (audit §2.4). To undo it, restore those
managed files from git (§5.1) — or re-sync against the *previous* Sentinel Shield ref:

```sh
git -C <sentinel-shield-checkout> checkout <previous-ref>
sh scripts/sync-baseline.sh --target <consumer> --apply --force   # re-writes managed files from the older ref
```

Always run a plain dry-run first (`sync-baseline.sh --target <consumer>`) to preview the drift
before re-forcing.

### 5.3 Restore-from-sync

If a managed file was hand-edited and you want Sentinel Shield's canonical version back, that *is*
the sync operation: `sh scripts/sync-baseline.sh --target <consumer> --apply --force` rewrites the
managed file from the pinned ref (S2, line 85).

### 5.4 Project-local files need no rollback

`accepted-risks.json`, `phpstan-baseline.neon`, and `never_touch` entries are never created or
overwritten by either script (audit §1.2, §2.2). An edited `profile.yaml` / stack config is
preserved on sync (`create-if-missing` → preserve, line 82). So an install or sync — even a forced
one — cannot have clobbered them, and there is nothing to restore. The self-tests pin this:
accepted-risks survives both `install --force` (self-test.sh:689) and `sync --apply --force`
(self-test.sh:711).

---

## 6. TROUBLESHOOTING (task 29)

| Symptom | Cause | Resolution |
|---|---|---|
| `error: jq is required` | `jq` not on `PATH` | Install `jq` (`brew install jq` / `apt-get install jq`). Both scripts hard-require it (install line 51; sync line 48). |
| `error: no manifest for profile '<x>'` | Wrong `--profile` name | Use a real profile. The script looks in `profiles/<name>/profile.manifest.json` then `profiles/combinations/<name>.manifest.json` (install lines 56–59; sync lines 51–54). Valid names per `install-sync-status.md`: `laravel-react-docker` (default), `react`, `node`, `docker`, `php-library`, `node-react`. |
| `error: target '<dir>' is not a directory` | `--target` missing or not a dir | Pass an existing project directory (install line 50). For sync the dir must already be installed. |
| `error: '<dir>/.sentinel-shield' not found — run install-baseline.sh first.` | Running **sync** on a project that was never installed | Run `install-baseline.sh --target <dir> --apply` first; sync never bootstraps (sync line 47). |
| Managed drift won't apply | Ran sync without `--force` (or without `--apply`) | Managed updates need **both** flags: `--apply --force`. Without `--force` you get `manual-review-needed` by design (sync line 87 / audit §2.4). |
| A protected file is "not updating" | **By design** | `accepted-risks.json`, `phpstan-baseline.neon`, and `never_touch` paths are never written, even with `--force` (line 81 / line 69). Edit them by hand; the engine intentionally stays out. |
| `profile.yaml` mode didn't change on re-install | **By design** | `profile.yaml` is `create-if-missing`; after first write it's project-owned and `--force` won't revert it (self-test.sh:697). Edit it directly, or set mode at first install via `--mode`. |
| `manifest is not valid JSON` | Corrupt/edited manifest | Validate with `jq -e . <manifest>` (install line 60; sync line 55). |
| `skip (missing in Sentinel Shield): <path>` | Manifest references a source not present in this checkout | Wrong/old Sentinel Shield ref; check out the ref that matches the manifest (install line 84; sync line 72). |

---

## 7. Install/sync RELEASE CHECKLIST (task 30)

Run before tagging an install/sync-affecting release.

1. **Self-tests green — these are the executable proof.**
   - `sh scripts/self-test.sh install-sync` — full laravel-react-docker round-trip (dry-run safety,
     mode stamping, managed-vs-project-local, accepted-risks never touched). Lines 659–715.
   - `sh scripts/self-test.sh install-matrix` — docker / php-library / node-react round-trip
     (dry-run writes nothing, managed workflow created, accepted-risks never created or clobbered).
     Lines 1209–1235.
   - (Optional sanity) `sh scripts/self-test.sh all`.
2. **Dry-run on each supported profile** and read the output:
   ```sh
   for p in laravel-react-docker react node docker php-library node-react; do
     echo "== $p =="; sh scripts/install-baseline.sh --target <fixture-copy> --profile "$p"
   done
   ```
   Confirm dry-run writes nothing and the managed vs project-local summary is correct.
3. **Confirm accepted-risks untouched** — assert no `accepted-risks.json` is created and a
   pre-existing one survives `--apply --force` (already covered by install-sync:684/689 and
   install-matrix:1223/1227, but re-confirm on any new profile/manifest).
4. **Pin `SENTINEL_SHIELD_REF`** — the installed workflow must reference a pinned ref (tag, then a
   full SHA before production), not a moving branch. (Manual step #2 in `install-sync-guide.md`.)
5. **Bump `SENTINEL_SHIELD_REF` in the managed templates** (`templates/workflows/sentinel-shield.yml`,
   `templates/workflows/sentinel-shield-pr-fast.yml`) to the new release ref so freshly-installed
   consumers and `sync --apply --force` consumers land on the right version.
6. **Verify the managed marker is intact** in both templates (`grep -n "MANAGED BY SENTINEL SHIELD"
   templates/workflows/*.yml`) so synced files stay recognizably managed.
7. **Update `install-sync-status.md`** if profile coverage or the `sync-managed-block` status
   changed.

---

## Cross-references

- [`install-sync-guide.md`](install-sync-guide.md) — behavior, file modes, manual post-install steps.
- [`install-sync-status.md`](install-sync-status.md) — per-stack coverage, known gaps, roadmap.
- [`profiles/profile.manifest.schema.json`](../profiles/profile.manifest.schema.json) — manifest schema and mode enum.
- `scripts/self-test.sh` (`install-sync`, `install-matrix`) — the executable proof for this audit.
