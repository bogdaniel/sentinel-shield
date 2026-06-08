# Scheduled Scan Report

- **Date / workflow run:** …
- **Scans run:** TruffleHog · Scorecard · Grype · Trivy image · Dockle · (ZAP/Nuclei?)

## Summary
| Tool | Summary key | Count | Action |
|---|---|---|---|
| trufflehog | secrets | … | … |
| scorecard | repository_health_warnings | … | … |
| grype | *_vulnerabilities | … | … |
| dockle | container_image_violations | … | … |

## Triage
Nightly findings are report-only; route confirmed items into the PR/main gate or file an
accepted-risk. Do not let nightly findings rot.
