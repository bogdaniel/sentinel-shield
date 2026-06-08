# Remediation: Docker DL3018 (unpinned apk/apt) decision tree

**What it means.** Hadolint DL3018 (apk) / DL3008 (apt) flags `add/install <pkg>` without
a pinned `=<version>`. Unpinned installs are non-reproducible and can pull a changed
package on rebuild.

**Decision tree.**
1. **Is the package set small and from a stable distro repo?** → **Pin** `pkg=version`.
   Resolve versions from the base image and commit them. Clears the finding.
2. **Does the set include fast-moving / large stacks** (Chromium, full Playwright deps,
   third-party PPAs like ondrej/nodesource/pgdg)? → Pinning is **brittle** (versions are
   retained only briefly upstream; pins break on the next base/repo refresh).
   a. **Can the heavy stack be isolated?** → See
      [`browser-stack-isolation.md`](browser-stack-isolation.md); remove it from the app
      image, then pin the small remainder.
   b. **Not now?** → Record a **finding-scoped** accepted-risk (rule_id DL3018/DL3008 +
      the specific files), owner + reason + expiry. Keep it visible; revisit before expiry.
3. **Always** digest-pin the base image regardless — see
   [`docker-base-digest-pinning.md`](docker-base-digest-pinning.md). It improves
   reproducibility but does NOT by itself clear DL3018/DL3008.

**When acceptable.** Time-boxed, finding-scoped acceptance of a genuinely-brittle stack,
with a documented plan. Never a broad gate suppression and never a blanket
`# hadolint ignore`.

**Validation steps.** Re-run Hadolint via Sentinel Shield; confirm pinned lines clear and
only the accepted (visible) findings remain.

**Rollback considerations.** Version pins can break a build when upstream drops a revision
— keep the base image digest-pinned so the pinned versions stay resolvable longer.
