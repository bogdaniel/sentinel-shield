# Semgrep / SAST Scoping (v0.1.4+)

Semgrep analyzes **application source**. On real Laravel/React projects it was also
scanning **vendored and generated assets** — e.g. `public/js/filament/**` (Filament's
published admin JS), `vendor/`, `node_modules/`, build output — producing noisy
findings in code the team does not author. v0.1.4 ships project-local
`.semgrepignore` templates and runs Semgrep from the repo root so they take effect.

## What is excluded by default

Copy a template to your repo **root** as `.semgrepignore`
([`profiles/laravel/.semgrepignore`](../profiles/laravel/.semgrepignore),
[`profiles/react/.semgrepignore`](../profiles/react/.semgrepignore); the example ships
[`examples/laravel-react-docker/.semgrepignore`](../examples/laravel-react-docker/.semgrepignore)):

```txt
vendor/              node_modules/         storage/        bootstrap/cache/
public/js/filament/  public/vendor/        public/build/   public/hot
dist/                build/                coverage/       (React: .next/ out/ …)
```

Application source — `app/`, `Modules/`, `resources/js`, `src/`, `routes/`, `config/`
— stays scanned. React XSS, SQLi, command-injection, etc. rules remain **enabled**;
only the *paths* change.

## Scanner-specific behavior — READ THIS

`.semgrepignore` affects **Semgrep / SAST ONLY**. It does **not** narrow any other
scanner:

| Scanner | Uses `.semgrepignore`? | Still scans |
| --- | --- | --- |
| **Semgrep / SAST** | ✅ yes | application source only |
| composer audit | ❌ no | `composer.lock` dependencies |
| npm audit | ❌ no | `package-lock.json` dependencies |
| Trivy (fs/deps) | ❌ no | the tree / lockfiles / vulns |
| Syft (SBOM) | ❌ no | full dependency graph |
| **Gitleaks** | ❌ no | the **whole repo history** (broad, by design) |
| Hadolint | ❌ no | the `Dockerfile` |

- **Why dependency scanners still scan `vendor/`/`node_modules/`/lockfiles:** that is
  exactly where dependency vulnerabilities live. Excluding them from *SAST* (which
  looks for code patterns) does not reduce dependency coverage — composer/npm
  audit, Trivy, and Syft read the lockfiles/installed packages directly.
- **Why Gitleaks is NOT narrowed:** a leaked secret can hide anywhere, including a
  generated file or a committed `vendor/` artifact. Gitleaks deliberately scans
  broadly; tune it only via its own `.gitleaks.toml` allowlist, never via
  `.semgrepignore`.

> **Excluding vendor from *app* SAST does not mean third-party code is unscanned.**
> A separate **third-party suspicious-code scan** (v0.1.5+) covers `vendor/`/
> `node_modules/` with supply-chain rules in its own channel — see
> [`third-party-supply-chain-scan.md`](third-party-supply-chain-scan.md).

## How it works mechanically

The Sentinel Shield workflows run the Docker Semgrep step with `-w /src` (working
directory = repo root), so Semgrep reads `.semgrepignore` from the project root, and
config from **`semgrep/app/`** only (v0.1.6+) — never the bare `semgrep/` root, so the
app scan can never load supply-chain rules. Output stays at `reports/raw/semgrep.json`.
If there are no findings, Semgrep still writes a valid (empty-results) JSON — the
collector reports `pass`, not `unavailable`. Excluded paths simply aren't scanned;
their absence never changes tool status. The third-party channel is a **separate**
scan over dependency code (config `semgrep/supply-chain/third-party`) — see
[`third-party-supply-chain-scan.md`](third-party-supply-chain-scan.md).

## Overriding / customizing

- **Remove an exclusion:** delete the line from your `.semgrepignore` and that path
  is scanned again.
- **Add an exclusion:** append a gitignore-style pattern.
- **Scan a normally-excluded path once:** run Semgrep manually without `-w /src`, or
  temporarily comment the line.
- **Per-finding, not per-path:** prefer a narrow inline `// nosemgrep: <rule-id> --
  <reason>` over excluding a whole directory when only one line is a false positive.

## Framework-specific guidance

- **Laravel / Filament:** exclude `public/js/filament/**` and `public/vendor/**`
  (published vendor assets), plus `vendor/`, `storage/`, `bootstrap/cache/`. Keep
  `app/`, `Modules/`, `resources/js` scanned.
- **React / front-end:** exclude `node_modules/`, `dist/`, `build/`, `coverage/`,
  and framework output (`.next/`, `out/`, `.svelte-kit/`, `storybook-static/`). Keep
  `src/` / `resources/js` scanned. In a monorepo with a PHP backend, also exclude
  `vendor/`, `storage/`, `public/build/`.

> Do not exclude application source to silence findings — fix them or use a narrow,
> justified `nosemgrep`. Path exclusions are for code you do not author.
