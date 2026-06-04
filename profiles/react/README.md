# React Profile

Sentinel Shield baseline for React + TypeScript (Vite or similar bundler).

## What's here

| File | Purpose |
| --- | --- |
| `eslint.config.js` | Flat config: React, hooks, jsx-a11y, XSS/DOM-safety, security |
| `tsconfig.strict.json` | Strict TypeScript for React/DOM |
| `vite.security.md` | Build-time and runtime hardening guide |

## Install

```sh
cp eslint.config.js tsconfig.strict.json /path/to/project/

npm i -D eslint typescript typescript-eslint \
  eslint-plugin-security eslint-plugin-no-unsanitized \
  eslint-plugin-react eslint-plugin-react-hooks eslint-plugin-jsx-a11y globals
```

Extend the strict TS config in your project `tsconfig.json`:

```json
{ "extends": "./tsconfig.strict.json" }
```

## Run

```sh
npx tsc --noEmit
npx eslint .
```

## Key guardrails

- `react/no-danger` — flags `dangerouslySetInnerHTML`.
- `no-unsanitized/property` & `/method` — block unsafe DOM writes.
- `no-script-url` — block `javascript:` URLs.
- `react-hooks/rules-of-hooks` — correctness of hooks.
- `jsx-a11y/*` — accessibility.

Disabling any XSS/DOM guardrail requires justification in review and, in `regulated`
mode, an exception record. See [`vite.security.md`](vite.security.md) for the runtime
side (CSP, secrets, source maps).
