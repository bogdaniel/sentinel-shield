# Sentinel Shield — Security Standard

This document defines the secure coding and operational security standard for
projects that adopt Sentinel Shield. It is normative: where it says *must*, the
requirement is mandatory in `strict` and `regulated` modes and strongly
recommended in `baseline`. In `report-only` mode the rules are advisory but still
scanned and reported.

Related documents:

- [`docs/secure-coding-standard.md`](docs/secure-coding-standard.md) — practical per-stack rules.
- [`docs/severity-policy.md`](docs/severity-policy.md) — how findings are rated.
- [`docs/exception-policy.md`](docs/exception-policy.md) — how risk is accepted.
- [`RELEASE-GATES.md`](RELEASE-GATES.md) — when a release may ship.

---

## 0. Doctrine

```txt
Security is a release requirement, not a best-effort activity.
CI may be intentionally broken until the project proves compliance.
Production must not be broken blindly.
Legacy issues must be made visible, tracked, owned, and burned down.
New code must not increase risk.
Exceptions require owner, reason, expiry, and review.
High-risk changes require human approval.
```

---

## 1. Secure coding

- All new code uses the strictest practical type checking for its stack
  (PHP `declare(strict_types=1)`, TypeScript `strict: true`).
- No code path may trust client-supplied data for authorization, identity, or
  pricing decisions.
- Fail closed. On error, deny access and log; never default to allow.
- Keep functions small and side-effect-explicit so review and analysis are feasible.

---

## 2. Authentication

- Use the framework's vetted authentication system. Do not hand-roll password
  hashing, session management, or token issuance.
- Passwords are hashed with bcrypt/argon2 (Laravel `Hash`, Symfony `PasswordHasher`).
  Never store or log plaintext or reversibly-encrypted passwords.
- Enforce rate limiting and lockout on authentication endpoints.
- Multi-factor authentication is required for administrative and
  compliance-sensitive access in `regulated` mode.
- Session and token lifetimes are bounded; refresh tokens are rotated and revocable.

```php
// Laravel — correct
if (! Auth::attempt($credentials)) {
    return back()->withErrors(['email' => __('auth.failed')]);
}
$request->session()->regenerate(); // prevent session fixation
```

---

## 3. Authorization

- Authorization is enforced server-side on every request, for every resource.
- Use policy/voter abstractions, not inline role string checks scattered in
  controllers.
- Default deny. A missing policy means access is refused, not granted.
- Object-level checks (does *this user* own *this record*) are mandatory — not just
  role checks.

```php
// Laravel policy gate
$this->authorize('update', $invoice); // throws if not permitted

// Symfony voter
$this->denyAccessUnlessGranted('EDIT', $invoice);
```

---

## 4. Input validation

- Validate at the boundary. Every external input is validated for type, length,
  format, and range before use.
- Prefer allow-lists over deny-lists.
- Use the framework validators (Laravel Form Requests, Symfony Validator
  constraints, Zod/valibot for Node/React) rather than ad-hoc checks.

```php
// Laravel Form Request
public function rules(): array
{
    return [
        'email'  => ['required', 'email:rfc', 'max:254'],
        'amount' => ['required', 'integer', 'min:1', 'max:1000000'],
    ];
}
```

---

## 5. Output encoding (and XSS)

- Encode on output for the correct context (HTML, attribute, JS, URL, CSS).
- Use framework auto-escaping (Blade `{{ }}`, Twig auto-escape, React JSX text
  nodes). Do not disable it casually.
- `dangerouslySetInnerHTML`, Blade `{!! !!}`, and Twig `|raw` are high-risk and
  require sanitisation (e.g. DOMPurify) plus a security note in the PR.

```jsx
// React — dangerous, must be sanitised and justified
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(userHtml) }} />
```

---

## 6. CSRF

- All state-changing browser requests are CSRF-protected. Keep framework CSRF
  middleware enabled (Laravel `VerifyCsrfToken`, Symfony CSRF tokens on forms).
- Stateless APIs use bearer tokens with `SameSite` cookies or token headers; do not
  silently disable CSRF for whole route groups.
- Use `SameSite=Lax` or `Strict` and `Secure` cookies in production.

---

## 7. SQL injection

- Use parameterised queries and the ORM/query builder. Never concatenate user input
  into SQL.
- `DB::raw`, `whereRaw`, native SQL, and Doctrine DQL string interpolation are
  flagged by Semgrep and must use bound parameters.

```php
// Wrong
DB::select("SELECT * FROM users WHERE email = '" . $request->email . "'");

// Correct
DB::select('SELECT * FROM users WHERE email = ?', [$request->email]);
```

---

## 8. Command injection

- Avoid shelling out. If unavoidable, use array-form process APIs that do not invoke
  a shell, and never interpolate user input into a command string.

```php
// Laravel/Symfony — safe (no shell, arguments are arrays)
$process = new Symfony\Component\Process\Process(['convert', $inputPath, $outputPath]);
$process->mustRun();
```

```js
// Node — safe: execFile with an argument array, not exec with a string
execFile('convert', [inputPath, outputPath], (err) => { /* ... */ });
```

---

## 9. SSRF

- Outbound requests to user-controlled URLs must validate the scheme and resolve and
  block private/link-local/metadata ranges (`127.0.0.0/8`, `169.254.0.0/16`,
  `10/8`, `172.16/12`, `192.168/16`, `::1`, cloud metadata `169.254.169.254`).
