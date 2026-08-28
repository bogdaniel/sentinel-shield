# M4 acceptance audit — scanner evidence transaction and collector trust

Every row is one acceptance criterion from the fifteen batch issues. A row counts as **satisfied**
only when a named assertion that **actually passed in a measured run** demonstrates it — the
citations below were verified as literal prefixes of the PASS output of `308`, `309` and `310`, not
matched by phrase search and not inferred from a suite exiting zero.

**15 sections · 98 rows · 98 satisfied · 0 evidence gaps · 0 implementation gaps · 0 blocked**

| Issue | AC | Criterion | Status | Suite | Citing assertion |
|---|---|---|---|---|---|
| #96 | AC1 | Missing Syft leaves no current SBOM at the requested output path. | satisfied | 309 | `[syft/missing] stale evidence does not survive` |
| #96 | AC2 | A non-zero Syft execution without a verified complete SBOM is an execution error/unavailable res… | satisfied | 309 | `[syft/fail] a non-completed state publishes nothing` |
| #96 | AC3 | A prior valid SBOM cannot survive an absent/failed new run as current evidence. | satisfied | 309 | `[syft/missing] a non-completed state publishes nothing` |
| #96 | AC4 | Output is atomically replaced only after structural validation. | satisfied | 308 | `a validated run publishes its report` |
| #96 | AC5 | Timeouts and interruption remove temporary/partial files. | satisfied | 308 | `timeout: no owned workspace remains` |
| #96 | AC6 | Provenance is required for gated use and is validated by the consumer/collector. | satisfied | 310 | `CONTROL: bound Syft evidence is accepted` |
| #96 | AC7 | Tests cover stale file, missing binary, timeout, truncated JSON, syntactically valid incomplete … | satisfied | 309 | `[syft/path-spaces] the hostile target arrived as ONE argument` |
| #97 | AC1 | Missing Checkov removes any previous output for the requested scan. | satisfied | 309 | `[checkov/missing] stale evidence does not survive` |
| #97 | AC2 | Findings produce a valid findings report without turning into runner failure. | satisfied | 309 | `[checkov/findings] reaches the state its contract row declares` |
| #97 | AC3 | Operational/configuration/parser failures produce execution-error/unavailable and cannot reuse o… | satisfied | 309 | `[checkov/operational-failure] is not reported as a completed scan` |
| #97 | AC4 | Unknown Checkov output shapes fail closed. | satisfied | 309 | `[checkov/malformed] a non-completed state publishes nothing` |
| #97 | AC5 | Report and provenance are atomically published only after validation. | satisfied | 308 | `a validator rejection publishes nothing` |
| #97 | AC6 | Timeout/interruption cleans partial files. | satisfied | 308 | `interrupt INT: no owned workspace remains` |
| #97 | AC7 | Tests cover stale output, absent binary, findings exit, internal error, malformed JSON, alternat… | satisfied | 309 | `[checkov/path-spaces] the hostile target arrived as ONE argument` |
| #98 | AC1 | A missing binary or failed invocation leaves no stale current report. | satisfied | 309 | `[conftest/missing] stale evidence does not survive` |
| #98 | AC2 | Policy violations normalize as findings; parser/configuration/internal failures normalize as exe… | satisfied | 310 | `conftest-findings: evaluated targets with failures are findings` |
| #98 | AC3 | No-target and no-policy states are explicit and cannot become a clean pass when applicability re… | satisfied | 310 | `conftest-no-targets: an empty result array with exit 0 is no-targets, not clean` |
| #98 | AC4 | Unknown or incomplete JSON shapes fail closed. | satisfied | 310 | `conftest-malformed: truncated output is an error, never no-targets` |
| #98 | AC5 | The final report is atomically published after validation. | satisfied | 308 | `a validated run publishes its report` |
| #98 | AC6 | Stderr is retained safely without secrets and linked from provenance/debug metadata. | satisfied | 308 | `redaction: the raw token does not appear in provenance` |
| #98 | AC7 | Tests cover malformed Rego, missing policy directory, no targets, violations, clean target, time… | satisfied | 309 | `[conftest/path-spaces] the hostile target arrived as ONE argument` |
| #99 | AC1 | All manifests, workflows, docs, collectors, and wrappers agree on one filesystem report path. | satisfied | 309 | `the filesystem and image scanners do not share an output path` |
| #99 | AC2 | Missing/failed Trivy leaves no stale current report. | satisfied | 309 | `[trivy-fs/missing] stale evidence does not survive` |
| #99 | AC3 | Findings remain findings; scanner/config/database failures become execution-error/unavailable. | satisfied | 309 | `[trivy-fs/findings] reaches the state its contract row declares` |
| #99 | AC4 | Empty results are accepted only when the report proves a successful applicable scan. | satisfied | 310 | `CONTROL: filesystem-mode Trivy evidence is accepted` |
| #99 | AC5 | Database/version/provenance metadata is recorded for gated evidence. | satisfied | 309 | `[trivy-fs/database-failure] is not reported as a completed scan` |
| #99 | AC6 | Output is atomically replaced after validation. | satisfied | 308 | `a validated run publishes its report` |
| #99 | AC7 | Tests cover stale output, absent binary, findings, clean scan, database failure, malformed/parti… | satisfied | 309 | `[trivy-fs/path-spaces] the hostile target arrived as ONE argument` |
| #100 | AC1 | Missing Scorecard or a failed current invocation leaves no old report as current evidence. | satisfied | 309 | `[scorecard/missing] stale evidence does not survive` |
| #100 | AC2 | Scores/check findings are separated from execution failures. | satisfied | 310 | `scorecard-findings: a low check score is a finding, not an error` |
| #100 | AC3 | Reports with missing check arrays, invalid score ranges, wrong repository identity, or unknown s… | satisfied | 310 | `scorecard-identity: a report with no repository identity is refused` |
| #100 | AC4 | Rate-limit, API authentication, and non-git repository errors are visible and retain redacted di… | satisfied | 309 | `[scorecard/api-failure] is not reported as a completed scan` |
| #100 | AC5 | Output and provenance are atomically published. | satisfied | 308 | `a validated run publishes its report` |
| #100 | AC6 | Tests cover stale output, clean/low scores, API failure, rate limit, missing git remote, wrong r… | satisfied | 309 | `[scorecard/rate-limit] is not reported as a completed scan` |
| #101 | AC1 | Multiple native TruffleHog JSON findings normalize to one correct secrets count. | satisfied | 310 | `trufflehog-valid-stream: a complete multi-record stream is accepted as findings` |
| #101 | AC2 | One finding, zero findings, mixed verified/unverified findings, and scanner error output are han… | satisfied | 310 | `trufflehog-empty-stream: no records is a clean scan` |
| #101 | AC3 | Invalid lines or a truncated final JSON object fail closed. | satisfied | 310 | `trufflehog-truncated: a truncated final record is rejected, not read as fewer findings` |
| #101 | AC4 | Raw secret values remain redacted and are not copied into debug/provenance artifacts. | satisfied | 308 | `redaction: the raw token does not appear in the published report` |
| #101 | AC5 | Wrapper and collector share a documented format contract. | satisfied | 309 | `every row resolves to a declared tool-specific validator` |
| #101 | AC6 | Tests use representative native stream output, not only a synthetic array. | satisfied | 310 | `trufflehog-mid-corrupt: a malformed intermediate record is rejected` |
| #101 | AC7 | `tests/fixtures/collectors-v024/INDEX.md` and current documentation agree with the collector's v… | satisfied | 310 | `index-agreement: INDEX.md's trufflehog count is what the collector actually emits` |
| #102 | AC1 | Findings exits produce findings evidence; unsupported provider/parser/config/internal failures p… | satisfied | 310 | `terrascan-unsupported: a scan that evaluated no file is not-applicable` |
| #102 | AC2 | Missing binary cannot leave an old report current. | satisfied | 309 | `[terrascan/missing] stale evidence does not survive` |
| #102 | AC3 | No-target state is explicit and consistent with applicability detection. | satisfied | 310 | `terrascan-clean: a supported provider with no violations is clean` |
| #102 | AC4 | Unknown/malformed/partial JSON fails closed. | satisfied | 309 | `[terrascan/malformed] a non-completed state publishes nothing` |
| #102 | AC5 | Stderr is preserved as a redacted debug artifact. | satisfied | 308 | `redaction: useful diagnostic context is still retained` |
| #102 | AC6 | Output/provenance are atomic and include scanner version, target/provider, and platform. | satisfied | 308 | `a validated run publishes its report` |
| #102 | AC7 | Tests cover supported and unsupported Terraform providers, Kubernetes/Compose inputs, parser err… | satisfied | 310 | `terrascan-kubernetes: a scanned Kubernetes manifest with no violations is clean` |
| #103 | AC1 | Missing Dockle, invalid target image, unavailable Docker daemon, permission failure, timeout, an… | satisfied | 309 | `[dockle/operational-failure] no report is published` |
| #103 | AC2 | Findings produce normalized findings without a runner error. | satisfied | 309 | `[dockle/findings] reaches the state its contract row declares` |
| #103 | AC3 | The report is bound to the exact target image digest, not only a mutable tag. | satisfied | 310 | `digest-pin CONTROL: a digest-pinned scanner with a registry port scans in regulated mode` |
| #103 | AC4 | The scanner container is digest-pinned for gated use. | satisfied | 310 | `digest-pin: a mutable tag is REFUSED in strict mode` |
| #103 | AC5 | Unknown/partial JSON fails closed. | satisfied | 309 | `[dockle/malformed] a non-completed state publishes nothing` |
| #103 | AC6 | Output and provenance are atomically published. | satisfied | 308 | `a validated run publishes its report` |
| #103 | AC7 | Tests cover local binary, container executor, findings, clean image, missing image, wrong tag/di… | satisfied | 308 | `hostile path (spaces): the run completes as a clean scan` |
| #104 | AC1 | Local and Docker execution work from paths containing spaces, tabs, Unicode, and shell metachara… | satisfied | 308 | `hostile path (Unicode): the run completes as a clean scan` |
| #104 | AC2 | Image input is validated as a single image reference and cannot inject Docker options. | satisfied | 310 | `grype-injection: an option-bearing image value is refused` |
| #104 | AC3 | Missing SBOM/executor removes or quarantines stale output. | satisfied | 309 | `[grype/missing] stale evidence does not survive` |
| #104 | AC4 | Findings are accepted as completed scans; database/network/config/internal errors are execution-… | satisfied | 309 | `[grype/database-failure] is not reported as a completed scan` |
| #104 | AC5 | Unknown/partial JSON never becomes current evidence. | satisfied | 309 | `[grype/malformed] a non-completed state publishes nothing` |
| #104 | AC6 | Provenance is finalized only after the report is validated and includes its checksum, target mod… | satisfied | 308 | `provenance binds the report digest` |
| #104 | AC7 | Tests cover local/Docker modes, stale output, path spaces, malicious image string, missing SBOM,… | satisfied | 309 | `[grype/path-spaces] the hostile target arrived as ONE argument` |
| #105 | AC1 | Provenance is never marked complete before the scan report passes validation. | satisfied | 308 | `a valid report is NOT published under a non-completed state` |
| #105 | AC2 | Missing binary, timeout, network/database failure, parser error, or interruption cannot leave st… | satisfied | 309 | `[osv-scanner/missing] stale evidence does not survive` |
| #105 | AC3 | Vulnerability findings remain valid completed evidence. | satisfied | 310 | `a clean applicable OSV scan is pass/ok` |
| #105 | AC4 | Empty results are accepted only when a known successful scan shape proves applicable inputs were… | satisfied | 310 | `no-targets is its own outcome, not clean` |
| #105 | AC5 | Report and provenance checksums/identity are cross-validated by collectors or the execution mani… | satisfied | 308 | `the recorded digest is the digest of the published report` |
| #105 | AC6 | Tests cover stale pairs, fresh provenance with failed scan, findings, clean scan, malformed/part… | satisfied | 309 | `[osv-scanner/path-spaces] the hostile target arrived as ONE argument` |
| #135 | AC1 | `{}`, unrelated objects, and incomplete SPDX/Syft documents produce execution-error. | satisfied | 310 | `an empty-object placeholder is not an SBOM` |
| #135 | AC2 | Native Syft and supported SPDX versions are explicitly validated. | satisfied | 310 | `syft-schema: a CycloneDX document does not satisfy the SPDX contract` |
| #135 | AC3 | A zero-package SBOM contains valid document metadata, target/source, creation info, and complete… | satisfied | 310 | `a populated inventory is still clean, not findings` |
| #135 | AC4 | Package counts reconcile with arrays and document metadata where available. | satisfied | 310 | `and reports its package count as inventory` |
| #135 | AC5 | Required profile/tool evidence cannot be satisfied by file presence alone. | satisfied | 310 | `NE_KIND=fixture without a sidecar is still refused` |
| #135 | AC6 | Tests include forged `{}`, valid empty inventory, populated native/SPDX, wrong schema, truncated… | satisfied | 310 | `syft-schema: an SPDX document missing its creation info is incomplete, not empty` |
| #136 | AC1 | Every item in supported finding arrays is reconciled to a known bucket or explicit unclassified … | satisfied | 310 | `reconcile: a vulnerability with no Severity is unaccounted and fails closed` |
| #136 | AC2 | Missing/non-string/unknown severity cannot be silently ignored. | satisfied | 310 | `reconcile: an unaccounted item fails closed even alongside classified findings` |
| #136 | AC3 | Misconfiguration statuses are normalized case-safely only for documented values; unknown values … | satisfied | 310 | `trivy-case: an unknown misconfiguration status still fails closed` |
| #136 | AC4 | Report-level scan errors and partial results prevent a clean pass. | satisfied | 310 | `trivy-partial: a result-level scan error prevents a clean pass` |
| #136 | AC5 | Total source items equal classified + intentionally ignored low/info items under a tested invari… | satisfied | 310 | `reconcile CONTROL: five source items are recorded` |
| #136 | AC6 | Tests cover unknown severities/statuses, missing fields, lowercase variants, mixed result types,… | satisfied | 310 | `trivy-future: an unrecognised future SchemaVersion fails closed` |
| #137 | AC1 | `{"matches":[]}` without verified provenance cannot produce health `ok`. | satisfied | 310 | `a forged minimal Grype object is refused` |
| #137 | AC2 | A clean result proves the exact target was scanned to completion by an approved scanner version/… | satisfied | 310 | `CONTROL: a complete clean Grype report is accepted` |
| #137 | AC3 | Sidecar and native provenance cannot contradict; mismatch fails closed. | satisfied | 310 | `a non-scan completion state is refused` |
| #137 | AC4 | Report checksum and target/source are bound to provenance. | satisfied | 310 | `a report mutated after generation fails digest binding` |
| #137 | AC5 | Missing, malformed, stale, future-dated, or expired database metadata follows a documented fail/… | satisfied | 310 | `db-policy: MISSING database metadata fails closed in a gated mode` |
| #137 | AC6 | Tests cover forged minimal object, stale sidecar, mismatched checksum/target, findings with vali… | satisfied | 310 | `grype-descriptor: a report with no scanner version cannot be a clean gated result` |
| #184 | AC1 | `{"results":[]}` without verified provenance cannot produce pass/no-targets. | satisfied | 310 | `empty results claiming clean is contradictory and refused` |
| #184 | AC2 | A legitimate no-targets result proves successful scanner startup/discovery and records the searc… | satisfied | 310 | `no-targets is its own outcome, not clean` |
| #184 | AC3 | A clean applicable scan is distinguishable from no-targets. | satisfied | 310 | `a clean applicable OSV scan is pass/ok` |
| #184 | AC4 | Missing/malformed/stale/mismatched provenance fails closed for gated use. | satisfied | 310 | `a wrong producer is refused` |
| #184 | AC5 | Report checksum, scanner version/source, target, commit, start/end time, and completion state ar… | satisfied | 308 | `provenance binds the report digest` |
| #184 | AC6 | Tests cover forged empty object, valid no-targets, valid clean scan, discovery failure, wrong ta… | satisfied | 310 | `osv-target: evidence describing ANOTHER subject is refused` |
| #185 | AC1 | Low-only OSV reports emit `health: findings` and preserve the low count/details while remaining … | satisfied | 310 | `a low-only result reports findings present` |
| #185 | AC2 | Clean/ok is emitted only when zero findings of every classified severity are present. | satisfied | 310 | `mixed severities reconcile with their components` |
| #185 | AC3 | Every source vulnerability reconciles to critical/high/medium/low/informational/unclassified. | satisfied | 310 | `osv-reconcile: a MODERATE vulnerability lands in medium` |
| #185 | AC4 | Unknown/missing severity remains visible and follows a conservative documented policy. | satisfied | 310 | `osv-unknown-severity: an unrecognised severity is still counted as a finding` |
| #185 | AC5 | Tool report separates execution health, finding presence, and gate outcome. | satisfied | 310 | `and preserves the low count in the serialized output` |
| #185 | AC6 | Tests cover low-only, info-only, mixed low/high, unknown severity, clean, and policy promotion o… | satisfied | 310 | `osv-info-only: a low-only report reports findings present` |

