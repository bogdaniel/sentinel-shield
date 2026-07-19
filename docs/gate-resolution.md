# Gate Resolution

Sentinel Shield turns a project's declared adoption mode into concrete, enforceable
gate thresholds. This page documents the resolver: what it reads, how it resolves
values, what it produces, and how CI consumes the output.

The resolver is [`scripts/resolve-gates.sh`](../scripts/resolve-gates.sh); shared
helpers live in [`scripts/lib/sentinel-shield-common.sh`](../scripts/lib/sentinel-shield-common.sh).

> **Resolution is half the story.** This page covers turning the mode into flags.
> The companion **enforcement** layer
> ([`scripts/enforce-gates.sh`](../scripts/enforce-gates.sh)) consumes those flags
> plus a normalized `security-summary.json` and decides pass/fail. See
> [`security-summary-schema.md`](security-summary-schema.md). Flow:
> `profile.yaml → resolve-gates.sh → gates.env → + security-summary.json → enforce-gates.sh → pass/fail`.

---

## Purpose

Adoption modes were previously only documented. The resolver makes them
**machine-readable and enforceable**: it reads `.sentinel-shield/profile.yaml`,
applies the mode defaults, layers any explicit overrides, and writes normalized
artifacts that CI loads and acts on. No more "the docs say strict but CI does
something else."

---

## Profile format

The canonical profile is [`templates/profile.yaml`](../templates/profile.yaml). The
resolver reads:

```yaml
project:
  name: proxyflux
  type: laravel
  criticality: high
  owner: platform-team

gates:
  mode: baseline          # report-only | baseline | strict | regulated
  fail_on:                # optional per-gate overrides
    medium_vulnerabilities: false

reports:
  output_dir: reports     # optional; default: reports
```

`profiles:` and `exceptions:` are read where useful (profiles appear in the report)
but do not change gate resolution.

The schema-required subset of the canonical gate keys, in output order:

```txt
secrets
critical_vulnerabilities
high_vulnerabilities
medium_vulnerabilities
architecture_violations
type_errors
test_failures
unsafe_docker
unsafe_github_actions
missing_sbom
missing_release_evidence
expired_exceptions
```

---

## Mode defaults

| Gate | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| secrets | ✅ | ✅ | ✅ | ✅ |
| critical_vulnerabilities | ❌ | ✅ | ✅ | ✅ |
| high_vulnerabilities | ❌ | ✅ | ✅ | ✅ |
| medium_vulnerabilities | ❌ | ❌ | ✅ | ✅ |
| architecture_violations | ❌ | ✅ | ✅ | ✅ |
| type_errors | ❌ | ✅ | ✅ | ✅ |
| test_failures | ❌ | ✅ | ✅ | ✅ |
| unsafe_docker | ❌ | ✅ | ✅ | ✅ |
| unsafe_github_actions | ❌ | ✅ | ✅ | ✅ |
| missing_sbom | ❌ | ❌ | ✅ | ✅ |
| missing_release_evidence | ❌ | ❌ | ❌ | ✅ |
| expired_exceptions | ✅ | ✅ | ✅ | ✅ |
| production_change_without_test_change | ❌ | ❌ | ✅ | ✅ |
| missing_test_change_evidence | ❌ | ❌ | ✅ | ✅ |
| missing_behavior_specification | ❌ | ❌ | app only | app only |
| orphan_behavior_specifications | ❌ | ❌ | ❌ | ✅ |
| acceptance_test_failures | ❌ | ✅ | ✅ | ✅ |
| missing_acceptance_evidence | ❌ | ❌ | app only | app only |
| third_party_suspicious_code | ❌ | ❌ | ❌ | ✅ |
| third_party_install_script_risk | ❌ | ❌ | ✅ | ✅ |
| third_party_obfuscation | ❌ | ❌ | ❌ | ✅ |
| third_party_network_behavior | ❌ | ❌ | ✅ | ✅ |

✅ = the gate blocks the build. ❌ = report-only (does not block).

