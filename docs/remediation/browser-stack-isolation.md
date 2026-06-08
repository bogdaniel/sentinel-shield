# Remediation: Browser / headless-Chrome stack isolation

**What it means.** Bundling Chromium/Puppeteer/Playwright + their system libraries into a
PHP/Node **application** image bloats it, enlarges the CVE surface, and makes apk/apt
pinning (DL3018/DL3008) impractical.

**When it is real.** The app image installs `chromium`, `nss`, `freetype`, `harfbuzz`,
`ttf-freefont`, the Playwright Debian lib set, etc. for screenshot/PDF/scraping features.

**When it may be acceptable.** A short-lived dev image, or a small service where a split is
disproportionate — but the package-pinning debt then stays (accepted-risk).

**Recommended fix — isolate the browser.**
- **Option A/C (preferred):** run a dedicated, **digest-pinned** browser service
  (e.g. `browserless/chromium`); the app connects over CDP/WS. Config-only app change.
- **Option B:** a separate browser worker image you own.
- After isolation, remove the browser packages from the app image and **pin** the small
  remaining apk/apt set — DL3018/DL3008 can then be genuinely cleared.

**Migration steps.** Stand up the browser service (digest-pinned) → point the client
(Browsershot/Puppeteer `setRemoteInstance`/WS endpoint) at it → verify the feature →
strip browser packages from the app image → pin remainder → re-scan → retire the
accepted-risk.

**Accepted-risk guidance.** Until the split lands, cover the apk/apt findings with a
finding-scoped, time-boxed accepted-risk — not a broad suppression.

**Validation steps.** Exercise the screenshot/PDF path against the service; confirm the
app image no longer installs the browser stack and Hadolint findings drop.

**Rollback considerations.** Keep the bundled Dockerfile in history; reverting the client
config + image restores the in-image browser. No data migration involved.
