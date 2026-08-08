# Canonical YAML policy contract

**Contract id:** `sentinel-shield-yaml-subset/v1`
**Implementation:** `scripts/lib/yaml-policy.sh`
**Corpus:** `tests/fixtures/yaml-policy/`
**Suite:** `tests/prod/257-yaml-policy-contract.sh`
**Issues:** #259 (yq/fallback parity), #260 (duplicate tool/field keys), #264 (duplicate profile/gate keys)

Sentinel Shield reads security policy out of YAML. This document defines exactly which
YAML it accepts, what each construct means, and what it does with everything else.

The rule the rest of this document exists to enforce:

> The same bytes produce either **one** canonical normalized document, or **one** stable
> error classification. Never a third thing, and never a different thing on a different
> machine.

---

## 1. Why this exists

Before this contract, five libraries each carried their own YAML reader, and each reader
had two backends: **mikefarah `yq` v4 when installed, and a hand-written `awk` flatten
otherwise**. The two backends did not agree, and the awk flattens did not agree with each
other.

### 1.1 Parser inventory (the state this replaces)

| Consumer | Input | Backend | Supported syntax | Duplicate semantics | Comment semantics | Quote semantics | Failure behaviour | Normalized output | Security impact |
|---|---|---|---|---|---|---|---|---|---|
| `scripts/resolve-gates.sh` | `.sentinel-shield/profile.yaml` | yq v4 **or** awk flatten | 2-space block maps + lists | **yq: last-wins**, fallback: **first-wins** (`print;exit`) | fallback strips `#` **before** quotes are parsed | **fallback never unquotes** — `mode: "strict"` stayed `"strict"` | fallback: `if (ci==0) next` silently drops malformed lines | dotted `path=value` text | **gate thresholds** — which findings block a release |
| `scripts/lib/tool-policy-override.sh` | `.sentinel-shield/tool-policy.yaml` | yq v4 **or** awk rows → `jq reduce` | `tools:` map only, block + inline `{}` | **both last-wins** (`.[k][k]=v` in `jq reduce`) | strips `#` before quotes | `unq()` = `gsub(/^["']|["']$/)`, strips mismatched quotes too | ignores any line without `:` | `{tools:{…}}` JSON | **per-tool policy** — can silently downgrade a control |
| `scripts/lib/quality-policy.sh` | `quality-policy.yaml` | yq v4 **or** awk flatten | 2-space block maps | **first-wins** | strips `#` before quotes | never unquotes | rejects tabs/advanced YAML, else drops the line | dotted `path=value` | quality thresholds |
| `scripts/lib/testing-discipline-policy.sh` | `testing-discipline-policy.yaml` | yq v4 **or** awk flatten | 2-space block maps + lists | **first-wins** | strips `#` before quotes | strips one quote layer (differs from `quality-policy`) | as above | dotted `path=value` | test-discipline gates |
| `scripts/lib/architecture-policy.sh` | `architecture-policy.yaml` | yq v4 **or** awk flatten | 2-space block maps | **first-wins** | strips `#` before quotes | never unquotes | as above | dotted `path=value` | architecture gates |
| `scripts/doctor.sh` (inline) | `.sentinel-shield/profile.yaml` | bare `awk`, **no yq path at all** | `profiles:` list only | none — takes every item | strips `#` before quotes | never unquotes | silently yields nothing | shell word list | reported active profile set |

Six readers. Three different duplicate-winner rules. Four different quote behaviours.

### 1.2 What that cost

* `mode: "strict"` was a **valid** mode with yq installed and an **invalid** one without it.
* `name: "a # b"` kept its value with yq and lost half of it without.
* A duplicate `gates.mode` resolved to the **last** value under yq and the **first** value
  under the fallback — so a reviewer reading top-to-bottom and the resolver could disagree,
  and the two environments could disagree with each other.
* Installing or removing a convenience binary changed enforced security policy **with no
  policy diff to review**.

---

## 2. Architecture decision

Three options were considered.

| | Approach | Verdict |
|---|---|---|
| **A** | Canonical restricted subset validated up-front, then *either* backend extracts values | **Rejected.** Still two semantic interpreters. A shared validator narrows the input but does not make `yq` and `awk` agree on what the accepted input *means* — the duplicate-winner and quote bugs all live in extraction, after validation. |
| **B** | One trusted parser, required in every environment; missing parser ⇒ fail closed | **Rejected.** `yq` is not currently a dependency and is not available in every consuming CI, offline install, or bootstrap path. Making it mandatory breaks documented installs to fix a parsing bug. |
| **C** | One deterministic normalization frontend producing a canonical IR; `yq` demoted to a test-only oracle | **Selected.** |