- Use an allow-list of permitted hosts where the destination set is known.
- Disable automatic following of redirects to internal addresses.

---

## 10. File upload security

- Validate MIME type by content inspection, not just extension.
- Store uploads outside the web root; serve through a controller that enforces
  authorization.
- Generate server-side filenames; never use the client-supplied name on disk.
- Enforce size limits and scan where required (Trivy/ClamAV) in `regulated` mode.
- Never place uploaded files where they can be executed.

---

## 11. Secrets management

- No secrets in source, image layers, logs, or CI logs. Gitleaks runs on every push
  and PR and is blocking in all modes.
- Secrets come from environment variables or a secret manager (Vault, AWS/GCP/Azure
  secret stores), injected at runtime.
- Rotate credentials on suspected exposure; rotation is mandatory after any
  confirmed leak.
- `.env` files are never committed. `.env.example` documents required keys with
  placeholder values only.

---

## 12. Logging and audit trails

- Log security-relevant events: authentication success/failure, authorization
  denials, privilege changes, data exports, and admin actions.
- Never log secrets, full PANs, passwords, tokens, or full PII. Mask sensitive
  fields.
- In `regulated` mode, audit logs are append-only, time-synchronised, and retained
  per the applicable compliance regime.
- Correlate logs with a request/trace ID.

---

## 13. Error handling

- Do not leak stack traces, SQL, framework versions, or internal paths to clients.
  `APP_DEBUG`/verbose errors must be off in production (enforced by
  [`policies/opa/production-env.rego`](policies/opa/production-env.rego)).
- Catch exceptions at boundaries, return generic messages to clients, and log
  details server-side.

---

## 14. Cryptography

- Use vetted libraries (libsodium, framework encrypters). Do not implement
  primitives.
- Symmetric encryption: AES-256-GCM or libsodium secretbox. Hashing for integrity:
  SHA-256+. Passwords: argon2id/bcrypt.
- Use cryptographically secure randomness (`random_bytes`, `crypto.randomBytes`),
  never `rand()`/`mt_rand()`/`Math.random()` for security purposes.
- TLS 1.2+ for all transport; never disable certificate verification.

---

## 15. Dependency security

- Lockfiles are committed and CI installs from them (`composer install`,
  `npm ci`). See [`docs/dependency-policy.md`](docs/dependency-policy.md).
- `composer audit` / `npm audit` / OSV-Scanner run in CI. New critical/high
  advisories block in `baseline`+.
- Abandoned or unmaintained packages are tracked and replaced.
- SBOM (Syft) is generated and retained in `regulated` mode.

---

## 16. Container security

Enforced by [`profiles/docker`](profiles/docker),
[`policies/opa/docker.rego`](policies/opa/docker.rego), and Hadolint/Trivy in CI.

- Run as a non-root user.
- Use minimal, pinned base images (digest or specific version, never `latest`).
- No secrets in image layers or `ENV`.
- No privileged containers; drop capabilities to least privilege.
- Read-only root filesystem where feasible; writable paths mounted explicitly.
- Define healthchecks and resource limits.

See [`docs/docker-security-standard.md`](docs/docker-security-standard.md).

---

## 17. CI/CD security

Enforced by [`docs/github-actions-security.md`](docs/github-actions-security.md) and
[`policies/opa/github-actions.rego`](policies/opa/github-actions.rego).

- Minimal `permissions:` per workflow and job; never `write-all`.
- Pin third-party actions to a commit SHA in sensitive workflows.
- No secrets exposed to untrusted pull requests; avoid unsafe
  `pull_request_target`.
- Separate build, test, and deploy privileges.
- No shell injection from event payloads (`${{ github.event.* }}` into `run:`).

---

## 18. Infrastructure security

Enforced by [`policies/opa/terraform.rego`](policies/opa/terraform.rego) and Trivy/
Checkov.

- No `0.0.0.0/0` ingress for SSH/RDP or databases.
- No public object storage unless explicitly classified public.
- Databases are private; access via bastion or private networking.
- Encryption at rest and in transit for data stores.
- Least-privilege IAM; no wildcard admin roles in application credentials.

---

## 19. Compliance-sensitive jobs and cron tasks

- Scheduled and queued jobs that touch payments, balances, KYC/AML, or audit data
  are treated as high-risk changes and require security review.
- Jobs are idempotent and safe to retry; financial operations are transactional.
- Job execution is logged to the audit trail with actor, inputs (masked), and
  outcome.
- Secrets used by jobs come from the secret manager, not baked-in config.
- In `regulated` mode, changes to such jobs require the security-review template and
  a rollback plan.

---

## Appendix: stack quick reference

| Concern | Laravel | Symfony | Node | React |
| --- | --- | --- | --- | --- |
| Validation | Form Requests | Validator constraints | Zod/valibot | Zod + form libs |
| AuthZ | Policies/Gates | Voters | Middleware guards | Server-enforced |
| Escaping | Blade `{{ }}` | Twig autoescape | n/a | JSX text nodes |
| SQL | Eloquent / bindings | Doctrine params | Parameterised driver | n/a |
| Secrets | `.env` + manager | `.env` + manager | env + manager | build-time public only |
