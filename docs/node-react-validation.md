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

Authority mapping (exactly one per repo):

| lockfile            | manager | immutable install command                       |
| ------------------- | ------- | ----------------------------------------------- |
| `package-lock.json` | npm     | `npm --prefix <dir> ci`                         |
| `pnpm-lock.yaml`    | pnpm    | `pnpm --dir <dir> install --frozen-lockfile`    |
| `yarn.lock`         | yarn    | `yarn --cwd <dir> install --immutable`          |

Resolution precedence: **explicit override → `packageManager` field → the sole
lockfile**. The chosen manager is cross-checked against the committed lockfile.

`pm_resolve <target> <mode> [override]` prints one TSV line and sets exit status:

```
ok<TAB><manager><TAB><lockfile>            exit 0
error<TAB><REASON_CODE><TAB><message>      exit 2
```

Stable reason codes (asserted by the driver):

| code                                | when                                             |
| ----------------------------------- | ------------------------------------------------ |
| `MULTIPLE_AUTHORITATIVE_LOCKFILES`  | more than one authoritative lockfile committed   |
| `MANAGER_MISMATCH`                  | chosen manager ≠ the committed lockfile          |
| `MISSING_LOCKFILE`                  | immutable mode, chosen manager has no lockfile   |
| `INVALID_MANAGER`                   | override / declared value is not npm\|pnpm\|yarn |

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

`yarn install --immutable` is the Yarn Berry (v2+) form. The sandbox ships classic
Yarn 1.22, which tolerates the flag; the `yarn.lock` variant is generated with
classic Yarn and is genuine. The engine's canonical immutable command is unchanged.
