# Security operations — bounding external processes

Sentinel Shield shells out to many external tools during a gate: the Docker
daemon (`docker info` / `docker inspect` / `docker image inspect`), security
scanners (version probes and full scans), the GitHub API (`gh api`), Git
signature verification (`git verify-tag`), package managers (version probes and
installs), archive inspection/extraction, and external consumer validation.

Any of these can **hang indefinitely** when the far side is unreachable or
unhealthy — a wedged Docker daemon, a stuck API endpoint, a scanner waiting on a
dead network. An unbounded child freezes the entire gate, and in CI it burns to
the job's 6-hour ceiling before failing. This is both an availability problem and
a security problem: a gate that never completes never enforces.

## The control: `bp_run`

[`scripts/lib/bounded-process.sh`](../scripts/lib/bounded-process.sh) runs every
such command under a hard, bounded wall-clock timeout:

- **Graceful then forced.** On timeout it sends `TERM` to the whole process tree,
  waits a bounded grace period, then sends `KILL`. Nothing is left running.
- **No orphans.** The command's descendants are enumerated (via `pgrep`) and
  reaped deepest-first, so a child a scanner spawned cannot outlive the timeout.
- **Exit-code preserving.** A command that completes normally returns its real
  exit code, untouched.
- **Distinct outcomes.** The result is classified as `success`, `failed`,
  `timed-out`, `unavailable` (executable missing — never launched), or
  `signalled` (killed by a signal not caused by our timeout).
- **Fail closed on misconfiguration.** A zero, negative, non-numeric, or
  excessive timeout rejects the invocation (return code 2). There is no silent
  coercion to a "safe" value.

See [automation-interface.md](automation-interface.md#bounded-external-processes-bounded-command-result)
for the full configuration table (`SENTINEL_SHIELD_*_TIMEOUT_SECONDS`) and the
`bounded-command-result` output shape.

## The historical defect this closes

Scanner provenance resolution (`scripts/audits/tool-provenance-audit.sh`) resolved
a container image's immutable digest with an **unbounded** `docker inspect`. When
the Docker daemon was unreachable or unhealthy, that call hung forever and the
whole audit stalled — the gate never produced a verdict.

It is now bounded (category `docker-probe`, default 15s). On timeout the digest is
treated as unresolved, so the image is recorded `unverified` and — under
`--require-image-digest` (release-authoritative runs) — the audit **fails closed**
instead of hanging. The timeout is surfaced in the machine report, not hidden:

```json
{
  "tool": "tool-provenance-audit",
  "status": "fail",
  "docker_probe_timeouts": 1,
  "docker_probes": [
    { "schema": "bounded-command-result", "command": "docker",
      "command_category": "docker-probe", "status": "timed-out",
      "exit_code": null, "timeout_seconds": 15, "timed_out": true }
  ]
}
```

An operator can see *why* provenance was unverifiable (the daemon did not answer
within the bound) rather than a silently-empty digest. The same bounding is
applied to the Grype and OSV wrapper version probes and to Grype's `docker
inspect` digest resolution.

## Redaction

Diagnostics and the machine result never include command arguments — only the
executable basename and the command category. Scanner/registry/API invocations
routinely carry tokens, registry credentials, or secret file paths in their
arguments; the bounded-process layer guarantees none of that reaches a log line,
a JSON artifact, or a security summary. This complements the redaction performed
by the `--output json` envelope (see automation-interface.md).

## Verification

`tests/prod/250-bounded-processes.sh` exercises: completion before timeout;
non-zero exit-code preservation; a command that ignores `TERM` and needs `KILL`;
a command that spawns a child (no orphan left); an unresponsive docker probe; a
hanging `gh api`; a hanging scanner version probe; rejection of
zero/negative/non-numeric/excessive timeouts; removal of internal temp files; and
the timeout state reaching both the `bounded-command-result` JSON and the
`tool-provenance-audit` security report. Run it with:

```sh
sh tests/prod/250-bounded-processes.sh
```
