# Scheduled / Nightly Scans (v0.1.12)

`sentinel-shield-scheduled.yml` runs heavier scans off the PR critical path, **report-only**
(does not block merges). Use it for repo health + deep/image scans.

| Tool | Raw report | Summary key | Notes |
|---|---|---|---|
| TruffleHog (deep) | trufflehog.json | secrets | verified-only count |
| OpenSSF Scorecard | scorecard.json | repository_health_warnings | regulated-only gate |
| Grype (SBOM/dir) | grype.json | *_vulnerabilities | severity-mapped |
| Trivy image | trivy.json | *_vulnerabilities | needs `SENTINEL_SHIELD_IMAGE` |
| Dockle | dockle.json | container_image_violations | built-image checks; needs image |
| ZAP baseline / Nuclei (optional) | zap.json / nuclei.json | dast_findings | staging only; allowlisted (see dast-policy.md) |

Nightly findings should be triaged into the main/PR gates or accepted-risks, not ignored.
Record summaries in [`templates/scheduled-scan-report.md`](../templates/scheduled-scan-report.md).
