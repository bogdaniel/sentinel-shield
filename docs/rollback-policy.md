# Rollback Policy

Sentinel Shield **never rolls back by deleting or moving a released tag**. A published tag is an
immutable, signed fact that consumers may already have pinned; deleting or re-pointing it
rewrites history under their feet and breaks reproducibility and supply-chain provenance. A
"rollback" here is a **roll-forward**: you publish a superseding fixed release, mark the affected
version(s) in an advisory, and give consumers explicit rollback/upgrade guidance.

This policy is enforced by `scripts/authorize-production-release.sh`, which **refuses**
`--delete-tag`, `--move-tag`, `--force-tag`, `--retag`, `--overwrite-tag`, `--delete-release`,
`--remove-release`, `--unpublish`, `--rewrite-history`, and `--force-push` in every mode
(exit 2), and by `scripts/verify-published-release.sh`, which is strictly read-only.

## Two remediation shapes

Both emit a machine-readable advisory conforming to
[`schemas/rollback-advisory.schema.json`](../schemas/rollback-advisory.schema.json). Neither
mutates any tag or release.

### 1. Superseding release (preferred)

A fixed release replaces the affected one. The affected version is marked `superseded`; its tag
stays published and immutable.

```sh
scripts/authorize-production-release.sh declare-superseded \
  --advisory-id SSA-2026-001 \
  --superseded-version 2.0.0 --superseded-tag v2.0.0 \
  --superseding-version 2.0.1 --superseding-tag v2.0.1 \
  --reason "critical fix for <CVE/issue>" \
  --guidance "Upgrade to 2.0.1: pin the Sentinel Shield ref to v2.0.1 and re-run CI." \
  --reference "https://github.com/<org>/<repo>/security/advisories/GHSA-xxxx" \
  --output advisories/SSA-2026-001.json
```

The superseding release is itself produced through the full
[production release runbook](production-release-runbook.md) — it is a normal, fully-verified,
authorized release, not a shortcut.

### 2. Recommend rollback (interim)

When no fix is ready, advise consumers to pin to a known-good **prior** version until the
superseding release ships. The affected version's tag is **not** removed.

```sh
scripts/authorize-production-release.sh rollback-advisory \
  --advisory-id SSA-2026-002 \
  --affected-version 2.0.0 --rollback-to 1.9.2 \
  --reason "regression in <area>; fix pending" \
  --guidance "Pin Sentinel Shield to v1.9.2 until the superseding release is published." \
  --output advisories/SSA-2026-002.json
```

## Consumer guidance the advisory must carry

- **How to move**: the exact ref to pin (the superseding tag, or the rollback target).
- **What to re-run**: `install-baseline` / `sync` against the new ref, then the consumer's CI.
- **What NOT to expect**: the affected tag will **not** move or disappear — the remediation is a
  new version, not a mutation of the old one.

## Relationship to incident response

A rollback/supersede advisory is the release-side output of the incident process in
[`security-incident-response.md`](security-incident-response.md). Emergency fixes still pass
production security acceptance (an emergency waiver is time-boxed and incident-linked — see
[`security-policy.md`](security-policy.md)); the emergency path changes urgency, never the
immutability of published tags.
