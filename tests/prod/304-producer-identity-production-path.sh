#!/bin/sh
# Sentinel Shield production test — producer identity through the REAL builder (#310, #204).
#
# WHY THIS SUITE EXISTS, AND WHY IT DOES NOT INVOKE COLLECTORS DIRECTLY
#
# #310 was audited item by item and closed twice. Both audits, and tests/prod/117, invoked
# collectors as:
#
#     sh scripts/collectors/osv-scanner.sh --input report.json
#
# Production does not. `build-security-summary.sh` invokes them with the emitted CHANNEL:
#
#     sh scripts/collectors/osv-scanner.sh --input report.json --tool-name osv_scanner
#
# and `--tool-name` used to overwrite the identity handed to `ne_execution_verify`. So
# osv-scanner and dependency-check — the two producers whose channel renames hyphen to
# underscore — REJECTED THEIR OWN REAL EXECUTION RECORDS in production, while every test passed.
# grype and codeql were unaffected because their channel equals their producer key, which is
# why nothing surfaced it.
#
# The component was tested in the one invocation mode where the defect disappears. This suite
# therefore drives `build-security-summary.sh` itself. A direct collector call may SUPPLEMENT a
# case here; it can never satisfy one.
#
# THE CONTRACT UNDER TEST
#
#     producer_key  what actually ran        verified identity, stamped into producer.tool
#     channel       how it is presented      renamable, shareable, never provenance
#
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BUILD="$ROOT/scripts/build-security-summary.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
[ -f "$BUILD" ] || { fail "build-security-summary.sh is missing"; exit 1; }

TMP=$(mktemp -d)
# No `exit` in the trap: an aborted suite must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

sha() { { command -v sha256sum >/dev/null 2>&1 && sha256sum "$1" || shasum -a 256 "$1"; } 2>/dev/null | awk '{print $1}'; }
# NOT `jq -r '.x // ""'` — `//` substitutes for false as well as null (#320).
f() { printf '%s' "$1" | jq -r "[$2] | .[0] | if . == null then \"\" else tostring end" 2>/dev/null; }

# native_report <producer-key> — a well-formed native report for that producer.
native_report() {
	case "$1" in
	osv-scanner)      printf '%s' '{"results":[]}' ;;
	dependency-check) printf '%s' '{"dependencies":[]}' ;;
	grype)            printf '%s' '{"matches":[]}' ;;
	codeql)           printf '%s' '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"CodeQL","rules":[]}},"results":[]}]}' ;;
	php-coverage)     printf '%s' '{"tool":"coverage","status":"pass","line_percent":95,"branch_percent":90,"violations":0,"regression":false}' ;;
	*) return 1 ;;
	esac
}

# partial_report <producer-key> — well-formed, but describing less than the full target. The
# point of AC2: this parses perfectly and must still not read as a clean scan.
partial_report() {
	case "$1" in
	osv-scanner)      printf '%s' '{"results":[{"packages":[{"vulnerabilities":[{"id":"OSV-1"}]}]}]}' ;;
	dependency-check) printf '%s' '{"dependencies":[{"vulnerabilities":[{"severity":"HIGH"}]}]}' ;;
	grype)            printf '%s' '{"matches":[{"vulnerability":{"severity":"HIGH"}}]}' ;;
	codeql)           printf '%s' '{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"CodeQL","rules":[]}},"results":[{"level":"error"}]}]}' ;;
	*) return 1 ;;
	esac
}

# record <producer-in-record> <report-path> [status] [exit-code] [scope]
# Writes the sidecar the way a real invoker does: digest-bound, naming a producer.
record() {
	_r_named=$1; _r_path=$2; _r_status=${3:-success}; _r_rc=${4:-0}; _r_scope=${5:-no}
	_r_extra='{}'
	if [ "$_r_scope" = "scope" ]; then
		_r_sd=$(printf '%s\n' "src/A.php" "src/B.php" | sort \
			| { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } 2>/dev/null | awk '{print $1}')
		_r_extra=$(jq -n --arg sd "$_r_sd" '{scope:{paths:["src/A.php","src/B.php"], sha256:$sd}}')
	fi
	jq -n --arg t "$_r_named" --arg st "$_r_status" --arg ec "$_r_rc" \
		--arg o "$_r_path" --arg d "$(sha "$_r_path")" --argjson extra "$_r_extra" '
		{
			record: "sentinel-shield/execution-record@1",
			producer: { tool: $t },
			execution: { observed: true, status: $st, completed: ($st == "success"),
			             exit_code: ($ec|tonumber), signal: null,
			             timed_out: ($st == "timed-out"), duration_seconds: 1 },
			output: { path: $o, sha256: $d },
			target: { repository: null, commit: null }
		} + $extra' > "${_r_path%.json}.execution.json"
}

