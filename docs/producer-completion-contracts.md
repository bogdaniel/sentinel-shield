<!-- GENERATED FILE — DO NOT EDIT.
     Source: config/producer-completion-contracts.json
     Render: scripts/render-producer-contracts.sh
     tests/prod/305 fails if this file and the JSON disagree. -->

# Producer completion contracts

Canonical source: [`config/producer-completion-contracts.json`](../config/producer-completion-contracts.json).
Generated for master `f19d68ea808550964552ed64dd1464ee6b73472e`.

Canonical, machine-readable completion semantics for the nine engineering-quality runner paths. This file is the SINGLE source; docs/producer-completion-contracts.md is generated from it and never maintained beside it.

## How to read this

- **`current_process_observation`** — what the SHIPPED runner captures about the process. 'unobserved' means the status is discarded at the call site; it does NOT mean the tool's semantics are unknown.
- **`current_report_observation`** — what can be inferred from the produced report. A parseable report proves REPORT READABILITY ONLY - never full target coverage or successful execution, unless report_finalization_condition establishes it.
- **`upstream_exit_semantics`** — what the tool's own exit codes mean. 'unknown' is recorded with the missing source named, and is a different fact from the runner discarding the status.
- **`normative_completion_requirement`** — what C2 must observe before granting completed-analysis credit.
- **`implementation_status`** — implemented | partial | unobserved | unknown.

## Summary

| producer key | channel | backends | process observed today | implementation |
| --- | --- | --- | --- | --- |
| `php-mutation` | `php_mutation` | `infection` | unobserved | **unobserved** |
| `js-mutation` | `js_mutation` | `stryker` | unobserved | **unobserved** |
| `php-complexity` | `php_complexity` | `phpmd` | unobserved | **unobserved** |
| `php-duplication` | `php_duplication` | `phpcpd` | unobserved | **unobserved** |
| `js-duplication` | `js_duplication` | `jscpd` | unobserved | **unobserved** |
| `js-dead-code` | `js_dead_code` | `knip`, `ts-prune` | mixed | **partial** |
| `php-coverage` | `php_coverage` | `pest`, `phpunit` | captured-not-used | **partial** |
| `js-coverage` | `js_coverage` | `consumer package.json coverage script` | unobserved | **unobserved** |
| `php-diff-coverage` | `php_diff_coverage` | `pest`, `phpunit` | captured-not-used | **partial** |

## Contracts

### `php-mutation`

| field | value |
| --- | --- |
| runner | `scripts/runners/infection.sh` |
| channel | `php_mutation` |
| native report | `reports/raw/php-mutation.json` |
| backends | `infection` |
| backend selection | executable probe: SENTINEL_SHIELD_INFECTION_BIN, else vendor/bin/infection, else infection on PATH |
| current process observation | **unobserved** — the invocation ends in `\\|\\| true`; the process status is discarded at the call site |
| current report observation | proves **report-readable** when the Infection JSON logger parses and .stats.msi is numeric. Does NOT prove: that the mutation run covered the full target, or that it terminated normally |
| upstream exit semantics | **partially-known** — known: the runner passes --min-msi=0 SPECIFICALLY so Infection never fails the process on a low score; the threshold decision belongs to Sentinel via quality.mutation.min_score. Established from shipped code, so this part is a repository-owned contract.; unknown: which exit codes Infection uses for infrastructure failure versus completion; missing_source: no composer.lock / package-lock.json in this repository: these are consumer-side dev dependencies, so no pinned version exists here whose documented exit table could be cited |
| normative completion requirement | An observed process outcome separating a completed mutation run from one aborted, killed or timed out after flushing a partial JSON logger. A present .stats.msi is NOT sufficient. |
| timeout handling | {"status":"unobserved","note":"no bounded-process wrapper; a timeout kill is indistinguishable from completion at the call site"} |
| signal handling | {"status":"unobserved"} |
| partial reports possible | true |
| report finalization | {"status":"unknown","note":"no authoritative signal that the logger is complete rather than truncated"} |
| analyzed scope identity | {"status":"unimplemented","note":"the runner does not record which files were mutated"} |
| configuration identity | {"source":"quality.mutation.min_score via .sentinel-shield/quality-policy.yaml","digest_inputs":["the resolved quality-policy file"],"status":"partial","note":"the threshold is read but no digest is bound to the evidence"} |
| target/commit binding | {"status":"implemented-in-envelope","note":"ne_target_json binds repository/commit when CI supplies them"} |
| execution record | {"location":"reports/raw/php-mutation.execution.json","schema":"sentinel-shield/execution-record@1","written_by":"nothing today"} |
| record/report binding | {"required":"the record must carry the sha256 of the report AS WRITTEN, so a stale successful record cannot be paired with a newer failed run","status":"contract-exists-unused"} |
| behaviour with no observation | {"envelope":"observed:false, completed:null","matrix":"unobserved -> never valid-clean; findings surface as valid-findings-unobserved"} |
| enforcing-mode requirement | {"flag":"SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION","modes":["strict","regulated"],"status":"available-opt-in"} |
| implementation status | **unobserved** |
| residual gap | C2 must wrap the invocation so exit status, signal and timeout are captured, and must define a finalization condition for the Infection logger. |

