# External Adoption Test (v1.8.0 — A04)

A repeatable way to prove a **new team can adopt Sentinel Shield without the author**. The observer
follows the public docs only; no insider knowledge.

## No-hidden-knowledge rule

The adopter uses **only** [`public-adoption-kit.md`](public-adoption-kit.md) and the docs it links.
If a step requires tribal knowledge, that's a **docs gap** to capture and fix — not a verbal fix.

## Modes

- **Real-team mode:** a team that has never used SS adopts a real repo (preferred).
- **Fixture fallback:** an observer adopts one of the profile fixtures from scratch (when no real
  team is available) — still author-independent.

## Metrics (record actuals)

| Metric | Definition | Target |
|---|---|---|
| time-to-first-summary | install → first `security-summary.json` | < 30 min |
| time-to-first-gate | install → PR-fast gate runs (pass or fail) | < 60 min |
| install friction | # of steps needing a doc fix or a guess | 0 blocking |
| docs gaps | unclear/missing/contradictory doc moments | logged, triaged |
| rollback verified | uninstall/restore leaves repo clean | yes/no |

## Observer checklist

- [ ] Followed `public-adoption-kit.md` only.
- [ ] `install-baseline --mode report-only` then `--apply` worked.
- [ ] `doctor.sh` reported a sane state.
- [ ] PR-fast gate produced a `security-summary.json`.
- [ ] A real finding blocked correctly (or a clean pass was explained).
- [ ] `accepted-risks.json` ownership understood; not auto-created.
- [ ] Rollback verified (managed files removed, project-local untouched).
- [ ] Support requests classified (docs gap / real bug / environment).

## Adoption scorecard (template)

```
consumer:            <repo/team>
mode:                real-team | fixture
time-to-first-summary: __ min
time-to-first-gate:    __ min
install friction:      __ blocking / __ minor
docs gaps:             <list>
rollback verified:     yes/no
verdict:               adoptable-unassisted | needs-doc-fixes | blocked
```

## Report template

Record the scorecard + each docs gap as an actionable item. **Patch the docs** (e.g.
[`quickstart.md`](quickstart.md)) for every gap found; do not rely on a person re-explaining.

Linked from [`public-adoption-kit.md`](public-adoption-kit.md) and
[`production-rollout.md`](production-rollout.md).
