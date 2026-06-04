# Dependency Policy

Most production risk arrives through dependencies. This policy defines how
dependencies are audited, pinned, updated, and retired.

---

## 1. Audit policy

- `composer audit`, `npm audit`, and OSV-Scanner run in CI on every PR and on
  `master`.
- New critical/high advisories block in `baseline` and above (see
  [`../RELEASE-GATES.md`](../RELEASE-GATES.md)).
- Findings are rated with [`severity-policy.md`](severity-policy.md), adjusting for
  reachability and exposure.
- Trivy and Grype scan the filesystem and built images/SBOM for known CVEs.

---

## 2. Lockfile requirements

- Lockfiles (`composer.lock`, `package-lock.json`) are committed.
- CI installs from the lockfile: `composer install` (not `update`), `npm ci` (not
  `install`). This guarantees reproducible, reviewed dependency trees.
- Lockfile changes are reviewed like code; an unexpected transitive bump is a signal.

---

## 3. Update policy

- Dependabot is configured ([`../github/dependabot.yml`](../github/dependabot.yml))
  for the package ecosystems in use plus GitHub Actions and Docker base images.
- Security updates are prioritised; apply within the severity SLA.
- Group low-risk dev-dependency updates to reduce churn.
- Major-version upgrades go through normal review and testing — never auto-merged.

---

## 4. Abandoned package handling

- A dependency is "abandoned" if it has no maintenance, no response to security
  reports, or is explicitly marked abandoned (e.g. Composer `abandoned`).
- Abandoned packages are tracked as findings and replaced or vendored-and-owned.
- Prefer well-maintained, widely-used libraries over single-maintainer micro-packages
  for security-sensitive functionality.

---

## 5. License awareness

- Track dependency licenses. Flag copyleft (GPL/AGPL) and unknown/missing licenses
  for legal review before adoption.
- The SBOM records license metadata where available.
- `regulated` projects maintain an approved-license list.

---

## 6. SBOM generation

- Syft generates an SBOM (CycloneDX or SPDX) in CI.
- The SBOM is archived per release; mandatory in `regulated`, recommended in
  `strict`.
- Grype scans the SBOM so vulnerability state is tracked against an immutable
  component inventory.

---

## Summary table

| Concern | Tool / mechanism | Blocking? |
| --- | --- | --- |
| Known CVEs (PHP) | `composer audit`, OSV-Scanner | new critical/high in baseline+ |
| Known CVEs (Node) | `npm audit`, audit-ci, OSV-Scanner | new critical/high in baseline+ |
| Image/FS CVEs | Trivy, Grype | per gate config |
| Updates | Dependabot | review required |
| Abandoned packages | manual + advisories | tracked |
| Licenses | SBOM + review | flagged |
| Inventory | Syft SBOM | required in regulated |
