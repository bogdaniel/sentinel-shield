# Standard Hardened Dockerfile

Reference Dockerfiles implementing the [Docker Security Standard](../../docs/docker-security-standard.md).
Copy and adapt; do not deploy verbatim without pinning a real digest.

---

## PHP-FPM (Laravel / Symfony) — multi-stage

```dockerfile
# syntax=docker/dockerfile:1

# ---- Build stage: composer + assets ----
FROM composer:2@sha256:<pin-digest> AS vendor
WORKDIR /app
COPY composer.json composer.lock ./
RUN --mount=type=cache,target=/tmp/composer \
    composer install --no-dev --no-scripts --prefer-dist --no-interaction --no-progress
COPY . .
RUN composer dump-autoload --optimize --no-dev

# ---- Runtime stage: minimal, non-root ----
FROM php:8.3-fpm-alpine@sha256:<pin-digest> AS runtime

# Install only required extensions, then clean up.
RUN apk add --no-cache fcgi \
 && docker-php-ext-install -j"$(nproc)" pdo_mysql opcache

# Create an unprivileged user.
RUN addgroup -S app && adduser -S -G app app

WORKDIR /var/www
COPY --from=vendor --chown=app:app /app /var/www

USER app

# Healthcheck (php-fpm ping via fcgi).
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD REQUEST_METHOD=GET SCRIPT_NAME=/ping SCRIPT_FILENAME=/ping \
      cgi-fcgi -bind -connect 127.0.0.1:9000 || exit 1

EXPOSE 9000
CMD ["php-fpm"]
```

---

## Node.js — multi-stage

```dockerfile
# syntax=docker/dockerfile:1

# ---- Build ----
FROM node:22.5.1-bookworm-slim@sha256:<pin-digest> AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build && npm prune --omit=dev

# ---- Runtime ----
FROM node:22.5.1-bookworm-slim@sha256:<pin-digest> AS runtime
ENV NODE_ENV=production
WORKDIR /app

# node:* images ship a non-root "node" user — use it.
COPY --from=build --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --from=build --chown=node:node /app/package.json ./

USER node

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8080/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

EXPOSE 8080
CMD ["node", "dist/server.js"]
```

---

## Rules embodied above

| Rule | How |
| --- | --- |
| Non-root user | `USER app` / `USER node` |
| Minimal image | `-alpine` / `-slim`, multi-stage drops build tooling |
| Pinned base | `@sha256:<digest>` (replace placeholders with real digests) |
| No secrets in layers | Secrets injected at runtime; `--mount=type=secret` for build |
| Healthcheck | `HEALTHCHECK` directive |
| Reproducible deps | `composer install --no-dev` from lock, `npm ci` |

Resource limits, read-only filesystem, capability dropping, and `no-new-privileges`
are set at run time — see [`compose.security.md`](compose.security.md).

Replace every `<pin-digest>` with a real digest:

```sh
docker pull php:8.3-fpm-alpine
docker inspect --format='{{index .RepoDigests 0}}' php:8.3-fpm-alpine
```
