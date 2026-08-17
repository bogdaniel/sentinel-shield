#!/bin/sh
# Sentinel Shield — generate config/harness-assertion-inventory.json (#345 Part C).
#
# The migration inventory is GENERATED, for the same reason the producer-contract document is:
# a hand-maintained list of 180 assertion sites is a list that drifts, and it drifts silently in
# the direction that matters — a site converted back to legacy syntax while the inventory still
# calls it canonical.
#
# One row per assertion site in a registered suite, plus one suite-level row for every named
# evidence-critical suite that is NOT registered, so what is uncovered is in the same file as
# what is covered rather than in a paragraph somewhere.
#
# The stable identifier is `<suite>#<helper>:<label>`, not a line number: labels survive edits
# above them, line numbers do not.
#
# Usage: render-assertion-inventory.sh [--check]
#   (no argument)  write config/harness-assertion-inventory.json
#   --check        print the document to stdout, write nothing
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
POLICY="$ROOT/config/harness-assertion-policy.json"
OUT="$ROOT/config/harness-assertion-inventory.json"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
[ -f "$POLICY" ] || { echo "missing config/harness-assertion-policy.json" >&2; exit 2; }

# Arity first: a typo must not silently regenerate or truncate the document.
[ $# -le 1 ] || { echo "usage: render-assertion-inventory.sh [--check]" >&2; exit 2; }
case "${1:-}" in
"") : ;;
--check) : ;;
*) echo "usage: render-assertion-inventory.sh [--check]" >&2; exit 2 ;;
esac

_helpers=$(jq -r '[.canonical_helpers[].name] | join("|")' "$POLICY")
_tmp=$(mktemp -d)
trap 'rm -rf "$_tmp" 2>/dev/null || :' EXIT

# --- one row per canonical assertion site in each registered suite ---------------------------
: > "$_tmp/sites.jsonl"
jq -r '.registered_suites[] | [.suite, (.security_critical|tostring), .migration_status] | @tsv' "$POLICY" \
	> "$_tmp/registered"
while IFS="$(printf '\t')" read -r _suite _sec _mig; do
	[ -n "$_suite" ] || continue
	[ -f "$ROOT/$_suite" ] || continue
	# A helper name at a COMMAND position: line start, or after `; ` / `&& ` / `|| ` / `then `.
	# The label is argument one, so it is taken as the rest of the line after the helper name;
	# the identifier only has to be stable, not shell-accurate.
	awk -v suite="$_suite" -v sec="$_sec" -v mig="$_mig" -v helpers="$_helpers" '
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			if (line !~ "^(" helpers ")[ \t]") next
			h = line
			sub(/[ \t].*$/, "", h)
			rest = line
			sub("^" h "[ \t]+", "", rest)
			# The label is the first quoted argument. Taken as text: this is an inventory
			# identifier, not a security decision, and the policy has already forbidden any
			# command substitution on this line.
			label = rest
			if (substr(label, 1, 1) == "\"") { label = substr(label, 2); sub(/".*$/, "", label) }
			else if (substr(label, 1, 1) == "\047") { label = substr(label, 2); sub(/\047.*$/, "", label) }
			else { sub(/[ \t].*$/, "", label) }
			gsub(/\\/, "\\\\", label); gsub(/"/, "\\\"", label)
			control = (h == "assert_rejection_with_control") ? "in-call" : \
			          ((h == "assert_accept") ? "is-a-control" : "not-a-rejection")
			if (h == "assert_reject") control = "MISSING"
			printf "{\"suite\":\"%s\",\"site\":\"%s#%s:%s\",\"helper\":\"%s\",\"syntax\":\"canonical\",\"acceptance_control\":\"%s\",\"security_critical\":%s,\"migration_status\":\"%s\",\"residual_gap\":\"none\"}\n", \
				suite, suite, h, label, h, control, sec, mig
		}
	' "$ROOT/$_suite" >> "$_tmp/sites.jsonl"
done < "$_tmp/registered"

# --- one suite-level row per named-but-unregistered evidence-critical suite -------------------
jq -c '.excluded_suites[] | {
	suite: .suite,
	site: (.suite + "#suite"),
	helper: null,
	syntax: "legacy",
	acceptance_control: "not-asserted-by-construction",
	security_critical: .security_critical,
	migration_status: .migration_status,
	residual_gap: .residual_gap }' "$POLICY" >> "$_tmp/sites.jsonl"

_render() {
	jq -n --slurpfile policy "$POLICY" --rawfile rows "$_tmp/sites.jsonl" '
		($rows | split("\n") | map(select(length > 0) | fromjson)) as $R
		| { schema: "sentinel-shield/harness-assertion-inventory@1",
		    generated_by: "scripts/render-assertion-inventory.sh",
		    note: "GENERATED FILE — edit the suites or the policy, then regenerate. tests/prod/307 regenerates and compares byte for byte.",
		    policy: "config/harness-assertion-policy.json",
		    totals: {
		      canonical_sites: ([$R[] | select(.syntax == "canonical")] | length),
		      legacy_suites_named: ([$R[] | select(.syntax == "legacy")] | length),
		      corpus_verdict_sites: $policy[0].corpus_census.verdict_sites,
		      corpus_suites: $policy[0].corpus_census.suites,
		      uncovered_sites: ($policy[0].corpus_census.verdict_sites - ([$R[] | select(.syntax == "canonical")] | length)) },
		    rows: ($R | sort_by(.suite, .site)) }'
}

if [ "${1:-}" = "--check" ]; then
	_render
	exit 0
fi
_out="$OUT.tmp.$$"
if ! _render > "$_out" 2>/dev/null; then
	rm -f "$_out"
	echo "render failed; $OUT left unchanged" >&2
	exit 1
fi
[ -s "$_out" ] || { rm -f "$_out"; echo "render produced an empty document; $OUT left unchanged" >&2; exit 1; }
mv "$_out" "$OUT"
echo "wrote ${OUT#"$ROOT"/}"
