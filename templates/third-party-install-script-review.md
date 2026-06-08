# Third-Party Install-Script Review

> Generic template. Copy to `docs/security/third-party-install-script-review.md`.
> Records review of dependency install/postinstall scripts flagged by the third-party
> supply-chain channel (`third_party_install_script_risk`). See
> `docs/remediation/third-party-install-script-review.md`.

## Reviewed packages
| Package | Version | Script(s) | What it does | Verdict | Reviewer | Date |
| --- | --- | --- | --- | --- | --- | --- |
| _e.g. esbuild_ | _x.y.z_ | postinstall | downloads platform binary | legitimate native build | _name_ | _date_ |
| _e.g. sharp_ | _x.y.z_ | install | compiles/downloads libvips | legitimate native build | _name_ | _date_ |

## Verdict legend
- **legitimate native build** — expected compile/download of a platform artifact.
- **suspicious** — obfuscation, env/secret reads, outbound exfiltration, `curl | sh`.
  → pin/replace/remove; report upstream; consider `--ignore-scripts`.

## Notes
- The third-party channel is non-blocking by default in report-only/baseline — do not
  silence it; record decisions here instead.
