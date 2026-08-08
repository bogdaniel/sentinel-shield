# Profile manifest validation

Every profile manifest is fully validated **before any of its fields are read,
merged, or acted on**. This page is the contract.

- Runtime authority: [`scripts/lib/profile-schema.sh`](../scripts/lib/profile-schema.sh)
- CLI: [`scripts/validate-profile-manifest.sh`](../scripts/validate-profile-manifest.sh)
- Published schema: [`profiles/profile.manifest.schema.json`](../profiles/profile.manifest.schema.json)
  and [`schemas/tool-policy.schema.json`](../schemas/tool-policy.schema.json)
- Validated by: [`tests/prod/300-profile-manifest-schema.sh`](../tests/prod/300-profile-manifest-schema.sh)

## Why there are two faces of one contract

The JSON Schema is what an adopter reads. The shell library is what actually
runs — `check-jsonschema` is not a dependency of this engine and is not
installed in CI, so a schema that only a JSON-Schema validator can enforce is a
document, not a gate.

They are held in lockstep: `tests/prod/300-profile-manifest-schema.sh` asserts
that every enum, field allowlist, identifier pattern, report-path pattern and
the supported `tool_policy_version` are **equal** in both. Changing one without
the other fails that suite.

## Roles

| Role | Who uses it | Extra requirement |
| --- | --- | --- |
| `policy` (default) | the resolver, and anything that only composes tool policy | — |
| `install` | `install-baseline`, `sync-baseline`, `plan-upgrade`, `migrate-v1`, `bootstrap-profile-tools`, release packaging, the repository audit | `files` must be present |

Every manifest shipped under `profiles/` is validated at `role=install` by
`scripts/audits/profile-tool-integrity.sh` and by release packaging, so no
shipped manifest escapes the full published schema. `role=policy` exists for
manifests that participate only in composition (test fixtures, an
`--manifest` entry point) and legitimately install nothing.

## What is checked

**Document**
- valid JSON, top level is an object
- unknown top-level fields are **rejected** (strict allowlist; there is no `x-`
  extension escape hatch)
- `$schema`, when present, must name `profile.manifest.schema.json`; any other
  schema is rejected rather than validated against the wrong contract

**Identity and versions**
- `profile` is required and must match `^[a-z0-9][a-z0-9-]*$` (max 64) — it
  becomes a filesystem path and a member of a space-delimited shell set
- `tool_policy_version` must be the integer `2`. It is **required whenever the
  manifest declares `tools` or `extends`**: a manifest that participates in
  tool-policy resolution must state the version it was written against
- a lower version fails with a pointer to `scripts/migrate-v1.sh`; a higher
  version fails because this engine cannot execute a newer tool policy and must
  not guess

**Inheritance**
- `extends` is an array of safe identifiers, no duplicates, no self-reference
- the identifier is validated **before** it is used to build a manifest path

**Tools**
- unknown tool fields, unknown execution stages, unknown package fields and
  unknown config fields are rejected
- `policy` is required and enum-checked; `missing_behavior`, `config.classification`,
  `packages[].scope` and `selection` are enum-checked
- `execution.{pr,main,scheduled}` must be real booleans. `"false"` is a *truthy
  string* in jq, so a quoted boolean is a stage that runs while the manifest says
  it does not
- `report` must match `^reports/raw/[A-Za-z0-9][A-Za-z0-9._-]*\.json$`. The
  previous `[^/]+` form admitted spaces, `$`, backticks and a leading dot
- `runner` and `audit` must be safe repo-relative `.sh` paths **and must exist in
  this engine**
- `executable[]`, `config.path`, and entry-list `source`/`target` must be safe
  paths: no whitespace, glob characters, control characters, leading dash, or
  `.`/`..` segment. `ep__exe_present` iterates `executable[]` unquoted, so a glob
  there changes which binary is probed
- `alternatives`, `fallback_order` and `selection` are one-of vocabulary and are
  rejected on any other policy — the resolver silently ignores them there, so the
  author believes a fallback exists when none does
- `fallback_order` must be a permutation of `alternatives`;
  `fallback_order[0]` is what `bootstrap-profile-tools.sh` installs

**After composition** (the merged inheritance result, before any project override)
- every `alternatives` / `requires` target must resolve to a tool declared
  somewhere in the DAG
- a one-of population must derive at least one **group**. Groups are derived as
  "a one-of tool nobody lists as an alternative", so a mutually-referencing set
  derives zero groups and the requirement disappears without an error — that is
  now `ONE_OF_NO_GROUP`
- every member belongs to exactly one group, every member is itself `one-of`, a
  group offers at least two alternatives, and a member's alternatives stay inside
  its own group

## Diagnostics

Failures are fail-closed (exit `2`) and print one machine-readable line per
violation, `CODE field=... reason=...`. Manifest content is never echoed
wholesale.

```
$ sh scripts/validate-profile-manifest.sh profiles/laravel/profile.manifest.json
OK   profiles/laravel/profile.manifest.json (role=policy)

$ sh scripts/validate-profile-manifest.sh --all --quiet   # every shipped manifest, role=install
```

## Known boundaries

- **Project overrides are a separate surface.** Cross-manifest validation runs on
  the merged inheritance result *before* `.sentinel-shield/tool-policy.yaml` is
  applied. Override semantics are validated by
  `scripts/lib/tool-policy-override.sh` and `ep__apply_override`.
- **Duplicate JSON keys are not detected.** `jq` collapses them last-wins with no
  way to observe the conflict. The YAML policy surface detects duplicates during
  tokenization (`docs/yaml-policy-contract.md`); the JSON manifest surface does
  not yet.
- **`policy: required` with `missing_behavior: warn` is accepted.** Four shipped
  tools use it deliberately (see `tool_notes` in the `node` and `react`
  profiles). It is a documented gate softening, not a schema error.
