# Remediation: Docker base-image digest pinning

**What it means.** `FROM image:tag` resolves a **mutable** tag — the same Dockerfile can
build a different base over time. Sentinel Shield's base-digest detector flags this
(contributes to `unsafe_docker`). This is **distinct** from DL3018/DL3008 (package pinning).

**When it is real.** Any externally-maintained base referenced by tag (or no tag →
implicit `:latest`) in an image you build/ship.

**When it may be acceptable.** A throwaway local build, or a base driven by a build ARG the
project controls deliberately. Multi-stage `FROM <previous-stage>` is fine (not a base).

**Recommended fix.** Pin the base by digest, keeping the tag as a comment:

```dockerfile
FROM php:8.3-fpm-alpine@sha256:<digest>   # php:8.3-fpm-alpine
```

Resolve with `docker buildx imagetools inspect <image>:<tag> --format '{{.Manifest.Digest}}'`
(multi-arch safe). Update deliberately after validating a newer base. Digest-pinning aids
reproducibility but does NOT clear DL3018/DL3008 — pin packages separately.

**Accepted-risk guidance.** Prefer fixing (digest-pinning is low-risk). If deferred,
record a finding-scoped accepted-risk; do not broadly suppress `unsafe_docker`.

**Validation steps.** Run `scripts/audit-docker-base-digest.sh`; confirm zero findings.
Build the image to confirm the digest resolves.

**Rollback considerations.** A pinned digest never drifts; to take base updates you must
bump it intentionally (that is the point). Keep the tag comment for traceability.
