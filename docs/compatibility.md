# Compatibility matrix

The single source of truth for what Sentinel Shield's **engine** runs on is the
machine-readable policy [`config/compatibility-policy.json`](../config/compatibility-policy.json)
(schema: [`schemas/compatibility-policy.schema.json`](../schemas/compatibility-policy.schema.json)).
This page is a human rendering of that file — if the two ever disagree, the JSON wins.

Two tools read the policy:

- **`sh scripts/health.sh`** — the **fail-closed compatibility gate**. It classifies the host
  and exits non-zero with a stable diagnostic when the environment is unsupported. Run it in CI
  (or before a real operation) to prove the runner is supported.
- **`sh scripts/doctor.sh`** — a supportability **report** that includes a `[compatibility]`
  section. It only hard-fails (exit 5) on a *definite* incompatibility, so it stays stable
  across hosts; `health.sh` is the strict gate.

Scope: this is the **engine** (POSIX sh + jq tooling and the CI it ships). It is **not** a claim
about running your application's framework — Laravel/Symfony live-validation is out of scope.

## How a version is classified

For every component the gate emits one of:

| Status | Meaning | Gate result |
| --- | --- | --- |
| `supported` | On a supported/tested version. | ok |
| `below-minimum` | Older than the documented minimum. | **FAIL (exit 3)** |
| `unsupported` | Explicitly outside the supported set (e.g. a rejected major). | **FAIL (exit 3)** |
| `unknown` | Value could not be recognised/parsed. | mandatory → FAIL; optional → WARN |

Every failure line carries `status=…; reason=<STABLE_CODE>; suite=<responsible validation suite>`
so the diagnostic is stable and points at the CI that guards the range.

## Gate exit codes

`sh scripts/health.sh --policy …` has its own exit vocabulary, distinct from the operational
health report. Precedence: `2 > 4 > 3 > 1 > 0`.

| Exit | Meaning | Is it a verdict? |
| --- | --- | --- |
| `0` | supported | yes |
| `1` | degraded — supported, with warnings | yes |
| `2` | invalid config or invocation | no (the gate could not run) |
| `3` | UNSUPPORTED | yes |
| `4` | UNVERIFIABLE — a bounded version probe timed out | **no** (see below) |

### Exit 4 is an environmental non-verdict

A bounded probe (`<tool> --version` under a 5s bound) that times out leaves the gate with no
classification at all. Exit 4 says *"this environment could not be judged"*, not *"this
environment is unsupported"* — the two must not be conflated:

- **The matrix does not treat it as a mismatch.** `compat-representative` pins an environment
  and asserts a classification. On exit 4 it re-probes once and, if the non-verdict persists,
  fails under `COMPAT UNVERIFIABLE` naming the runner — never under `COMPAT MISMATCH`, which
  would report a compatibility verdict the gate never reached.
- **It is never tolerated into green.** A wedged probe fails the job. The `expect_rc`
  assertion is unweakened and still applies to every verdict the gate does produce.
- **It is reachable.** `timeout`'s raw 124 used to escape the gate untranslated: the probe runs
  inside a command substitution, so the flag that maps it to exit 4 was raised in a subshell
  and discarded. `tests/prod/302-dead-gate-reachability.sh` proves exit 4 under a `timeout`
  shim, and that exits 0/1/2/3 are unchanged.

## Operating systems

| OS | Support |
| --- | --- |
| Linux | Supported (tested) |
| macOS | Supported (tested) |
| Windows | Supported **only** through a POSIX layer (Git Bash / WSL / MSYS2) |
| FreeBSD / OpenBSD / NetBSD / AIX / Solaris | Unsupported → `UNSUPPORTED_OS` |

## CPU architectures

| Arch | Support |
| --- | --- |
| `x86_64` | Supported (tested) |
| `arm64` | Supported (tested) |
| `i386` / `armv6l` / `armv7l` / `ppc64le` / `s390x` / `riscv64` | Unsupported → `UNSUPPORTED_ARCH` |

