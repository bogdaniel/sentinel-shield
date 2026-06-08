# Remediation: React `dangerouslySetInnerHTML`

**What it means.** A React component injects raw HTML via
`dangerouslySetInnerHTML={{ __html: value }}`. If `value` contains attacker-influenced
content, this is a stored/reflected **XSS** sink. Sentinel Shield's React SAST flags every
use because the rule cannot prove the input is trusted.

**When it is real.** `value` derives (now or later) from user input, an API response, a
CMS field, query params, or anything not a hard-coded constant — a real XSS risk.

**When it may be acceptable.** The HTML is a build-time constant the team controls (e.g.
an inlined SVG/icon string), or it is sanitized immediately before rendering with a
vetted sanitizer. Even then the rule still fires — record the decision, do not pretend it
is gone.

**Recommended fix.** Prefer not injecting HTML at all (render structured React). If you
must, **sanitize with DOMPurify** at the injection point:

```jsx
import DOMPurify from 'dompurify';
<div dangerouslySetInnerHTML={{ __html: DOMPurify.sanitize(value) }} />
```

Centralize it in a helper (e.g. `sanitizeHtml(value)`) so every sink is consistent, and
add a narrowly-scoped `// nosemgrep: <rule-id>` only on the sanitized line, with a comment
pointing at the helper. Do not blanket-ignore the rule file-wide.

**Accepted-risk guidance.** If a sink genuinely cannot be changed yet, record a
finding-scoped accepted-risk (rule_id + file) with owner, reason, expiry — never a broad
gate suppression. Sanitization is strongly preferred over acceptance.

**Validation steps.** Re-run the React SAST; confirm the only remaining hits are the
sanitized, annotated lines. Add a test feeding `"<img src=x onerror=alert(1)>"` and assert
the rendered DOM has no executable handler.

**Rollback considerations.** DOMPurify is render-time only; reverting the helper restores
the prior behavior. Keep DOMPurify pinned and updated (it ships XSS-bypass fixes).
