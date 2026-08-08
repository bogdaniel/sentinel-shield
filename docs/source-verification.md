# Source verification and trust anchors

## A tag name is not an identity

`scripts/acquire-sentinel-shield.sh` refuses moving branches and accepts only a tag
or a full 40-hex commit SHA. That is necessary, and it is **not sufficient**, and
earlier versions of this document said otherwise.

A git tag can be deleted and recreated, or force-moved. Resolving `v1.2.3` therefore
tells you what that name meant *at that instant* — nothing more. The old default path
resolved the tag, cloned it again **by name**, and checked that the clone's HEAD
matched the value resolved a moment earlier. That proves one command was internally
consistent. It does not prove the same tag will install the same code tomorrow, and it
does not prove the tag was published by the project's release signer.

So acquisition now separates three values that a ref name used to blur together —
the **requested ref**, the **resolved commit**, and the **resolved tree** — and states
its **trust anchor** explicitly in the record.

## Trust anchors

An anchor is a binding that exists **outside the mutable ref namespace**. There are
three, and an acquisition may carry more than one:

| anchor              | how you get it                                              | what it pins                                   |
| ------------------- | ------------------------------------------------------------ | ---------------------------------------------- |
| `requested-commit`  | `--ref <40-hex SHA>`                                          | The caller named the content. Nothing in the ref namespace can change what is delivered. |
| `expected-tree`     | `--verify-source tree-checksum --expected-tree <40-hex>`      | The exact tree content, compared out of band.  |
| `signed-tag`        | `--verify-source signature --trusted-signers <file>`          | The identity that published the tag.           |

With none of them, the acquisition still succeeds — a tag is a legitimate way to ask
for a version — but it is recorded as trust level `resolved-ref` with
`trust.anchored: false`, and `acquire` says so on stderr. Nothing in the system
describes it as immutable.

```sh
# Production / release: refuse anything that is not anchored.
sh scripts/acquire-sentinel-shield.sh --repository owner/repo --ref v1.2.3 \
   --destination <dir> --require-trust anchored \
   --verify-source signature --trusted-signers .sentinel-shield/allowed-signers
```

`--require-trust anchored` (or `SENTINEL_SHIELD_REQUIRE_TRUST=anchored` for automation
that cannot edit a command line) fails closed with **exit 5** when no anchor could be
established.

## Moved tags and the resolution/fetch race

Two distinct failures, both **exit 5**:

* **Moved tag across installations.** If a destination previously recorded the same
  repository and the same tag name resolving to a *different* commit, acquisition
  refuses. The requested version did not change but the code behind it did. There is
  no flag to suppress this, because a flag is exactly how it would get suppressed —
  the deliberate escape is to review the change and then either pin `--ref <new SHA>`
  or discard the old checkout with a standalone `--cleanup` run.
* **Movement between resolution and fetch.** The transport is still asked for the ref
  by name (the only cheap way to get a shallow tag fetch), but nothing it returns is
  trusted on the strength of that name: the fetched `refs/tags/<ref>` is re-resolved
  locally and compared against the object resolved before the fetch, and the working
  tree is checked out **by object id**. A tag that moves inside that window is
  detected, not installed.

`--no-verify` has been **removed**. It made the HEAD/commit assertion optional, which
is what turned that race from "detected" into "installed and recorded as the requested
version". Passing it is now a hard invocation error (exit 2) carrying a migration
message — silently ignoring it would leave callers believing verification was off
while it was on, and automation propagating a flag nobody validates. There is no
"unsafe development mode": with no such mode, no record can ever describe an
unverified checkout, and there is nothing for `doctor`, release, strict, or regulated
paths to have to exclude.

## Signer trust, rotation, and revocation

`git verify-tag` answers *"did a key git accepts sign this?"*. It does not answer
*"did the project's release signer sign this?"* — and only the second question is
worth anything when a tag can be force-moved. The difference is a **policy**:

* `--trusted-signers <file>` — the identities you trust. Accepts an OpenSSH
  allowed-signers file (`principal namespaces="git" ssh-ed25519 AAAA…`) and/or a list
  of GPG fingerprints/key ids, one per line, `#` comments ignored.
* `--revoked-signers <file>` — identities you have revoked. Evaluated **first**, so a
  revoked key that is still sitting in a stale allow list fails anyway.