### `js-mutation`

| field | value |
| --- | --- |
| runner | `scripts/runners/stryker.sh` |
| channel | `js_mutation` |
| native report | `reports/raw/js-mutation.json` |
| backends | `stryker` |
| backend selection | executable probe: SENTINEL_SHIELD_STRYKER_BIN, else node_modules/.bin/stryker |
| current process observation | **unobserved** — the invocation ends in `\\|\\| true` |
| current report observation | proves **report-readable** when the Stryker JSON report parses and yields a mutation score. Does NOT prove: completion of the mutation run |
| upstream exit semantics | **unknown** — missing_source: no composer.lock / package-lock.json in this repository: these are consumer-side dev dependencies, so no pinned version exists here whose documented exit table could be cited |
| normative completion requirement | An observed outcome separating a completed Stryker run from one aborted after emitting a partial JSON report. |
| timeout handling | {"status":"unobserved"} |
| signal handling | {"status":"unobserved"} |
| partial reports possible | true |
| report finalization | {"status":"unknown"} |
| analyzed scope identity | {"status":"unimplemented"} |
| configuration identity | {"source":"quality.mutation.min_score","digest_inputs":["the resolved quality-policy file"],"status":"partial"} |
| target/commit binding | {"status":"implemented-in-envelope"} |
| execution record | {"location":"reports/raw/js-mutation.execution.json","schema":"sentinel-shield/execution-record@1","written_by":"nothing today"} |
| record/report binding | {"required":"sha256 of the report as written","status":"contract-exists-unused"} |
| behaviour with no observation | {"envelope":"observed:false, completed:null","matrix":"unobserved -> never valid-clean; findings surface as valid-findings-unobserved"} |
| enforcing-mode requirement | {"flag":"SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION","modes":["strict","regulated"],"status":"available-opt-in"} |
| implementation status | **unobserved** |
| residual gap | C2 must capture the process outcome; Stryker's exit table is not citable from this repository. |

### `php-complexity`

