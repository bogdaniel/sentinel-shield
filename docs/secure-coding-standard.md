# Secure Coding Standard (Practical, by Stack)

This is the hands-on companion to [`../SECURITY-STANDARD.md`](../SECURITY-STANDARD.md).
It gives concrete, do-this / not-that rules per stack. The high-level *why* lives in
the security standard; this file is the *how*.

---

## All stacks

- Validate input at the boundary; encode output for its context.
- Default deny for authorization; enforce server-side.
- No secrets in code, logs, or images.
- Use parameterised queries and array-form process execution.
- Use CSPRNG for anything security-relevant.
- Fail closed; never leak internals in errors.

---

## PHP (Laravel & Symfony)

```php
<?php
declare(strict_types=1); // required in new files
```

Do:

- Use Form Requests (Laravel) / Validator constraints (Symfony) for validation.
- Use Eloquent/query-builder bindings or Doctrine parameters for all queries.
- Authorize with Policies/Gates (Laravel) or Voters (Symfony).
- Use `Hash::make` / the Symfony password hasher; never custom hashing.
- Mass-assignment: define `$fillable` / use DTOs; never `Model::create($request->all())`.

Don't:

- `DB::raw`/`whereRaw`/native SQL with interpolated input.
- `eval`, `unserialize` on untrusted input (`Symfony Serializer`/`json_decode` instead).
- `exec`/`shell_exec`/`system` with user input — use `Symfony\Component\Process` arrays.
- Ship with `APP_DEBUG=true` or `app.env=dev` in production.

```php
// Laravel mass assignment — safe
$user = User::create($request->safe()->only(['name', 'email']));
```

---

## Node.js

Target Node 22+, ES modules, TypeScript `strict`.

Do:

- Validate request input with a schema (Zod/valibot) before use.
- `execFile`/`spawn` with argument arrays; never `exec` with interpolated strings.
- Verify JWTs with an explicit algorithm allow-list and a verified secret/key.
- Use parameterised queries / prepared statements / ORM bindings.
- Set security headers (helmet or equivalent) and strict CORS.

Don't:

- `eval`, `new Function`, or `vm` on untrusted input.
- `child_process.exec(\`... ${userInput}\`)`.
- Disable TLS verification (`rejectUnauthorized: false`,
  `NODE_TLS_REJECT_UNAUTHORIZED=0`).
- Build NoSQL queries directly from request bodies (operator injection).

```ts
import { z } from "zod";
const Body = z.object({ email: z.string().email(), amount: z.number().int().positive() });
const { email, amount } = Body.parse(req.body); // throws on invalid input
```

---

## React

Do:

- Render user data as JSX text nodes (auto-escaped).
- Sanitise any HTML before `dangerouslySetInnerHTML` (DOMPurify) and justify it.
- Validate/normalise URLs before using them in `href`/`src`; block `javascript:`.
- Keep secrets out of the bundle — only truly public values belong in client code.

Don't:

- `dangerouslySetInnerHTML` with unsanitised input.
- Write to `innerHTML`/`document.write` directly.
- Trust client-side checks for authorization — enforce on the server.

```jsx
const safe = DOMPurify.sanitize(userHtml);
return <article dangerouslySetInnerHTML={{ __html: safe }} />;
```

---

## Docker

See [`docker-security-standard.md`](docker-security-standard.md) for the full set.
In short: non-root user, pinned minimal base image, no secrets in layers, no
privileged mode, drop capabilities, read-only FS where feasible, healthcheck,
resource limits.

---

## Review heuristics

When reviewing a change, ask:

1. Where does untrusted data enter, and is it validated?
2. Who is allowed to do this, and is that enforced server-side per object?
3. What happens on error — does it fail closed?
4. Are any secrets, queries, commands, or HTML built from input?
5. Does this change touch auth, payments, compliance, data access, cron, or infra?
   If yes, it is high-risk and needs human security review.