# build <producer-key> — run THE BUILDER over a raw dir containing exactly this report, and
# echo the resulting summary. This is the invocation the product uses.
build() {
	_b_key=$1
	_b_dir="$TMP/$_b_key-run"
	rm -rf "$_b_dir"; mkdir -p "$_b_dir/reports/raw"
	cp "$TMP/staging/$_b_key.json" "$_b_dir/reports/raw/$_b_key.json" 2>/dev/null || true
	[ -f "$TMP/staging/$_b_key.execution.json" ] \
		&& cp "$TMP/staging/$_b_key.execution.json" "$_b_dir/reports/raw/$_b_key.execution.json"
	( cd "$_b_dir" && sh "$BUILD" --raw-dir "$_b_dir/reports/raw" \
		--output "$_b_dir/reports/security-summary.json" ) >/dev/null 2>&1 || true
	cat "$_b_dir/reports/security-summary.json" 2>/dev/null || printf '{}'
}

# stage <producer-key> <report-json> — place a report in staging for build().
stage() {
	mkdir -p "$TMP/staging"
	rm -f "$TMP/staging/$1.json" "$TMP/staging/$1.execution.json"
	printf '%s' "$2" > "$TMP/staging/$1.json"
}

# channel_of <producer-key> — the emitted channel, read from TOOL_TABLE rather than assumed.
channel_of() { awk -F'|' -v k="$1" '$1==k{print $4; exit}' "$BUILD"; }

SECURITY="osv-scanner dependency-check grype codeql"

# ===========================================================================
# 1. THE IDENTITY MATRIX, through the builder
# ===========================================================================
printf '\n--- identity matrix (production path) ---\n'
for k in $SECURITY; do
	_ch=$(channel_of "$k")
	[ -n "$_ch" ] || { fail "$k: no TOOL_TABLE row — cannot test the production path"; continue; }

	# (a) ACCEPT: the record names the producer; the builder presents it as the channel.
	stage "$k" "$(native_report "$k")"
	record "$k" "$TMP/staging/$k.json" success 0
	out=$(build "$k")
	_st=$(f "$out" ".tools.$_ch.status")
	_prod=$(f "$out" ".tools.$_ch.evidence.producer.tool")
	_exec=$(f "$out" ".tools.$_ch.evidence.execution.status")
	if [ "$_st" = "pass" ] && [ "$_prod" = "$k" ] && [ "$_exec" = "success" ]; then
		pass "$k: record naming the PRODUCER is accepted through the builder (channel=$_ch)"
	else
		fail "$k: production path rejected its own record (status=$_st producer=$_prod exec=$_exec, channel=$_ch)"
	fi

	# (b) REJECT: a record naming the CHANNEL is not this producer's record. If the channel
	#     could stand in for the producer, two producers sharing a channel could impersonate
	#     each other.
	if [ "$_ch" != "$k" ]; then
		stage "$k" "$(native_report "$k")"
		record "$_ch" "$TMP/staging/$k.json" success 0
		_st=$(f "$(build "$k")" ".tools.$_ch.status")
		[ "$_st" = "execution-error" ] \
			&& pass "$k: a record naming the CHANNEL '$_ch' is refused" \
			|| fail "$k: a record naming the channel was accepted (status=$_st) — channel can impersonate producer"
	fi

	# (c) REJECT: a record from a DIFFERENT producer.
	stage "$k" "$(native_report "$k")"
	record "not-$k" "$TMP/staging/$k.json" success 0
	_st=$(f "$(build "$k")" ".tools.$_ch.status")
	[ "$_st" = "execution-error" ] \
		&& pass "$k: a record from a different producer is refused" \
		|| fail "$k: a foreign producer's record was accepted (status=$_st)"
done

# (d) A channel rename alone must NOT invalidate provenance; a producer change MUST.
#     Driven directly at the collector because it varies the ARGUMENTS the builder computes —
#     this is the supplement the production cases above make meaningful.
printf '\n--- identity is bound to the producer, not the presentation ---\n'
stage osv-scanner "$(native_report osv-scanner)"
record osv-scanner "$TMP/staging/osv-scanner.json" success 0
_a=$(sh "$ROOT/scripts/collectors/osv-scanner.sh" --input "$TMP/staging/osv-scanner.json" \
	--tool-name osv_scanner --producer-key osv-scanner 2>/dev/null | jq -r '.status')
