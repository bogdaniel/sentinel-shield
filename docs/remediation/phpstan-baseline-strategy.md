# Remediation: PHPStan / Larastan debt baseline strategy

**What it means.** PHPStan reports `type_errors`. On an existing codebase the count can be
large; a baseline lets you **stop the bleeding** (block NEW errors) while paying down the
existing debt over time.

**When it is real.** Every PHPStan error is a real type/contract concern at the chosen
level. Higher levels surface more. New errors in changed code should always block.

**When a baseline is appropriate.** Adopting PHPStan on a mature project where fixing all
errors at once is impractical. A baseline is **debt tracking, not a fix** — it must shrink.

**Recommended approach.**
1. Pick a level you can hold for new code; raise it gradually.
2. Generate a baseline: `phpstan analyse --generate-baseline phpstan-baseline.neon` and
   `includes:` it from `phpstan.neon`.
3. CI fails on NEW errors only (errors not in the baseline).
4. Track the baseline count in the security debt register; reduce it each iteration
   (e.g. "no net increase" + a burn-down target). Re-generating to silence new errors is
   forbidden — fix or explicitly review.
5. Keep the Sentinel Shield `type_errors` gate enabled; the baseline shrinks the *new*
   error count to 0 without faking the debt away.

**Accepted-risk guidance.** The baseline file IS the governance artifact; it is not an
accepted-risk record. Do not suppress `type_errors` via accepted-risks to hide a rising
baseline.

**Validation steps.** `phpstan analyse` exits 0 with the baseline; introduce a deliberate
type error in changed code and confirm CI fails.

**Rollback considerations.** Removing `phpstan-baseline.neon` surfaces all debt at once
(noisy but safe). Never delete it to pass CI.
