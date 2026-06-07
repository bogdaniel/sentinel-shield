# Third-Party Suspicious-Code Scan (v0.1.5+)

Sentinel Shield runs **two separate SAST channels**:

| Channel | Scans | Rules | Artifact | Summary keys | Default gating |
| --- | --- | --- | --- | --- | --- |
| **Application SAST** | code you own (`app/`, `Modules/`, `resources/js`, `src/`) | `semgrep/app/**` only | `reports/raw/semgrep.json` | `*_vulnerabilities` | baseline-blocking when configured |
| **Third-party suspicious scan** | dependency/vendored code (`vendor/`, `node_modules/`, `public/vendor/`, `public/js/filament/`) | `semgrep/supply-chain/third-party/**` only | `reports/raw/third-party-semgrep.json` | `third_party_*` | non-blocking by default (report-only/baseline) |

**Rule trees are physically separate (v0.1.6+):** application rules live under
`semgrep/app/` and supply-chain rules under `semgrep/supply-chain/`. The app scan
configs from `semgrep/app` and **cannot** load third-party rules; the broad/noisy
behavioral rules live in a **sibling** `semgrep/supply-chain/third-party-experimental/`
that the default third-party config does **not** load. No workflow uses the bare
`semgrep/` root as a catch-all.

They never mix: third-party findings land in their own summary keys and their own
artifact, and the app scan still excludes vendor/generated assets via `.semgrepignore`
(see [`semgrep-scoping.md`](semgrep-scoping.md)).

## Why vendor/node_modules are excluded from the normal app scan

Running the full app rule set over dependencies produces overwhelming false-positive
noise (minified bundles, framework idioms) and makes baseline SAST unusable. So app
SAST is scoped to code you own — see `semgrep-scoping.md`.

## Why that does NOT mean third-party code is ignored

Dependencies are a primary attack vector. Excluding them from *app* SAST does not
ignore them — they are covered by:

- **Trivy / composer audit / npm audit** — known-CVE dependency vulnerabilities.
- **Syft** — SBOM / component inventory.
- **Gitleaks** — secrets anywhere in the repo (broad, not narrowed).
- **This third-party suspicious scan** — *behavioral* indicators of a malicious or
  compromised package that a CVE feed would not yet know about.

## How the third-party scan works

A **separate** Semgrep run uses only `semgrep/supply-chain/third-party/*.yml` against the
dependency directories. In CI it runs from `-w /tmp` (not the repo root) with the
dependency dirs passed as **explicit targets**, so the app `.semgrepignore` (which
excludes `vendor/`/`node_modules/`) is **not** applied to this channel. Output goes
to `reports/raw/third-party-semgrep.json`; the
[`third-party-semgrep` collector](../scripts/collectors/third-party-semgrep.sh) maps
findings into four summary keys via each rule's `metadata.sentinel_shield_category`
(missing category → `third_party_suspicious_code`):

```txt
third_party_suspicious_code       eval/new Function/dynamic exec, child_process, shell_exec, unserialize, dynamic require
third_party_install_script_risk   npm pre/post/install lifecycle hooks
third_party_obfuscation           decode→eval chains, packed/long base64 blobs
third_party_network_behavior      .env reads, curl/fetch/http(s)/net/dns outbound primitives
```

## Default (high-confidence) vs experimental (opt-in) — v0.1.6+

The default config (`semgrep/supply-chain/third-party/`) is **intentionally
high-confidence** so it is usable over a real `node_modules` without drowning in
false positives:

- `js-install-scripts.yml` — npm `pre/post/install` hooks (and a higher-severity
  variant when the script runs `curl`/`wget`/`bash`/`node -e`/`child_process`/a URL).
- `js-high-confidence.yml` — decode→eval (`eval(atob(...))`, `eval(Buffer.from(...))`)
  and remote-fetch→eval.
- `php-suspicious.yml` — decode→eval chains and `preg_replace` `/e` (RCE).