_b=$(sh "$ROOT/scripts/collectors/osv-scanner.sh" --input "$TMP/staging/osv-scanner.json" \
	--tool-name a_completely_different_channel --producer-key osv-scanner 2>/dev/null | jq -r '.status')
[ "$_a" = "pass" ] && [ "$_b" = "pass" ] \
	&& pass "renaming ONLY the channel does not invalidate the execution record" \
	|| fail "a channel rename changed provenance validity ($_a vs $_b)"
_c=$(sh "$ROOT/scripts/collectors/osv-scanner.sh" --input "$TMP/staging/osv-scanner.json" \
	--tool-name osv_scanner --producer-key some-other-producer 2>/dev/null | jq -r '.status')
[ "$_c" = "execution-error" ] \
	&& pass "changing the PRODUCER key does invalidate the execution record" \
	|| fail "a producer-key change left the record valid (status=$_c) — identity is not bound"

# (e) The real many-to-one channel: two producers, one channel, still distinguishable.
printf '\n--- a shared channel keeps producers distinguishable ---\n'
_shared=$(awk -F'|' 'NF>=4 && $1 !~ /^#/ && $4 != "" {print $4}' "$BUILD" | sort | uniq -d | grep -E '^[a-z0-9_]+$' | head -1 || true)
if [ -n "$_shared" ]; then
	_keys=$(awk -F'|' -v c="$_shared" '$4==c{printf "%s ", $1}' "$BUILD")
	pass "channel '$_shared' is emitted by distinct producers ($_keys) — provenance must not use it"

	# Reading TOOL_TABLE proves the CONFIGURATION allows a shared channel. It does not prove the
	# builder keeps those producers distinguishable in the EVIDENCE, which is the actual claim.
	# So run both producers together through the builder and inspect what it emits.
	_sd="$TMP/shared/reports/raw"; rm -rf "$TMP/shared"; mkdir -p "$_sd"
	printf '%s' '{"totals":{"errors":0}}' > "$_sd/php-style.json"
	printf '%s' '[]' > "$_sd/php-cs-fixer.json"
	( cd "$TMP/shared" && sh "$BUILD" --raw-dir "$_sd" --output "$TMP/shared/s.json" ) >/dev/null 2>&1 || true
	_got=$(jq -r '[.tools.php_style.producers[]?.producer] | sort | join(",")' "$TMP/shared/s.json" 2>/dev/null || printf '')
	if [ "$_got" = "php-cs-fixer,php-style" ]; then
		pass "builder keeps both producers distinguishable under one channel (php_style -> $_got)"
	else
		fail "php_style did not retain both producer identities through the builder (got '${_got:-absent}')"
	fi
	# One entry per producer, each carrying its own report digest: the collapse this prevents is
	# a later report silently overwriting an earlier one while its counts stay in the aggregate.
	_ndig=$(jq -r '[.tools.php_style.producers[]?.sha256] | unique | length' "$TMP/shared/s.json" 2>/dev/null || printf 0)
	[ "$_ndig" -ge 2 ] \
		&& pass "each producer under the shared channel carries its own report digest ($_ndig distinct)" \
		|| fail "the shared channel collapsed its producers to $_ndig distinct digest(s)"
else
	fail "no shared channel found in TOOL_TABLE — the many-to-one premise is unsupported"
fi

