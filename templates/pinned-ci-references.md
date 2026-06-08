# Pinned CI References

> Generic template. Copy to `docs/security/pinned-ci-references.md`. Records why CI refs
> are pinned and the tag→SHA/digest mapping. See `docs/remediation/github-actions-sha-pinning.md`
> and `docs/remediation/docker-base-digest-pinning.md`.

## Why
Tags/branches are mutable; commit SHAs and image digests are immutable. Pinning prevents a
moved upstream ref from silently changing CI behavior.

## Sentinel Shield ref
| | Value |
| --- | --- |
| Tag | `<vX.Y.Z>` |
| Pinned SHA | `<full 40-char commit SHA>` |
| Resolved via | `gh api repos/<owner>/sentinel-shield/commits/<tag> --jq .sha` |

## GitHub Actions (`uses:`) — commit SHAs
| Action | Tag | Pinned SHA |
| --- | --- | --- |
| _actions/checkout_ | _v4_ | _<sha>_ |

## Container images — digests
| Image | Tag | Digest |
| --- | --- | --- |
| _semgrep/semgrep_ | _latest_ | _@sha256:…_ |

## Base images (Dockerfiles) — digests
| File / stage | Tag | Digest |
| --- | --- | --- |
| _Dockerfile base_ | _php:8.3-fpm-alpine_ | _@sha256:…_ |

## Update / rollback
- Resolve the new SHA/digest, replace it, refresh the `# tag` comment, update this table.
- Open a PR; confirm the Sentinel Shield gate stays green before merge.
- Reverting = restore the prior SHA/digest from this table or git history.