### 2.1 Selected: Architecture C

`scripts/lib/yaml-policy.sh` tokenizes the input itself and emits one canonical JSON
document. **`yq` is never consulted for meaning.** There is no fallback, because there is
no primary — there is one parser.

Phases, deliberately separated:

```
read bytes
  → lexical validation      (encoding, control bytes, tabs, line endings)
  → tokenization            (keys, scalars, sequences, inline maps)
  → duplicate detection     ← runs HERE, while keys are still tokens
  → subset validation       (indentation, structure, unsupported constructs)
  → canonical representation (jq-serialized, sorted, typed)
```

Duplicate detection sits before normalization for a specific reason: once `yq`, `jq`, or an
`awk` associative assignment has collapsed two keys into one, **the losing value is gone**.
The conflict is only recoverable while both keys are still tokens.

This batch owns **syntax and duplicate integrity only**. Profile inheritance, override
precedence, tool selection and gate enforcement remain above it, in the M3 issues that
depend on this one.

### 2.2 Dependency audit

Architecture C needs `awk` (POSIX, already used throughout) and `jq` for serialization.

`resolve-gates.sh` previously advertised "no hard dependency on jq/yq/Python". That
exemption was already hollow: **`scripts/doctor.sh` lists `jq` as a MANDATORY engine tool**
(`have jq "jq not found — REQUIRED for the engine/self-test"`), and every pipeline that
invokes `resolve-gates.sh` also invokes `jq`-requiring scripts in the same run. No supported
configuration loses functionality; the local exemption is removed and the docs corrected.

`jq` performs **all** JSON serialization. No component of this contract builds JSON by hand
or escapes strings itself.

---

## 3. Supported syntax

Everything below is accepted with exactly the stated meaning.

| Construct | Policy |
|---|---|
| Block mappings | Supported. Indentation is **exactly 2 spaces per level**. |
| Block sequences | Supported, scalar items only. Item indent may equal the parent key's indent or be `+2` — both styles are accepted, but all items of one sequence must share an indent. |
| Inline flow mapping | Supported **one level deep, scalars only**: `grype: { policy: optional }`. This is the documented override spelling (`docs/profile-tool-policy.md`). |
| Plain scalars | Supported. Terminated by end-of-line or by ` #`. |
| Single-quoted scalars | Supported. `''` is the only escape (a literal `'`). |
| Double-quoted scalars | Supported. Escapes: **`\"` and `\\` only**. |
| Literal `#` inside quotes | Supported — quotes are interpreted **before** comments are stripped. |
| Literal `:` inside quotes | Supported. |
| Inline comments | Supported. `#` starts a comment only at line start or when preceded by whitespace, outside quotes. |
| Blank lines | Ignored. |
| Empty value (`key:`) | Supported ⇒ JSON `null`, unless children or a sequence follow. |
| `null` | Supported ⇒ JSON `null`. |
| Booleans | `true` / `false` only ⇒ JSON booleans. |
| Integers | `-?(0\|[1-9][0-9]*)`, at most 15 digits ⇒ JSON number. |
| Decimals | `-?(0\|[1-9][0-9]*)\.[0-9]*[1-9]`, at most 15 significant digits ⇒ JSON number. |
| Quoted keys | Supported. `"mode"` and `mode` are **the same key**. |
| Key charset | `[A-Za-z0-9_][A-Za-z0-9_.-]*` — ASCII only. A key may contain `.`. |
| Non-ASCII in scalar **values** | Supported, must be well-formed UTF-8. |

### 3.1 Numbers that stay strings

Values matching none of the numeric grammars above remain **strings**. They are not
rejected and not guessed at:

| Input | Result | Why |
|---|---|---|
| `007` | `"007"` | A leading zero means the author wrote an identifier. `7` is not what they wrote. |
| `1.50`, `1.0` | `"1.50"`, `"1.0"` | Trailing fraction zeros do **not** render identically across `jq` versions. |
| `12345678901234567890` | `"…"` | Beyond exact integer range; `yq` cannot even serialize it. |
| `yes`, `no`, `on`, `off` | `"yes"`, … | YAML 1.1 booleanising these is the format's most notorious silent config change. |
| `1e3` | `"1e3"` | Exponent form has no stable rendering. |

Every value that *does* become a JSON number round-trips byte-for-byte. That is what makes
the canonical form reproducible rather than merely usually-identical.

---

## 4. Rejected constructs

Each is rejected **before any policy value is applied**, with a stable code.

