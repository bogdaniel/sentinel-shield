#!/bin/sh
# Sentinel Shield production test — canonical YAML policy contract (#259 / #260 / #264).
#
# WHY THIS EXISTS
#
# The engine used to interpret policy YAML with whichever of two backends happened to be
# installed: mikefarah yq v4, or a hand-written awk flatten. They disagreed about comments
# inside quotes, about surrounding quotes, about malformed lines, and — worst — about which
# of two duplicate keys wins. Installing a convenience binary could therefore change the
# SECURITY POLICY a repository enforces, with no policy diff to review.
#
# scripts/lib/yaml-policy.sh replaces both with ONE frontend (docs/yaml-policy-contract.md).
# This suite is the evidence that the replacement actually holds:
#
#   (1) corpus        — every accepted fixture normalizes to its expected canonical JSON;
#                       every rejected fixture fails with its exact error code AND both
#                       conflict locations.
#   (2) witness       — each rejection fixture still CONTAINS the construct it is named for.
#                       A fixture whose duplicate was accidentally edited away would pass a
#                       naive "it was rejected" check while proving nothing.
#   (3) backend       — the result is byte-identical with yq present, with yq POISONED, and
#                       with yq absent, and the poisoned shim proves yq is never consulted.
#                       Hiding yq behind PATH alone would not prove that.
#   (4) oracle        — where the contract claims to agree with YAML at large, the accepted
#                       corpus is re-derived with real yq and must match byte-for-byte.
#   (5) mutation      — seven historical defects are reintroduced into a COPY of the library;
#                       each must be proven applied, and each must break the corpus. A suite
#                       that cannot fail is not evidence.
#   (6) consumers     — the migrated override/profile readers reject duplicates end-to-end,
#                       so no consumer path can bypass the frontend.
#
# Hermetic. NETWORK-FREE. Runs identically with or without yq installed.
# Run via: sh tests/prod/257-yaml-policy-contract.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/lib/yaml-policy.sh"
FIX="$ROOT/tests/fixtures/yaml-policy"

FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

