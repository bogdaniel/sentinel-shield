# Sentinel Shield — security model: filesystem trust boundaries

Every Sentinel Shield operation that *mutates a consuming project* — installing baseline
workflows, syncing them, migrating, recovering an interrupted run, verifying downloaded release
artifacts, extracting archives, or writing a generated report / release manifest — passes each
path it touches through a single, fail-closed filesystem-safety layer. This document describes
what that layer guarantees, why, and how to invoke it.

The implementation is `scripts/lib/filesystem-safety.sh` (POSIX `sh`, source-only). It
generalises the physical-containment validator proven for transactions
(`scripts/lib/transaction.sh :: _tx_contained`) to **every** mutable surface, so a check that
holds for a managed-file write also holds for a lock, a journal, a snapshot, a downloaded
artifact, an extracted tree, a security report, a ref record, and a temp work dir.

## Threat model

A hostile or accidentally-misconfigured filesystem state must never let an operation:

- write or delete **outside** the project (or owned) root — via an absolute path, a `..`
  traversal, or a **symlinked** parent/final component that physically resolves elsewhere;
- treat a **non-regular** object (device, FIFO, socket, directory) as a metadata/managed file,
  or follow an **unexpected hard link** that aliases a file outside the trust root;
- write **through** a symlinked destination (e.g. a report path swapped to point at an outside
  file), or replace a file that was **swapped between validation and the write** (a TOCTOU race);
- leave sensitive metadata **group/world-writable**, owned by another user, or with an
  over-broad default mode;
- silently **clobber** one entry with another that differs only by case on a case-insensitive
  filesystem, or that collides after path normalisation;
- run a **recursive delete** against `/`, `$HOME`, the repo root, an empty argument, or any
  directory not proven to be operation-owned;
- exceed **bounded** path/filename lengths (a hostile manifest cannot blow up processing).

Every one of these fails **closed**: the operation refuses and surfaces a **stable reason code**
(see below) rather than proceeding on unverifiable state.

## Guarantees and the functions that enforce them

| Guarantee | Function | Reason code(s) on failure |
| --- | --- | --- |
| Canonical, non-symlinked trust root | `fs_canonical_root` | `FS_ROOT_SYMLINK`, `FS_ROOT_NOT_DIR`, `FS_INVALID_PATH` |
| Physical parent containment (no symlinked component, no `..`/absolute) | `fs_contained` | `FS_SYMLINK_COMPONENT`, `FS_ESCAPES_ROOT`, `FS_INVALID_PATH` |
| No-follow expectation (lstat guard — POSIX has no `O_NOFOLLOW`) | `fs_assert_not_symlink` | `FS_IS_SYMLINK` |
| Regular-file-only (reject device/FIFO/socket/dir) | `fs_assert_regular`, `fs_assert_no_special` | `FS_NOT_REGULAR`, `FS_SPECIAL_FILE`, `FS_IS_SYMLINK` |
| No unexpected hard link on sensitive files | `fs_assert_single_link` | `FS_UNEXPECTED_HARDLINK` |
| Not group/world-writable metadata | `fs_assert_not_group_world_writable` | `FS_GROUP_WORLD_WRITABLE` |
| Owner consistency (where portable) | `fs_assert_owner` | `FS_OWNER_MISMATCH` |
| Restrictive default perms; preserved exec bit | `fs_apply_secret_mode`, `fs_apply_file_mode`, `fs_preserve_exec` | `FS_MODE_FAILED` |
| Safe dir creation | `fs_safe_mkdir` | `FS_MKDIR_FAILED`, plus containment reasons |
| Safe atomic replace (never through a symlink) | `fs_atomic_replace` | `FS_IS_SYMLINK`, `FS_SPECIAL_FILE`, `FS_SYMLINK_COMPONENT`, `FS_WRITE_FAILED`, `FS_MODE_FAILED` |
| Trusted-root temp creation (never `$TMPDIR`) | `fs_mktemp_dir`, `fs_mktemp_file`, `fs_assert_temp_root` | `FS_TEMP_OUTSIDE_ROOT`, `FS_MKDIR_FAILED`, `FS_ESCAPES_ROOT` |
| Case-fold / normalisation collision detection | `fs_casefold_collisions`, `fs_path_collisions`, `fs_fs_case_insensitive` | `FS_CASE_COLLISION`, `FS_PATH_COLLISION` |
| Race detection (validate vs. mutate) | `fs_identity`, `fs_verify_unchanged` | `FS_RACE_DETECTED` |
| Bounded path/name lengths | `fs_check_lengths` | `FS_PATH_TOO_LONG`, `FS_NAME_TOO_LONG` |
| Guarded recursive delete (operation-owned only) | `fs_safe_rmtree` | `FS_REFUSE_DELETE` |

### Contract

Validators **print a stable reason token to stdout and return non-zero on failure**; they print
nothing (or, for `fs_canonical_root`/`fs_mktemp_*`, the resolved path) and return `0` on success.
Callers gate on the return code and surface the token in a fail-closed diagnostic. Advisory notes
go to stderr via `log_*`. Diagnostics carry **no secrets** and no repo-local absolute paths beyond
the caller-supplied root.

### Reason-code catalog (machine-readable)

The complete, **closed** set of reason tokens is emitted by `fs_reason_codes` and cataloged in
`schemas/filesystem-safety-reasons.schema.json`. `tests/prod/252-filesystem-boundaries.sh`
cross-checks the two (jq, structural — this repo has no ajv) so the enum can never drift from the
code. Adding or renaming a token without updating the schema fails the test.

