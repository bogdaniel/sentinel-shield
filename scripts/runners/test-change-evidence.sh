#!/bin/sh
# Sentinel Shield runner — TDD proxy: production change without test change (v2.2.0).
#
# WHAT THIS IS: a PROXY. It compares the changed files in a diff and asks one narrow question —
# "did production behavior change while no test/spec/feature/acceptance file changed?". That is
# evidence, not proof. Sentinel Shield cannot prove that a developer wrote the test first: TDD
# is a workflow, and a final code snapshot does not record the order in which its lines were
# written (docs/tdd-evidence-policy.md).
#
# Honest statuses (never a faked clean run):
#   not a git work tree / no resolvable diff base -> status "unavailable",
#                                                    missing_test_change_evidence=true
#   policy disables the TDD proxy                 -> status "disabled"
#   malformed waivers file                        -> status "execution-error",
#                                                    missing_test_change_evidence=true
#   ran                                           -> status "pass" | "findings"
#
# Base ref detection order (first that resolves wins):
#   $SENTINEL_SHIELD_DIFF_BASE, origin/main, origin/master, main, master, HEAD~1
#
# Raw contract (templates/raw/test-change-evidence.example.json):
#   { "tool":"test-change-evidence", "status":"findings",
#     "production_changed_files":3, "test_changed_files":0,
#     "production_change_without_test_change":1, "missing_test_change_evidence":false,
#     "expired_waivers":0, "waived_production_files":0,
#     "files": { "production":[...], "tests":[...], "ignored":[...] } }
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/testing-discipline-evidence.sh
. "$SCRIPT_DIR/../lib/testing-discipline-evidence.sh"
# shellcheck source=scripts/lib/testing-discipline-policy.sh
. "$SCRIPT_DIR/../lib/testing-discipline-policy.sh"

OUT="reports/raw/test-change-evidence.json"
POLICY=".sentinel-shield/testing-discipline-policy.yaml"
WAIVERS=".sentinel-shield/test-discipline-waivers.json"
BASE_CLI=""

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: test-change-evidence.sh [--output <path>] [--policy <path>] [--waivers <path>] [--base <ref>]
Compute the TDD proxy "production change without test change" from the git diff and write the
normalized testing-discipline report. Emits an honest unavailable / disabled / execution-error
report instead of a faked clean result.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		--waivers) WAIVERS="${2:?--waivers requires a value}"; shift 2 ;;
		--base) BASE_CLI="${2:?--base requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
	esac
done

ss_require_jq
ensure_dir "$(dirname -- "$OUT")"

# write_status <status> <message> <extra-json> — honest non-evidence report, then exit 0.
write_status() {
	_wx=${3:-}; [ -n "$_wx" ] || _wx='{}'
	td_write_status "$OUT" "test-change-evidence" "test-change-evidence" "$1" "$2" "$_wx"
	exit 0
}

# --- policy ------------------------------------------------------------------
td_load "$POLICY"
if td_present && ! td_tdd_enabled; then
	write_status "disabled" "TDD proxy disabled in $POLICY" \
		'{"production_change_without_test_change":0,"missing_test_change_evidence":false}'
fi

# Path classes. A policy list REPLACES the built-in list for that class (an explicit
# production_paths of ["src"] means src is the only production tree). A present-but-empty list
# already failed closed in the loader.
PROD_PATHS=$(td_list_or testing_discipline.tdd.production_paths \
	'app/**' 'src/**' 'packages/**' 'lib/**' 'server/**' 'client/**')
TEST_PATHS=$(td_list_or testing_discipline.tdd.test_paths \
	'tests/**' 'test/**' 'spec/**' '__tests__/**' '*.test.*' '*.spec.*' '*.feature' \
	'features/**' 'e2e/**' 'playwright/**' 'cypress/**')
IGNORE_PATHS=$(td_list_or testing_discipline.tdd.ignore_paths \
	'docs/**' 'README*' 'CHANGELOG*' '.github/**' 'config/**' 'database/migrations/**' \
	'public/build/**' 'dist/**' 'build/**' 'coverage/**' 'reports/**' 'vendor/**' 'node_modules/**')

# A bare policy entry (`- app`) means the whole tree: normalize it to `app/**` so the canonical
# policy in templates/testing-discipline-policy.example.yaml works without glob syntax.
normalize_patterns() {
	while IFS= read -r _p; do
		[ -n "$_p" ] || continue
		case "$_p" in
			*'*'*) printf '%s\n' "$_p" ;;
			*/) printf '%s**\n' "$_p" ;;
			*) printf '%s/**\n' "$_p" ;;
		esac
	done
}
PROD_PATHS=$(printf '%s\n' "$PROD_PATHS" | normalize_patterns)
TEST_PATHS=$(printf '%s\n' "$TEST_PATHS" | normalize_patterns)
IGNORE_PATHS=$(printf '%s\n' "$IGNORE_PATHS" | normalize_patterns)

