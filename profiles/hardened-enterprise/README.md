# Profile: `hardened-enterprise` (opt-in)

First-class **opt-in** hardened overlay. **Defaults are unchanged** — you get this only with
`--profile hardened-enterprise`.

```sh
sh scripts/install-baseline.sh --target <dir> --profile hardened-enterprise            # dry-run
sh scripts/install-baseline.sh --target <dir> --profile hardened-enterprise --apply    # write
```

## What it installs

- Standard managed files (`.sentinel-shield/profile.yaml`, `accepted-risks.example.json`).
- The **digest-pinned / SHA-pinned hardened reference** at
  `.sentinel-shield/hardened/sentinel-shield-hardened.snippet.yml` (copied from
  [`examples/hardened/`](../../examples/hardened/sentinel-shield-hardened.snippet.yml)).
- The standard combined workflow (`overwrite-if-force`).

## Hardening you apply (from the snippet)

- **Digest-pin** every scanner image (`@sha256:…`); **SHA-pin** GitHub Actions.
- **Minimal `permissions`** (least privilege); add `concurrency`, `timeout-minutes`,
  artifact `retention-days`, `if: always()` uploads.
- Optional **Dependency-Check transitive** knobs (`INSTALL_PHP`/`INSTALL_NODE`, default off).
- **NVD key** is consumer-provided (repo secret), `0600 --propertyfile`, **never committed**; rotate
  per [`security-hygiene.md`](../../docs/security-hygiene.md).

## Safety

- **No credentials** are shipped or required by the profile itself.
- Project-local files (`accepted-risks.json`, baselines) are **never** touched.
- **Rollback:** digests/SHAs are immutable — pin the previous ref to restore the exact toolchain.
- **Digest update:** re-resolve via [`scanner-image-digest-pinning.md`](../../docs/scanner-image-digest-pinning.md).

See [`enterprise-hardening.md`](../../docs/enterprise-hardening.md) and
[`enterprise-buyer-pack.md`](../../docs/enterprise-buyer-pack.md).
