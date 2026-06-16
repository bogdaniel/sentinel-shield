# Consumer Cleanup / Lifecycle (v1.8.0 — A08)

After capturing evidence (e.g. the Deptrac silver-potato run, or an evidence-only IaC workflow), clean
up the consumer safely. **Nothing here deletes anything automatically** — these are commands/checklists
you run deliberately. Linked from [`live-validation-playbook.md`](live-validation-playbook.md) and
[`security-hygiene.md`](security-hygiene.md).

## Branch cleanup

```sh
# delete a remote evidence-only branch after the run ID + artifact are recorded
gh api -X DELETE repos/<owner>/<repo>/git/refs/heads/evidence/<branch>
# or
git push origin --delete evidence/<branch>
```
The CI **run ID and artifacts persist** in Actions history after the branch is gone — cite the run ID
in the registry first.

## Evidence workflow cleanup

- Remove the evidence-only workflow file from the branch (or delete the branch).
- Or disable it: Actions tab → workflow → **Disable workflow** (keeps history).

## GitHub secret rotation

```sh
# rotate / remove a repo secret (e.g. the NVD key) when no longer needed
gh secret set SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY --repo <owner>/<repo>   # rotate
gh secret delete SENTINEL_SHIELD_DEPENDENCY_CHECK_NVD_API_KEY --repo <owner>/<repo> # remove
```
Rotate on schedule per [`security-hygiene.md`](security-hygiene.md). **Never** print or commit values.

## Artifact retention

Set `retention-days` on uploads; old artifacts expire automatically. Manually delete via Actions UI if
an artifact must go sooner.

## Accepted-risks review

Periodically review `.sentinel-shield/accepted-risks.json`: remove expired/obsolete entries; never
auto-prune. `secrets` are never suppressible.

## Stale evidence reports

Remove stale local `reports/` (gitignored anyway) and outdated `*-vNNN` evidence fixtures that a newer
run supersedes — keeping the registry as the source of truth.

## Consumer handoff checklist

- [ ] Run ID + artifact recorded in the registry.
- [ ] Evidence branch deleted or workflow disabled.
- [ ] Secrets rotated/removed if no longer needed.
- [ ] No raw private artifact committed anywhere.
- [ ] `accepted-risks.json` reviewed.

## What NOT to delete

- The **engine** files / managed workflow you actually gate with.
- `accepted-risks.json` (project-local risk decisions).
- Released **tags** or registry history.
- The cited **run ID** reference (immutable evidence).
