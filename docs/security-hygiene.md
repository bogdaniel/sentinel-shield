# Security Hygiene — Secrets, Key Rotation, Artifact Retention

> Operational hygiene for adopting Sentinel Shield. Covers the NVD API key (rotation + safe handling),
> verifying no secret was committed, consumer evidence-branch cleanup, and artifact retention.
> **Never print, log, commit, or paste a key value** anywhere.

## NVD API key — rotation

The NVD key is **consumer-provided** via the GitHub secret `SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY`.
Rotate it if it may have been exposed (e.g. pasted into a chat/log) or on a periodic cadence.

1. Request/regenerate a key at **https://nvd.nist.gov/developers/request-an-api-key** (free; email +
   org; activate via the email link). The old key keeps working until you stop using it.
2. Update the GitHub Actions secret (value read from a local file or prompt — **never** echoed):
   ```sh
   # value piped from a 0600 file you control; gh never prints it:
   gh secret set SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY \
     --repo <owner>/<consumer> < /path/to/new-key-file
   # or interactively (gh prompts and hides input):
   gh secret set SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY --repo <owner>/<consumer>
   ```
3. Re-run the Dependency-Check workflow; confirm it authenticates (no HTTP 429) and the propertyfile
   path stays leak-safe (see below).
4. Delete the old key from any local file; do **not** keep it in shell history (`unset HISTFILE` or
   prefix the command with a space if your shell ignores space-prefixed history).

**How the key is handled (already enforced by the wrapper):** passed only via a container-readable but
**ephemeral** propertyfile (removed on exit via `trap`); **never** on the command line / process list,
in logs, in the report, or committed. Verified by `self-test v026-live`/`v030-live`.

## Verify no key was committed

Search tracked files for UUID-shaped strings (the NVD key shape) — **report the location, never the value**:

```sh
# 0 matches expected. Do NOT print any matching value in shared logs.
git grep -nIE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' -- \
  scripts/ docs/ examples/ templates/ profiles/ schemas/ github/

# Confirm the key name appears only as a variable/secret reference, never with an inline value:
git grep -n 'SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY' .
```

If a real key is ever found committed: **rotate immediately** (above), then purge history with
`git filter-repo` / BFG and force-push (coordinate — rewriting history is disruptive). A rotated key
makes the leaked one useless, which is the faster mitigation.

## Consumer evidence-branch cleanup

Evidence runs use a dedicated branch on the consumer (e.g. `ss-…-strict-evidence`,
`release/v100-rc2-consumer-soak`), kept off the default branch (the consumer's `deploy.yml` may trigger
on push to `main`). After the run ID + artifacts are cited, the branch can be deleted — the run history
and artifacts persist:

```sh
gh api -X DELETE repos/<owner>/<consumer>/git/refs/heads/<evidence-branch>
# or: git push origin --delete <evidence-branch>
```

Do not commit raw private consumer artifacts (e.g. a private repo's `dependency-check.json`) into this
**public** repo — cite aggregate counts only.

## Artifact retention

- Workflow artifacts upload with `retention-days: 30` and `if: always()` (raw reports survive scanner
  failure/findings). Lower the retention for sensitive consumers if needed.
- Raw reports live under `reports/` which is **gitignored** — they are CI artifacts, not committed.
- The NVD cache lives under `.sentinel-shield/cache/` (gitignored); it contains NVD data, never the key.

## .gitignore coverage (confirm in each consumer + this repo)

```txt
/reports/                 # raw scanner output + summaries (CI artifacts)
.sentinel-shield/         # NVD cache + local runtime state
.claude/                  # local agent metadata (never commit)
graphify-out/             # local tooling output
```

Verify: `git check-ignore reports/raw/x .sentinel-shield/cache/x .claude/x` should print each path.