The **broad** heuristics (generic `eval`/`new Function`, dynamic `require`,
`child_process`, generic outbound network, `.env` read, long-base64) are **opt-in** in
the sibling `semgrep/supply-chain/third-party-experimental/`. In one real rollout the
generic `require(var)` rule alone produced ~10.5k false positives across CommonJS
bundles — that is why it is not in the default set. Opt in for a focused audit:

```sh
semgrep --config <…>/semgrep/supply-chain/third-party-experimental \
  --exclude '*.min.js' --exclude dist --exclude build --exclude coverage <targets>
```

Both trees map to the same `third_party_*` categories via
`metadata.sentinel_shield_category`, so enabling experimental rules does not change the
summary schema — only the counts.

## What it detects / does NOT detect

**Detects (default, high-confidence):** npm install hooks (and risky install commands),
decode→eval obfuscation (JS + PHP), `preg_replace` `/e`, remote-fetch→eval. **Opt-in
(experimental):** generic eval/`new Function`/dynamic `require`, `child_process`/
`shell_exec`, `.env` reads, generic outbound network, long-base64 blobs.

**Does NOT detect (be honest):** novel/obfuscated malware that avoids these patterns,
logic-only backdoors, compromised binaries/postinstall payloads fetched at runtime,
typosquatting, dependency confusion, or anything in compiled/native code. **This is a
triage aid, not a guarantee** — it will miss real attacks and will flag benign code.

## Why it is separate from Trivy / composer audit / npm audit

Those answer “does this dependency have a *known CVE*?” (version/advisory lookups).
This scan answers “does this dependency *behave* suspiciously?” (code patterns). They
are complementary; **this does not replace them**, and they remain the source of truth
for dependency CVEs, SBOM, and secrets.

## When to run it

- **report-only / baseline:** visible, non-blocking — review findings out of band.
- **scheduled:** good for a nightly/weekly job and on dependency-change PRs (lockfile
  diffs), where new install hooks / behaviors are most interesting.
- **strict:** blocks the higher-confidence signals (`install_script_risk`,
  `network_behavior`) when configured.
- **regulated:** blocks all four categories by default (override via accepted-risk
  policy / gate flags).

## How to interpret findings

1. **Triage by category + confidence.** `install_script_risk` and decode→eval
   (`obfuscation`, ERROR) are the highest-signal; generic `eval` in a bundle is often
   benign.
2. **Look at the package + path**, not just the count. A hit in a well-known library’s
   minified bundle is usually noise; a hit in a small, recently-added dependency is
   worth real attention.
3. **Correlate** with composer/npm audit and the lockfile diff.

## Avoiding noise from bundled/minified code

- The `obfuscation` long-base64 rule is `LOW` confidence and **non-blocking** outside
  regulated; expect minified-bundle hits.
- Prefer enabling gating only for `install_script_risk` / `network_behavior` first.
- Scope further via the `supply_chain.third_party_sast.paths` in `profile.yaml`, or
  drop a path from the explicit target list.

## Why dependency CVEs are still handled elsewhere

CVE detection needs an advisory database and exact version matching — that is Trivy /
composer audit / npm audit, not pattern matching. This scan deliberately does **not**
attempt CVE detection; keep those scanners enabled.

## Configuration

`templates/profile.yaml`:

```yaml
supply_chain:
  third_party_sast:
    enabled: true
    mode: report-only      # disabled | report-only | scheduled | strict | regulated
    paths: [vendor/**, node_modules/**, public/vendor/**, public/js/filament/**]
    high_confidence_blocking: false
```

Gate flags (resolved by adoption mode; override under `gates.fail_on`):
`third_party_suspicious_code`, `third_party_install_script_risk`,
`third_party_obfuscation`, `third_party_network_behavior`. v1 defaults — report-only:
all false; baseline: all false; strict: install_script_risk + network_behavior true;
regulated: all true. Accepted-risk suppression for these gates may come later; **v1
keeps them report-only unless explicitly configured**, and **secrets are never
suppressible**.
