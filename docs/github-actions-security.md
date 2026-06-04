# GitHub Actions Security

CI/CD is part of your attack surface. A compromised workflow can exfiltrate secrets,
tamper with artifacts, or push to production. These rules are enforced by actionlint,
zizmor, OpenSSF Scorecard, and [`../policies/opa/github-actions.rego`](../policies/opa/github-actions.rego).

---

## 1. Minimal token permissions

Set `permissions:` explicitly. Default to read-only at the top level and grant the
narrowest scope per job.

```yaml
permissions:
  contents: read   # top-level default for the whole workflow

jobs:
  release:
    permissions:
      contents: write      # only this job can write
      id-token: write      # only if using OIDC
```

Never use `permissions: write-all`. It is denied by policy.

---

## 2. No unsafe `pull_request_target`

`pull_request_target` runs with repository secrets in the context of a PR from a
fork. Combined with checking out and executing PR code, it is a known
secret-exfiltration vector.

- Prefer `pull_request` (no secrets, runs untrusted code safely).
- If `pull_request_target` is unavoidable, do **not** check out and build the PR
  head, and require explicit approval. Policy flags any
  `pull_request_target` + `actions/checkout` of the PR ref.

---

## 3. Pin sensitive third-party actions

Pin third-party actions to a full commit SHA, not a moving tag. A tag can be
re-pointed to malicious code after you trusted it.

```yaml
# Pinned to a commit SHA (good)
- uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11 # v4.1.1
```

First-party `actions/*` may use a tag in low-sensitivity workflows, but pinning is
preferred everywhere and required in sensitive (deploy/release) workflows.

---

## 4. Avoid shell injection

Never interpolate untrusted event data directly into a `run:` script. Values such as
PR titles, branch names, and issue bodies are attacker-controlled.

```yaml
# Wrong — injectable
- run: echo "Title: ${{ github.event.pull_request.title }}"

# Right — pass through env, quote in shell
- env:
    TITLE: ${{ github.event.pull_request.title }}
  run: echo "Title: $TITLE"
```

---

## 5. Never expose secrets to untrusted PRs

- Workflows triggered by forked PRs must not have access to secrets.
- Do not echo secrets, even masked, into logs.
- Gate deployment/secret-bearing steps on trusted events (push to `master`, tags) or
  on an approved environment with required reviewers.

---

## 6. Separate build / test / deploy permissions

Split responsibilities so a compromised test job cannot deploy:

- Build/test jobs: `contents: read` only.
- Deploy jobs: scoped write/OIDC, gated behind a protected environment with required
  reviewers.
- Use GitHub Environments for production with required approvals.

---

## 7. Other hardening

- Set a top-level `concurrency` to avoid racing deploys.
- Disable credential persistence in checkout when not needed
  (`persist-credentials: false`).
- Run actionlint and zizmor in CI; track OpenSSF Scorecard.
- Pin runner images where reproducibility matters.

---

## Enforcement summary

| Rule | Tool |
| --- | --- |
| Explicit minimal permissions / no write-all | OPA, Scorecard |
| Safe `pull_request_target` | OPA, zizmor |
| Pinned third-party actions | OPA, Scorecard, zizmor |
| No shell injection | zizmor, actionlint |
| No secrets to untrusted PRs | zizmor, review |
| Separated deploy permissions | review, OPA |

See [`../github/workflows`](../github/workflows) for templates that already follow
these rules.