| field | value |
| --- | --- |
| runner | `scripts/runners/phpmd-complexity.sh` |
| channel | `php_complexity` |
| native report | `reports/raw/php-complexity.json` |
| backends | `phpmd` |
| backend selection | executable probe: SENTINEL_SHIELD_PHPMD_BIN, else vendor/bin/phpmd, else phpmd on PATH |
| current process observation | **unobserved** — the invocation ends in `\\|\\| true` |
| current report observation | proves **report-readable** when the PHPMD JSON parses and a violation count can be derived. Does NOT prove: that PHPMD analysed every file in scope |
| upstream exit semantics | **unknown** — suspected: PHPMD is widely understood to exit non-zero when violations are found, which would make a non-zero exit a FINDINGS signal rather than a failure; missing_source: no composer.lock / package-lock.json in this repository: these are consumer-side dev dependencies, so no pinned version exists here whose documented exit table could be cited; caution: recording the suspicion as a rule would be the invention this inventory forbids; C2 must establish it against the version an adopter pins |
| normative completion requirement | An observed outcome separating 'analysis completed and found violations' from 'analysis failed'. For this producer that CANNOT be exit_code==0 without first establishing the exit table. |
| timeout handling | {"status":"unobserved"} |
| signal handling | {"status":"unobserved"} |
| partial reports possible | true |
| report finalization | {"status":"unknown"} |
| analyzed scope identity | {"status":"partial","note":"the runner passes an explicit path set, so the intended scope is known to the invoker but is not recorded in evidence"} |
| configuration identity | {"source":"the PHPMD codesize ruleset","digest_inputs":["the ruleset as resolved at run time"],"status":"unimplemented"} |
| target/commit binding | {"status":"implemented-in-envelope"} |
| execution record | {"location":"reports/raw/php-complexity.execution.json","schema":"sentinel-shield/execution-record@1","written_by":"nothing today"} |
| record/report binding | {"required":"sha256 of the report as written","status":"contract-exists-unused"} |
| behaviour with no observation | {"envelope":"observed:false, completed:null","matrix":"unobserved -> never valid-clean; findings surface as valid-findings-unobserved"} |
| enforcing-mode requirement | {"flag":"SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION","modes":["strict","regulated"],"status":"available-opt-in"} |
| implementation status | **unobserved** |
| residual gap | C2 must establish PHPMD's exit table for the pinned version before mapping any exit code to completion; a naive rc!=0 -> failed mapping would turn findings into execution errors. |

### `php-duplication`

| field | value |
| --- | --- |
| runner | `scripts/runners/phpcpd.sh` |
| channel | `php_duplication` |
| native report | `reports/raw/php-duplication.json` |
| backends | `phpcpd` |
| backend selection | executable probe: SENTINEL_SHIELD_PHPCPD_BIN, else vendor/bin/phpcpd, else phpcpd on PATH |
| current process observation | **unobserved** — the invocation ends in `\\|\\| true` |
| current report observation | proves **report-readable** when the phpcpd output parses into a duplication percentage. Does NOT prove: full-scope analysis |
| upstream exit semantics | **unknown** — missing_source: no composer.lock / package-lock.json in this repository: these are consumer-side dev dependencies, so no pinned version exists here whose documented exit table could be cited |
| normative completion requirement | An observed outcome separating completion-with-duplication from analysis failure. |
| timeout handling | {"status":"unobserved"} |
| signal handling | {"status":"unobserved"} |
| partial reports possible | true |
| report finalization | {"status":"unknown"} |
| analyzed scope identity | {"status":"partial","note":"path set known to the invoker, not recorded"} |
| configuration identity | {"source":"quality-policy duplication threshold","digest_inputs":["the resolved quality-policy file"],"status":"partial"} |
| target/commit binding | {"status":"implemented-in-envelope"} |
| execution record | {"location":"reports/raw/php-duplication.execution.json","schema":"sentinel-shield/execution-record@1","written_by":"nothing today"} |
| record/report binding | {"required":"sha256 of the report as written","status":"contract-exists-unused"} |
| behaviour with no observation | {"envelope":"observed:false, completed:null","matrix":"unobserved -> never valid-clean; findings surface as valid-findings-unobserved"} |
| enforcing-mode requirement | {"flag":"SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION","modes":["strict","regulated"],"status":"available-opt-in"} |
| implementation status | **unobserved** |
| residual gap | C2 must capture the process outcome and establish phpcpd's exit table. |

### `js-duplication`