## Shells

All engine scripts are POSIX `sh`. Supported: `sh`, `bash`, `dash`, `ash`, `busybox`, `zsh`.
Refused (non-POSIX): `csh`, `tcsh`, `fish`, `powershell`/`pwsh`, `cmd` → `UNSUPPORTED_SHELL`.

## Tool versions

| Tool | Minimum | Tested | Mandatory | Unsupported → reason |
| --- | --- | --- | --- | --- |
| Git | 2.20 | 2.34, 2.39, 2.43, 2.45 | yes | `UNSUPPORTED_GIT_VERSION` |
| jq | 1.6 | 1.6, 1.7, 1.7.1 | yes | `UNSUPPORTED_JQ_VERSION` |
| Docker | 20.10 | 20.10–27.0 | no (per-profile) | `UNSUPPORTED_DOCKER_VERSION` / absent-when-required → `DOCKER_REQUIRED_ABSENT` |
| PHP | 8.1 | 8.1–8.4 (major 8) | no (PHP stacks) | `UNSUPPORTED_PHP_VERSION` |
| Node | 18.0 | 18/20/22 LTS | no (Node stacks) | `UNSUPPORTED_NODE_VERSION` |
| npm | 8.0 | majors **8–11** | no | `UNSUPPORTED_NPM_VERSION` |
| pnpm | 8.0 | majors **8–10** | no | `UNSUPPORTED_PNPM_VERSION` |
| Yarn | 1.22 | majors **1–4** | no | `UNSUPPORTED_YARN_VERSION` |
| Composer | 2.2 | 2.2–2.8 (major 2) | no | `UNSUPPORTED_COMPOSER_VERSION` |

Node is restricted to even-numbered Active/Maintenance LTS lines (18, 20, 22); odd-numbered
current lines (19, 21, 23) are refused. Yarn Classic (1.x) and Modern (2–4) both work and resolve
to **distinct** immutable-install commands (`--frozen-lockfile` vs `--immutable`).

## Filesystem assumptions

- UTF-8 paths; POSIX permissions; atomic `rename()` within a directory; symlink creation allowed.
- **Case-insensitive filesystems** (macOS default APFS/HFS+) are a **warning**, not a failure
  (`CASE_INSENSITIVE_FS`): managed files use case-unique lowercase names.

## Network

The gate is **offline-capable** (`doctor`, `health`, gate resolution over cached reports). A run
that performs an **online-only** operation (engine `git clone`/`fetch`, Docker image pulls,
Dependency-Check NVD sync, package-registry installs) should be invoked with
`sh scripts/health.sh --policy config/compatibility-policy.json --require-network`; an offline host
then fails with `NETWORK_REQUIRED_OFFLINE`. (`--require-network` is only valid together with
`--policy`; without it the script runs the operational health report and rejects the flag.)

## GitHub-hosted runner images

| Support | Images |
| --- | --- |
| Supported | `ubuntu-22.04`, `ubuntu-24.04`, `ubuntu-latest`, `macos-14`, `macos-15`, `macos-latest` |
| Tested | `ubuntu-22.04`, `ubuntu-24.04` |
| Unsupported → `UNSUPPORTED_RUNNER_IMAGE` | `ubuntu-20.04`, `ubuntu-18.04`, `macos-11`, `macos-12`, `macos-13`, `windows-2019` |

Pin a dated image (e.g. `ubuntu-24.04`) rather than `*-latest` in release-critical jobs.

## Where it is enforced

- [`.github/workflows/ci-compatibility.yml`](../.github/workflows/ci-compatibility.yml) — a
  blocking deterministic unit job, a representative pairwise matrix on every PR/push, and the
  full runner-image matrix on a nightly schedule / manual dispatch.
- [`tests/prod/260-compatibility-policy.sh`](../tests/prod/260-compatibility-policy.sh) — the
  network-free contract test (positive, negative, tolerated, failure-injection, schema).

See [`docs/support-policy.md`](support-policy.md) for the deprecation/lifecycle policy.
