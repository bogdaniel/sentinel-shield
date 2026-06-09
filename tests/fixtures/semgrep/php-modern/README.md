# Modern-PHP Semgrep fixture (v0.1.19)
Representative PHP 8.1+ syntax that the older `semgrep/semgrep:1.90.0` tree-sitter parser
choked on (PartialParsing/Syntax errors) on the zenchron-tools pilot: `readonly` properties,
constructor property promotion, attributes, enums, `match`, typed properties. Used by
`scripts/verify-semgrep-image.sh` to check whether the configured Semgrep image parses modern
PHP cleanly. **Fixture verification ≠ live consumer validation.**