| field | value |
| --- | --- |
| runner | `scripts/runners/jscpd.sh` |
| channel | `js_duplication` |
| native report | `reports/raw/js-duplication.json` |
| backends | `jscpd` |
| backend selection | executable probe: SENTINEL_SHIELD_JSCPD_BIN, else node_modules/.bin/jscpd |
| current process observation | **unobserved** — the invocation ends in `\\|\\| true` |
| current report observation | proves **report-readable** when .statistics.total.percentage is numeric in the jscpd JSON report. Does NOT prove: that every file in scope was compared |
| upstream exit semantics | **unknown** — missing_source: no composer.lock / package-lock.json in this repository: these are consumer-side dev dependencies, so no pinned version exists here whose documented exit table could be cited |
| normative completion requirement | An observed outcome separating a completed comparison from an aborted one that still wrote statistics. |
| timeout handling | {"status":"unobserved"} |
| signal handling | {"status":"unobserved"} |
| partial reports possible | true |
| report finalization | {"status":"unknown"} |
| analyzed scope identity | {"status":"partial"} |
| configuration identity | {"source":"quality-policy duplication threshold","digest_inputs":["the resolved quality-policy file"],"status":"partial"} |
| target/commit binding | {"status":"implemented-in-envelope"} |
| execution record | {"location":"reports/raw/js-duplication.execution.json","schema":"sentinel-shield/execution-record@1","written_by":"nothing today"} |
| record/report binding | {"required":"sha256 of the report as written","status":"contract-exists-unused"} |
| behaviour with no observation | {"envelope":"observed:false, completed:null","matrix":"unobserved -> never valid-clean; findings surface as valid-findings-unobserved"} |
| enforcing-mode requirement | {"flag":"SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION","modes":["strict","regulated"],"status":"available-opt-in"} |
| implementation status | **unobserved** |
| residual gap | C2 must capture the process outcome and establish jscpd's exit table. |

### `js-dead-code`

| field | value |
| --- | --- |
| runner | `scripts/runners/knip.sh` |
| channel | `js_dead_code` |
| native report | `reports/raw/js-dead-code.json` |
| backends | `knip`, `ts-prune` |
| backend selection | knip first when node_modules/.bin/knip is executable; otherwise ts-prune from node_modules/.bin or PATH. Selected at run time, and the choice CHANGES THE COUNTING SEMANTICS. |
| current process observation | **mixed** — unobserved - the knip invocation ends in `\\|\\| true` OBSERVED - a ts-prune failure is caught and leaves the report absent rather than producing a clean one |
| current report observation | proves **report-readable** when knip: .files and .issues arrays present, every issue category summed. ts-prune: line count excluding '(used in module)'.. Does NOT prove: comparability between the two backends - knip sums issue categories, ts-prune counts output lines, so one producer key can carry two non-comparable numbers |
| upstream exit semantics | **unknown** — missing_source: no composer.lock / package-lock.json in this repository: these are consumer-side dev dependencies, so no pinned version exists here whose documented exit table could be cited |
| normative completion requirement | An observed outcome per backend, AND the backend identity recorded in the evidence: a knip->ts-prune switch changes what the number means and can happen between CI runs purely by dependency installation. |
| timeout handling | {"status":"unobserved"} |
| signal handling | {"status":"partial","note":"a ts-prune signal death is caught by its failure guard; a knip signal death is not"} |
| partial reports possible | true |
| report finalization | {"status":"unknown"} |
| analyzed scope identity | {"status":"unimplemented"} |
| configuration identity | {"source":"none - dead_code has no numeric threshold","digest_inputs":[],"status":"not-applicable"} |
| target/commit binding | {"status":"implemented-in-envelope"} |
| execution record | {"location":"reports/raw/js-dead-code.execution.json","schema":"sentinel-shield/execution-record@1","written_by":"nothing today"} |
| record/report binding | {"required":"sha256 of the report as written, PLUS the backend that produced it","status":"contract-exists-unused"} |
| behaviour with no observation | {"envelope":"observed:false, completed:null","matrix":"unobserved -> never valid-clean; findings surface as valid-findings-unobserved"} |
| enforcing-mode requirement | {"flag":"SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION","modes":["strict","regulated"],"status":"available-opt-in"} |
| implementation status | **partial** |
| residual gap | Backend identity is not recorded anywhere in the evidence, so a knip result and a ts-prune result are indistinguishable to a consumer. C2 must record it as provenance. |

