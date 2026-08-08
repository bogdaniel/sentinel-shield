#!/bin/sh
# Sentinel Shield audit — repository-wide YAML sanity, with a REGISTERED negative corpus.
#
# WHY THIS EXISTS
#
# The canonical policy parser (scripts/lib/yaml-policy.sh) has to be proven against malformed
# input, so the repository now carries YAML files that are deliberately not valid YAML. The
# repository-wide "every *.yml/*.yaml must parse" check and that corpus cannot both be
# satisfied, and the tempting fix — skip anything under tests/fixtures/ — would create exactly
# the blind spot the check exists to prevent: a real workflow or profile could then be
# malformed and nothing would notice.
#
# So the exemption is a REGISTRY, and it is enforced in BOTH directions:
#
#   * a file that fails to parse and is NOT registered  -> error (register it deliberately)
#   * a file that IS registered but parses cleanly      -> error (it is not a negative fixture)
#
# The second direction is the one that keeps the registry honest. A one-way skip list rots into
# a dumping ground: entries stay after the file is fixed, and the exemption silently widens.
#
# IMPORTANT SCOPE NOTE. Most of the rejected corpus is NOT registered here. Duplicate keys,
# anchors, aliases, block scalars and multi-document files are all *valid YAML* that the
# Sentinel contract rejects for its own reasons. Those must keep satisfying repository YAML
# sanity — the contract is stricter than YAML syntax, and this audit proves that rather than
# obscuring it.
#
# Usage:
#   yaml-corpus-audit.sh [--root <dir>] [--manifest <path>] [--quiet]
#
# Exit 0 = the set of unparseable files is EXACTLY the registered set.
# Exit 1 = a discrepancy in either direction. Exit 2 = cannot run (no parser, bad manifest).
set -eu

ROOT_DIR=""
MANIFEST=""
QUIET=0
while [ $# -gt 0 ]; do
	case "$1" in
	--root) ROOT_DIR=${2:?--root requires a value}; shift 2 ;;
	--manifest) MANIFEST=${2:?--manifest requires a value}; shift 2 ;;
	--quiet) QUIET=1; shift ;;
	-h | --help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	*) printf '[yaml-corpus-audit] ERROR: unknown argument: %s\n' "$1" >&2; exit 2 ;;
	esac
done

if [ -z "$ROOT_DIR" ]; then
	_sd=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	ROOT_DIR=$(CDPATH= cd -- "$_sd/../.." && pwd)
fi
[ -n "$MANIFEST" ] || MANIFEST="$ROOT_DIR/config/intentionally-invalid-yaml.json"

say() { [ "$QUIET" = 1 ] || printf '[yaml-corpus-audit] %s\n' "$*"; }
err() { printf '[yaml-corpus-audit] %s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || { err "ERROR: jq is required"; exit 2; }
[ -f "$MANIFEST" ] || { err "ERROR: manifest not found: $MANIFEST"; exit 2; }
jq -e 'has("intentionally_invalid_yaml") and (.intentionally_invalid_yaml | type == "array")' \
	"$MANIFEST" >/dev/null 2>&1 || { err "ERROR: manifest has no intentionally_invalid_yaml array"; exit 2; }

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted audit must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# --- collect the files that do not parse ----------------------------------
# Ruby/Psych is the reference implementation the repository has always used. Python's PyYAML
# is the fallback so the audit still runs where ruby is absent; the two disagree on edge cases,
# which is precisely why the registry is compared rather than assumed, and why a disagreement
# surfaces as a loud, specific error instead of a silent pass.
if command -v ruby >/dev/null 2>&1; then
	PARSER=ruby
	( cd "$ROOT_DIR" && find . -path ./.git -prune -o \( -name '*.yml' -o -name '*.yaml' \) -print ) \
		| sed 's|^\./||' | sort > "$TMP/all"
	( cd "$ROOT_DIR" && ruby -ryaml -e '
		ARGF.each_line do |line|
			f = line.chomp
			next if f.empty?
			begin
				YAML.load_stream(File.read(f))
			rescue Exception => e
				puts f
			end
		end
	' "$TMP/all" ) > "$TMP/invalid" 2>/dev/null || true
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' 2>/dev/null; then
	PARSER=python3
	( cd "$ROOT_DIR" && find . -path ./.git -prune -o \( -name '*.yml' -o -name '*.yaml' \) -print ) \
		| sed 's|^\./||' | sort > "$TMP/all"
	( cd "$ROOT_DIR" && python3 -c '
import sys, yaml
for line in open(sys.argv[1]):
    f = line.strip()
    if not f: continue
    try:
        list(yaml.safe_load_all(open(f, "rb").read()))
    except Exception:
        print(f)
' "$TMP/all" ) > "$TMP/invalid" 2>/dev/null || true
else
	err "ERROR: neither ruby nor python3+PyYAML is available — refusing to report YAML sanity it cannot check"
	exit 2
fi

sort -u "$TMP/invalid" -o "$TMP/invalid"
jq -r '.intentionally_invalid_yaml[]' "$MANIFEST" | sort -u > "$TMP/registered"

_total=$(wc -l < "$TMP/all" | tr -d ' ')
say "parser=$PARSER files=$_total registered=$(wc -l < "$TMP/registered" | tr -d ' ') unparseable=$(wc -l < "$TMP/invalid" | tr -d ' ')"

RC=0

# Direction 1 — unparseable but not registered. The original failure mode: a genuinely broken
# workflow or profile slipping in.
_unreg=$(comm -23 "$TMP/invalid" "$TMP/registered")
if [ -n "$_unreg" ]; then
	err "ERROR: file(s) are not valid YAML and are NOT registered as intentional:"
	printf '%s\n' "$_unreg" | sed 's/^/         /' >&2
	err "       If a file is a deliberate negative fixture, add it to $(basename -- "$MANIFEST")."
	err "       Otherwise it is simply broken — fix the file, do not register it."
	RC=1
fi

# Direction 2 — registered but parses cleanly. Keeps the registry from becoming a dumping
# ground that silently widens as fixtures are fixed or reclassified.
_stale=$(comm -13 "$TMP/invalid" "$TMP/registered")
if [ -n "$_stale" ]; then
	err "ERROR: file(s) are registered as intentionally-invalid but parse cleanly:"
	printf '%s\n' "$_stale" | sed 's/^/         /' >&2
	err "       Remove them from $(basename -- "$MANIFEST"). A registry entry that no longer"
	err "       describes a broken file is an exemption nothing is checking."
	RC=1
fi

# Every registered path must exist. A registry pointing at a deleted file exempts nothing and
# hides that the corpus lost a case.
while IFS= read -r _p; do
	[ -n "$_p" ] || continue
	[ -e "$ROOT_DIR/$_p" ] || { err "ERROR: registered path does not exist: $_p"; RC=1; }
done < "$TMP/registered"

[ "$RC" = 0 ] && say "OK: the unparseable set is exactly the registered set"
exit "$RC"
