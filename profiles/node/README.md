# Node.js Profile

Sentinel Shield baseline for Node.js services (Node 22+, TypeScript, ESM).

## What's here

| File | Purpose |
| --- | --- |
| `eslint.config.js` | ESLint flat config with security + type-safety rules |
| `tsconfig.strict.json` | Strict TypeScript compiler options |
| `knip.json` | Unused files / deps / exports detection |
| `audit-ci.json` | `npm audit` fail thresholds for CI |

## Install

```sh
cp eslint.config.js tsconfig.strict.json knip.json audit-ci.json /path/to/project/

npm i -D eslint typescript typescript-eslint \
  eslint-plugin-security eslint-plugin-no-unsanitized globals \
  knip audit-ci prettier
```

Have your project `tsconfig.json` extend the strict base:

```json
{ "extends": "./tsconfig.strict.json" }
```

## Run

```sh
npx tsc --noEmit                 # type check
npx eslint .                     # lint (security + type rules)
npx knip                         # unused code/deps
npx audit-ci --config audit-ci.json
npm ci && npm audit              # install from lockfile, audit
```

## Assumptions

- ES modules, TypeScript, entry points under `src/`.
- `npm ci` (lockfile-based) is used in CI, not `npm install`.
- Security rules are errors by default; disabling one requires justification in
  review and, in `regulated` mode, an exception record.
