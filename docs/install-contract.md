# Install / sync / migrate durability contract

This is the **durability, concurrency, and crash-recovery** contract that
`scripts/install-baseline.sh`, `scripts/sync-baseline.sh`, and `scripts/migrate-v1.sh` uphold
for every `--apply` run, implemented once in the shared library `scripts/lib/transaction.sh`
and exercised by `tests/prod/251-transaction-durability.sh` (plus `120`, `121`, `210`, `211`).
It is the production hardening layered on top of the logical-rollback contract described in
[`recovery.md`](recovery.md); read that first for the operator-facing recovery workflow.

Engine-only scope: this contract governs how the installer mutates a consuming project's files
on disk. It makes no claim about Laravel/Symfony live validation.

## Guarantees

1. **No two operations mutate one project at once.** Ownership is granted **only** by a single
   atomic `mkdir` of the mutex directory `<target>/.sentinel-shield/operation-lock.d`. `mkdir`
   is an atomic test-and-set on every POSIX filesystem: exactly one concurrent process can
   create it; every other gets a non-zero `mkdir` and **fails closed** (never writes through a
   mutex it does not own). The lock-directory contract is explicit and regression-tested — the
   engine does **not** rely on any weaker signal. A torn acquisition (mutex present, no marker
   — a crash between `mkdir` and the marker write) is itself detected and fails closed.

2. **Lock ownership is not a bare PID.** The marker records a PID-independent random **token**
   (from `/dev/urandom` where available), the **hostname** + stable `host_id`, the owning PID,
   and — where the platform exposes it — the process **start identity** (`pid_start`; Linux
   `/proc` starttime or BSD/macOS `ps -o lstart`). A recycled PID whose start identity differs
   from the recorded value is classified **stale**, not live, so PID reuse can never make an
   interrupted operation masquerade as a running one. A lock from a **different host** is never
   mistaken for a live local process.

3. **The lock marker is durable.** It is serialised to a temp file, atomically renamed over
   `operation-lock.json`, and flushed. Its `state` follows an explicit machine
   (`initializing | active | validating | committing | rolling-back | rollback-incomplete |
   completed`) whose only legal transitions are enforced — an impossible jump is rejected.

4. **Managed files are written atomically and verified.** `tx_install_file` snapshots the
   pre-write state (a **verified** `cmp` copy — a bad snapshot fails closed), writes the new
   content to a same-directory in-flight temp, flushes it, **atomically renames** it into place,
   then **post-write digest-verifies** the on-disk bytes against the source and flushes again.
   An interrupted / disk-full / permission-denied write can only ever leave the in-flight temp —
   **never a half-written managed file** — and fails closed so the transaction rolls back.

5. **The lock is never removed before the final state is durable.** Commit records `committing`
   then `completed` (each fsync'd) **before** removing the marker + mutex. A crash mid-finalise
   leaves a `completed` marker that the next run/recovery treats as **already-finished**
   (idempotent) — a committed operation is **never rolled back**.

6. **Recovery is fail-closed and idempotent.** `--recover` / `recover-operation.sh
   --resume-rollback` verifies the journal chain (tolerating only a torn trailing line),
   re-validates every path for physical containment, restores modified files, removes created
   files, and **post-verifies** the result — clearing the lock **only** when every step holds,
   otherwise retaining the lock + snapshot, stamping `rollback-incomplete`, and exiting `4`.
   Running it twice is safe: a second invocation finds nothing to do.

## Crash points and their handling

| crash point | recorded state | recovery action |
| --- | --- | --- |
| after snapshot, before write | `active` | restore snapshot (live already == snapshot), clear |
| after write, before validation | `active` | roll back to the pre-write snapshot |
| during commit | `committing` | **complete-forward** — keep the committed writes, clear the lock |
| during rollback | `rolling-back` / `rollback-incomplete` | resume and finish the rollback |
| after commit, before lock removal | `completed` | clear only (no rollback) |
| torn journal tail (interrupted append) | any | tolerated on resume; rejected on strict `--inspect` |
| partial lock write | — (invalid marker) | fail closed, retain the marker for inspection |
| torn mutex (no marker) | — | fail closed on a new run; `--recover` clears it |

## Fault-injection seams (test-only, inert by default)

`tx_install_file` honours two environment seams used **only** by
`tests/prod/251-transaction-durability.sh` to exercise fault paths deterministically; both are
no-ops unless set to the exact relative path being written:

- `SENTINEL_SHIELD_TX_SIMULATE_ENOSPC=<rel>` — simulate an interrupted / disk-full write (the
  managed file is left untouched, no partial file).
- `SENTINEL_SHIELD_TX_CORRUPT_AFTER_WRITE=<rel>` — corrupt the just-written file so post-write
  digest verification trips.

`install-baseline.sh` additionally honours `SENTINEL_SHIELD_FAULT_AFTER=<managed-target>` to
simulate a mid-operation crash after a chosen file is written (used by `120`/`210`).

## Machine-readable artifacts (jq-validated, no ajv)

| artifact | schema |
| --- | --- |
| operation lock | `schemas/operation-lock.schema.json` |
| transaction journal (JSONL) | `schemas/transaction-journal.schema.json` |
| `--inspect --format json` report | `schemas/recovery-inspection.schema.json` |

None of these contain secrets, credentials, or repo-local absolute paths beyond the
caller-supplied target. Validation is structural via `jq` filters (this repo has no ajv), matching
the pattern used elsewhere in the engine.

## Exit codes

Identical to the mutating-script contract in [`recovery.md`](recovery.md): `0` success (dry-run,
apply, or recovery); `2` invalid config/input; `4` execution error / interrupted prior operation
(stale lock — run `--recover`), a concurrent operation, or a fail-closed recovery.
