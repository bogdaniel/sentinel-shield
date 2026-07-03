# Node / React real-consumer validation

Sentinel Shield ships **genuine, runnable** Node and React consumer projects and a
driver that proves the engine's package-manager authority model and Node quality
gates against them. Nothing here is mocked at the fixture level: each consumer has a
real `package.json`, a real committed lockfile, real dev-tooling (TypeScript,
ESLint, Vitest), and passes a real install + build in this repo's sandbox.

## What lives where

```
tests/consumers/
  node-service/            TypeScript Node service (npm authoritative)
    package.json           typescript, eslint, vitest; scripts: typecheck/lint/test/audit
    package-lock.json      REAL committed lockfile (npm ci reproducible)
    tsconfig.json          strict; includes src/, excludes mutations/
    eslint.config.js       flat config; ignores mutations/
    vitest.config.ts       include src/ only
    src/index.ts           clean, strict-typed baseline (green)
    src/index.test.ts      real Vitest test
    mutations/             intentional-defect fixtures (see below)
    .gitignore             node_modules/ OUT of git
  react-app/               React + TypeScript app (npm authoritative)
    ...                    same shape; src/Badge.tsx + Badge.test.tsx (jsdom + Testing Library)
  pm-variants/             package-manager authority variants, ONE lockfile each
    npm/    package.json + package-lock.json
    pnpm/   package.json + pnpm-lock.yaml
    yarn/   package.json + yarn.lock

scripts/lib/package-manager-resolver.sh   pm_* — read-only manager authority resolver
scripts/report-consumer-validation.sh     rcv_* — shared record emitter + jq validator
schemas/consumer-validation.schema.json    record contract (jq-structural)
tests/prod/201-node-consumers.sh           the driver (auto-run by production-readiness)
```

`node_modules/` is never committed — every consumer `.gitignore`s it. The
**lockfile** is the committed artifact and the single source of package-manager
authority.

## Package-manager authority (`pm_*`)

`scripts/lib/package-manager-resolver.sh` is a sourced POSIX library. It **reads** a
project and decides which manager is authoritative and which immutable install
command reproduces the lockfile. It never writes, never runs a package manager, and
**never switches the manager**.

Authority mapping (exactly one per repo). Each manager maps to a FIXED
`immutable-command-id`; callers translate that id to a fixed command TEMPLATE via
`pm_immutable_template <command-id> <dir>` — the resolver never emits a shell
command assembled from untrusted project content:

| lockfile            | manager | immutable-command-id   | command template                                |
| ------------------- | ------- | ---------------------- | ----------------------------------------------- |
| `package-lock.json` | npm     | `npm-ci`               | `npm --prefix <dir> ci`                         |
| `pnpm-lock.yaml`    | pnpm    | `pnpm-frozen-lockfile` | `pnpm --dir <dir> install --frozen-lockfile`    |
| `yarn.lock` (modern)| yarn ≥2 | `yarn-immutable`       | `yarn --cwd <dir> install --immutable`          |
| `yarn.lock` (classic)| yarn 1 | `yarn-classic-frozen`  | `yarn --cwd <dir> install --frozen-lockfile`    |

Resolution precedence: **explicit override → `packageManager` field → the sole
lockfile**. The chosen manager is cross-checked against the committed lockfile. A
**present but invalid** `packageManager` declaration is a HARD FAILURE — it is never
silently dropped so the sole lockfile can be chosen against an explicit project intent.

`pm_resolve <target> <mode> [override]` prints one TSV line and sets exit status:

```
ok<TAB><manager><TAB><version><TAB><lockfile><TAB><immutable-command-id>   exit 0
error<TAB><REASON_CODE><TAB><message>                                      exit 2
```

`<version>` is the declared version (e.g. `10.9.3`) or `-` when none was declared.

### Supported-version policy

A machine-readable policy (`pm_policy` prints one TSV row per manager;
`pm_supported_majors <manager>` prints the accepted majors):

| manager | supported majors | Corepack? | notes                                                        |
| ------- | ---------------- | --------- | ------------------------------------------------------------ |
| npm     | 8, 9, 10, 11     | no (ships with Node) | `npm ci` immutable install                         |
| pnpm    | 8, 9, 10         | yes       | `pnpm install --frozen-lockfile`                             |
| yarn    | 1, 2, 3, 4       | yes (v≥2) | **classic** (1.x) → `install --frozen-lockfile`; **modern** (≥2) → `install --immutable` |

Accepted version syntax is `MAJOR[.MINOR[.PATCH]]` with an optional `-prerelease`
tag; a Corepack integrity suffix (`+sha…`) is tolerated and ignored. Yarn CLASSIC
and MODERN are DISTINCT policies with different immutable commands and command-ids.

Stable reason codes (asserted by the driver):

