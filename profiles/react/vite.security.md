# Vite / React Security Guide

Build-time and runtime hardening for React apps bundled with Vite. The client bundle
is fully public — assume an attacker reads every line and intercepts every request.

---

## 1. Secrets and environment variables

- Only `VITE_`-prefixed env vars are exposed to client code, and **anything exposed
  is public**. Never put API secrets, tokens, or private keys behind `VITE_`.
- Server-side secrets stay on the server / in a backend-for-frontend. The browser
  receives only short-lived, scoped tokens obtained at runtime.

```sh
# .env  — only VITE_* reaches the bundle; keep secrets unprefixed and server-side.
VITE_API_BASE_URL=https://api.example.com   # public, fine
API_SIGNING_SECRET=...                       # NOT exposed to client (correct)
```

---

## 2. XSS / DOM safety

- Render user data as JSX text; let React escape it.
- Avoid `dangerouslySetInnerHTML`. When unavoidable, sanitise with DOMPurify and add
  a security note in the PR. ESLint `react/no-danger` flags it.
- Validate and normalise any URL used in `href`/`src`; block `javascript:` schemes.
- Never write to `innerHTML`/`document.write` directly.

---

## 3. Content Security Policy

Serve a strict CSP from the host/edge (not from the SPA). A reasonable starting
point:

```http
Content-Security-Policy:
  default-src 'self';
  script-src 'self';
  style-src 'self' 'unsafe-inline';
  img-src 'self' data:;
  connect-src 'self' https://api.example.com;
  frame-ancestors 'none';
  base-uri 'self';
  object-src 'none'
```

Avoid `'unsafe-eval'` and `'unsafe-inline'` for scripts. If a dependency needs them,
treat that as a finding.

---

## 4. Dependencies and supply chain

- Vite plugins and React libraries run in your build and ship in your bundle. Audit
  them (`npm audit`, OSV-Scanner) and pin via the committed lockfile.
- Review new transitive dependencies introduced by lockfile changes.
- Knip removes unused libraries, shrinking attack surface.

---

## 5. Source maps

- Do not deploy source maps to public production unless you accept that your source
  is readable. If you upload them to an error tracker, restrict access.

```ts
// vite.config.ts
export default defineConfig({
  build: { sourcemap: false }, // or "hidden" to keep maps off the public CDN
});
```

---

## 6. Build integrity

- Build in CI from a clean checkout and the committed lockfile (`npm ci`).
- Set security headers at the edge: `X-Content-Type-Options: nosniff`,
  `Referrer-Policy`, `Strict-Transport-Security`, and the CSP above.
- Subresource Integrity (SRI) for any third-party scripts loaded from a CDN.

---

## Checklist

- [ ] No secrets behind `VITE_` or anywhere in the bundle.
- [ ] No unsanitised `dangerouslySetInnerHTML`.
- [ ] URLs validated; no `javascript:` schemes.
- [ ] Strict CSP served at the edge.
- [ ] Source maps not public (or access-restricted).
- [ ] `npm ci` build; lockfile committed and audited.
- [ ] Security headers set at the edge.