The four `third_party_*` gates (v0.1.5+) come from the **separate** third-party
supply-chain scan (see
[`third-party-supply-chain-scan.md`](third-party-supply-chain-scan.md)); v1 keeps
them non-blocking except strict (install-script + network) and regulated (all).

- **report-only** — Legacy visibility mode. Only leaked secrets and expired
  exceptions block.
- **baseline** — Migration mode. Existing debt may remain, but new high-risk issues
  do not enter.
- **strict** — Production mode. Security, quality, architecture, and SBOM evidence
  are release requirements.
- **regulated** — Compliance-heavy mode. Release evidence and SBOM are mandatory.

---

## Engineering quality gates (v2.1)

> **Unreleased, additive engine capability.** These six gate keys are **not** part of `v2.0.1`/`v2.0.0`
> and are **not** a new release claim (latest release remains `v2.0.1`, engine-only). They are additive
> to the resolver: existing gates and their mode defaults above are **unchanged**, and consumers may
> ignore them entirely. Full reference: [`engineering-quality-gates.md`](engineering-quality-gates.md).

The engineering-quality family is a **separate counter channel** from security (the two are never
folded together). The resolver emits these alongside the canonical keys, uppercased and prefixed
`SENTINEL_SHIELD_FAIL_ON_` (e.g. `SENTINEL_SHIELD_FAIL_ON_COVERAGE_THRESHOLD_VIOLATIONS`):

```txt
coverage_threshold_violations
coverage_regression
mutation_score_violations
complexity_violations
duplication_violations
dead_code_violations
missing_coverage_evidence
changed_lines_coverage_violations
missing_test_evidence
empty_test_suite
skipped_tests
focused_test_violations
skipped_test_marker_violations
debug_code_violations
large_file_violations
large_function_violations
```

Mode defaults (blocks the build?):

| Gate | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| coverage_threshold_violations | ❌ | ❌ | ✅ | ✅ |
| coverage_regression | ❌ | ❌ | ✅ | ✅ |
| mutation_score_violations | ❌ | ❌ | ❌ | ✅ |
| complexity_violations | ❌ | ❌ | ✅ | ✅ |
| duplication_violations | ❌ | ❌ | ✅ | ✅ |
| dead_code_violations | ❌ | ❌ | ❌ | ✅ |
| missing_coverage_evidence | ❌ | ❌ | ✅ | ✅ |
| changed_lines_coverage_violations | ❌ | ✅ | ✅ | ✅ |
| missing_test_evidence | ❌ | ✅ | ✅ | ✅ |
| empty_test_suite | ❌ | ✅ | ✅ | ✅ |
| debug_code_violations | ❌ | ✅ | ✅ | ✅ |
| focused_test_violations | ✅ | ✅ | ✅ | ✅ |
| skipped_test_marker_violations | ❌ | ❌ | ✅ | ✅ |
| large_file_violations | ❌ | ❌ | ✅ | ✅ |
| large_function_violations | ❌ | ❌ | ✅ | ✅ |
| skipped_tests | ❌ | ❌ | ❌ | ✅ |

✅ = the gate blocks the build. ❌ = report-only (does not block). The original six (plus
`missing_coverage_evidence`) are unchanged: `report-only`/`baseline` keep them non-blocking, `strict`
adds coverage threshold/regression, complexity, duplication, and `missing_coverage_evidence`, and
`regulated` adds mutation and dead-code. The second-round keys tighten earlier:
`focused_test_violations` blocks in **every** mode (a stray `.only()` silently disables the suite);
`changed_lines_coverage_violations`, `missing_test_evidence`, `empty_test_suite`, and
`debug_code_violations` block from **baseline** up; `skipped_test_marker_violations`,
`large_file_violations`, and `large_function_violations` block from **strict** up; `skipped_tests`
blocks only in **regulated**. `missing_coverage_evidence`, `missing_test_evidence`, and
`empty_test_suite` are boolean gates the builder (`--profile`) raises when an APPLICABLE coverage/test
tool produced no report (or ran zero tests), so strict/regulated fail on ABSENT evidence (not only on
bad results); all are additive to the resolver and a missing summary key reads as `0`/`false`.