| Construct | Error code |
|---|---|
| Tab in any line | `YAML_TAB_INDENTATION` |
| CRLF line endings | `YAML_CRLF_LINE_ENDING` |
| Other control bytes | `YAML_CONTROL_CHARACTER` |
| Malformed UTF-8 | `YAML_INVALID_UTF8` |
| Indentation not a multiple of 2, or a level skip | `YAML_BAD_INDENTATION` |
| Anchors (`&x`) | `YAML_UNSUPPORTED_ANCHOR` |
| Aliases (`*x`) | `YAML_UNSUPPORTED_ALIAS` |
| Merge keys (`<<:`) | `YAML_UNSUPPORTED_MERGE_KEY` |
| Tags (`!!str`) | `YAML_UNSUPPORTED_TAG` |
| Literal / folded block scalars (`\|`, `>`) | `YAML_UNSUPPORTED_BLOCK_SCALAR` |
| Flow sequences (`[a, b]`) | `YAML_UNSUPPORTED_FLOW_SEQUENCE` |
| Nested flow collections | `YAML_UNSUPPORTED_FLOW_NESTING` |
| Malformed flow entry | `YAML_MALFORMED_FLOW_ENTRY` / `YAML_UNTERMINATED_FLOW` |
| Document markers (`---`, `...`), multiple documents | `YAML_UNSUPPORTED_DOCUMENT_MARKER` |
| Sequence of mappings (`- key: value`) | `YAML_UNSUPPORTED_SEQUENCE_ITEM` |
| Empty sequence item | `YAML_EMPTY_SEQUENCE_ITEM` |
| Unterminated quote | `YAML_UNTERMINATED_QUOTE` |
| Escape other than `\"` / `\\` | `YAML_UNSUPPORTED_ESCAPE` |
| `: ` inside an unquoted scalar | `YAML_AMBIGUOUS_PLAIN_SCALAR` |
| Content after a complete value | `YAML_TRAILING_CONTENT` |
| Line with no `:` | `YAML_MALFORMED_LINE` |
| Empty key | `YAML_EMPTY_KEY` |
| Key outside the charset (incl. non-ASCII) | `YAML_INVALID_KEY` |
| No mapping key anywhere | `YAML_EMPTY_DOCUMENT` |
| Duplicate mapping key | `YAML_DUPLICATE_KEY` |
| Keys differing only by ASCII case | `YAML_AMBIGUOUS_KEY_CASE` |
| Repeated item in one sequence | `YAML_DUPLICATE_LIST_ITEM` |

`\/` is **not** supported. YAML 1.2 permits it, but go-yaml (and therefore `yq`, the
independent oracle) rejects it. A construct only *we* accept is a parity gap pointing the
wrong way.

---

## 5. Duplicate-key model

Duplicate mapping keys are **always** an error. There is no first-wins and no last-wins
anywhere in the engine any more.

Detection happens during tokenization, at every level:

* top-level sections (including a section re-opened far below);
* nested mappings at any depth;
* tool names and tool policy fields;
* keys inside an inline flow mapping;
* a key declared inline in one place and as a block elsewhere;
* keys that differ only in quoting style (`mode` / `"mode"` / `'mode'`);
* keys reachable through an alias or merge key — those constructs are rejected outright, so
  they cannot introduce a hidden duplicate at all.

### 5.1 Repeated list items

`profiles: [node, node]` is an **error** (`YAML_DUPLICATE_LIST_ITEM`), not a
silently-deduplicated list and not meaningful repetition. Every list in the policy surface
(`profiles`, `reports.format`, scan paths) is a *set*; a repeat is always a mistake, and
letting one consumer dedupe while another counts twice is exactly the class of divergence
this contract exists to remove.

### 5.2 Key canonicalization

Decided deliberately, per axis:

| Axis | Policy |
|---|---|
| Exact bytes | Identical bytes ⇒ same key. |
| Quoting | Quoted and unquoted spellings of the same text ⇒ **same key**. |
| Escapes | Compared after unescaping. |
| ASCII case | Keys are case-**sensitive**, but two keys differing only by case are **rejected** (`YAML_AMBIGUOUS_KEY_CASE`). `Grype:` and `grype:` in one mapping is a mistake, and letting it through lets a reviewer misread which tool is configured. |
| Unicode | Non-ASCII keys are **rejected**. NFC-vs-NFD collisions are therefore unrepresentable, rather than resolved differently per locale or per backend. |

Keys are **not** lowercased. That was never the public contract and silently folding case
would change which tool an override targets.

---

## 6. Error contract

One machine-readable line on **stderr**, exit status **3**:

```
sentinel-shield-yaml: YAML_DUPLICATE_KEY key=gates.fail_on.secrets first=12:5 second=28:5
```