### Portable degrades (honest, never faked)

Where a platform cannot report a fact (hard-link count, numeric owner, permission bits when `ls`
output is unavailable), the corresponding check **degrades to a documented pass** rather than
fabricating a result. It never reports a boundary as *enforced* when it could not be checked; the
containment and symlink guarantees do not depend on any such degrade.

## Where it is applied

- **Downloaded artifacts + extracted archives** — `scripts/verify-release-artifacts.sh` via
  `scripts/lib/archive-safety.sh` (path traversal, symlink, duplicate, zip-bomb **and**
  case-fold collision, `archive_safety_case_scan`).
- **Generated release evidence / manifests** — `scripts/generate-release-manifest.sh` refuses a
  symlinked or special-file `--output` before writing.
- **Transaction metadata, locks, journals, snapshots, managed files** — the transaction library
  already enforces the same physical-containment invariant (`_tx_contained`); this library is the
  shared, generalised statement of it for the rest of the codebase.

See also `docs/recovery.md` (interrupted-operation recovery) and
`schemas/filesystem-safety-reasons.schema.json`.

# Sentinel Shield — security model: secret handling, environment isolation, diagnostic redaction

Alongside the filesystem trust boundary, every string Sentinel Shield **displays or persists** —
a diagnostic, a journal line, an intermediate JSON file, a generated report, a release artifact —
passes through a single, fail-closed redaction layer, `scripts/lib/redaction.sh` (POSIX `sh`,
source-only). It removes credentials and repo-local identity, and it proves, on demand, that a
produced artifact carries no confirmed secret before it is uploaded.

## Threat model

Secret material and local identity must never leak into a place an operator or a downstream
consumer can read:

- a **token** in the environment, in command output, in a URL's userinfo, or in a query parameter;
- a secret whose **value contains regex metacharacters** or sed-hostile bytes (`/`, `#`, `&`,
  backslashes, Unicode) — which must never (a) inject a pattern into the redactor or (b) break its
  own delimiters and thereby leak;
- **repo-local absolute paths** (a nested project path under `$HOME`, the repo root, a temp root),
  a **signing-key path** (SSH private key, GnuPG home) in a git error, or a user **email**;
- **registry credentials** (npm `_authToken`, Composer / registry `_password`/`_auth`, docker
  registry auth) in package-manager output;
- a **confirmed secret** written into a release artifact that is then uploaded;
- an **extremely long untrusted diagnostic line** used to blow up processing or push a secret past
  a naive truncation.

## Guarantees and the functions that enforce them

| Guarantee | Function |
| --- | --- |
| Literal, longest-value-first redaction of known secret VALUES (no regex injection) | `rd_secret_add`, `rd_redact_stream` |
| Bounded sensitive-value registry (capped count + per-value size; under-min refused) | `rd_secret_add` |
| Also redact the percent-**encoded** form of a registered value | `rd_secret_add` / `rd_urlencode` |
| Structural masking: GitHub tokens, `Authorization`, URL userinfo, npm/Composer/registry/docker auth, JWT, AWS keys, sensitive query params, SSH/GnuPG paths, emails, `NAME=VALUE` | `rd_redact_stream` (`_rd_pattern_stage`) |
| Path relativization: `$HOME`→`~`, `--target`→`<target>`, repo→`<repo>`, temp→`<tmp>` | `rd_redact_stream` |
| Extremely long line bounded AFTER literal redaction | `rd_redact_stream` (`RD_MAX_LINE`) |
| No `set -x` leakage of a secret | `_rd_harden` (`set +x`) inside every secret-handling function |
| Restrictive perms (0600) on the materialised registry temp file | `rd_mktemp` |
| Allowlisted environment for an external tool; full env never printed | `rd_run_isolated` (`env -i` + named vars) |
| Screen a produced artifact for CONFIRMED secrets; FAIL CLOSED before upload | `rd_scan_paths` |
| Machine-readable report — counts + categories, **never a value** | `rd_report_json`, `rd_scan_paths` |

### Redact before persistence, not only before display

Callers pipe intermediate JSON and journal writes through `rd_redact_stream`, so a secret value
never reaches an intermediate file — redaction is applied *before* the bytes are written, not only
before they are shown. The command-result envelope shares this exact implementation
(`scripts/lib/output-contract.sh :: oc_redact` delegates to `rd_redact_stream`).

### Fail-closed confirmed-secret gate

`rd_scan_paths` screens files/trees for **high-confidence** credential shapes (GitHub token, AWS
access key, JWT, private-key block, npm token, Slack token, Google API key) and returns non-zero if
any is present. `scripts/verify-release-artifacts.sh` runs it over every extracted artifact tree and
**rejects** the artifact (`confirmed-secret-in-artifact`) rather than backing a release with it;
`.github/workflows/ci-security.yml` runs the same scan over the normalized security summary before
upload — no `continue-on-error`, no `|| true`.

### Reason / report catalog (machine-readable)

The CLOSED set of confirmed-secret categories is emitted by `rd_scan_categories` and cataloged in
`schemas/redaction-report.schema.json`. `tests/prod/253-redaction-security.sh` cross-checks the two
(jq, structural — this repo has no ajv) so the enum can never drift from the code, and injects all
twelve required cases (token in env / output / URL userinfo / query param; regex-metacharacter and
special-char/Unicode secrets; nested home path; signing-key path; registry creds; secret in an
uploaded-artifact fixture; overlapping secrets; extremely long line), asserting removal plus a
positive control for each. The report contains **no secret value** — only counts, category names,
and bounded-registry metadata.
