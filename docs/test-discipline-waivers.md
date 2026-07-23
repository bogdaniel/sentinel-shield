# Test Discipline Waivers (v2.2.0)

Some production changes genuinely carry no test change: a regenerated API client, vendored
code, a mechanical rename. A waiver records that judgement — with a reason and an expiry —
instead of quietly weakening the gate for everyone.

File: `.sentinel-shield/test-discipline-waivers.json`

```json
{
  "waivers": [
    {
      "id": "TD-001",
      "reason": "Documentation-only generated code update",
      "paths": ["src/generated/**"],
      "expires_at": "2026-12-31"
    }
  ]
}
```

## Rules

- **Every waiver must have a `reason` and an `expires_at`.** A waiver without a stated reason is
  an unreviewable one; a waiver without an expiry is a permanent hole nobody revisits. Both are
  mandatory, along with `id` and a non-empty `paths` array.
- **Waivers suppress matching production paths only.** They narrow what counts as a production
  change. They never suppress the gate wholesale, and they never touch test classification.
- **A waiver does not hide unwaived changes in the same diff.** If `src/generated/api.ts` is
  waived but `src/domain/order.ts` also changed with no test change, the violation still fires.
- **Expired waivers suppress nothing.** They are counted and reported — never silently ignored.
- **A malformed waivers file fails closed.** Invalid JSON, or any waiver missing a valid `id`,
  `reason`, `expires_at` (`YYYY-MM-DD`) or `paths`, produces `status: execution-error` with
  `missing_test_change_evidence: true`. A waivers file that cannot be trusted must not be
  allowed to suppress evidence.

## Expired waivers are expired exceptions

An expired waiver increments **`expired_exceptions`**, the long-standing gate that blocks in
*every* mode including report-only. Sentinel Shield deliberately does not introduce a parallel,
quieter counter for this: an expired waiver *is* an expired exception, and it should be as loud
as any other.

Practically: letting a test-discipline waiver lapse turns into a build failure everywhere, at
which point the choice is to renew it with a fresh review or delete it. That is the intended
pressure. Renewing should require the same judgement as granting it did.

## Path matching

`paths` entries use the same matching as the policy path lists:

- `src/generated/**` — everything under `src/generated`, at any depth
- `src/generated` — the same (a bare path is normalized to `path/**`)
- `*.pb.go` — glob matched against the full path and the basename

## Worked example

```txt
diff:  src/generated/api.ts   (waived)
       README.md              (ignored by default)
->     production_changed_files = 0, violation = 0, status = pass

diff:  src/generated/api.ts   (waived)
       src/domain/order.ts    (production, unwaived)
->     production_changed_files = 1, violation = 1, status = findings

waiver expired:
diff:  src/generated/api.ts
->     production_changed_files = 1, violation = 1, expired_waivers = 1
       and expired_exceptions = 1, which blocks in every mode
```

## What a waiver is not

A waiver is not an accepted risk record and is not a control waiver — it does not use
`.sentinel-shield/accepted-risks.json` or `control-waivers.json`, and it cannot suppress
security findings. It only narrows which paths count as production change for the TDD proxy.

## Related

- [`tdd-evidence-policy.md`](tdd-evidence-policy.md)
- [`testing-discipline-governance.md`](testing-discipline-governance.md)
- [`exception-policy.md`](exception-policy.md)
