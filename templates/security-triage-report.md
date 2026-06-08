# Security Triage Report

> Generic template. Copy to `docs/security/sentinel-shield-triage.md` (append-only log).
> One section per triage event (a run, an investigation, a remediation).

## <YYYY-MM-DD> — <event title> (branch `<branch>`, run `<id>`)

### Context
- Mode / Sentinel Shield ref:
- What triggered this:

### Findings (by gate)
| Gate | Count | Real? | Disposition |
| --- | --- | --- | --- |
| secrets | | | |
| critical/high vulns | | | |
| type_errors | | | |
| test_failures | | | |
| unsafe_docker | | | accepted-risk (scope) / fixed |
| unsafe_github_actions | | | |

### Decisions
- **Fixed:** <what + how>
- **Accepted (finding-scoped):** <rule_id + files + record id + expiry>  (NOT fixed)
- **Deferred:** <what + when>

### Validation
- Commands run / run ID / result:

### Honesty notes
- What remains unfixed, what is only accepted, what was not validated.
