# Installer / upgrade recovery, journaling, and source verification

Sentinel Shield's mutating operations — `install-baseline.sh`, `sync-baseline.sh`, and
`migrate-v1.sh` — run inside a **transaction** so an interrupted or failed run never leaves a
consuming project half-written. The transaction machinery lives in a single shared library,
`scripts/lib/transaction.sh` (POSIX sh, sourced), and is exercised by
`tests/prod/120-installer-tx.sh`, `tests/prod/121-recovery.sh`, and
`tests/prod/210-transaction-journal.sh`.

## The transaction contract

Every `--apply` run:

1. **Detects a stale lock.** If `<target>/.sentinel-shield/operation-lock.json` already exists,
   the run refuses to mutate and exits `4`, pointing you at `--recover`. A lock is left behind
   only by an ungraceful kill (SIGKILL / power loss); a graceful failure rolls itself back.
2. **Opens the transaction** (`tx_begin`): writes an atomic operation-lock
   (`schemas/operation-lock.schema.json`) and creates a per-run snapshot dir
   `<target>/.sentinel-shield/.txn-<pid>/`.
3. **Snapshots before writing** (`tx_snapshot`): each file is copied to the snapshot dir *once*,
   in its pre-write state, before it is overwritten. Files that did not previously exist are
   recorded in `created` (no copy) so recovery can tell a **modified** file (must be restored)
   from a **newly-created** file (must be removed).
4. **Commits** (`tx_commit`) on success: removes the lock and the snapshot dir.
5. **Auto-rolls-back** on a graceful failure/interrupt (the caller's `ss_cleanup` trap calls
   `tx_rollback`), then clears the lock — no manual step needed.

### Recovering an ungraceful kill

If a run was killed so hard it could not clean up, the next `--apply` sees the stale lock and
stops. Roll the partial run back with the SAME script that left the lock:

```sh
sh scripts/install-baseline.sh --target <dir> --recover
sh scripts/sync-baseline.sh    --target <dir> --recover
sh scripts/migrate-v1.sh       --target <dir> --recover
```

Recovery is **fail-closed** (`tx_recover`): it clears the lock and snapshot and exits `0` **only
when every step of the recovery contract holds** — the lock is schema-valid, its `target` matches
the current canonical target, the `snapshot_dir` is canonically contained under
`.sentinel-shield/.txn-*`, the `touched` manifest is present, every touched path is
project-relative (no `..`/absolute escape), every modified file has a snapshot to restore, and a
post-rollback verify confirms the result. On **any** failure it retains the lock **and** every
snapshot, stamps the lock `state=rollback-incomplete`, prints the exact failing path + operation
+ a manual procedure, and exits `4`. A corrupt/incomplete snapshot is treated as *potential data
loss* and never silently deleted.

### Symlink containment — the engine never follows a transaction path outside the consumer root

A lexical check (reject absolute paths and `..`) is **not** enough: a path like `a/b/c` is
lexically clean yet still escapes the target if `a` is a **symlink** to somewhere else. Every
mutating transaction path — snapshotting a pre-write file, restoring a snapshot, deleting a
newly-created file, and creating a restoration parent directory — therefore passes through a
**physical** containment validator that walks the real filesystem:

- it rejects an empty / absolute / `..`-traversal / control-character path outright
  (`INVALID_TRANSACTION_PATH`);
- it walks **every existing parent component** from the consumer root and **rejects any component
  that is a symlink** (`TARGET_SYMLINK_PARENT`), then resolves the nearest existing parent with
  `cd -P`/`pwd -P` and confirms it is the target root or below it (a brand-new destination file
  need not exist);
- on the snapshot side it verifies the `.txn-*` dir resolves under `.sentinel-shield`, that a
  snapshot entry does not traverse a symlinked parent, and that a file restore reads a **regular
  file** — a malicious symlink planted inside the snapshot is **never followed**
  (`SNAPSHOT_SYMLINK`);
- the `touched`/`created` manifests are hardened before a single entry runs: one contained
  relative path per line, a bounded line length and entry count, no duplicate line
  (`DUPLICATE_TRANSACTION_PATH`), and no path claimed as **both** newly-created and modified
  (`CONTRADICTORY_TRANSACTION_STATE`) — a malformed manifest never partially executes.

