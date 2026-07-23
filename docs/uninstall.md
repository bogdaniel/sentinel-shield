# Removing Sentinel Shield (offboarding)

A production adopter needs a documented way to fully remove Sentinel Shield, not just lower
its gate mode. This is the complete offboarding checklist. Lowering the mode
(`docs/quickstart.md` §11) or rolling back the managed workflow
(`docs/consumer-cleanup.md`) is a *pause*; the steps below are a *full removal*.

> Do this on a branch and open a PR — removing the gate is a change reviewers should see.

## 1. Stop the gate from running

- Delete the managed workflow(s) under `.github/workflows/` that Sentinel Shield installed
  (`sentinel-shield*.yml` — check the `# === MANAGED BY SENTINEL SHIELD ===` header).
- If Sentinel Shield was vendored (Option A), also remove the vendored
  `tools/sentinel-shield/` (or wherever `SENTINEL_SHIELD_PATH` pointed).

## 2. Remove branch-protection required checks

If you wired the gate's check names into branch protection
(`docs/branch-protection.md`), remove them under **Settings → Branches → your rule →
Require status checks**, or via the API. Otherwise the branch stays blocked on a check that
no longer runs.

## 3. Remove the project-local config and evidence

- `.sentinel-shield/` — the profile, tool-policy overrides, accepted-risks, and any
  `operation-lock*`/`transaction-journal*` state.
- `reports/` — generated summaries and raw scanner reports (if committed; usually gitignored).
- `evidence/` — any committed release-evidence bundles, if you used them.
- Managed docs Sentinel Shield wrote under `docs/security/` (check the managed header).

## 4. Remove secrets and CI wiring

- Delete any repository/organization secrets you added for the gate (for example
  `SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY`, a read token for a private engine repo).
- Remove Sentinel Shield entries from `.github/dependabot.yml` if you added the engine there.

## 5. Clean `.gitignore`

Remove the `reports/`, `.sentinel-shield/`-state, and any scanner-cache entries Sentinel
Shield asked you to ignore, if you no longer want them ignored.

## 6. Verify

- Confirm no `sentinel-shield*` workflow remains: `ls .github/workflows/`.
- Confirm no required check references the removed gate in branch protection.
- Push the branch and confirm CI is green without the gate.

Nothing Sentinel Shield installs runs outside these locations — there is no global install,
daemon, or hook to remove.