Overrides follow the **same precedence and reporting** as every other gate: a `gates.fail_on.<key>`
value in `.sentinel-shield/profile.yaml` overrides its mode default and is reported explicitly. An
**invalid (non-boolean) override value fails closed (exit 2)**, exactly like the canonical keys. Quality
gates are **not** accepted-risk-suppressible — to stop blocking on one, set its `fail_on` flag to
`false` or drop to a lower mode. Numeric thresholds (and the coverage baseline) live in
`.sentinel-shield/quality-policy.yaml`; a malformed policy file fails closed (exit 2), an absent one
falls back to documented defaults. Missing quality summary keys are treated as `0` (additive/optional).

---

## Architecture governance gates (v2.1)

> **Unreleased, additive engine capability.** `architecture_violations` is a **canonical** gate and its
> mode defaults above are **unchanged**; v2.1 adds one new gate key alongside it and does **not** make a
> new release claim (latest release remains `v2.0.1`, engine-only). Full reference:
> [`architecture-governance.md`](architecture-governance.md).

Sentinel Shield enforces architecture governance through normalized architecture evidence. Deptrac is
the PHP structural-boundary producer. dependency-cruiser and ESLint boundaries are JS/TS producers.
Custom architecture tests can also emit the same contract. Architecture findings are a **separate
counter channel** from security (never folded into vulnerability counters). In v2.1
`architecture_violations` is the **sum** across every architecture producer, and the resolver emits one
new flag alongside the canonical keys, uppercased and prefixed `SENTINEL_SHIELD_FAIL_ON_`:

```txt
architecture_violations
missing_architecture_evidence
```

Mode defaults (blocks the build?):

| Gate | report-only | baseline | strict | regulated |
| --- | --- | --- | --- | --- |
| architecture_violations | ❌ | ✅ | ✅ | ✅ |
| missing_architecture_evidence | ❌ | ❌ | ✅ | ✅ |

✅ = the gate blocks the build. ❌ = report-only (does not block). The split is deliberate:
**baseline** fails on violations found by evidence that exists, but not on absent evidence;
**strict** and **regulated** also fail when expected evidence is missing, unavailable, or errored;
**regulated** additionally requires the raw evidence artifacts to be retained with the release
evidence. `missing_architecture_evidence` is a boolean gate the builder (`--profile`) raises when an
APPLICABLE architecture producer emitted no valid report — `optional` producers are opt-in and never
raise it. Both keys are additive to the resolver and a missing summary key reads as `0`/`false`.

Overrides follow the **same precedence and reporting** as every other gate: a `gates.fail_on.<key>`
value in `.sentinel-shield/profile.yaml` overrides its mode default and is reported explicitly, and an
**invalid (non-boolean) override value fails closed (exit 2)**:

```yaml
gates:
  mode: strict
  fail_on:
    missing_architecture_evidence: false   # temporary ramp while producers are wired up
```

Which producers are applicable comes from the profile (`category: architecture`, see
[`profile-tool-policy.md`](profile-tool-policy.md)); a project can opt out honestly in
`.sentinel-shield/architecture-policy.yaml` (`architecture.enabled: false` or
`architecture.evidence_required: false`) — that never fakes a pass.

> Architecture tools detect dependency-boundary violations, not the quality of domain modeling
> itself. Architecture governance is supported by engine tests and fixtures. Do not claim real
> consumer proof until a real Laravel/Symfony/Node consumer validation exists.

---

## Override precedence

Resolution order is strict and explicit:

1. Built-in defaults for the selected mode.
2. Values from `.sentinel-shield/profile.yaml` `gates.fail_on` override those
   defaults.
3. Invalid values fail with a clear error (invalid mode, non-boolean override).

The CLI `--mode` flag overrides the profile's `gates.mode`. An override that
differs from the mode default is reported explicitly — overrides are never hidden:

```txt
[sentinel-shield] Mode: strict
[sentinel-shield] Override: medium_vulnerabilities=false (default true)
```

The same overrides appear in the JSON `overrides` array and the Markdown report.

---

## Generated artifacts

With `--format all` (default), the resolver writes to the output directory
(`reports/` by default):