| code                                 | when                                                       |
| ------------------------------------ | ---------------------------------------------------------- |
| `MULTIPLE_AUTHORITATIVE_LOCKFILES`   | more than one authoritative lockfile committed             |
| `MANAGER_MISMATCH`                   | chosen manager ≠ the committed lockfile, or a CLI override conflicts with the declaration |
| `MISSING_LOCKFILE`                   | immutable mode, chosen manager has no lockfile             |
| `INVALID_MANAGER`                    | CLI override value is not npm\|pnpm\|yarn                  |
| `MALFORMED_PACKAGE_JSON`             | `package.json` exists but is not valid JSON                |
| `INVALID_PACKAGE_MANAGER_DECLARATION`| `packageManager` present but not `name@version` (missing name/version, non-string, whitespace/command-like content) |
| `UNSUPPORTED_PACKAGE_MANAGER`        | declared name is not npm\|pnpm\|yarn (e.g. `bun@1.2.0`)    |
| `INVALID_PACKAGE_MANAGER_VERSION`    | declared version is not valid version syntax (e.g. `npm@not-a-version`) |
| `UNSUPPORTED_PACKAGE_MANAGER_VERSION`| version syntax valid but major outside the supported range |

## Intentional defects (mutations)

Each app consumer keeps a clean, green baseline in `src/` **and** a `mutations/`
directory holding three intentional-defect fixtures that the driver overlays into a
throwaway copy of `src/` to prove each gate catches a real fault. `mutations/` is
excluded from `tsconfig.json`, `eslint.config.js`, and `vitest.config.ts`, so the
committed baseline stays green and only the injected fault trips a gate.

| fixture             | gate      | stable reason code | isolation                          |
| ------------------- | --------- | ------------------ | ---------------------------------- |
| `type-error.ts(x)`  | typecheck | `TS_COMPILE_FAIL`  | ESLint clean (type-only fault)     |
| `lint-error.ts`     | lint      | `ESLINT_ERROR`     | tsc clean (no `noUnusedLocals`)    |
| `failing.test.ts(x)`| test      | `TEST_FAIL`        | isolated failing assertion         |

## Two validation tiers (honesty: a skip is never a pass)

`tests/prod/201-node-consumers.sh` runs two clearly separated tiers.

**STRUCTURAL (always; network-free, deterministic).** Runs under
`sh scripts/self-test.sh production-readiness`. Asserts: exactly one authoritative
lockfile per consumer + `node_modules` gitignored; positive `pm_resolve` per
variant with the manager-correct immutable command; the four negative reason codes;
one-of tool groups (Jest|Vitest, ESLint, TypeScript, npm-audit provider); mutation
wiring; and **byte-for-byte lockfile rollback** through the real
`scripts/bootstrap-profile-tools.sh` engine with fault-injected manager stubs (the
real committed `package-lock.json` is mutated by a failing install and restored
byte-for-byte; reconstruction uses `npm ci`; pnpm/yarn are never invoked — no
manager switch).

**LIVE (opt-in: `SS_CONSUMER_LIVE=1`; needs toolchain + network).** Runs a real
`npm ci` from the committed lockfile, asserts a GREEN baseline
(typecheck/lint/test), then overlays each mutation and asserts it FAILS at the
correct gate with the stable reason code. When the flag is unset these checks are
emitted as explicit `LIVE_UNAVAILABLE` skips — recorded as a limitation, not a pass.

```sh
# structural tier (what CI / production-readiness runs)
sh tests/prod/201-node-consumers.sh

# live tier (real install + real mutation gates)
SS_CONSUMER_LIVE=1 sh tests/prod/201-node-consumers.sh
```

## Evidence records

Every check emits a line-delimited JSON record via `rcv_record`, conforming to
`schemas/consumer-validation.schema.json` (validated jq-structurally by
`rcv_validate` at the end of the run — no ajv). Each record carries the consumer,
package manager, check, gate, status (`pass`/`fail`/`skip`), a stable `reason_code`,
and `mode` (`live` vs `structural`) so downstream tooling can tell proven-live
evidence from structural assertion.

## Regenerating the committed lockfiles

Lockfiles are real and reproducible. To refresh them (network required):

```sh
( cd tests/consumers/node-service && rm -rf node_modules && npm install )
( cd tests/consumers/react-app   && rm -rf node_modules && npm install )
( cd tests/consumers/pm-variants/npm  && npm install )
pnpm install --dir tests/consumers/pm-variants/pnpm
( cd tests/consumers/pm-variants/yarn && yarn install )
```

Commit only the lockfiles; `node_modules/` stays ignored.

## Sandbox note

`yarn install --immutable` is the Yarn Berry (v2+) form; `yarn install
--frozen-lockfile` is the classic (1.x) form. The `pm-variants/yarn` fixture
declares classic `yarn@1.22.22`, so the resolver selects the
`yarn-classic-frozen` command-id (frozen-lockfile) — the honest classic command —
rather than the modern `--immutable` flag. A modern declaration (`yarn@2/3/4`)
resolves to `yarn-immutable`. The `yarn.lock` variant is generated with classic
Yarn and is genuine.
