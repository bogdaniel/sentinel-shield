# Hardened Docker Compose Patterns

Runtime hardening for Compose services, implementing the
[Docker Security Standard](../../docs/docker-security-standard.md). These settings
are validated by Trivy (misconfig) and [`policies/opa/docker.rego`](../../policies/opa/docker.rego).

---

## Reference service

```yaml
services:
  app:
    # Pin the image; never :latest.
    image: registry.example.com/app:1.4.2

    # Do not run as root; match a non-root UID:GID in the image.
    user: "10001:10001"

    # Read-only root filesystem; mount only what must be writable.
    read_only: true
    tmpfs:
      - /tmp
      - /var/run

    # Drop all capabilities; add back only what is strictly required.
    cap_drop: ["ALL"]
    # cap_add: ["NET_BIND_SERVICE"]   # only if binding a port < 1024

    # Block privilege escalation.
    security_opt:
      - no-new-privileges:true

    # No privileged mode, no host namespaces (these are the defaults — keep them).
    privileged: false

    # Resource limits to contain runaway / DoS.
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 512M
        reservations:
          memory: 128M

    # Healthcheck so the orchestrator can detect failure.
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://127.0.0.1:8080/health"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 10s

    # Secrets are injected at runtime, never baked into the image.
    environment:
      NODE_ENV: production
    secrets:
      - db_password

    # Expose only what is needed; bind to localhost if fronted by a proxy.
    ports:
      - "127.0.0.1:8080:8080"

    networks:
      - internal

secrets:
  db_password:
    file: ./secrets/db_password.txt   # or an external secret manager

networks:
  internal:
    driver: bridge
```

---

## Anti-patterns (denied / flagged)

```yaml
# DON'T:
services:
  bad:
    image: app:latest          # unpinned — non-reproducible
    privileged: true           # full host access
    network_mode: host         # breaks network isolation
    user: root                 # runs as root
    environment:
      DB_PASSWORD: hunter2      # secret in plaintext env
    # no resource limits, no healthcheck, no cap_drop
```

---

## Validation

```sh
docker compose config        # validates and renders the merged config
trivy config docker-compose.yml
conftest test docker-compose.yml --policy ../../policies/opa/docker.rego
```

| Setting | Why |
| --- | --- |
| `user:` non-root | Limit blast radius of compromise |
| `read_only: true` | Prevent binary/config tampering |
| `cap_drop: [ALL]` | Least privilege |
| `no-new-privileges` | Block setuid escalation |
| resource limits | Contain DoS / runaway |
| pinned image | Reproducible, auditable |
| runtime secrets | No secrets in image or VCS |