| File | Purpose |
| --- | --- |
| `sentinel-shield-gates.env` | Shell-safe `KEY=value` lines for CI to source |
| `sentinel-shield-gates.json` | Valid JSON for programmatic consumers |
| `sentinel-shield-gates.md` | Human-readable summary |

The `.env` keys are uppercase and prefixed `SENTINEL_SHIELD_`:

```env
SENTINEL_SHIELD_MODE=baseline
SENTINEL_SHIELD_PROJECT_NAME=proxyflux
SENTINEL_SHIELD_PROJECT_TYPE=laravel
SENTINEL_SHIELD_PROJECT_CRITICALITY=high
SENTINEL_SHIELD_PROJECT_OWNER=platform-team
SENTINEL_SHIELD_FAIL_ON_SECRETS=true
SENTINEL_SHIELD_FAIL_ON_CRITICAL_VULNERABILITIES=true
SENTINEL_SHIELD_FAIL_ON_HIGH_VULNERABILITIES=true
SENTINEL_SHIELD_FAIL_ON_MEDIUM_VULNERABILITIES=false
SENTINEL_SHIELD_FAIL_ON_ARCHITECTURE_VIOLATIONS=true
SENTINEL_SHIELD_FAIL_ON_TYPE_ERRORS=true
SENTINEL_SHIELD_FAIL_ON_TEST_FAILURES=true
SENTINEL_SHIELD_FAIL_ON_UNSAFE_DOCKER=true
SENTINEL_SHIELD_FAIL_ON_UNSAFE_GITHUB_ACTIONS=true
SENTINEL_SHIELD_FAIL_ON_MISSING_SBOM=false
SENTINEL_SHIELD_FAIL_ON_MISSING_RELEASE_EVIDENCE=false
SENTINEL_SHIELD_FAIL_ON_EXPIRED_EXCEPTIONS=true
```

---

## CI integration

[`.github/workflows/ci-release-gate.yml`](../.github/workflows/ci-release-gate.yml):

1. Runs the resolver and uploads the three artifacts.
2. Appends `sentinel-shield-gates.env` to `$GITHUB_ENV`.
3. Enforces the **evidence-presence** gates it can verify directly:
   - `missing_sbom` → `reports/sbom.spdx.json`
   - `missing_release_evidence` → `reports/release-evidence.md`
4. For **scanner-result** gates (secrets, vulnerabilities, type errors, tests,
   architecture, unsafe Docker/Actions) it surfaces an optional aggregated summary
   (`reports/security-summary.json`) but does **not** re-run scanners. Those gates
   are enforced in their own workflows (`ci-security.yml`, `ci-php.yml`,
   `ci-node.yml`, `ci-docker.yml`).

> The evidence file paths above are PLACEHOLDERS for the first version. A consuming
> project wires its real SBOM / evidence / summary artifacts into those paths.

A minimal consumer in any workflow:

```yaml
- run: sh scripts/resolve-gates.sh --output-dir reports
- run: cat reports/sentinel-shield-gates.env >> "$GITHUB_ENV"
- run: |
    if [ "$SENTINEL_SHIELD_FAIL_ON_MISSING_SBOM" = "true" ] && [ ! -f reports/sbom.spdx.json ]; then
      echo "::error::SBOM required"; exit 1
    fi
```

---

## Mode controls the summary fallback

The resolved mode does more than pick thresholds — it decides whether a missing
findings document may fall back to the example. The release gate runs
[`scripts/select-security-summary.sh`](../scripts/select-security-summary.sh), which
reads `SENTINEL_SHIELD_MODE` from the resolved env:

| Mode | No real `security-summary.json` |
| --- | --- |
| `report-only` | warn, use the all-zero example, continue |
| `baseline` / `strict` / `regulated` | **fail** (the example is not evidence) |

So `report-only` can demonstrate the pipeline without scanners, while
`baseline`+ require real, scanner-produced findings — fail-closed. See
[`scanner-normalization.md`](scanner-normalization.md) and
[`security-summary-schema.md`](security-summary-schema.md).

