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

## The embedded Sentinel Shield checkout is excluded (v2.2+)

The managed workflows check Sentinel Shield out **inside the consuming repository** at
`SENTINEL_SHIELD_PATH` (default `tools/sentinel-shield`) and run Semgrep from the repository
root. Every shipped ignore template therefore excludes it:

```txt
tools/sentinel-shield/
```

Without that rule Semgrep analyzes the engine's own scripts, examples and **intentionally
insecure test fixtures** as if they were your application code. The consequences were real:
false-positive findings you cannot fix, inflated scan time and report size, findings that
change when you bump the pinned engine version, and a **required Semgrep gate failing on clean
consumer source**.

Coverage is derived, not hand-maintained: `tests/prod/283-semgrep-scope.sh` resolves every
shipped profile, installs it, and fails when a profile that selects Semgrep does not exclude
the checkout — or when an ignore file excludes consumer application source. Profiles that do
not select Semgrep (e.g. `docker`) are exempt, and that exemption comes from the resolver.

**Existing consumers.** `.semgrepignore` stays **project-owned** — `sync-baseline.sh` never
overwrites it, reorders it, or removes an entry — but the rules the template carries are
**required**, so the file is installed with the `merge-required-lines` mode: any required rule
the project file does not already contain is appended under a marker comment. The merge is
idempotent (matching is on exact rule text), so re-running changes nothing once the rules are
present:

```text
merged (required rules appended; project entries kept): .semgrepignore
up-to-date (all required rules present): .semgrepignore
```

Until the merge runs, `doctor.sh` reports the gap:

```text
WARN  .semgrepignore does not exclude the configured Sentinel Shield checkout path(s): tools/sentinel-shield
```

Run `sync-baseline.sh --apply` to close it, or add the rule yourself (one line).

**Non-default checkout path.** If you change `SENTINEL_SHIELD_PATH`, add the matching
exclusion. `doctor.sh` reads the path from your installed workflows and names the exact rule
to add — it does not assume the default.

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

## Image version (v0.1.18)
Use `SENTINEL_SHIELD_SEMGREP_IMAGE` (default `semgrep/semgrep:1.165.0`). The older 1.90.0 PHP
parser produced PartialParsing errors on modern PHP — `.semgrepignore` does NOT fix those (they
are app-source, not vendored). See [`remediation/semgrep-parser-errors.md`](remediation/semgrep-parser-errors.md).

## Image verification (v0.1.19)
Run `sh scripts/verify-semgrep-image.sh` to check the configured `SENTINEL_SHIELD_SEMGREP_IMAGE`
parses modern PHP cleanly. 1.165.0 is fixture-verified (0 parser errors). See
[`remediation/semgrep-parser-errors.md`](remediation/semgrep-parser-errors.md).