**Recovery rejects a symlinked-parent path and fails closed.** When a symlink (or a tampered
manifest) would make a rollback step land outside the consumer root, recovery does **not** skip
that entry and continue — it retains the lock **and** the snapshot, stamps the lock
`state=rollback-incomplete`, journals the exact rejected path and reason, and exits `4` so the
state is preserved for **manual inspection**. This holds whether the escape was pre-planted before
an interrupted run or introduced after the snapshot but before rollback (a TOCTOU swap): each path
is re-validated **immediately before** it is touched. During a **live** `--apply`, the same
validator aborts the operation at snapshot time and the normal auto-rollback then unwinds it — so
nothing is ever written or deleted *through* a symlink out of the target. These guarantees are
regression-tested by `tests/prod/211-transaction-symlink.sh`.

## `recover-operation.sh` — inspect and resume

`scripts/recover-operation.sh` is an operator front-end over the same library (it duplicates no
`tx_*` logic):

```sh
# Read-only: report the interrupted operation (if any) and VERIFY the journal integrity.
sh scripts/recover-operation.sh --target <dir> --inspect

# Perform the fail-closed rollback of an interrupted operation.
sh scripts/recover-operation.sh --target <dir> --resume-rollback
```

`--inspect` exits `0` when the journal is consistent, `4` when it is tampered/partial.
`--resume-rollback` delegates to `tx_recover` (exit `0` on a clean recovery, `4` otherwise).

## The append-only transaction journal

Every transaction appends structured entries to
`<target>/.sentinel-shield/transaction-journal.jsonl` — one JSON object per line, conforming to
`schemas/transaction-journal.schema.json`. Phases recorded: `start`, `precondition`, `snapshot`,
`mutation`, `validation`, `rollback-step`, `completion`.

The journal is an **audit trail**, not a control path: a journal-write failure is logged
(visible, never hidden) but never aborts a real operation. It records **no secrets and no file
contents** — only project-relative paths and short phase details.

**Integrity.** Each entry carries `prev` (the previous entry's `hash`) and `hash`
(= digest of the entry with its `hash` field removed; sha256 where available, else a `cksum:`
CRC fallback). `recover-operation.sh --inspect` rejects: a non-JSON (truncated/partial) line, a
missing/ill-typed field or unknown phase, an unsafe (absolute/`..`) path, a broken `seq`, a
broken `prev` linkage, and a recomputed-hash mismatch (in-place tampering). A keyless hash chain
detects truncation and prefix tampering; it is **not** tamper-*proof* against a full re-chaining
rewrite — anchor the journal externally (WORM storage / signed backup) if you need that.

## Optional source verification

`scripts/acquire-sentinel-shield.sh` already offers `--verify` (checkout `HEAD` == the resolved
ref commit — a commit-identity check). `--verify-source <mode>` adds **opt-in** tree/signature
verification on top, without changing existing `--ref`/`--verify` behaviour (default `none`):

```sh
sh scripts/acquire-sentinel-shield.sh --repository <owner/repo|url> --ref <tag|40-hex-sha> \
   --destination <dir> --verify --verify-source tree-checksum --expected-tree <40-hex-tree-oid>
```

| mode | what it does |
| --- | --- |
| `none` (default) | nothing beyond the existing `--verify` commit identity |
| `tree-record` | **records** the deterministic `HEAD^{tree}` object id — a fingerprint, **not** a verification (nothing is compared) |
| `tree-checksum` | **verifies**: requires `--expected-tree <hex>`, computes `HEAD^{tree}`, compares exactly, **fails closed** on mismatch (records both expected and calculated) |
| `signature` | verifies a **signed annotated tag** with `git verify-tag` (GPG **or** SSH, per Git config) and that it peels to the expected commit; **fails closed** if unsigned/bad or no verification key is available |
| `tree-checksum+signature` | both |
| `checksum` | deprecated alias for `tree-record` (record-only), kept working with a warning |

The method that passed is recorded in `.sentinel-shield-ref` as `verification_method` (and, for
`tree-checksum`, both `tree_expected` and `tree_calculated`). This is additive — readers that ignore
the fields are unaffected. A `tree-record` fingerprint is never reported as "verified".

> Environment note: `signature` verification needs a signing toolchain (GPG or SSH) plus the
> signer's public key. Where those are absent (e.g. a minimal CI sandbox), `--verify-source
> signature` **fails closed** by design rather than reporting a false pass — that is a genuine
> "cannot verify", not a success.

## Exit codes (mutating scripts)

| code | meaning |
| --- | --- |
| `0` | success (dry-run, apply, or recovery) |
| `2` | invalid config/input |
| `4` | execution error / interrupted prior operation (stale lock — run `--recover`) or a fail-closed recovery/verification |
