# Remediation: GitHub Actions SHA pinning

**What it means.** `uses: owner/action@v4` (or `@main`, a tag, or no ref) resolves a
**mutable** reference: the owner can move the tag/branch, changing what runs in your CI
with your secrets. `unsafe_github_actions` (via the pin audit) flags these.

**When it is real.** Always, for third-party actions in any workflow with access to
secrets, packages, or deploy credentials. Tags are not immutable.

**When it may be acceptable.** First-party actions in the same org under your control, or
a short-lived experiment — but pinning is cheap, so prefer it everywhere.

**Recommended fix.** Pin to a full 40-char commit SHA, keeping the human tag as a comment:

```yaml
uses: actions/checkout@<40-hex-sha> # v4
```

Resolve with `gh api repos/<owner>/<action>/commits/<tag> --jq .sha`. Pin container images
by digest (`image@sha256:...`). Keep a mapping table (see
[`docker-base-digest-pinning.md`](docker-base-digest-pinning.md) and the
`pinned-ci-references` template). Update deliberately, re-resolving the SHA.

**Accepted-risk guidance.** `unsafe_github_actions` is **not** suppressible via
accepted-risks by default — fix the pins. Local (`./`) actions are exempt.

**Validation steps.** Run `scripts/audit-github-actions-pins.sh`; confirm zero findings.
Re-run the workflow to ensure the pinned SHA resolves.

**Rollback considerations.** Each pin carries its `# vX` comment, so reverting is
mechanical. A wrong SHA fails fast (action not found) — safe, not silent.
