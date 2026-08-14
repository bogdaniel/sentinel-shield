#!/bin/sh
# Sentinel Shield production test — harness truthfulness detectors (#345).
#
# WHY
#
# Five defects of one family have been found in this repository's own suites, every one by
# mutation or inspection rather than by a suite failing:
#
#   1. a pipeline-fed loop mutated FAILS in a subshell — the suite printed FAIL and exited 0
#   2. `pass` in both arms of an if/else — the assertion could never notice its own subject
#   3. tests invoked a collector directly while production wraps it with an identity change —
#      #310 shipped with AC6 unmet and was closed twice on that evidence
#   4. a substring grep for a variable name — a rename still matched
#   5. `git push ... | tail` — the pipeline reported tail's status, so a failed push read as OK
#
# They share one shape: THE SUITE REPORTS SUCCESS UNDER THE EXACT CONDITION IT EXISTS TO DETECT.
#
# BOUNDED COVERAGE, STATED PLAINLY
#
# Detectors 1, 6 and 8 are EXECUTABLE — the fixture is run and its exit status observed, so no
# textual claim is involved. Detectors 2, 3, 4, 5 and 7 are STRUCTURAL: they inspect shell
# structure or a declared inventory. None of them is a general shell-language analysis, and
# each names what it cannot see. Every detector is proved by rejecting a deliberately broken
# fixture and accepting a valid control, so a detector that stops working fails here rather
# than going quiet.
# DETECTOR MATRIX — every detector has an explicit broken input and a valid control.
#
#  id   property detected                          broken input                       valid control
#  ---  -----------------------------------------  ---------------------------------  --------------------------------
#  D1   prints FAIL, exits zero                    bad-fail-exit-zero.sh              good-fail-exit-zero.sh
#  D2   pipeline-fed loop mutates verdict state    bad-pipeline-loop.sh               good-pipeline-loop.sh
#  D3   pass in BOTH arms of one conditional       bad-both-branches-pass.sh          good-both-branches-pass.sh
#  D4   unanchored identity grep                   bad-loose-substring.sh             good-loose-substring.sh
#  D5   mandatory subject covered only directly    bad-fidelity-inventory.json        good-fidelity-inventory.json
#  D6   status taken from a downstream consumer    bad-pipeline-status.sh             good-pipeline-status.sh
#  D7   rejection with no acceptance control       bad-rejection-without-control.sh   good-rejection-without-control.sh
#  D8   detector accepts zero targets              bad-zero-targets.sh                good-zero-targets.sh
#  D9a  live backtick in a diagnostic argument     $TMP/d9/bad-backtick.sh            6 generated controls
#  D9b  live $( ) in a diagnostic argument         $TMP/d9/bad-dollar-paren.sh        6 generated controls
#
# D1, D6, D8, D9 are proved EXECUTABLY — the input is run and its behaviour observed. D2, D3,
# D4, D5, D7 are structural or inventory-driven. No fixture pair is counted for two detectors:
# each detector asserts its own verdict on its own input.
#
# D9's inputs are SYNTHESIZED INTO $TMP as data, never committed: a fixture that executes
# anything belongs in a sandbox, not in the repository. Its unsafe input proves execution by
# writing a fixed sentinel to a path this suite supplies inside $TMP — no account data, no
# environment values, no network, nothing outside the temporary directory, removed by the
# existing trap.
#
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIX="$ROOT/tests/fixtures/harness-truthfulness"
PRODDIR="$ROOT/tests/prod"
FIDELITY="$ROOT/config/invocation-fidelity.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -d "$FIX" ] || { fail "fixture directory is missing"; exit 1; }
[ -f "$FIDELITY" ] || { fail "config/invocation-fidelity.json is missing"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# --- 0. the fixtures must not contaminate production discovery -------------------------------
# A broken fixture that leaked into the production sweep would fail it for the wrong reason.
# Compare against fixture BASENAMES, not a path substring: this suite's own filename contains
# "harness-truthfulness", and a substring test flagged it as a leaked fixture.
_leak=0
for _fx in "$FIX"/*.sh; do
	[ -e "$_fx" ] || continue
	[ -e "$PRODDIR/$(basename "$_fx")" ] && _leak=$((_leak + 1))
done
[ "$_leak" -eq 0 ] \
	&& pass "no fixture is discoverable inside tests/prod" \
	|| fail "$_leak fixture(s) are inside tests/prod and would be run as production tests"
_misnamed=$(find "$FIX" -name '[0-9][0-9][0-9]-*.sh' | wc -l | tr -d ' ')
[ "$_misnamed" -eq 0 ] \
	&& pass "no fixture uses the NNN-*.sh production-suite naming" \
	|| fail "$_misnamed fixture(s) use production-suite naming"

# Every detector below needs its pair present. A missing fixture must FAIL, never skip.
for _n in fail-exit-zero pipeline-loop both-branches-pass loose-substring pipeline-status \
	rejection-without-control zero-targets; do
	if [ -f "$FIX/bad-$_n.sh" ] && [ -f "$FIX/good-$_n.sh" ]; then
		pass "fixtures present for '$_n'"
	else
		fail "missing bad-/good- fixture pair for '$_n' — its detector has no evidence"
	fi
done

# ===========================================================================
# DETECTOR 1 (executable) — a suite prints an assertion-level FAIL and exits zero
# ===========================================================================
# Executable, so there is no textual heuristic: the fixture is RUN.
d1() { # d1 <script> -> 0 when the script is truthful, 1 when it prints FAIL and exits 0
	_out=$(sh "$1" 2>/dev/null) && _rc=0 || _rc=$?
	if printf '%s' "$_out" | grep -qE '^FAIL' && [ "$_rc" -eq 0 ]; then return 1; fi
	return 0
}
d1 "$FIX/bad-fail-exit-zero.sh" && fail "D1: a script printing FAIL and exiting 0 was accepted" \
	|| pass "D1: a script printing FAIL and exiting 0 is rejected"
d1 "$FIX/good-fail-exit-zero.sh" && pass "D1 CONTROL: a script printing FAIL and exiting non-zero is accepted" \
	|| fail "D1 CONTROL: the truthful script was rejected — D1 proves nothing"

# Applied to the REAL production suites. Only suites that are cheap and side-effect-free to
# re-run are executed here; the rest are covered by the structural detectors below. That bound
# is deliberate and named: running all 96 suites inside one suite would be a second sweep.
_d1_checked=0
for _s in "$PRODDIR"/303-*.sh "$PRODDIR"/305-*.sh; do
	[ -e "$_s" ] || continue
	_d1_checked=$((_d1_checked + 1))
	d1 "$_s" || fail "D1: $(basename "$_s") prints FAIL and exits 0"
done
[ "$_d1_checked" -gt 0 ] \
	&& pass "D1: $_d1_checked production suite(s) checked executably" \
	|| fail "D1: zero production suites checked — the detector ran over an empty set"

# ===========================================================================
# DETECTOR 2 (structural) — a pipeline-fed loop mutating parent verdict state
# ===========================================================================
# Bounded: matches `... | while ... done` whose BODY assigns a verdict-ish variable. It does not
# understand every way a subshell can be created, and it deliberately ignores harmless
# pipelines — a `| while` that only prints is not flagged.
d2() { # d2 <script> -> 1 when a pipeline-fed loop mutates verdict state
	# Comments are stripped first: 268 documents this exact defect in prose, and an unstripped
	# scan flagged the explanation as the defect.
	# An OBSERVATION-ONLY conditional — one that reports which environment or branch was taken,
	# with the real invariant asserted separately — is legitimate and must DECLARE itself with
	# `sentinel-shield-harness: observation-only` on the line above the `if`. Declaring beats
	# inferring: 301 reports locale and filesystem behaviour this way, and 289 reports which
	# refusal message appeared, in each case with a `check` doing the actual work.
	grep -vE '^[[:space:]]*#[^s]' "$1" | awk '
		/\|[[:space:]]*while /            { inloop = 1 }
		inloop && /(FAILS|FAILED|RC|_rc|VERDICT)[[:space:]]*=/ { found = 1 }
		inloop && /^[[:space:]]*done/     { inloop = 0 }
		END { exit (found ? 1 : 0) }
	'
}
d2 "$FIX/bad-pipeline-loop.sh" && fail "D2: a pipeline-fed loop mutating FAILS was accepted" \
	|| pass "D2: a pipeline-fed loop mutating verdict state is rejected"
d2 "$FIX/good-pipeline-loop.sh" && pass "D2 CONTROL: the same loop fed from a file is accepted" \
	|| fail "D2 CONTROL: the file-fed loop was rejected — D2 proves nothing"
_d2_bad=""; _d2_n=0
for _s in "$PRODDIR"/*.sh; do
	[ -e "$_s" ] || continue
	_d2_n=$((_d2_n + 1))
	d2 "$_s" || _d2_bad="$_d2_bad $(basename "$_s")"
done
[ "$_d2_n" -gt 0 ] || fail "D2: zero production suites scanned"
[ -z "$_d2_bad" ] \
	&& pass "D2: no production suite mutates verdict state in a pipeline-fed loop ($_d2_n scanned)" \
	|| fail "D2: pipeline-fed loops mutating verdict state in:$_d2_bad"

# ===========================================================================
# DETECTOR 3 (structural) — `pass` in both arms of one if/else
# ===========================================================================
# Bounded: comment lines are stripped first, and only the arms of the SAME conditional at the
# same nesting are compared. A nested branch inside one arm is not treated as the other arm.
d3() { # d3 <script> -> 1 when an if/else calls pass in both arms
	# Comments are stripped EXCEPT the observation-only marker, which is itself a comment: a
	# plain comment filter removed the very declaration this detector must read.
	awk '!/^[[:space:]]*#/ || /sentinel-shield-harness/' "$1" | awk '
		/sentinel-shield-harness: observation-only/ { obs = 1 }
		/^[[:space:]]*if / { depth++; a[depth] = 0; b[depth] = 0; fa[depth] = 0; fb[depth] = 0; inelse[depth] = 0; ob[depth] = obs; obs = 0 }
		depth > 0 && /^[[:space:]]*else[[:space:]]*$/ { inelse[depth] = 1 }
		depth > 0 && /(^|[^_[:alnum:]])pass[[:space:]]+"/ {
			if (inelse[depth]) b[depth] = 1; else a[depth] = 1
		}
		# An arm that can FAIL is not a false green, however it also passes. 283 flags here
		# otherwise: its then-arm is `pass || fail`, and its else-arm passes because "no ignore
		# file required" is a genuinely valid state.
		depth > 0 && /(^|[^_[:alnum:]])fail[[:space:]]+"/ {
			if (inelse[depth]) fb[depth] = 1; else fa[depth] = 1
		}
		/^[[:space:]]*fi([[:space:]]|$)/ {
			if (depth > 0) {
				if (a[depth] && b[depth] && !fa[depth] && !fb[depth] && !ob[depth]) found = 1
				depth--
			}
		}
		END { exit (found ? 1 : 0) }
	'
}
d3 "$FIX/bad-both-branches-pass.sh" && fail "D3: an if/else calling pass in both arms was accepted" \
	|| pass "D3: an if/else calling pass in both arms is rejected"
d3 "$FIX/good-both-branches-pass.sh" && pass "D3 CONTROL: pass/fail arms are accepted" \
	|| fail "D3 CONTROL: the pass/fail conditional was rejected — D3 proves nothing"
_d3_bad=""; _d3_n=0
for _s in "$PRODDIR"/*.sh; do
	[ -e "$_s" ] || continue
	_d3_n=$((_d3_n + 1))
	d3 "$_s" || _d3_bad="$_d3_bad $(basename "$_s")"
done
[ "$_d3_n" -gt 0 ] || fail "D3: zero production suites scanned"
[ -z "$_d3_bad" ] \
	&& pass "D3: no production suite calls pass in both arms of one conditional ($_d3_n scanned)" \
	|| fail "D3: both-branches-pass conditionals in:$_d3_bad"

# ===========================================================================
# DETECTOR 4 (structural) — a loose substring match where an identity is required
# ===========================================================================
# Bounded to the case that actually bit: a bare `grep -q '<SENTINEL_SHIELD_...>'` asserting a
# variable is USED. A rename to <NAME>_TYPO still matches such a grep. Anchored forms and
# expansions are accepted.
d4() { # d4 <script> -> 1 when an unanchored SENTINEL_SHIELD_* identity grep is present
	grep -vE '^[[:space:]]*#' "$1" \
		| grep -E "grep -q ['\"]SENTINEL_SHIELD_[A-Z_]+['\"]" >/dev/null && return 1
	return 0
}
d4 "$FIX/bad-loose-substring.sh" && fail "D4: an unanchored identity grep was accepted" \
	|| pass "D4: an unanchored identity grep is rejected"
d4 "$FIX/good-loose-substring.sh" && pass "D4 CONTROL: an anchored identity grep is accepted" \
	|| fail "D4 CONTROL: the anchored form was rejected — D4 proves nothing"
_d4_bad=""; _d4_n=0
for _s in "$PRODDIR"/*.sh; do
	[ -e "$_s" ] || continue
	_d4_n=$((_d4_n + 1))
	d4 "$_s" || _d4_bad="$_d4_bad $(basename "$_s")"
done
[ "$_d4_n" -gt 0 ] || fail "D4: zero production suites scanned"
[ -z "$_d4_bad" ] \
	&& pass "D4: no production suite asserts an identity with an unanchored grep ($_d4_n scanned)" \
	|| fail "D4: unanchored identity greps in:$_d4_bad"

# ===========================================================================
# DETECTOR 5 (inventory) — evidence-critical subjects must be covered through the orchestrator
# ===========================================================================
# Driven by config/invocation-fidelity.json, NOT by guessing from source text. A suite may be
# direct-only provided its SUBJECT is covered through the orchestrator by a named other suite.
_n_suites=$(jq -r '.suites | length' "$FIDELITY")
[ "$_n_suites" -gt 0 ] \
	&& pass "D5: the invocation-fidelity inventory holds $_n_suites suite row(s)" \
	|| fail "D5: the inventory is empty — this detector would pass vacuously"
_d5_bad=$(jq -r '.suites[]
	| select(.production_path_mandatory == true)
	| select((.subject_covered_through_orchestrator_by // "") == "")
	| .suite' "$FIDELITY")
[ -z "$_d5_bad" ] \
	&& pass "D5: every mandatory subject names a suite that covers it through the orchestrator" \
	|| fail "D5: mandatory subjects with no named production-path coverage: $_d5_bad"
# The named covering suite must EXIST, and a direct-only suite may not name itself.
_d5_missing=""
jq -r '.suites[] | select(.production_path_mandatory == true)
	| [.suite, .subject_covered_through_orchestrator_by, (.builder_orchestrator_coverage|tostring)] | @tsv' "$FIDELITY" > "$TMP/fid"
while IFS="$(printf '\t')" read -r _su _by _has; do
	[ -n "$_su" ] || continue
	[ -f "$ROOT/$_by" ] || _d5_missing="$_d5_missing $_by"
	# A suite may name itself when it DOES drive the production layer for its subject. Only a
	# direct-only suite naming itself is circular. 302 drives enforce-gates — the layer that
	# transforms the observed-execution contract — so it legitimately covers its own subject
	# even though no BUILDER transformation applies to it.
	_cs=$(jq -r --arg s "$_su" '.suites[] | select(.suite == $s) | .coverage_status' "$FIDELITY" | head -1)
	if [ "$_su" = "$_by" ] && [ "$_cs" = "direct-only" ]; then
		fail "D5: $_su is direct-only yet names itself as its production-path coverage"
	fi
done < "$TMP/fid"
[ -z "$_d5_missing" ] \
	&& pass "D5: every named covering suite exists" \
	|| fail "D5: named covering suite(s) do not exist:$_d5_missing"

# D5's own broken input and valid control. Without these the detector is only ever run against
# a passing inventory, so a detector that accepted anything would look identical.
d5() { # d5 <inventory> -> 1 when a mandatory subject has no valid covering suite
	jq -e '[.suites[]
		| select(.production_path_mandatory == true)
		| select(((.subject_covered_through_orchestrator_by // "") == "")
		         or (.coverage_status == "direct-only" and .subject_covered_through_orchestrator_by == .suite))
		] | length == 0' "$1" >/dev/null 2>&1 || return 1
	return 0
}
d5 "$FIX/bad-fidelity-inventory.json" \
	&& fail "D5: an inventory with an uncovered mandatory subject was accepted" \
	|| pass "D5: an inventory with an uncovered mandatory subject is rejected"
d5 "$FIX/good-fidelity-inventory.json" \
	&& pass "D5 CONTROL: a fully-covered inventory is accepted" \
	|| fail "D5 CONTROL: the valid inventory was rejected — D5 proves nothing"
d5 "$FIDELITY" \
	&& pass "D5: the shipped invocation-fidelity inventory satisfies the rule" \
	|| fail "D5: the shipped inventory has an uncovered mandatory subject"

# ===========================================================================
# DETECTOR 6 (executable) — pipeline status taken from a downstream consumer
# ===========================================================================
# Executable AND structural. The structural half matches a security-relevant command whose
# status is consumed by a downstream stage; the executable half proves the shape really does
# lose the status, so the rule is demonstrated rather than asserted.
_probe_rc=$( (exit 7) | tail -1 >/dev/null 2>&1; printf '%s' "$?")
[ "$_probe_rc" = "0" ] \
	&& pass "D6: demonstrated — a pipeline reports the LAST stage's status, so an upstream failure is lost" \
	|| fail "D6: the shell did not exhibit the pipeline-status behaviour this detector is built on (got $_probe_rc)"
d6() { # d6 <script> -> 1 when a status-critical command's exit is consumed by a pipe
	grep -vE '^[[:space:]]*#' "$1" \
		| grep -E "(^|;|&&|\\|\\||\\\$\\(|\\bif |\\belif |\\bthen |\\bdo )[[:space:]]*(git (push|merge)|gh (pr|api)|merge-evidence\.sh)[^|']*\|[[:space:]]*(tail|tee|head|cat|grep)" >/dev/null && return 1
	return 0
}
d6 "$FIX/bad-pipeline-status.sh" && fail "D6: a push piped into tail was accepted (the shape that reports tail status)" \
	|| pass "D6: a status-critical command piped into a consumer is rejected"
d6 "$FIX/good-pipeline-status.sh" && pass "D6 CONTROL: capturing rc before the pipe is accepted" \
	|| fail "D6 CONTROL: the correct form was rejected — D6 proves nothing"
_d6_bad=""; _d6_n=0
for _s in "$PRODDIR"/*.sh "$ROOT"/scripts/*.sh; do
	[ -e "$_s" ] || continue
	_d6_n=$((_d6_n + 1))
	d6 "$_s" || _d6_bad="$_d6_bad $(basename "$_s")"
done
[ "$_d6_n" -gt 0 ] || fail "D6: zero files scanned"
[ -z "$_d6_bad" ] \
	&& pass "D6: no shipped script takes a status-critical exit from a downstream consumer ($_d6_n scanned)" \
	|| fail "D6: pipeline-status defects in:$_d6_bad"

# ===========================================================================
# DETECTOR 7 (structural, declared) — a rejection assertion with no acceptance control
# ===========================================================================
# Pairing is DECLARED, not inferred from test names. A fixture states its own shape with a
# `sentinel-shield-harness:` marker, so the detector reads an explicit claim rather than
# guessing from wording — which is what makes it evidence rather than a heuristic.
d7() { # d7 <script> -> 1 when a declared rejection has no declared control
	grep -q 'sentinel-shield-harness: declares-rejection' "$1" || return 0
	grep -q 'sentinel-shield-harness: declares-control' "$1" && return 0
	return 1
}
d7 "$FIX/bad-rejection-without-control.sh" && fail "D7: a rejection with no control was accepted" \
	|| pass "D7: a declared rejection with no declared control is rejected"
d7 "$FIX/good-rejection-without-control.sh" && pass "D7 CONTROL: a rejection with a control is accepted" \
	|| fail "D7 CONTROL: the paired fixture was rejected — D7 proves nothing"
# Bound, named: only files that OPT IN by declaring a rejection are evaluated. This detector
# cannot find an undeclared rejection, and does not pretend to.
_d7_declared=$(grep -rl 'sentinel-shield-harness: declares-rejection' "$PRODDIR" "$FIX" 2>/dev/null | wc -l | tr -d ' ')
[ "$_d7_declared" -gt 0 ] \
	&& pass "D7: $_d7_declared file(s) declare a rejection shape and were evaluated" \
	|| fail "D7: no file declares a rejection shape — the detector ran over an empty set"

# ===========================================================================
# DETECTOR 8 (executable) — a detector that accepts zero discovered targets
# ===========================================================================
d8() { # d8 <script> -> 1 when the script reports success over zero targets
	_o=$(sh "$1" 2>/dev/null) && _r=0 || _r=$?
	if [ "$_r" -eq 0 ] && printf '%s' "$_o" | grep -qE 'checked 0 target'; then return 1; fi
	return 0
}
d8 "$FIX/bad-zero-targets.sh" && fail "D8: a detector reporting success over zero targets was accepted" \
	|| pass "D8: a detector reporting success over zero targets is rejected"
d8 "$FIX/good-zero-targets.sh" && pass "D8 CONTROL: a detector that fails on zero targets is accepted" \
	|| fail "D8 CONTROL: the refusing detector was rejected — D8 proves nothing"
# This suite holds itself to the same rule: every detector above asserted a non-zero scanned
# count, and those assertions are what make D8 apply to 306 itself.
[ "$_d2_n" -gt 0 ] && [ "$_d3_n" -gt 0 ] && [ "$_d4_n" -gt 0 ] && [ "$_d6_n" -gt 0 ] \
	&& pass "D8: this suite's own detectors each scanned a non-empty target set" \
	|| fail "D8: one of this suite's detectors scanned nothing"

# ===========================================================================
# DETECTOR 9 — a diagnostic that EXECUTES the syntax it describes
# ===========================================================================
# Security-relevant, and found the hard way: a `fail` message in this suite once carried a live
# backtick inside a double-quoted string, so the shell ran the example command while the suite
# reported the defect.
#
# TWO NAMED SUBCHECKS, because the unsafe family has two spellings:
#   D9a  live backtick substitution inside an expandable diagnostic argument
#   D9b  live $( ) substitution inside an expandable diagnostic argument
#
# COVERED SHAPES, stated exactly: a call to one of the diagnostic helpers pass / fail /
# log_error / log_warn / log_info whose FIRST argument is a DOUBLE-QUOTED string containing an
# unescaped substitution. Not covered, deliberately: single-quoted arguments (never expanded),
# escaped forms, comments, and syntax inside single-quoted grep/awk/jq program text — all of
# which appear legitimately in this repository. This is not a shell parser and does not claim
# to be one.
#
# The dangerous bytes are BUILT AS DATA and written only into $TMP. Committing a fixture that
# executes anything, or embedding the syntax in this suite, would put the hazard in the
# repository rather than in a sandbox.
_BT=$(printf '\140')          # backtick
_DL=$(printf '\044')          # dollar

D9DIR="$TMP/d9"; mkdir -p "$D9DIR"
# The unsafe fixtures prove execution by writing a FIXED SENTINEL to a path this suite supplies,
# inside $TMP. No account data, no environment values, no network, nothing outside $TMP.
SENTINEL="$D9DIR/executed.token"
_mk() { printf '%s\n' "$2" > "$D9DIR/$1"; chmod +x "$D9DIR/$1"; }
_mk bad-backtick.sh "#!/bin/sh
fail() { printf 'FAIL: %s\\n' \"\$1\"; }
fail \"unsafe example ${_BT}printf 'D9-EXECUTED' > \$SS_D9_SENTINEL${_BT}\""
_mk bad-dollar-paren.sh "#!/bin/sh
fail() { printf 'FAIL: %s\\n' \"\$1\"; }
fail \"unsafe example ${_DL}(printf 'D9-EXECUTED' > \$SS_D9_SENTINEL)\""
_mk good-escaped-backtick.sh "#!/bin/sh
fail() { printf 'FAIL: %s\\n' \"\$1\"; }
fail \"prose describing a \\${_BT}command\\${_BT} shape\""
_mk good-literal-dollar-paren.sh "#!/bin/sh
fail() { printf 'FAIL: %s\\n' \"\$1\"; }
fail 'prose describing a ${_DL}(command) shape'"
_mk good-single-quoted.sh "#!/bin/sh
fail() { printf 'FAIL: %s\\n' \"\$1\"; }
fail 'a single-quoted diagnostic is never expanded'"
_mk good-command-as-data.sh "#!/bin/sh
fail() { printf 'FAIL: %s\\n' \"\$1\"; }
_cmd='printf hello'
fail \"the command text is passed as data: \$_cmd\""
_mk good-comment-only.sh "#!/bin/sh
# a comment may mention ${_BT}cmd${_BT} and ${_DL}(cmd) freely
fail() { printf 'FAIL: %s\\n' \"\$1\"; }
fail 'nothing unsafe here'"
_mk good-single-quoted-program.sh "#!/bin/sh
fail() { printf 'FAIL: %s\\n' \"\$1\"; }
_n=\$(awk '/${_BT}/ { n++ } END { print n+0 }' /dev/null)
fail 'a jq/awk program in single quotes is program text, not a diagnostic'"

# Both subchecks use awk with index() rather than a regex containing the dangerous characters.
# `$` is an ERE anchor, so a naive pattern silently never matched — and escaping the sequence
# into a double-quoted regex would have put the hazard back into this file.
_d9_scan() { # _d9_scan <file> <2-char-sequence> -> 1 when found unescaped in a diagnostic arg
	awk -v seq="$2" '
		/^[[:space:]]*#/ { next }
		/(^|[^_[:alnum:]])(pass|fail|log_error|log_warn|log_info)[[:space:]]+"/ {
			i = index($0, "\"")
			if (i == 0) next
			rest = substr($0, i + 1)
			j = index(rest, seq)
			if (j > 0 && (j == 1 || substr(rest, j - 1, 1) != "\\")) { found = 1 }
		}
		END { exit (found ? 1 : 0) }
	' "$1"
}
d9a() { _d9_scan "$1" "$_BT"; }          # live backtick substitution
d9b() { _d9_scan "$1" "$_DL("; }         # live $( ) substitution
d9()  { d9a "$1" && d9b "$1"; }

d9a "$D9DIR/bad-backtick.sh" && fail "D9a: a live backtick diagnostic was accepted" \
	|| pass "D9a: a live backtick inside a diagnostic argument is rejected"
d9b "$D9DIR/bad-dollar-paren.sh" && fail "D9b: a live command substitution diagnostic was accepted" \
	|| pass "D9b: a live substitution inside a diagnostic argument is rejected"
for _g in good-escaped-backtick good-literal-dollar-paren good-single-quoted \
	good-command-as-data good-comment-only good-single-quoted-program; do
	d9 "$D9DIR/$_g.sh" && pass "D9 CONTROL: $_g is accepted" \
		|| fail "D9 CONTROL: $_g was rejected — the detector over-matches legitimate prose"
done

# EXECUTABLE PROOF that the rejected shape really is dangerous, run ONLY in the sandbox and
# asserted on a fixed sentinel. Detection above is textual and needs no execution; this proves
# the property the detector claims, rather than asserting it.
rm -f "$SENTINEL"
( cd "$D9DIR" && SS_D9_SENTINEL="$SENTINEL" sh "$D9DIR/bad-backtick.sh" >/dev/null 2>&1 ) || true
if [ -f "$SENTINEL" ] && [ "$(cat "$SENTINEL" 2>/dev/null)" = "D9-EXECUTED" ]; then
	pass "D9: the rejected shape provably executes (fixed sentinel written inside the temp dir)"
else
	fail "D9: the unsafe fixture did not execute — the detector may be guarding a shape that is not actually dangerous"
fi
rm -f "$SENTINEL"
( cd "$D9DIR" && SS_D9_SENTINEL="$SENTINEL" sh "$D9DIR/good-single-quoted.sh" >/dev/null 2>&1 ) || true
[ ! -f "$SENTINEL" ] \
	&& pass "D9 CONTROL: the accepted shape executes nothing" \
	|| fail "D9 CONTROL: a single-quoted diagnostic executed its content"

# REPO-WIDE ENFORCEMENT IS D9a ONLY, and the asymmetry is deliberate.
#
# A live BACKTICK in a diagnostic has no legitimate use in this repository — every existing one
# is escaped prose — so a blanket rule is correct and it holds at zero findings.
#
# `$( )` is DIFFERENT. `fail "... $(basename "$_s") ..."` is a correct, pervasive idiom that
# builds diagnostic text, and it is mechanically indistinguishable from a substitution that
# executes example syntax: both are a command substitution in an expandable string. Telling
# them apart needs intent, which needs a real parser and more. A repo-wide D9b ban flagged 70+
# files, essentially all of them correct.
#
# BOUNDED LIMITATION, recorded rather than papered over: D9b is NOT enforced repo-wide. It is
# proven on fixtures above, and enforced where example syntax actually lives — the fixture
# surface — so a future fixture or example-bearing diagnostic cannot reintroduce the shape.
_d9a_bad=""; _d9_n=0
for _s in "$PRODDIR"/*.sh "$ROOT"/scripts/*.sh "$ROOT"/scripts/lib/*.sh; do
	[ -e "$_s" ] || continue
	_d9_n=$((_d9_n + 1))
	d9a "$_s" || _d9a_bad="$_d9a_bad $(basename "$_s")"
done
[ "$_d9_n" -gt 0 ] || fail "D9a: zero files scanned"
[ -z "$_d9a_bad" ] \
	&& pass "D9a: no shipped diagnostic contains a live backtick ($_d9_n files scanned)" \
	|| fail "D9a: diagnostics with a live backtick in:$_d9a_bad"

_d9b_bad=""; _d9b_n=0
for _s in "$FIX"/*.sh; do
	[ -e "$_s" ] || continue
	_d9b_n=$((_d9b_n + 1))
	d9b "$_s" || _d9b_bad="$_d9b_bad $(basename "$_s")"
done
[ "$_d9b_n" -gt 0 ] || fail "D9b: zero fixtures scanned"
[ -z "$_d9b_bad" ] \
	&& pass "D9b: no committed fixture diagnostic interpolates a command ($_d9b_n fixtures scanned)" \
	|| fail "D9b: fixture diagnostics that would execute embedded syntax in:$_d9b_bad"

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d harness-truthfulness check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nharness-truthfulness: OK (D1-D9, 10 subchecks, each with a rejected fixture and an accepted control)\n'
exit 0