For SSH signatures both files are also handed to git itself
(`gpg.ssh.allowedSignersFile` / `gpg.ssh.revocationFile`) because git is the component
that can check a signature against a principal. For GPG the fingerprint is extracted
from the verification status output and matched here, since git has no allowlist
concept.

**Rotation and revocation are ordinary edits to these two files.** Sentinel Shield
stores no key material and operates no key registry: add the new signer's line, and
move the retired one into the revocation list. A file that cannot be read is a policy
that is **not in force**, so an unreadable `--trusted-signers` is refused at
invocation (exit 2) rather than degraded to ambient trust.

Two failure modes are deliberately non-obvious:

* A good signature with **no policy** is recorded honestly
  (`signature_status: good`, `signer_policy: ambient-git-trust`) but is **not** an
  anchor. It proves someone signed the tag, not who.
* A signature whose signer **cannot be identified** fails closed whenever a policy is
  in force — an unattributable signature cannot satisfy an allowlist.

The recorded `trust.signer` is a public identity (`ssh:<principal>`,
`gpg:<fingerprint>`). Local key **file paths** are secrets and are never recorded or
logged.

## Layered checkout verification

`scripts/lib/source-verification.sh` (sourced `sv_*` helpers) adds **opt-in**
verification of the TREE content and/or a signed annotated tag, layered on top of the
always-on commit-identity check. The contract is **explicit and honest**: a value that
is *calculated but not compared* is never labelled "verified".

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

### Version-2 trust fields

The record is `schema_version: 2` and is produced by `jq` from typed arguments — never
by string concatenation, which cannot round-trip a value containing a quote,
backslash, or control character. `jq` is therefore required by `acquire`
(exit 3 when absent); every reader of the record already required it.

| field                  | meaning                                                                       |
| ---------------------- | ----------------------------------------------------------------------------- |
| `schema_version`       | `2`. **Absent** means a version-1 record written before the trust model existed. |
| `resolved_tree`        | The checkout's `HEAD^{tree}` — content identity, recorded independently of commit identity and of the ref name. |
| `trust.level`          | Strongest anchor established: `signed-tag` > `expected-tree` > `requested-commit` > `resolved-ref` (none). |
| `trust.anchored`       | Whether *any* anchor exists. `false` is a first-class, honest outcome.          |
| `trust.anchors[]`      | Every anchor established, not only the strongest.                              |
| `trust.signer`         | `ssh:<principal>` / `gpg:<fingerprint>` (signature modes).                      |
| `trust.signer_policy`  | `trusted-signers-file` (an anchor) or `ambient-git-trust` (not an anchor).      |
| `trust.verified_at`    | RFC3339 UTC. For an unanchored acquisition this timestamp *is* the whole meaning of the record. |

### Migration from version-1 records

A version-1 record has no `trust` object. It states which ref was requested and which
commit it resolved to, and carries **no evidence** about whether that mapping was
anchored — so it is never reinterpreted as one:

* `doctor` reports it as a *pre-trust-model* record: consistent, but not proven
  immutable. It stays `ok`, because an install that was valid under the contract it
  was written to is not retroactively a failure.
* A version-2 record with `anchored: false` is reported as a **warning** (degraded) —
  the acquisition was recent, so the missing anchor is a live choice, not history.
* A version-1 record is never upgraded in place. Re-acquisition is what produces an
  anchor, and re-acquisition is also what would surface a tag that moved in the
  meantime.

## Acquisition lifecycle

```text
INIT
 → RESOLVE_TRUSTED_OBJECT   ls-remote; classify tag|sha; reject moving branches
 → DETECT_MOVED_TAG         compare against any prior record at this destination
 → FETCH                    shallow fetch of the requested ref
 → VERIFY_REF_RELATIONSHIP  re-resolve refs/tags/<ref> locally; must equal the object
                            resolved before the fetch, or exit 5
 → CHECKOUT_EXACT_OBJECT    detach to the commit id, never to a name
 → VERIFY_HEAD              HEAD == expected; NOT optional, no flag disables it
 → VERIFY_SOURCE            optional tree-checksum / signature + signer policy
 → COMPUTE_TRUST_ANCHORS    and enforce --require-trust
 → WRITE_RECORD             jq-serialized, atomic within the destination
 → VERIFIED
```

### What this lifecycle does not yet do

Everything above acquires **into the final destination**. Three gaps remain open, and
they are stated here rather than glossed, because each one is a property a reader might
otherwise assume the lifecycle already has.