### `php-coverage`

| field | value |
| --- | --- |
| runner | `scripts/runners/php-coverage.sh` |
| channel | `php_coverage` |
| native report | `reports/raw/php-coverage.json` |
| backends | `pest`, `phpunit` |
| backend selection | executable probe: vendor/bin/pest first, else vendor/bin/phpunit; overridable by env |
| current process observation | **captured-not-used** — the exit status IS captured into a local variable, then only logged; it never reaches the evidence |
| current report observation | proves **report-readable-and-non-empty** when the Clover file exists and is non-empty, then the adapter produces the normalized report. Does NOT prove: that the test run completed - a failing test suite still produces a complete Clover report |
| upstream exit semantics | **known-in-part** — known: a non-zero exit from pest/phpunit means TEST FAILURES OR ERRORS, not a failed coverage measurement. The runner is written on that basis: it keeps the status separate and still accepts a finalized Clover report. Established from shipped code.; unknown: the precise code table for the pinned pest/phpunit version; missing_source: no composer.lock / package-lock.json in this repository: these are consumer-side dev dependencies, so no pinned version exists here whose documented exit table could be cited |
| normative completion requirement | Coverage completion is a property of the CLOVER REPORT being finalized, not of the test-runner exit status. C2 must observe the process to detect a kill or timeout that truncated Clover, while keeping the test-failure signal on its own gate. |
| timeout handling | {"status":"unobserved","note":"a timeout kill would truncate Clover; the non-empty check catches an empty file but not a truncated one"} |
| signal handling | {"status":"unobserved"} |
| partial reports possible | true |
| report finalization | {"status":"partial","implemented":"non-empty Clover file","missing":"a check that the Clover document is well-formed and complete rather than truncated"} |
| analyzed scope identity | {"status":"partial","note":"the Clover report names the files measured, but the scope is not digested into the evidence"} |
| configuration identity | {"source":"quality.coverage.* thresholds","digest_inputs":["the resolved quality-policy file"],"status":"partial"} |
| target/commit binding | {"status":"implemented-in-envelope"} |
| execution record | {"location":"reports/raw/php-coverage.execution.json","schema":"sentinel-shield/execution-record@1","written_by":"nothing today"} |
| record/report binding | {"required":"sha256 of the normalized report as written, plus the backend actually selected (pest or phpunit)","status":"contract-exists-unused"} |
| behaviour with no observation | {"envelope":"observed:false, completed:null","matrix":"unobserved -> never valid-clean; findings surface as valid-findings-unobserved"} |
| enforcing-mode requirement | {"flag":"SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION","modes":["strict","regulated"],"status":"available-opt-in"} |
| implementation status | **partial** |
| residual gap | The captured exit status is discarded before the evidence layer, and the selected backend is not recorded. |

### `js-coverage`

