# Docker Security Standard

Container hardening rules enforced by [`../profiles/docker`](../profiles/docker),
Hadolint, Trivy, and [`../policies/opa/docker.rego`](../policies/opa/docker.rego).

These rules apply to application images and Compose definitions. Each rule states
the requirement and why it exists.

---

## 1. Non-root user

Run the application as a dedicated unprivileged user. A compromised process should
not be root inside the container.

```dockerfile
RUN addgroup --system app && adduser --system --ingroup app app
USER app
```

OPA denies images that have no `USER` directive or that set `USER root`.

---

## 2. Minimal images

Use the smallest viable base (`-slim`, `-alpine`, distroless). Fewer packages means
less attack surface and fewer CVEs to patch.

Prefer multi-stage builds so build tooling never ships in the runtime image.

---

## 3. No secrets in image layers

Never `COPY` `.env`, keys, or credentials into an image, and never bake secrets into
`ENV`/`ARG`. Layers are extractable; deleting a file in a later layer does not remove
it from history.

- Inject secrets at runtime (env from a secret manager, mounted files, BuildKit
  `--mount=type=secret`).
- Trivy and Gitleaks scan for secrets in images and layers.

---

## 4. No privileged containers

`privileged: true` grants the container near-host capabilities and defeats isolation.
It is denied by policy. The same applies to `--cap-add=SYS_ADMIN` and host PID/IPC
namespaces.

---

## 5. Read-only filesystem where possible

Run with a read-only root filesystem and mount only the specific writable paths the
app needs (e.g. `/tmp`, a cache dir). This blocks tampering with binaries and config.

```yaml
services:
  app:
    read_only: true
    tmpfs:
      - /tmp
```

---

## 6. Healthchecks

Define a healthcheck so orchestrators can detect and replace unhealthy containers.

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1
```

---

## 7. Resource limits

Set CPU and memory limits to contain runaway processes and resource-exhaustion DoS.

```yaml
services:
  app:
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
```

OPA flags Compose services and Kubernetes workloads with no limits.

---

## 8. Pinned image versions

Pin base images to a specific version, ideally by digest. `latest` is non-reproducible
and silently changes under you. Denied by policy and flagged by Hadolint (DL3007).

```dockerfile
FROM node:22.5.1-bookworm-slim@sha256:<digest>
```

---

## 9. Least-privilege capabilities

Drop all Linux capabilities and add back only what is required.

```yaml
services:
  app:
    cap_drop: ["ALL"]
    cap_add: ["NET_BIND_SERVICE"]  # only if binding < 1024
    security_opt:
      - no-new-privileges:true
```

---

## Enforcement summary

| Rule | Hadolint | Trivy | OPA |
| --- | --- | --- | --- |
| Non-root user | DL3002 | — | ✅ |
| Pinned base image | DL3006/DL3007 | — | ✅ |
| No secrets in layers | — | ✅ | — |
| No privileged | — | misconfig | ✅ |
| Read-only FS | — | misconfig | ✅ (warn) |
| Resource limits | — | misconfig | ✅ |
| Healthcheck | DL3057 (configurable) | — | ✅ (warn) |

See [`../profiles/docker/Dockerfile.standard.md`](../profiles/docker/Dockerfile.standard.md)
and [`../profiles/docker/compose.security.md`](../profiles/docker/compose.security.md)
for full reference implementations.
