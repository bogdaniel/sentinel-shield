# Fixture consumer projects (v0.1.13)

Minimal, offline, NOT full apps. Used by `scripts/self-test.sh install-sync` and
`fixtures` to exercise detect-stack, install/sync, profile resolution, and enforcement
with example summaries. No network, no real dependency installs.

| Fixture | Detects | Purpose |
|---|---|---|
| laravel-react-docker | laravel, react, node, docker | full combination install/sync |
| node-react | node, react | JS-only stack |
| docker-only | docker | Dockerfile/compose-only |
| php-library | php (not laravel) | plain PHP package |