In the recommended combined pipeline
([`.github/workflows/ci-pipeline.yml`](../.github/workflows/ci-pipeline.yml)) the
`release-gate` job consumes the **real** `sentinel-shield-security-summary` artifact
produced by its `build-security-summary` dependency (same run, `needs:`), then runs
`resolve-gates.sh → select-security-summary.sh → enforce-gates.sh`. Because the
build job is a dependency, a real summary is always present for `baseline`+.

Gate resolution is exercised on every push/PR by the self-test
([`.github/workflows/ci-self-test.yml`](../.github/workflows/ci-self-test.yml)): its
`lifecycle` job runs `resolve-gates.sh` against `templates/profile.yaml`, and its
`fallback-policy` job asserts that the resolved mode drives the correct fail-closed
behavior. So this resolution logic is continuously verified, not just documented.

The `negative-policy` job proves the mode→threshold mapping with a controlled
experiment: the **same** finding (a single medium vulnerability) is enforced under
two modes — `baseline` (medium not gated → **pass**) and `strict` (medium gated →
**fail**). Same input, different mode, opposite outcome: evidence that resolution
actually changes enforcement.

## Fallback parser limitations

The resolver prefers **mikefarah `yq` v4** when it is installed. Otherwise it uses a
limited awk/sed parser that understands **only the canonical profile structure**:

- 2-space indentation.
- `key: value` scalars under `project:`, `gates:`, `gates.fail_on:`, `reports:`.
- a simple `profiles:` list of `- value` items.

It does **not** support, and will refuse (asking for `yq`) when it detects:

```txt
anchors (&) and aliases (*)
inline/flow collections: { ... } or [ ... ]
block scalars: | or >
quoted booleans: "true" / 'false'
nested complex values beyond the canonical format
```

This is deliberate: the resolver is not a general YAML parser. Keep the profile
canonical, or install `yq`.

---

## Common failure modes

| Symptom | Cause | Fix |
| --- | --- | --- |
| `invalid mode '<x>'` | `gates.mode` / `--mode` not one of the four modes | Use a valid mode |
| `invalid boolean for gates.fail_on.<k>` | Override value is not true/false | Use `true` or `false` |
| `profile uses advanced YAML…` | Fallback parser hit an unsupported feature | Install `yq` v4 or simplify the profile |
| `profile not found … --require-profile` | No profile and `--require-profile` set | Create the profile or drop the flag |
| All gates `false` except secrets | No profile present → report-only defaults | Add `.sentinel-shield/profile.yaml` |

---

## Examples

```sh
# Resolve using the project profile (default path), all formats.
sh scripts/resolve-gates.sh

# Force strict mode regardless of the profile, JSON only.
sh scripts/resolve-gates.sh --mode strict --format json

# Use a profile elsewhere, write artifacts to a custom directory.
sh scripts/resolve-gates.sh --profile ci/profile.yaml --output-dir build/gates

# Fail if the profile is missing (CI hardening).
sh scripts/resolve-gates.sh --require-profile
```

---

## Testing discipline gates (v2.2.0)

> **Additive engine capability.** Six gates cover TDD proxies, BDD specification evidence and
> ATDD acceptance evidence. All are optional: an older summary that omits them stays valid, and
> an absent key reads as `0` / `false`.

```txt
production_change_without_test_change
missing_test_change_evidence
missing_behavior_specification
orphan_behavior_specifications
acceptance_test_failures
missing_acceptance_evidence
```

`app only` in the matrix above means the gate defaults to `true` for **application** profiles
(`laravel`, `symfony`, `node`, `react`, `laravel-react-docker`, `node-react`,
`hardened-enterprise`, or an application `project.type`) and `false` otherwise. Libraries are
not forced to carry BDD/ATDD by default; any project can opt in explicitly with
`gates.fail_on.missing_behavior_specification: true`.

`production_change_without_test_change` is a **TDD proxy**. TDD cannot be proven from final
code — Sentinel Shield enforces TDD evidence proxies, not developer intent. See
[`testing-discipline-governance.md`](testing-discipline-governance.md) and
[`tdd-evidence-policy.md`](tdd-evidence-policy.md).
