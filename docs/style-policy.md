# Style Policy (v0.1.14)

Code style (Pint / PHP-CS-Fixer / PHPCS) → `style_violations`. **Non-blocking in baseline**
(visible only); **blocking in strict+**. Rationale: style is real debt but should not block
migration-phase projects.

- Runner: `scripts/runners/php-style.sh` (Pint `--test`, else PHP-CS-Fixer `--dry-run`; PHPCS optional).
- Raw: `reports/raw/php-style.json` (Pint/PHP-CS-Fixer JSON, or a `.txt` diagnostic log when JSON is unavailable — never fake-clean).
- Collector: `php-style.sh` → `style_violations`.
- Fix locally: `vendor/bin/pint` (or `php-cs-fixer fix`). Keep style auto-fixable; do not accept-risk style debt — fix it.