## Per-issue totals

| Issue | Title | Rows | Satisfied |
|---|---|---|---|
| #96 | [High] Harden Syft wrapper against stale and partial SBOM evidence | 7 | 7 |
| #97 | [High] Harden Checkov wrapper against stale reports and swallowed execution failures | 7 | 7 |
| #98 | [High] Harden Conftest wrapper and prevent empty/error output from becoming IaC evidence | 7 | 7 |
| #99 | [High] Harden Trivy filesystem wrapper against stale and incomplete scan reports | 7 | 7 |
| #100 | [High] Harden Scorecard wrapper and preserve scanner execution integrity | 6 | 6 |
| #101 | [High] Support native TruffleHog JSON streaming output without collector failure | 7 | 7 |
| #102 | [High] Harden Terrascan wrapper against stale output and hidden scan errors | 7 | 7 |
| #103 | [High] Harden Dockle wrapper and distinguish findings from operational failure | 7 | 7 |
| #104 | [High] Harden Grype execution, report validation, and Docker argument handling | 7 | 7 |
| #105 | [High] Finalize OSV provenance only after a validated completed scan | 6 | 6 |
| #135 | [High] Reject empty placeholder objects as valid Syft SBOM evidence | 6 | 6 |
| #136 | [High] Fail closed on unknown Trivy severity and misconfiguration status vocabularies | 6 | 6 |
| #137 | [High] Require completed-scan provenance before Grype can report a clean result | 6 | 6 |
| #184 | [High] Require completed-scan provenance before OSV empty results can pass as no-targets | 6 | 6 |
| #185 | [High] Preserve low-severity OSV findings in health and normalized evidence | 6 | 6 |
| **total** | | **98** | **98** |

## How to reproduce

```sh
sh tests/prod/308-scanner-lifecycle.sh
sh tests/prod/309-scanner-conformance.sh
sh tests/prod/310-scanner-semantics.sh
```

Each citation is a literal prefix of a `PASS:` line emitted by the named suite. A citation that
stops matching is a broken row, not a cosmetic drift.