# path_matches <file> <newline-separated-patterns> — 0 (true) when the file matches any
# pattern. `dir/**` matches everything under dir (at any depth); other patterns are matched as
# ordinary shell globs against the whole path AND against the basename, so `*.test.*` catches
# `src/domain/order.test.ts`.
#
# The loop is fed by a HERE-DOC, not a pipe: a `while` in a pipeline runs in a subshell, where
# neither `break` nor an assignment could report the answer back to the caller. Here-doc
# expansion is single-pass, so a pattern containing `$(...)` is inert text, not a command.
path_matches() {
	_f=$1; _base=${1##*/}; _rc=1
	while IFS= read -r _pat; do
		[ -n "$_pat" ] || continue
		case "$_pat" in
			*'/**')
				_pre=${_pat%/**}
				case "$_f" in "$_pre"/*) _rc=0; break ;; esac ;;
			*)
				# shellcheck disable=SC2254  # the pattern is intentionally a glob
				case "$_f" in $_pat) _rc=0; break ;; esac
				# shellcheck disable=SC2254
				case "$_base" in $_pat) _rc=0; break ;; esac ;;
		esac
	done <<EOF
$2
EOF
	return $_rc
}

# --- waivers -----------------------------------------------------------------
# A waiver suppresses matching PRODUCTION paths only. Every waiver MUST carry a reason and an
# expiry: an eternal waiver is an unreviewed one. An EXPIRED waiver never suppresses anything
# and is counted so it surfaces as expired_exceptions (docs/test-discipline-waivers.md).
TODAY=$(date -u +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)
WAIVER_PATTERNS=""
EXPIRED_WAIVERS=0
if [ -f "$WAIVERS" ] && [ -s "$WAIVERS" ]; then
	if ! jq -e . "$WAIVERS" >/dev/null 2>&1; then
		write_status "execution-error" "invalid JSON in waivers file: $WAIVERS" \
			'{"production_change_without_test_change":0,"missing_test_change_evidence":true}'
	fi
	# Fail closed on a structurally invalid waiver (missing id/reason/expires_at/paths, or a
	# non-ISO expiry). A waivers file we cannot trust must not silently suppress evidence.
	_bad=$(jq -r '
		[ (.waivers // [])[]
		  | select(
			((.id // "") | type != "string" or . == "")
			or ((.reason // "") | type != "string" or . == "")
			or ((.expires_at // "") | type != "string" or (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not))
			or ((.paths // []) | type != "array" or length == 0)) ] | length' "$WAIVERS" 2>/dev/null || printf 'invalid')
	case "$_bad" in
		'' | *[!0-9]*)
			write_status "execution-error" "could not validate waivers file: $WAIVERS" \
				'{"production_change_without_test_change":0,"missing_test_change_evidence":true}' ;;
	esac
	if [ "$_bad" -gt 0 ]; then
		write_status "execution-error" "$_bad waiver(s) in $WAIVERS lack a valid id, reason, expires_at (YYYY-MM-DD) or paths" \
			'{"production_change_without_test_change":0,"missing_test_change_evidence":true}'
	fi
	EXPIRED_WAIVERS=$(jq -r --arg t "$TODAY" '[ (.waivers // [])[] | select(.expires_at < $t) ] | length' "$WAIVERS")
	case "$EXPIRED_WAIVERS" in '' | *[!0-9]*) EXPIRED_WAIVERS=0 ;; esac
	[ "$EXPIRED_WAIVERS" -gt 0 ] && log_warn "test-change-evidence: $EXPIRED_WAIVERS expired waiver(s) in $WAIVERS — they suppress nothing and are reported as expired exceptions"
	WAIVER_PATTERNS=$(jq -r --arg t "$TODAY" '(.waivers // [])[] | select(.expires_at >= $t) | .paths[]' "$WAIVERS" 2>/dev/null || true)
	WAIVER_PATTERNS=$(printf '%s\n' "$WAIVER_PATTERNS" | normalize_patterns)
fi

# --- diff base ---------------------------------------------------------------
command_exists git || write_status "unavailable" "git not found; changed-file evidence cannot be computed" \
	'{"production_change_without_test_change":0,"missing_test_change_evidence":true}'
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
	|| write_status "unavailable" "not a git work tree; changed-file evidence cannot be computed" \
		'{"production_change_without_test_change":0,"missing_test_change_evidence":true}'

BASE=""
for _c in "$BASE_CLI" "${SENTINEL_SHIELD_DIFF_BASE:-}" origin/main origin/master main master HEAD~1; do
	[ -n "$_c" ] || continue
	if git rev-parse --verify --quiet "$_c" >/dev/null 2>&1; then BASE="$_c"; break; fi
done
[ -n "$BASE" ] || write_status "unavailable" "no diff base could be resolved (tried SENTINEL_SHIELD_DIFF_BASE, origin/main, origin/master, main, master, HEAD~1)" \
	'{"production_change_without_test_change":0,"missing_test_change_evidence":true}'

# --name-only over the merge base: the changed files THIS branch introduced, not everything
# that also landed on the base branch meanwhile.
MB=$(git merge-base "$BASE" HEAD 2>/dev/null || printf '%s' "$BASE")
CHANGED=$(git diff --name-only "$MB" HEAD 2>/dev/null || printf '')
if [ -z "$CHANGED" ]; then
	# A genuinely empty diff is not missing evidence: nothing changed, so nothing is owed.
	printf '%s\n' "$(jq -n --arg b "$BASE" '{
		tool:"test-change-evidence", producer:"test-change-evidence", status:"pass", base:$b,
		production_changed_files:0, test_changed_files:0,
		production_change_without_test_change:0, missing_test_change_evidence:false,
		expired_waivers:0, waived_production_files:0,
		files:{production:[], tests:[], ignored:[]} }')" > "$OUT"
	log_info "test-change-evidence: no changed files vs $BASE; report written to $OUT"
	exit 0
fi

# --- classify ----------------------------------------------------------------
# Order matters: TEST wins over PRODUCTION (src/order.test.ts is a test), then IGNORE, then
# PRODUCTION. A file matching NONE of the three lists is recorded as ignored — only declared
# production paths count as production change, so an unmapped tree can never manufacture a
# violation. Widen testing_discipline.tdd.production_paths to cover a non-standard layout.
# ponytail: prefix/glob matching, not gitattributes-aware pathspecs; upgrade if a consumer
# needs negation patterns.
PROD_FILES=""; TEST_FILES=""; IGN_FILES=""; WAIVED=0
OLD_IFS=$IFS; IFS='
'
for f in $CHANGED; do
	IFS=$OLD_IFS
	[ -n "$f" ] || continue
	if path_matches "$f" "$TEST_PATHS"; then
		TEST_FILES="$TEST_FILES$f
"
	elif path_matches "$f" "$IGNORE_PATHS"; then
		IGN_FILES="$IGN_FILES$f
"
	elif path_matches "$f" "$PROD_PATHS"; then
		if [ -n "$WAIVER_PATTERNS" ] && path_matches "$f" "$WAIVER_PATTERNS"; then
			WAIVED=$((WAIVED + 1))
			IGN_FILES="$IGN_FILES$f
"
		else
			PROD_FILES="$PROD_FILES$f
"
		fi
	else
		IGN_FILES="$IGN_FILES$f
"
	fi
	IFS='
'
done
IFS=$OLD_IFS

# count_lines <text> — number of non-empty lines. `grep -c` prints 0 AND exits 1 on no match,
# so the fallback must add nothing (a `|| printf 0` here would emit "00").
count_lines() {
	_n=$(printf '%s' "$1" | grep -c . 2>/dev/null || printf '')
	case "$_n" in '' | *[!0-9]*) printf 0 ;; *) printf '%s' "$_n" ;; esac
}
NPROD=$(count_lines "$PROD_FILES")
NTEST=$(count_lines "$TEST_FILES")

# ONE violation per diff, not one per file: the finding is "this change carries no test
# evidence", which is a single reviewable fact.
if [ "$NPROD" -gt 0 ] && [ "$NTEST" -eq 0 ]; then VIOL=1; STATUS="findings"; else VIOL=0; STATUS="pass"; fi

# to_json_array <text> — newline-separated list as a JSON array of strings (empties dropped).
to_json_array() {
	printf '%s' "$1" | jq -R -s 'split("\n") | map(select(length > 0))' 2>/dev/null || printf '[]'
}

jq -n --arg b "$BASE" \
	--argjson np "$NPROD" --argjson nt "$NTEST" --argjson v "$VIOL" \
	--argjson ew "$EXPIRED_WAIVERS" --argjson w "$WAIVED" \
	--argjson prod "$(to_json_array "$PROD_FILES")" \
	--argjson test "$(to_json_array "$TEST_FILES")" \
	--argjson ign "$(to_json_array "$IGN_FILES")" \
	--arg st "$STATUS" '{
		tool:"test-change-evidence", producer:"test-change-evidence", status:$st, base:$b,
		production_changed_files:$np, test_changed_files:$nt,
		production_change_without_test_change:$v, missing_test_change_evidence:false,
		expired_waivers:$ew, waived_production_files:$w,
		files:{production:$prod, tests:$test, ignored:$ign} }' > "$OUT"

log_info "test-change-evidence: base=$BASE production=$NPROD tests=$NTEST violation=$VIOL waived=$WAIVED expired_waivers=$EXPIRED_WAIVERS -> $OUT"
exit 0