# (f) STRUCTURAL: no collector may let a channel argument write the producer identity.
#
# The dynamic matrix above CANNOT see this. The builder passes `--tool-name "$emit"` before
# `--producer-key "$key"`, so a collector that did `--tool-name) TOOL=...; PRODUCER="$TOOL"`
# would have PRODUCER restored by the later flag and every case above would still pass. That
# mutation was run: the suite stayed green until this assertion existed.
#
# Argument ORDER is not a security property. The guarantee has to be that the channel branch
# never touches the producer at all.
printf '\n--- structural: a channel argument never writes the producer identity ---\n'
_bad=""
for _c in "$ROOT"/scripts/collectors/*.sh; do
	# The --tool-name case body, up to its terminating `;;`.
	_body=$(awk '/--tool-name\)/{f=1} f{print; if (/;;/) exit}' "$_c")
	printf '%s' "$_body" | grep -q 'PRODUCER=' && _bad="$_bad $(basename "$_c")"
done
if [ -n "$_bad" ]; then
	fail "collector(s) assign PRODUCER inside the --tool-name branch:$_bad — the channel can overwrite provenance identity"
else
	pass "no collector assigns PRODUCER from the --tool-name branch"
fi
# CONTROL: the detector must actually match a PRODUCER assignment in that position, or the
# assertion above is satisfied by a grep that can never fire.
_probe="$TMP/probe.sh"
printf '%s\n' 'case "$1" in' '\t--tool-name) TOOL="$2"; PRODUCER="$TOOL"; shift 2 ;;' '\tesac' > "$_probe"
_pb=$(awk '/--tool-name\)/{f=1} f{print; if (/;;/) exit}' "$_probe")
printf '%s' "$_pb" | grep -q 'PRODUCER=' \
	&& pass "CONTROL: the detector does fire on a channel branch that writes PRODUCER" \
	|| fail "CONTROL: the detector cannot see a PRODUCER assignment — the check above proves nothing"

# ===========================================================================
# 2. #310 ACCEPTANCE CRITERIA, every one through the builder
# ===========================================================================
printf '\n--- #310 AC1: a non-zero exit cannot produce completed:true ---\n'
for k in $SECURITY; do
	_ch=$(channel_of "$k")
	stage "$k" "$(native_report "$k")"
	record "$k" "$TMP/staging/$k.json" failed 3
	out=$(build "$k")
	_present=$(f "$out" ".tools.$_ch.status")
	_done=$(f "$out" ".tools.$_ch.evidence.execution.completed")
	# The tool must BE in the summary. `completed != "true"` is also satisfied by a channel that
	# is absent entirely, which is how an early draft of this suite reported four green AC1
	# rejections while the builder was emitting nothing at all.
	if [ -z "$_present" ]; then
		fail "AC1 $k: channel '$_ch' is absent from the summary — this assertion would pass vacuously"
	elif [ "$_done" != "true" ]; then
		pass "AC1 $k: exit 3 -> completed=${_done:-null} via the builder (status=$_present)"
	else
		fail "AC1 $k: exit 3 recorded as completed:true on the production path"
	fi
done
for k in $SECURITY; do
	_ch=$(channel_of "$k")
	stage "$k" "$(native_report "$k")"
	record "$k" "$TMP/staging/$k.json" success 0
	_done=$(f "$(build "$k")" ".tools.$_ch.evidence.execution.completed")
	[ "$_done" = "true" ] \
		&& pass "AC1 CONTROL $k: exit 0 -> completed:true" \
		|| fail "AC1 CONTROL $k: exit 0 did not complete (=$_done) — the rejections above prove nothing"
done

printf '\n--- #310 AC2: non-zero with a WELL-FORMED PARTIAL report is not a clean scan ---\n'
for k in $SECURITY; do
	_ch=$(channel_of "$k")
	stage "$k" "$(partial_report "$k")"
	record "$k" "$TMP/staging/$k.json" failed 3
	_st=$(f "$(build "$k")" ".tools.$_ch.status")
	case "$_st" in
	pass | fail | findings) fail "AC2 $k: a partial report after exit 3 produced a verdict ($_st)" ;;
	# An EMPTY status also matches `*`. A missing TOOL_TABLE entry or absent builder output
	# would therefore satisfy this criterion by producing nothing at all — the same vacuity
	# guarded in AC1, which this case originally lacked.
	"") fail "AC2 $k: channel '$_ch' is absent from the summary — this assertion would pass vacuously" ;;
	*) pass "AC2 $k: partial report + exit 3 -> $_st" ;;
	esac
done

printf '\n--- #310 AC3: unobserved execution is recorded explicitly ---\n'
for k in $SECURITY; do
	_ch=$(channel_of "$k")
	stage "$k" "$(native_report "$k")"   # no record written
	out=$(build "$k")
	_obs=$(f "$out" ".tools.$_ch.evidence.execution.observed")
	_done=$(f "$out" ".tools.$_ch.evidence.execution.completed")
	[ "$_obs" = "false" ] && [ -z "$_done" ] \
		&& pass "AC3 $k: no sidecar -> observed=false, completed=null" \
		|| fail "AC3 $k: no sidecar -> observed='$_obs' completed='$_done'"
done

printf '\n--- #310 AC5: the five enumerated states, each through the builder ---\n'
_k=osv-scanner; _ch=$(channel_of "$_k")
stage "$_k" "$(native_report "$_k")"; record "$_k" "$TMP/staging/$_k.json" success 0
[ "$(f "$(build "$_k")" ".tools.$_ch.status")" = "pass" ] \
	&& pass "AC5.1 exit 0 + full report -> pass" || fail "AC5.1 exit 0 + full report did not pass"
stage "$_k" "$(partial_report "$_k")"; record "$_k" "$TMP/staging/$_k.json" failed 3
[ "$(f "$(build "$_k")" ".tools.$_ch.status")" = "execution-error" ] \
	&& pass "AC5.2 non-zero + partial report -> execution-error" || fail "AC5.2 not refused"
stage "$_k" "$(native_report "$_k")"; record "$_k" "$TMP/staging/$_k.json" failed 3
rm -f "$TMP/staging/$_k.json"
_st=$(f "$(build "$_k")" ".tools.$_ch.status")
case "$_st" in
unavailable | execution-error | "") pass "AC5.3 non-zero + NO report -> ${_st:-absent}, never a verdict" ;;
*) fail "AC5.3 a scan that wrote nothing produced status=$_st" ;;
esac
stage "$_k" "$(native_report "$_k")"
_obs=$(f "$(build "$_k")" ".tools.$_ch.evidence.execution.observed")
[ "$_obs" = "false" ] && pass "AC5.4 report with no provenance sidecar -> observed=false" \
	|| fail "AC5.4 missing sidecar reported observed='$_obs'"

printf '\n--- #310 AC4/AC5.5: enforcing modes refuse unobserved completion ---\n'
# The layer that materially transforms this contract is the ENFORCER, not the builder — the
# builder does not evaluate observed completion. So AC4 is exercised through enforce-gates over
# a COMPLETE, attested enforcement input.
#
# A hand-written summary was tried first and was the wrong call: strict and regulated
# legitimately refuse an evidence-free summary, and regulated requires an independent
# attestation, so BOTH the rejection and the control returned exit 2 and proved nothing. That
# is the same trap tests/prod/117 records. The fixture below is the shipped example summary
# with exactly ONE field varied — `execution.observed` — matching the construction pinned by
# tests/prod/288 and 302.
ENF="$ROOT/scripts/enforce-gates.sh"
RES="$ROOT/scripts/resolve-gates.sh"
EXAMPLE="$ROOT/templates/security-summary.example.json"
if [ ! -f "$ENF" ] || [ ! -f "$EXAMPLE" ]; then
	fail "AC4: enforce-gates.sh or the example summary is missing; the dynamic check cannot run"
else
	ac4_case() { # ac4_case <label> <mode> <observed-json> -> echoes the prepared directory
		_d="$TMP/ac4-$1"; mkdir -p "$_d"
		sh "$RES" --mode "$2" --output-dir "$_d" --format all >/dev/null 2>&1
		jq --argjson obs "$3" '''.tools = {
				"gitleaks": {"status":"pass","evidence":{"execution":{"observed":$obs}}},
				"tests":    {"status":"pass"}
			}
			| .source.trust = "github-actions-attested"
			| .attestation = {verified:true, issuer:"https://token.actions.githubusercontent.com",
				repository:(.source.repository // "example-org/example-repo"),
				commit:(.source.commit // "0123456789abcdef0123456789abcdef01234567"),
				workflow:"sentinel-shield", workflow_sha:"1111111111111111111111111111111111111111",
				run_id:"1", run_attempt:"1",
				artifact_digest:"sha256:0000000000000000000000000000000000000000000000000000000000000000"}''' \
			"$EXAMPLE" > "$_d/s.json"
		printf '%s' "$_d"
	}
	ac4_enf() { # ac4_enf <dir> -> echoes the exit code
		_d="$1"; _c=0
		jq -n --arg dg "sha256:$(sha "$_d/s.json")" \
			--arg r "$(jq -r '''.source.repository // ""''' "$_d/s.json")" \
			--arg c "$(jq -r '''.source.commit // ""''' "$_d/s.json")" \
			'''{attestation:"sentinel-shield/source-attestation@1", verified:true, verifier:"tests/prod/304",
			  artifact:"s.json", artifact_digest:$dg, repository:$r, commit:$c,
			  workflow:"sentinel-shield", run_id:"1"}''' > "$_d/att.json"
		sh "$ENF" --gates-env "$_d/sentinel-shield-gates.env" --summary "$_d/s.json" \
			--attestation "$_d/att.json" --output-dir "$_d" --format json >"$_d/out.log" 2>&1 || _c=$?
		printf '%s' "$_c"
	}
	for _m in strict regulated; do
		_rc=$(SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION=1 ac4_enf "$(ac4_case "obs-$_m" "$_m" true)")
		[ "$_rc" = "0" ] \
			&& pass "AC4 CONTROL $_m: observed:true is ACCEPTED with the requirement on" \
			|| fail "AC4 CONTROL $_m: observed evidence rejected (exit $_rc) — any refusal below is unattributable"
		_d=$(ac4_case "unobs-$_m" "$_m" false)
		_rc=$(SENTINEL_SHIELD_REQUIRE_OBSERVED_EXECUTION=1 ac4_enf "$_d")
		if [ "$_rc" = "0" ]; then
			fail "AC4 $_m: unobserved completion was accepted with the requirement on"
		elif grep -q 'UNOBSERVED execution' "$_d/out.log"; then
			pass "AC4 $_m: unobserved completion refused, and the refusal names THIS gate (exit $_rc)"
		else
			fail "AC4 $_m: refused (exit $_rc) but for another reason: $(head -1 "$_d/out.log")"
		fi
		_rc=$(ac4_enf "$(ac4_case "optin-$_m" "$_m" false)")
		[ "$_rc" = "0" ] \
			&& pass "AC4 CONTROL $_m: WITHOUT the requirement, unobserved is accepted (opt-in preserved)" \
			|| fail "AC4 CONTROL $_m: unobserved rejected without the flag (exit $_rc) — not opt-in"
	done
fi

printf '\n--- #310 AC6: all four migrated collectors, consistently, on the production path ---\n'
_shape=""
for k in $SECURITY; do
	_ch=$(channel_of "$k")
	stage "$k" "$(native_report "$k")"
	record "$k" "$TMP/staging/$k.json" timed-out 124
	out=$(build "$k")
	_cs=$(f "$out" ".tools.$_ch.status")
	_s="$_cs/$(f "$out" ".tools.$_ch.evidence.execution.completed")"
	printf '    %-18s timed-out -> %s\n' "$k" "$_s"
	# Four ABSENT channels all produce the identical shape "/", so consistency would hold
	# vacuously across collectors that emitted nothing. Require presence first.
	if [ -z "$_cs" ]; then
		fail "AC6 $k: channel '$_ch' is absent from the summary — consistency cannot be judged"
		continue
	fi
	[ -z "$_shape" ] && _shape="$_s"
	[ "$_s" = "$_shape" ] || fail "AC6 $k answers a timed-out scan as '$_s'; the first collector answered '$_shape'"
done
[ -n "$_shape" ] \
	&& pass "AC6: all four migrated collectors answer identically through the builder ($_shape)" \
	|| fail "AC6: no collector produced a status — the consistency claim is untested"

printf '\n--- a quality producer through the builder ---\n'
_qk=php-coverage; _qch=$(channel_of "$_qk")
if [ -n "$_qch" ]; then
	stage "$_qk" "$(native_report "$_qk")"
	record "$_qk" "$TMP/staging/$_qk.json" success 0 scope
	out=$(build "$_qk")
	_st=$(f "$out" ".tools.$_qch.status")
	_prod=$(f "$out" ".tools.$_qch.evidence.producer.tool")
	[ "$_st" = "pass" ] && [ "$_prod" = "$_qk" ] \
		&& pass "quality: $_qk accepted through the builder as channel $_qch, producer $_prod" \
		|| fail "quality: $_qk on the production path gave status=$_st producer=$_prod"
	stage "$_qk" "$(native_report "$_qk")"
	record "$_qch" "$TMP/staging/$_qk.json" success 0 scope
	_st=$(f "$(build "$_qk")" ".tools.$_qch.status")
	[ "$_st" != "pass" ] \
		&& pass "quality: a record naming the channel '$_qch' is refused ($_st)" \
		|| fail "quality: the channel impersonated the producer key"
else
	fail "php-coverage has no TOOL_TABLE row — the quality production path cannot be tested"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d producer-identity production-path check(s) failed\n' "$FAILS" >&2
	exit 1
fi
printf '\nproducer-identity-production-path: OK (identity matrix + #310 AC1-AC6 through build-security-summary.sh)\n'
exit 0