[ -f "$LIB" ] || { fail "scripts/lib/yaml-policy.sh is missing"; exit 1; }
[ -d "$FIX" ] || { fail "tests/fixtures/yaml-policy/ is missing"; exit 1; }
command -v jq >/dev/null 2>&1 || { fail "jq is required to run this suite"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/257-yaml-policy.XXXXXX")
# No `exit` in the trap: an aborted run must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT INT TERM

# norm <lib> <file> — normalize with a given library copy; canonical JSON on stdout,
# the diagnostic on stderr, the library's exit status preserved.
norm() { sh "$1" normalize "$2"; }

# ---------------------------------------------------------------------------
# (0) corpus integrity — no orphan expectations
# ---------------------------------------------------------------------------
# A renamed or deleted fixture leaves its expectation behind. The orphan then looks
# like coverage in the directory listing while nothing executes it.
orphans=""
for e in "$FIX"/expected/*; do
	n=$(basename "$e"); n=${n%.json}; n=${n%.err}
	[ -f "$FIX/accepted/$n.yaml" ] || [ -f "$FIX/divergent/$n.yaml" ] || [ -f "$FIX/rejected/$n.yaml" ] \
		|| orphans="$orphans $n"
done
[ -z "$orphans" ] && pass "every expectation file has a live fixture (no orphans)" \
	|| fail "orphan expectation(s) with no fixture:$orphans"

# ---------------------------------------------------------------------------
# (1) corpus — accepted
# ---------------------------------------------------------------------------
acc_total=0; acc_bad=0
for f in "$FIX"/accepted/*.yaml; do
	n=$(basename "$f" .yaml)
	exp="$FIX/expected/$n.json"
	acc_total=$((acc_total + 1))
	if [ ! -f "$exp" ]; then fail "accepted/$n has no expected/$n.json"; acc_bad=$((acc_bad + 1)); continue; fi
	if ! got=$(norm "$LIB" "$f" 2>"$TMP/err"); then
		fail "accepted/$n was REJECTED: $(cat "$TMP/err")"; acc_bad=$((acc_bad + 1)); continue
	fi
	if [ "$got" != "$(cat "$exp")" ]; then
		fail "accepted/$n canonical JSON differs from expected"
		diff -u "$exp" - <<EOF || :
$got
EOF
		acc_bad=$((acc_bad + 1))
	fi
done
[ "$acc_total" -ge 15 ] || fail "accepted corpus is suspiciously small ($acc_total fixtures)"
[ "$acc_bad" -eq 0 ] && pass "every accepted fixture normalizes to its expected canonical JSON ($acc_total)"

# deliberate, documented divergences from YAML-at-large (see docs/yaml-policy-contract.md).
div_total=0; div_bad=0
for f in "$FIX"/divergent/*.yaml; do
	n=$(basename "$f" .yaml); exp="$FIX/expected/$n.json"; div_total=$((div_total + 1))
	if ! got=$(norm "$LIB" "$f" 2>/dev/null); then fail "divergent/$n was rejected"; div_bad=$((div_bad + 1)); continue; fi
	[ "$got" = "$(cat "$exp")" ] || { fail "divergent/$n differs from expected"; div_bad=$((div_bad + 1)); }
done
[ "$div_bad" -eq 0 ] && pass "documented type divergences are stable ($div_total)"

# ---------------------------------------------------------------------------
# (1) corpus — rejected, with EXACT code and both locations
# ---------------------------------------------------------------------------
rej_total=0; rej_bad=0
for f in "$FIX"/rejected/*.yaml; do
	n=$(basename "$f" .yaml)
	exp="$FIX/expected/$n.err"
	rej_total=$((rej_total + 1))
	if [ ! -f "$exp" ]; then fail "rejected/$n has no expected/$n.err"; rej_bad=$((rej_bad + 1)); continue; fi
	# `rc=$?` AFTER an `if` reads the status of the `if`, not of the command — the
	# status has to be captured on the invocation itself.
	rc=0; norm "$LIB" "$f" 2>"$TMP/err" >"$TMP/out" || rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "rejected/$n was ACCEPTED (expected: $(cat "$exp"))"; rej_bad=$((rej_bad + 1)); continue
	fi
	[ "$rc" -eq 3 ] || { fail "rejected/$n exited $rc, expected 3 (contract violation)"; rej_bad=$((rej_bad + 1)); }
	if [ "$(cat "$TMP/err")" != "$(cat "$exp")" ]; then
		fail "rejected/$n error differs: got [$(cat "$TMP/err")] want [$(cat "$exp")]"
		rej_bad=$((rej_bad + 1))
	fi
	# A rejection must produce NO document: a partially-built object is exactly the
	# state in which an overwritten duplicate would already have been lost.
	[ -s "$TMP/out" ] && { fail "rejected/$n still emitted a document on stdout"; rej_bad=$((rej_bad + 1)); }
done
[ "$rej_total" -ge 30 ] || fail "rejected corpus is suspiciously small ($rej_total fixtures)"
[ "$rej_bad" -eq 0 ] && pass "every rejected fixture fails closed with its exact error and no output ($rej_total)"

# every duplicate-class rejection must name BOTH conflicting locations
dup_bad=0
for e in "$FIX"/expected/*.err; do
	case "$(awk '{print $2}' "$e")" in
		YAML_DUPLICATE_KEY | YAML_DUPLICATE_LIST_ITEM | YAML_AMBIGUOUS_KEY_CASE)
			grep -Eq 'key=[^ ]+ first=[0-9]+:[0-9]+ second=[0-9]+:[0-9]+' "$e" \
				|| { fail "$(basename "$e"): duplicate error lacks key/first/second"; dup_bad=1; }
			;;
	esac
done
[ "$dup_bad" -eq 0 ] && pass "every duplicate rejection reports the canonical key and BOTH locations"

# errors must not echo file content (policy files sit beside secrets in CI logs)
leak=0
for f in "$FIX"/rejected/*.yaml; do
	n=$(basename "$f" .yaml)
	# any error line longer than 200 bytes is a content dump, not a diagnostic
	[ "$(wc -c < "$FIX/expected/$n.err")" -gt 200 ] && { fail "rejected/$n error message is oversized (possible content leak)"; leak=1; }
done
[ "$leak" -eq 0 ] && pass "no rejection message dumps file content"

# ---------------------------------------------------------------------------
# (2) witness — the fixture still contains the construct it is named for
# ---------------------------------------------------------------------------
# Keyed by error code. A fixture that lost its defect (a duplicate silently edited
# away) would otherwise keep "passing" while testing nothing.
witness_bad=0
for f in "$FIX"/rejected/*.yaml; do
	n=$(basename "$f" .yaml)
	code=$(awk '{print $2}' "$FIX/expected/$n.err")
	ok=1
	case "$code" in
		YAML_DUPLICATE_KEY | YAML_AMBIGUOUS_KEY_CASE)
			# the leaf of the reported canonical key must appear at least twice
			leaf=$(awk '{for(i=1;i<=NF;i++) if($i ~ /^key=/){k=substr($i,5)}} END{n=split(k,p,"."); print p[n]}' "$FIX/expected/$n.err")
			cnt=$(grep -Eic "(^|[^A-Za-z0-9_-])['\"]?${leaf}['\"]?[[:space:]]*:" "$f" || true)
			[ "${cnt:-0}" -ge 2 ] || ok=0
			;;
		YAML_DUPLICATE_LIST_ITEM)
			cnt=$(grep -c '^[[:space:]]*- ' "$f" || true)
			[ "${cnt:-0}" -ge 2 ] || ok=0
			;;
		YAML_TAB_INDENTATION)       grep -q "$(printf '\t')" "$f" || ok=0 ;;
		YAML_CRLF_LINE_ENDING)      grep -q "$(printf '\r')" "$f" || ok=0 ;;
		YAML_UNSUPPORTED_ANCHOR)    grep -Eq '(^|[[:space:]])&[A-Za-z0-9_]' "$f" || ok=0 ;;
		YAML_UNSUPPORTED_ALIAS)     grep -Eq ':[[:space:]]*\*[A-Za-z0-9_]' "$f" || ok=0 ;;
		YAML_UNSUPPORTED_MERGE_KEY) grep -Eq '<<[[:space:]]*:' "$f" || ok=0 ;;
		YAML_UNSUPPORTED_TAG)       grep -q '!' "$f" || ok=0 ;;
		YAML_UNSUPPORTED_BLOCK_SCALAR) grep -Eq ':[[:space:]]*[|>]([[:space:]]|$)' "$f" || ok=0 ;;
		YAML_UNSUPPORTED_DOCUMENT_MARKER) grep -Eq '^(---|\.\.\.)' "$f" || ok=0 ;;
		YAML_UNSUPPORTED_FLOW_SEQUENCE) grep -q '\[' "$f" || ok=0 ;;
		YAML_UNSUPPORTED_FLOW_NESTING)  [ "$(grep -c '{' "$f" || true)" -ge 1 ] || ok=0 ;;
		YAML_UNSUPPORTED_ESCAPE)    grep -q '\\' "$f" || ok=0 ;;
		YAML_INVALID_UTF8)          LC_ALL=C grep -q '[\200-\377]' "$f" || ok=0 ;;
		YAML_CONTROL_CHARACTER)     LC_ALL=C grep -q '[\001-\010\013-\037\177]' "$f" || ok=0 ;;
		YAML_UNSUPPORTED_SEQUENCE_ITEM) grep -Eq '^[[:space:]]*-[[:space:]]+[^[:space:]]+:' "$f" || ok=0 ;;
	esac
	[ "$ok" -eq 1 ] || { fail "rejected/$n no longer contains the $code construct it claims to test"; witness_bad=1; }
done
[ "$witness_bad" -eq 0 ] && pass "every rejection fixture still contains the construct it tests"

# ---------------------------------------------------------------------------
# (3) backend — yq is never a semantic authority
# ---------------------------------------------------------------------------
# Structural guard first: the library must not invoke yq at all.
if grep -nE '(^|[^A-Za-z0-9_-])yq([^A-Za-z0-9_-]|$)' "$LIB" | grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .; then
	fail "yaml-policy.sh references yq outside comments — there must be no second interpreter"
else
	pass "yaml-policy.sh contains no yq invocation (single semantic authority)"
fi

# corpus_digest <extra-path> — a stable digest of the WHOLE corpus result under a
# given PATH prefix, so three environments can be compared as one value.
corpus_digest() {
	_pfx="$1"
	for f in "$FIX"/accepted/*.yaml "$FIX"/divergent/*.yaml "$FIX"/rejected/*.yaml; do
		printf '%s\n' "$(basename "$f")"
		PATH="$_pfx$PATH" sh "$LIB" normalize "$f" 2>&1 || printf 'rc=%s\n' "$?"
	done | (command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256) | cut -d' ' -f1
}

# Poisoned yq: if the parser ever calls it, the sentinel appears and the call fails.
POISON="$TMP/poison"; mkdir -p "$POISON"
SENTINEL="$TMP/yq-was-called"
cat > "$POISON/yq" <<EOF
#!/bin/sh
: > "$SENTINEL"
echo "poisoned yq must never be consulted" >&2
exit 42
EOF
chmod +x "$POISON/yq"

# yq stripped from PATH entirely (a different failure mode from a poisoned binary:
# this one exercises "command_exists yq" being false rather than the call failing).
NOYQ="$TMP/noyq"; mkdir -p "$NOYQ"
cat > "$NOYQ/yq" <<'EOF'
#!/bin/sh
echo "yq: not found" >&2
exit 127
EOF
chmod +x "$NOYQ/yq"

d_real=$(corpus_digest "")
d_poison=$(corpus_digest "$POISON:")
d_noyq=$(corpus_digest "$NOYQ:")

[ -e "$SENTINEL" ] && fail "the parser INVOKED yq — yq is still a semantic authority" \
	|| pass "the parser never invoked yq (poisoned shim was not touched)"

if [ "$d_real" = "$d_poison" ] && [ "$d_real" = "$d_noyq" ]; then
	pass "corpus result is byte-identical with yq present, poisoned, and unavailable"
else
	fail "corpus result changed with yq availability (real=$d_real poisoned=$d_poison absent=$d_noyq)"
fi

# The suite must be able to observe whether real yq exists, and say so — a skipped
# oracle that looks like a pass is how parity claims rot.
if command -v yq >/dev/null 2>&1 && yq --version 2>/dev/null | grep -Eq 'mikefarah|version v4'; then
	YQ_REAL=1; pass "backend probe: real mikefarah yq v4 IS installed (oracle checks will run)"
else
	YQ_REAL=0; printf 'SKIP: mikefarah yq v4 is not installed — the independent-oracle checks did not run\n'
fi

# ---------------------------------------------------------------------------
# (4) oracle — accepted corpus re-derived by an independent implementation
# ---------------------------------------------------------------------------
if [ "$YQ_REAL" -eq 1 ]; then
	orc_bad=0
	for f in "$FIX"/accepted/*.yaml; do
		n=$(basename "$f" .yaml)
		if ! oracle=$(yq -o=json e '.' "$f" 2>/dev/null | jq -S . 2>/dev/null); then
			fail "oracle: yq could not parse accepted/$n (the subset accepts something YAML does not)"; orc_bad=1; continue
		fi
		got=$(norm "$LIB" "$f")
		[ "$got" = "$oracle" ] || { fail "oracle: accepted/$n differs from yq"; orc_bad=1; }
	done
	[ "$orc_bad" -eq 0 ] && pass "every accepted fixture matches the independent yq oracle byte-for-byte"

	# The repository's own shipped policy files must survive its own parser AND agree
	# with the oracle — a parser that rejects the templates it ships is not shippable.
	ship_bad=0
	for f in "$ROOT"/templates/profile.yaml "$ROOT"/templates/quality-policy.example.yaml \
		"$ROOT"/templates/testing-discipline-policy.example.yaml \
		"$ROOT"/templates/architecture-policy.example.yaml \
		"$ROOT"/examples/laravel-react-docker/.sentinel-shield/profile.yaml \
		"$ROOT"/docs/examples/profiles/*.yaml; do
		[ -f "$f" ] || continue
		got=$(norm "$LIB" "$f" 2>"$TMP/err") || { fail "shipped $(basename "$f") is REJECTED: $(cat "$TMP/err")"; ship_bad=1; continue; }
		oracle=$(yq -o=json e '.' "$f" 2>/dev/null | jq -S .)
		[ "$got" = "$oracle" ] || { fail "shipped $(basename "$f") differs from yq"; ship_bad=1; }
	done
	[ "$ship_bad" -eq 0 ] && pass "every shipped policy/profile file parses and matches the oracle"
fi

# ---------------------------------------------------------------------------
# (5) mutation proofs — reintroduce historical defects; each MUST break the corpus
# ---------------------------------------------------------------------------
# mutate <name> <sed-expr> <proof-grep> <fixture> <mode>
#   mode=accepts  : the mutant must now ACCEPT a fixture the contract rejects
#   mode=miscompiles: the mutant must now produce the WRONG json for an accepted fixture
#
# The mutant runs from a COPY OF THE WHOLE lib directory: yaml-policy.sh locates its
# siblings via `dirname $0`, so a lone mutant in $TMP would die at exit 2 for a
# missing sentinel-shield-common.sh — which reads exactly like "the defect was still
# caught" and would turn every mutation proof into a false negative.
MUTLIB="$TMP/lib"
mkdir -p "$MUTLIB"
cp "$ROOT"/scripts/lib/*.sh "$MUTLIB/"

mutate() {
	_name="$1"; _sed="$2"; _proof="$3"; _fixture="$4"; _mode="$5"
	_m="$MUTLIB/yaml-policy.sh"
	sed "$_sed" "$LIB" > "$_m"
	# Proving the mutation APPLIED is not ceremony: a sed that silently matched
	# nothing would leave the pristine library, and "the corpus still fails" would
	# be read as the defect being caught when nothing was ever injected.
	# -F: the proof patterns are literal awk source containing /, $, *, [ ] and +.
	# Interpreted as a regex they would silently fail to match and void the proof.
	if ! grep -qF "$_proof" "$_m"; then
		fail "mutation '$_name' did not apply (proof pattern absent) — mutation proof is void"; return
	fi
	if cmp -s "$_m" "$LIB"; then
		fail "mutation '$_name' produced an identical file — mutation proof is void"; return
	fi
	# Sanity: the mutant must still be a runnable library, otherwise "the fixture is
	# still rejected" would just mean the mutant crashed.
	if ! sh "$_m" normalize "$FIX/accepted/01-simple-block-map.yaml" >/dev/null 2>&1; then
		fail "mutation '$_name' broke the library outright — the proof would be vacuous"; return
	fi
	case "$_mode" in
		accepts)
			if sh "$_m" normalize "$FIX/rejected/$_fixture.yaml" >/dev/null 2>&1; then
				pass "mutation '$_name' reintroduces the defect (fixture $_fixture now accepted) — corpus catches it"
			else
				fail "mutation '$_name' did NOT change behaviour: $_fixture still rejected, so the corpus does not actually prove this defect"
			fi
			;;
		code-changes)
			# For a construct guarded by MORE than one rule (a merge key is rejected
			# both by its dedicated check and by the key charset), removing one rule
			# cannot make the file parse. What must change is the DIAGNOSIS — proving
			# the removed rule is the one that produces it, and documenting honestly
			# that a second layer still stands behind it.
			_want=$(awk '{print $2}' "$FIX/expected/$_fixture.err")
			_got=$(sh "$_m" normalize "$FIX/rejected/$_fixture.yaml" 2>&1 >/dev/null | awk '{print $2}')
			if [ "$_got" != "$_want" ]; then
				pass "mutation '$_name' changes the diagnosis ($_want -> ${_got:-none}) — corpus catches it"
			else
				fail "mutation '$_name' left the diagnosis at $_want; the check is not what produces it"
			fi
			;;
		miscompiles)
			_got=$(sh "$_m" normalize "$FIX/accepted/$_fixture.yaml" 2>/dev/null || printf 'PARSE_FAILED')
			if [ "$_got" != "$(cat "$FIX/expected/$_fixture.json")" ]; then
				pass "mutation '$_name' corrupts accepted/$_fixture — corpus catches it"
			else
				fail "mutation '$_name' did NOT change accepted/$_fixture output; the corpus does not prove this defect"
			fi
			;;
	esac
}

# 1+2+4+5. duplicate winner behaviour (yq last-wins / fallback first-wins / tool overwrite /
#          gates.mode acceptance) all share one root: no duplicate gate before normalization.
mutate 'duplicate-key detection disabled (last/first-wins restored)' \
	's/if (path in seen)$/if (0 \&\& (path in seen))/' \
	'if (0 && (path in seen))' '02-duplicate-nested-key' accepts
mutate 'duplicate tool declaration overwrite' \
	's/if (path in seen)$/if (0 \&\& (path in seen))/' \
	'if (0 && (path in seen))' '03-duplicate-tool' accepts
mutate 'duplicate gates.mode accepted' \
	's/if (path in seen)$/if (0 \&\& (path in seen))/' \
	'if (0 && (path in seen))' '31-duplicate-after-many-lines' accepts
mutate 'duplicate list item accepted' \
	's/if ((seq_path SEP iv) in seqitem)$/if (0 \&\& ((seq_path SEP iv) in seqitem))/' \
	'if (0 && ((seq_path SEP iv) in seqitem))' '26-duplicate-list-item' accepts
mutate 'case-equivalent key collision accepted' \
	's/if (lc in seenlc \&\& seenlc\[lc\] != path)$/if (0)/' \
	'if (0)' '09-case-collision' accepts

# 3. comment stripping BEFORE quote interpretation — the original fallback defect.
mutate 'comments stripped before quotes are parsed' \
	's|content = substr(line, indent + 1)|sub(/[ ]+#.*$/, "", line); content = substr(line, indent + 1)|' \
	'sub(/[ ]+#.*$/, "", line); content = substr' '04-double-quoted-hash-colon' miscompiles

# 6. malformed line silently ignored (`if (ci == 0) next`).
mutate 'malformed line silently ignored' \
	's/if (ci == 0) err("YAML_MALFORMED_LINE", "at=" at(NR, kc))/if (ci == 0) next/' \
	'if (ci == 0) next' '29-malformed-line' accepts

# 7. alias / merge-key acceptance.
mutate 'YAML aliases accepted' \
	's/if (c == "\*") err("YAML_UNSUPPORTED_ALIAS", "at=" at(NR, start))//' \
	'YAML_UNSUPPORTED_ANCHOR' '14-alias' accepts
mutate 'merge-key rejection removed' \
	's/if (k == "<<") err("YAML_UNSUPPORTED_MERGE_KEY", "at=" at(l, c))//' \
	'YAML_EMPTY_KEY' '15-merge-key' code-changes

# ---------------------------------------------------------------------------
# (6) consumers — no migrated path can bypass the frontend
# ---------------------------------------------------------------------------
TPO="$ROOT/scripts/lib/tool-policy-override.sh"
GATES="$ROOT/scripts/resolve-gates.sh"

if [ -f "$TPO" ]; then
	# duplicate tool -> the override loader must fail closed, not pick a winner
	cat > "$TMP/dup-override.yaml" <<'EOF'
tools:
  grype:
    policy: optional
  grype:
    policy: required
EOF
	if out=$(sh "$TPO" load "$TMP/dup-override.yaml" 2>&1 >/dev/null); then
		fail "tool-policy-override accepted a duplicate tool declaration"
	else
		printf '%s' "$out" | grep -q 'YAML_DUPLICATE_KEY' \
			&& pass "tool-policy-override rejects duplicate tool declarations via the shared frontend" \
			|| fail "tool-policy-override rejected the duplicate but not through the frontend: $out"
	fi

	# quoted '#' must survive: the old fallback truncated it before parsing quotes
	cat > "$TMP/hash-override.yaml" <<'EOF'
tools:
  grype:
    policy: optional
EOF
	sh "$TPO" load "$TMP/hash-override.yaml" >/dev/null 2>&1 \
		&& pass "tool-policy-override still loads a valid override" \
		|| fail "tool-policy-override rejected a VALID override"

	# the loader must not carry its own YAML reader any more
	if grep -qE 'yq -o=json|awk .$' "$TPO" && ! grep -q 'yaml-policy.sh' "$TPO"; then
		fail "tool-policy-override still has its own YAML backend"
	else
		pass "tool-policy-override delegates YAML parsing to the shared frontend"
	fi
fi

if [ -f "$GATES" ]; then
	cat > "$TMP/dup-profile.yaml" <<'EOF'
gates:
  mode: strict
  mode: regulated
EOF
	if out=$(sh "$GATES" --profile "$TMP/dup-profile.yaml" --require-profile --format env 2>&1 >/dev/null); then
		fail "resolve-gates accepted a duplicate gates.mode"
	else
		printf '%s' "$out" | grep -q 'YAML_DUPLICATE_KEY' \
			&& pass "resolve-gates rejects duplicate gates.mode via the shared frontend" \
			|| fail "resolve-gates rejected the duplicate but not through the frontend: $out"
	fi

	# a quoted scalar must resolve identically to an unquoted one — the old fallback
	# never removed quotes, so `mode: "strict"` was an INVALID mode without yq.
	cat > "$TMP/quoted-mode.yaml" <<'EOF'
gates:
  mode: "strict"
EOF
	# resolve-gates WRITES its output file and logs to stderr; capturing stdout would
	# assert on an empty string and pass for the wrong reason.
	if sh "$GATES" --profile "$TMP/quoted-mode.yaml" --require-profile --format env \
		--output-dir "$TMP/rg" >/dev/null 2>"$TMP/q.err"; then
		if grep -q '=strict$' "$TMP/rg"/*.env 2>/dev/null; then
			pass "resolve-gates reads a QUOTED scalar identically to an unquoted one"
		else
			fail "resolve-gates lost the quoted mode value: $(cat "$TMP/rg"/*.env 2>/dev/null | grep -i mode || echo '(no mode line)')"
		fi
	else
		fail "resolve-gates rejected a quoted mode value: $(cat "$TMP/q.err")"
	fi
fi

# ---------------------------------------------------------------------------
[ "$FAILED" -eq 0 ] && printf 'yaml-policy-contract: OK\n'
exit "$FAILED"