1. **No transaction boundary.** A failure between `FETCH` and `WRITE_RECORD` leaves a
   partial checkout at the trusted path, where other automation can discover and execute
   it before verification finished, and a verification failure does not restore the
   previous known-good checkout.
   *Design:* acquire into a unique sibling `\.sentinel-shield.acquire.<operation-id>/`,
   run every gate there, write the record inside the transaction, and promote by
   same-filesystem `rename()` — validating that the promotion really is atomic, and
   failing closed (or using a documented fallback that preserves the old checkout) where
   it cannot be. Single-writer locking, ownership-verified transaction dirs, EXIT/INT/TERM
   handling, and stale-transaction journalling belong to the same change.
2. **Reuse is gated on a cleanliness hint.** `--reuse-existing` accepts a checkout when
   HEAD matches and `git status --porcelain` is empty. That command does not report
   ignored files by default, and says nothing about nested repositories, submodules,
   worktrees, or repository-local git configuration — so a "clean" checkout can carry an
   ignored executable, a vendored dependency, or a hostile `.git/config`. It is also
   self-contradictory today: Sentinel Shield's own untracked `.sentinel-shield-ref` makes
   the check non-empty, so reuse falls through to re-acquisition.
   *Design:* compare the working tree against the expected commit with plumbing
   (`git diff-index`, `ls-files` including ignored and untracked) under explicit config
   isolation, so no repository alias, hook, filter, or local config runs while proving
   integrity; define a versioned allowlist for Sentinel Shield-owned metadata and require
   everything else to be tracked and byte-identical; re-acquire when exactness cannot be
   proven rather than guessing.
3. **Destructive cleanup validates a path, then deletes a path.** `rm -rf "$DEST"` runs
   as a separate operation after `acquire_validate_destination`, so a component swapped
   between the two can redirect the deletion. Canonicalisation alone cannot close that:
   it compares strings, and the string is not the object.
   *Design:* require valid ownership metadata before any automatic removal, take an
   operation-specific lock, revalidate immediately before mutation, and pin identity
   (inode-level where the platform allows) across the check/mutate boundary — with the
   honest caveat that POSIX `sh` may not offer a descriptor-pinned recursive delete on
   every supported platform, in which case the supported set is narrowed and unsupported
   platforms fail closed to manual cleanup.

**Dependency order.** (1) must land before (2) and (3): both need the transaction and
ownership model to say what a Sentinel Shield-owned directory *is*. (3) depends on (2)
only for the metadata allowlist that decides which files legitimately exist outside the
verified commit.

## Regression coverage

`tests/prod/12-source-verification.sh` builds local git fixtures (lightweight,
unsigned annotated, and stub-signed annotated tags) and asserts the full contract:
commit assertion (mismatch/malformed/missing), tree-record vs tree-checksum
(match/mismatch/missing-expectation), signature fail-closed cases, and a
good-signature-but-wrong-commit identity failure. The cryptographic primitive is
stubbed via a fake `gpg.program` so the `git verify-tag` machinery is exercised
end-to-end without provisioning a signing identity; a real GPG identity, when
present, drives the same integration path.

`tests/prod/13-source-trust.sh` covers the trust model itself, offline, against local
git repositories. Every case is a fixture that reproduces the concrete defect, a proof
that the fixture reached the vulnerable path, and an assertion that the current
implementation refuses it — plus a control proving the refusal is specific:

* `--no-verify` refused with a migration message, and the same acquisition succeeding
  without it;
* anchors for full-SHA, expected-tree, and signed-tag, and the absence of one for a
  bare tag or a record-only `tree-record`;
* `--require-trust anchored` refusing an unanchored tag and accepting an anchored one;
* a **moved lightweight tag** and a **replaced annotated tag**, each with a proof that
  the remote ref actually moved, plus an idempotence control on a tag that did not;
* the **resolution/fetch race**, driven by a `git` shim that force-pushes the tag onto
  a different commit at the moment acquisition issues its fetch — with an assertion
  that the shim fired and that the remote ref really changed, so the case cannot pass
  vacuously;
* SSH-signed tags with a **trusted**, an **untrusted**, and a **revoked** signer (real
  `ssh-keygen` identities; reported as SKIP, never PASS, where signing is unavailable),
  the ambient-trust downgrade, and a check that no local key path reaches the record;
* the record's conformance to the closed schema, and `doctor`'s reporting of anchored,
  unanchored, and version-1 records.
