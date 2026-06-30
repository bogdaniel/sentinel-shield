#!/bin/sh
# tests/prod/140-planner.sh — WS14 upgrade-planner completeness + ZERO mutation.
#
# Asserts the contract of scripts/plan-upgrade.sh:
#   (a) running the planner against a fixture target leaves that target
#       BYTE-FOR-BYTE unchanged (tree checksum snapshot before == after) and
#       creates/deletes no files — proving the planner mutates nothing.
#   (b) --format json emits a single valid JSON document (jq parses it).
#   (c) the json AND text output mention the key comparison dimensions:
#       version, profile, tools, drift, and rollback.
# Self-contained (own mktemp fixture, cleaned up), no network.
# Run via: sh tests/prod/140-planner.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
SCRIPT="$ROOT/scripts/plan-upgrade.sh"

FAILED=0
ok()  { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

command -v jq >/dev/null 2>&1 || { bad "jq is available"; exit 1; }
[ -f "$SCRIPT" ] || { bad "scripts/plan-upgrade.sh exists"; exit 1; }

# tree_checksum <dir> — deterministic content+name+size fingerprint of every file
# under <dir>. cksum is POSIX; sort makes ordering stable; the file list itself is
# part of the output so additions/deletions also change the fingerprint.
tree_checksum() {
	( cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done )
}

# --- build a self-contained fixture consuming project ------------------------
FIX=$(mktemp -d 2>/dev/null || mktemp -d -t ssplanner)
trap 'rm -rf "$FIX"' EXIT INT TERM

mkdir -p "$FIX/.sentinel-shield" "$FIX/docs/security"
# A valid installation record (conforms to schemas/installation.schema.json) so the
# planner takes its --target-aware code path (installed schema + enabled_tools).
cat > "$FIX/.sentinel-shield/installation.json" <<'JSON'
{
  "version": "1.8.0",
  "profile": "laravel",
  "profile_schema": 1,
  "tool_mode": "config-only",
  "installed_at": "2025-01-01T00:00:00Z",
  "managed_files": [".github/workflows/sentinel-shield.yml"],
  "project_owned_files": ["phpstan.neon"],
  "enabled_tools": ["php-syntax", "phpstan", "legacy-tool"],
  "disabled_tools": []
}
JSON
# A couple of project-owned files the planner must never touch.
printf 'parameters:\n  level: 5\n' > "$FIX/phpstan.neon"
printf '# debt register\n' > "$FIX/docs/security/security-debt-register.md"

# --- (a) ZERO mutation: snapshot the tree before and after a planner run ------
BEFORE=$(tree_checksum "$FIX")

rc=0
sh "$SCRIPT" --from 1.8.0 --to 2.0.0 --profile laravel --target "$FIX" --format json >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then ok "(a) planner exits 0 against fixture target"
else bad "(a) planner expected exit 0, got $rc"; fi

AFTER=$(tree_checksum "$FIX")
if [ "$BEFORE" = "$AFTER" ]; then ok "(a) fixture target is byte-for-byte unchanged (zero mutation)"
else bad "(a) planner MUTATED the target tree"; fi

# Run all three formats and re-check — none of them may write to the target.
for fmt in text markdown json; do
	sh "$SCRIPT" --from 1.8.0 --to 2.0.0 --profile laravel --target "$FIX" --format "$fmt" >/dev/null 2>&1 || true
done
AFTER2=$(tree_checksum "$FIX")
if [ "$BEFORE" = "$AFTER2" ]; then ok "(a) text+markdown+json runs all leave the target unchanged"
else bad "(a) some format mutated the target tree"; fi

# --- (b) --format json emits valid JSON --------------------------------------
JSON_OUT=$(sh "$SCRIPT" --from 1.8.0 --to 2.0.0 --profile laravel --target "$FIX" --format json 2>/dev/null)
if printf '%s' "$JSON_OUT" | jq -e . >/dev/null 2>&1; then ok "(b) --format json emits valid JSON (jq parses it)"
else bad "(b) --format json output is not valid JSON"; fi

# It must be a SINGLE JSON document (object), not a concatenated stream.
if printf '%s' "$JSON_OUT" | jq -e 'type == "object"' >/dev/null 2>&1; then ok "(b) json output is a single JSON object"
else bad "(b) json output is not a single object"; fi

# --- (c) json mentions the key comparison dimensions -------------------------
if printf '%s' "$JSON_OUT" | jq -e '
	has("profile")
	and (.sentinel_shield | has("from") and has("to"))
	and (.profile_schema | has("drift"))
	and (.tool_changes | has("added") and has("removed"))
	and has("required_tools")
	and has("rollback")
	and (.rollback | type == "array")
' >/dev/null 2>&1; then
	ok "(c) json covers version, profile, tools, drift, rollback"
else bad "(c) json is missing one of: version/profile/tools/drift/rollback"; fi

# --- (c) text output mentions the same dimensions (case-insensitive) ---------
TEXT_OUT=$(sh "$SCRIPT" --from 1.8.0 --to 2.0.0 --profile laravel --target "$FIX" --format text 2>/dev/null)
check_text() { # check_text <regex> <label>
	if printf '%s' "$TEXT_OUT" | grep -iqE "$1"; then ok "(c) text mentions $2"
	else bad "(c) text output missing $2"; fi
}
check_text 'version'  'version'
check_text 'profile'  'profile'
check_text 'tool'     'tools'
check_text 'drift'    'drift'
check_text 'rollback' 'rollback'

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