| Field | Meaning |
|---|---|
| `YAML_…` | Stable error code (§4). |
| `key=` | Canonical dotted key. Present for duplicate-class errors. |
| `first=` / `second=` | Both conflicting locations, `line:column`. |
| `at=` | Single location, for non-duplicate errors. |

Guarantees:

* **Line and column are byte offsets into the original input.** The tokenizer runs under
  `LC_ALL=C`, so positions and the accepted language cannot shift with the ambient locale.
* **File content is never echoed.** Policy files sit beside secrets in CI logs. Only
  coordinates, the error code, and the structural key are printed — and the key is capped
  at 64 bytes.
* **Nothing is written to stdout on rejection.** A partially-built document is precisely
  the state in which an overwritten duplicate has already been lost.

---

## 7. Normalized representation

`yp_normalize <file>` emits one JSON document with:

* recursively sorted keys (`jq -S`) — deterministic ordering;
* stable scalar typing (§3.1);
* no comments, no backend-specific fields, no ambiguous numbers;
* no lossy conversion of quoted strings;
* valid UTF-8, validated by the tokenizer rather than by `jq` (which silently substitutes
  U+FFFD for malformed bytes);
* duplicate-free **by construction**;
* serializer-backed output — no hand-built escaping anywhere.

Provenance travels in a **sidecar**, via `yp_envelope <file>`, so the public policy JSON
stays schema-compatible:

```json
{
  "parser_contract": "sentinel-shield-yaml-subset/v1",
  "input_sha256": "sha256:…",
  "normalized": { }
}
```

---

## 8. Relationship to `yq`

`yq` is **not** a backend. It is an independent oracle used only by the test suite.

`tests/prod/257-yaml-policy-contract.sh` proves this three ways: the library is statically
checked to contain no `yq` invocation; the whole corpus is run with a **poisoned** `yq`
shim that reports if it is ever executed; and the corpus digest must be byte-identical with
`yq` present, poisoned, and absent. Merely hiding `yq` behind `PATH` would not prove it.

Where the contract claims to agree with YAML at large, that claim is checked rather than
asserted: all 18 accepted fixtures **and every policy file this repository ships** are
re-parsed with real `yq` and must match byte-for-byte.

The deliberate divergences are the type decisions in §3.1, held in
`tests/fixtures/yaml-policy/divergent/` and excluded from the oracle comparison by design.

---

## 9. Consumer migration status

| Consumer | Input | Status |
|---|---|---|
| `scripts/lib/tool-policy-override.sh` | `tool-policy.yaml` | **Migrated** |
| `scripts/resolve-effective-profile.sh` | `tool-policy.yaml` | **Migrated** (delegates to the loader above) |
| `scripts/resolve-gates.sh` | `profile.yaml` | **Migrated** |
| `scripts/doctor.sh` (`profiles:` list) | `profile.yaml` | **Migrated** |
| `scripts/lib/quality-policy.sh` | `quality-policy.yaml` | **Not migrated** — different file, different issue |
| `scripts/lib/testing-discipline-policy.sh` | `testing-discipline-policy.yaml` | **Not migrated** — as above |
| `scripts/lib/architecture-policy.sh` | `architecture-policy.yaml` | **Not migrated** — as above |

Every reader of `profile.yaml` and of `tool-policy.yaml` — the two file types named by
#259, #260 and #264 — now goes through this contract. No bypass remains for either.

The three unmigrated libraries read **different files** and are consumed almost entirely by
`scripts/runners/*`, which is M4 collector territory. They keep their existing documented
behaviour and their existing dual-backend caveat until their own issue moves; nothing in
this contract changes them.

---

## 10. Compatibility and migration

Every policy/profile file this repository ships parses under the new contract **and matches
the `yq` oracle byte-for-byte** — verified in the suite, not assumed. No shipped file needed
migration.

One documented promise did change. `templates/profile.yaml` and `docs/gate-resolution.md`
previously said that advanced YAML (anchors, aliases, inline collections, block scalars)
would work *if you installed `yq` v4*. That promise is the defect: it is precisely how
installing a binary changed policy interpretation. Advanced YAML is now rejected
**uniformly**, whether or not `yq` is installed, and those documents have been corrected.

Rejections name the construct and the fix rather than saying "invalid configuration" — for
example `YAML_UNSUPPORTED_MERGE_KEY at=14:5`, whose remedy is to write the mapping entries
out explicitly.

Consuming projects that relied on advanced YAML in `profile.yaml` or `tool-policy.yaml`
must simplify to the canonical format. Given that no shipped template, example, or profile
used any such construct, this is expected to be an empty set in practice — but it is a
contract change, and it is why the contract carries a version in its id.
