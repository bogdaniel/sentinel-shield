# PHPStan / Psalm Triage (v0.1.14)

For `type_errors` from PHPStan/Larastan or Psalm.
1. **Fix the type** (annotations, narrowing, real null checks) — preferred.
2. **Baseline (PHPStan)**: keep pre-existing debt in `phpstan-baseline.neon`; shrink over time.
   NEVER regenerate the baseline to mask NEW errors. New errors must be fixed or explicitly baselined with a reason.
3. **Environment divergence** (local vs CI): trust CI's measured `phpstan.json`; do not delete
   baseline entries unless CI proves them resolved (see the zenchron Filament-cluster case).
4. Psalm maps to the same `type_errors` key — reconcile both tools' baselines separately.
