# Source verification (immutable checkout integrity)

`scripts/acquire-sentinel-shield.sh` always acquires an **immutable** checkout (a
tag or a full 40-hex commit SHA; moving branches are refused). `--verify` asserts
the checkout HEAD equals the resolved ref commit — a **commit-identity** check.

`scripts/lib/source-verification.sh` (sourced `sv_*` helpers) adds **opt-in**
verification of the TREE content and/or a signed annotated tag, layered on top.
The contract is **explicit and honest**: a value that is *calculated but not
compared* is never labelled "verified".

## Modes (`--verify-source <mode>`)

| mode                      | what it does                                                                                     |
| ------------------------- | ----------------------------------------------------------------------------------------------- |
| `tree-record`             | Compute `HEAD^{tree}` and **RECORD** it. This is a record, not a check — it compares against nothing and proves nothing on its own. |
| `tree-checksum`           | **REQUIRE** `--expected-tree <40-hex>`; compute `HEAD^{tree}`; compare **EXACTLY**; **fail closed** on mismatch; record BOTH ids. |
| `signature`               | Verify a **signed annotated tag** with `git verify-tag` and confirm it peels to the resolved commit; **fail closed**. |
| `tree-checksum+signature` | Both of the above.                                                                              |
| `checksum` *(deprecated)* | Backward-compatible alias for `tree-record` (record-only). Emits a deprecation warning.          |

**Every** mode ALSO independently asserts `HEAD == the resolved commit` FIRST
(`sv_assert_commit`), so `sv_verify` is safe and meaningful even when called on its
own, and a tree or signature check can NEVER bypass commit identity.

```sh
# record the tree id (no comparison)
sh scripts/acquire-sentinel-shield.sh --repository owner/repo --ref v1.2.3 \
   --destination <dir> --verify --verify-source tree-record

# compare the tree against a known-good expected tree id (fail closed on mismatch)
sh scripts/acquire-sentinel-shield.sh --repository owner/repo --ref v1.2.3 \
   --destination <dir> --verify --verify-source tree-checksum \
   --expected-tree 1a2b3c…<40-hex>

# verify a signed annotated tag (fail closed if unsigned/bad/wrong-target)
sh scripts/acquire-sentinel-shield.sh --repository owner/repo --ref v1.2.3 \
   --destination <dir> --verify --verify-source signature
```

## Signatures: GPG **or** SSH

`git verify-tag` validates **GPG or SSH** signatures according to the
repository/user Git configuration (`gpg.format`, the verifying keyring, or
`gpg.ssh.allowedSignersFile`) — it is **not** restricted to GnuPG. Signature mode:

* requires an **annotated** tag — a **lightweight** tag or an absent ref fails;
* fails on an **unsigned** annotated tag or a **bad/unverifiable** signature;
* on a good signature, additionally requires the tag to **peel to the expected
  commit** (a signed tag targeting the wrong commit fails commit identity);
* **fails closed** when no verification material is available (e.g. a minimal CI
  sandbox with no key) — an unverifiable signature is never treated as verified;
* records the signature status, best-effort mechanism (`gpg`/`ssh`/`unknown`), tag
  object id, and peeled commit — and **never** logs a signer identity or local key
  path in any failure reason.

## Recorded fields

The outcome is written into `.sentinel-shield-ref` (see
`schemas/installation-metadata.schema.json`), additively:

| field                 | when                | meaning                                                        |
| --------------------- | ------------------- | -------------------------------------------------------------- |
| `verification_method` | always              | `none` / `tree-record` / `tree-checksum` / `signature` / `tree-checksum+signature` |
| `tree_calculated`     | any tree mode       | the computed `HEAD^{tree}` id                                  |
| `tree_expected`       | `tree-checksum` only | the caller-supplied expected tree id (equals `tree_calculated` on a match) |
| `signature_status`    | signature modes     | `good` (a bad signature fails closed and writes no record)     |
| `signature_mechanism` | signature modes     | `gpg` / `ssh` / `unknown`                                      |
| `tag_object`          | signature modes     | the annotated tag object id                                    |
| `peeled_commit`       | signature modes     | the commit the signed tag peels to (equals `resolved_commit`)  |

`tree-record` NEVER records a `tree_expected`: an uncompared value is a record,
not a match. A `tree-checksum` mismatch, a wrong signature, or a commit-identity
mismatch **fails closed** (exit 4) and writes **no** ref record.

## Regression coverage

`tests/prod/12-source-verification.sh` builds local git fixtures (lightweight,
unsigned annotated, and stub-signed annotated tags) and asserts the full contract:
commit assertion (mismatch/malformed/missing), tree-record vs tree-checksum
(match/mismatch/missing-expectation), signature fail-closed cases, and a
good-signature-but-wrong-commit identity failure. The cryptographic primitive is
stubbed via a fake `gpg.program` so the `git verify-tag` machinery is exercised
end-to-end without provisioning a signing identity; a real GPG identity, when
present, drives the same integration path.