| field | value |
| --- | --- |
| runner | `scripts/runners/js-coverage.sh` |
| channel | `js_coverage` |
| native report | `reports/raw/js-coverage.json` |
| backends | `consumer package.json coverage script` |
| backend selection | the package.json script 'test:coverage' then 'coverage', run through the detected package manager. The BACKEND IS THE CONSUMER'S SCRIPT and is not knowable from this repository. |
| current process observation | **unobserved** — the package-manager invocation ends in `\\|\\| true` |
| current report observation | proves **report-readable-and-non-empty** when an Istanbul json-summary exists and is non-empty; the runner clears any stale summary FIRST so a previous run cannot be normalized as current evidence. Does NOT prove: that the coverage run completed |
| upstream exit semantics | **unknown** — reason: the backend is an arbitrary consumer-defined npm script, so there is no exit table to cite; missing_source: by construction - the script is defined in the adopter's package.json |
| normative completion requirement | An observed outcome for the consumer's script, plus the identity of the script actually run. Completion is a property of the Istanbul summary being finalized, not of the script's exit status. |
| timeout handling | {"status":"unobserved"} |
| signal handling | {"status":"unobserved"} |
| partial reports possible | true |
| report finalization | {"status":"partial","implemented":"non-empty summary plus stale-summary clearing","missing":"a completeness check on the summary document"} |
| analyzed scope identity | {"status":"unimplemented"} |
| configuration identity | {"source":"quality.coverage.* thresholds","digest_inputs":["the resolved quality-policy file"],"status":"partial"} |
| target/commit binding | {"status":"implemented-in-envelope"} |
| execution record | {"location":"reports/raw/js-coverage.execution.json","schema":"sentinel-shield/execution-record@1","written_by":"nothing today"} |
| record/report binding | {"required":"sha256 of the normalized report as written, plus the script name actually executed","status":"contract-exists-unused"} |
| behaviour with no observation | {"envelope":"observed:false, completed:null","matrix":"unobserved -> never valid-clean; findings surface as valid-findings-unobserved"} |
| enforcing-mode requirement | {"flag":"SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION","modes":["strict","regulated"],"status":"available-opt-in"} |
| implementation status | **unobserved** |
| residual gap | The backend is consumer-defined, so C2 can record WHICH script ran but cannot establish an exit contract for it. That limit is inherent, not a deferral. |

### `php-diff-coverage`

| field | value |
| --- | --- |
| runner | `scripts/runners/php-diff-coverage.sh` |
| channel | `php_diff_coverage` |
| native report | `reports/raw/php-diff-coverage.json` |
| backends | `pest`, `phpunit` |
| backend selection | executable probe: vendor/bin/pest first, else vendor/bin/phpunit; overridable by env |
| current process observation | **captured-not-used** — the exit status IS captured into a local variable, then only logged |
| current report observation | proves **report-readable-and-non-empty** when the Clover file exists and is non-empty, then the diff adapter produces the normalized report. Does NOT prove: that the test run completed, nor which base the diff was taken against |
| upstream exit semantics | **known-in-part** — known: a non-zero exit from pest/phpunit means TEST FAILURES OR ERRORS, not a failed coverage measurement. Established from shipped code.; unknown: the precise code table for the pinned pest/phpunit version; missing_source: no composer.lock / package-lock.json in this repository: these are consumer-side dev dependencies, so no pinned version exists here whose documented exit table could be cited |
| normative completion requirement | Coverage completion is a property of the Clover report being finalized, not of the test-runner exit status. The DIFF BASE must also be recorded: the same commit measured against a different base is a different measurement. |
| timeout handling | {"status":"unobserved"} |
| signal handling | {"status":"unobserved"} |
| partial reports possible | true |
| report finalization | {"status":"partial","implemented":"non-empty Clover file","missing":"a completeness check on the Clover document"} |
| analyzed scope identity | {"status":"partial","note":"the changed-line set is computed from a diff base resolved from SENTINEL_SHIELD_DIFF_BASE or a merge-base; the base is NOT recorded in evidence"} |
| configuration identity | {"source":"quality.coverage.changed_lines_min and related thresholds","digest_inputs":["the resolved quality-policy file"],"status":"partial"} |
| target/commit binding | {"status":"implemented-in-envelope"} |
| execution record | {"location":"reports/raw/php-diff-coverage.execution.json","schema":"sentinel-shield/execution-record@1","written_by":"nothing today"} |
| record/report binding | {"required":"sha256 of the normalized report as written, plus the backend selected and the diff base used","status":"contract-exists-unused"} |
| behaviour with no observation | {"envelope":"observed:false, completed:null","matrix":"unobserved -> never valid-clean; findings surface as valid-findings-unobserved"} |
| enforcing-mode requirement | {"flag":"SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION","modes":["strict","regulated"],"status":"available-opt-in"} |
| implementation status | **partial** |
| residual gap | The captured exit status is discarded, the selected backend is not recorded, and the diff base is not recorded. |

