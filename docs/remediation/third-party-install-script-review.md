# Remediation: Third-party dependency install-script review

**What it means.** Sentinel Shield's third-party supply-chain channel flags dependencies
whose `preinstall`/`install`/`postinstall` scripts run arbitrary code at install time
(`third_party_install_script_risk`). This is a supply-chain execution surface.

**When it is real.** A transitive/new dependency runs network calls, writes outside its
package dir, downloads binaries, or reads environment/secrets during install.

**When it may be acceptable.** Well-known packages with legitimate native-build scripts
(e.g. `esbuild`, `sharp`) that compile/download a platform binary. Expected, but still
worth recording.

**Recommended review.**
1. Read the actual script (`node_modules/<pkg>/package.json` scripts + referenced files).
2. Classify: legitimate native build vs. suspicious (obfuscation, exfiltration, env reads,
   curl|sh).
3. For suspicious: pin/replace/remove the dependency; report upstream; consider
   `--ignore-scripts` in CI where feasible.
4. For legitimate: record it in the third-party install-script review template
   (package, version, what the script does, why accepted).

**Accepted-risk guidance.** The third-party channel is non-blocking by default in
report-only/baseline; do not silence it. Document accepted packages in the review template
rather than suppressing the gate.

**Validation steps.** Re-run the third-party scan; confirm only reviewed packages remain
and each has a register entry.

**Rollback considerations.** `--ignore-scripts` can break packages that need their native
build; test the app after enabling it.
