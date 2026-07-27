#!/bin/sh
# Sentinel Shield prod test — the enforcement INPUT contract (issues #217, #218, #220, #221, #222).
#
# enforce-gates.sh decides the release verdict. Everything it reads is therefore policy input,
# and every one of these defects let a weaker-than-configured policy reach a `pass`:
#
#   #217  a gates env with DUPLICATE keys was ambiguous (first match won, the tail was
#         ignored) and UNKNOWN keys were accepted, hiding typos and resolver drift.
#   #218  SENTINEL_SHIELD_MODE was defaulted to "unknown" and never validated, so an
#         undefined mode skipped the strict/regulated evidence preconditions.
#   #220  `.tools: {}` bought an exemption from those preconditions — a hand-built summary
#         with no producers at all could certify strict/regulated.
#   #221  complete structural validation ran only when the caller passed --strict-summary,
#         so a workflow that omitted the flag enforced production modes with WEAKER
#         validation than an optional CLI option provided.
#   #222  eval_unsafe_docker still coerced malformed counts to 0 and recorded `pass`.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
ENFORCE="$ROOT/scripts/enforce-gates.sh"
RESOLVE="$ROOT/scripts/resolve-gates.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

# mkcase <name> <mode> — a VALID enforcement input pair, ready to be broken.
mkcase() {
	_d="$WORK/$1"; mkdir -p "$_d"
	sh "$RESOLVE" --mode "$2" --output-dir "$_d" --format all >/dev/null 2>&1
	# Evidence-bearing: strict/regulated legitimately refuse a summary with no producers.
	jq '.tools = {"gitleaks":{"status":"pass"},"tests":{"status":"pass"}}' \
		"$ROOT/templates/security-summary.example.json" > "$_d/s.json"
	printf '%s' "$_d"
}
# enf <dir> [extra args] — run the enforcer, echo its exit code.
enf() {
	_d="$1"; shift
	_c=0
	sh "$ENFORCE" --gates-env "$_d/sentinel-shield-gates.env" --summary "$_d/s.json" \
		--output-dir "$_d" --format json "$@" >"$_d/out.log" 2>&1 || _c=$?
	printf '%s' "$_c"
}

# ---------------------------------------------------------------------------
# 0. Control: a valid pair enforces normally in every mode.
# ---------------------------------------------------------------------------
for _m in report-only baseline strict regulated; do
	D=$(mkcase "ok-$_m" "$_m")
	check "control: a valid input pair enforces in $_m" "$(enf "$D")" 0
done

# ---------------------------------------------------------------------------
# 1. #217 — duplicate and unknown gates-env keys.
# ---------------------------------------------------------------------------
D=$(mkcase dup baseline)
printf 'SENTINEL_SHIELD_FAIL_ON_SECRETS=false\n' >> "$D/sentinel-shield-gates.env"
check "a DUPLICATE gate flag is rejected (ambiguous policy)" "$(enf "$D")" 2
grep -q 'duplicate key' "$D/out.log" && pass "  the duplicate key is named" || fail "  duplicate key not reported"

D=$(mkcase dup-first baseline)
# The tail value is the one a human reading the file last sees; the parser used to take the
# head. Either way it is ambiguous — assert BOTH orderings are refused, not resolved.
{ printf 'SENTINEL_SHIELD_FAIL_ON_SECRETS=false\n'; cat "$D/sentinel-shield-gates.env"; } > "$D/tmp" && mv "$D/tmp" "$D/sentinel-shield-gates.env"
check "the reverse duplicate ordering is rejected too" "$(enf "$D")" 2

D=$(mkcase dupmode baseline)
printf 'SENTINEL_SHIELD_MODE=regulated\n' >> "$D/sentinel-shield-gates.env"
check "a duplicate MODE line is rejected" "$(enf "$D")" 2

D=$(mkcase unknown baseline)
printf 'SENTINEL_SHIELD_FAIL_ON_SECRTES=true\n' >> "$D/sentinel-shield-gates.env"
check "an UNKNOWN (typo) key is rejected, not ignored" "$(enf "$D")" 2
grep -qE 'unknown key|the resolver does not know' "$D/out.log" \
	&& pass "  the unknown key is named" || fail "  unknown key not reported"

D=$(mkcase strayns baseline)
printf 'SOMETHING_ELSE=true\n' >> "$D/sentinel-shield-gates.env"
check "a key outside the SENTINEL_SHIELD_ namespace is rejected" "$(enf "$D")" 2

# Env / JSON reconciliation: a tampered env next to the resolver's JSON is contradictory.
D=$(mkcase tamper baseline)
sed 's/^SENTINEL_SHIELD_FAIL_ON_SECRETS=true/SENTINEL_SHIELD_FAIL_ON_SECRETS=false/' \
	"$D/sentinel-shield-gates.env" > "$D/tmp" && mv "$D/tmp" "$D/sentinel-shield-gates.env"
check "an env flag that contradicts the resolver JSON is rejected" "$(enf "$D")" 2
grep -q 'disagree' "$D/out.log" && pass "  the disagreement is named" || fail "  disagreement not reported"

D=$(mkcase tampermode baseline)
sed 's/^SENTINEL_SHIELD_MODE=baseline/SENTINEL_SHIELD_MODE=report-only/' \
	"$D/sentinel-shield-gates.env" > "$D/tmp" && mv "$D/tmp" "$D/sentinel-shield-gates.env"
check "an env MODE that contradicts the resolver JSON is rejected" "$(enf "$D")" 2

# ---------------------------------------------------------------------------
# 2. #218 — the mode is a validated enum.
# ---------------------------------------------------------------------------
for _bad in unknown Strict STRICT baseline-ish '' regulated-plus; do
	D=$(mkcase "mode-$(printf '%s' "${_bad:-empty}" | tr -c 'A-Za-z0-9' '_')" baseline)
	rm -f "$D/sentinel-shield-gates.json"   # isolate the enum check from reconciliation
	sed "s/^SENTINEL_SHIELD_MODE=baseline/SENTINEL_SHIELD_MODE=$_bad/" \
		"$D/sentinel-shield-gates.env" > "$D/tmp" && mv "$D/tmp" "$D/sentinel-shield-gates.env"
	check "mode '${_bad:-<empty>}' is rejected" "$(enf "$D")" 2
done

D=$(mkcase modeabsent baseline)
rm -f "$D/sentinel-shield-gates.json"
grep -v '^SENTINEL_SHIELD_MODE=' "$D/sentinel-shield-gates.env" > "$D/tmp" && mv "$D/tmp" "$D/sentinel-shield-gates.env"
check "an ABSENT mode is rejected (never inferred)" "$(enf "$D")" 2

# ---------------------------------------------------------------------------
# 3. #220 — omission is not an external-evidence contract.
# ---------------------------------------------------------------------------
for _m in strict regulated; do
	D=$(mkcase "notools-$_m" "$_m")
	jq '.tools = {}' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	check "an EMPTY tools object cannot certify $_m" "$(enf "$D")" 2
	grep -q 'declares no producers' "$D/out.log" && pass "  $_m: the absence of producers is named" || fail "  $_m: producer absence not reported"

	D=$(mkcase "notoolskey-$_m" "$_m")
	jq 'del(.tools)' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	check "an ABSENT tools key cannot certify $_m" "$(enf "$D")" 2

	D=$(mkcase "unavail-$_m" "$_m")
	jq '.tools = {"gitleaks":{"status":"unavailable"},"tests":{"status":"unavailable"}}' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	check "an all-unavailable tools object still cannot certify $_m" "$(enf "$D")" 2

	D=$(mkcase "someevidence-$_m" "$_m")
	jq '.tools = {"gitleaks":{"status":"pass"},"tests":{"status":"unavailable"}}' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	check "a summary with real evidence still enforces in $_m" "$(enf "$D")" 0
done
# report-only / baseline are visibility modes and are deliberately unchanged.
for _m in report-only baseline; do
	D=$(mkcase "notools-$_m" "$_m")
	jq '.tools = {}' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	check "an empty tools object still enforces in $_m (visibility mode)" "$(enf "$D")" 0
done

# ---------------------------------------------------------------------------
# 4. #221 — complete validation is a property of the MODE, not of a CLI flag.
# ---------------------------------------------------------------------------
for _m in baseline strict regulated; do
	D=$(mkcase "novalidflag-$_m" "$_m")
	jq 'del(.source)' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	check "$_m rejects a summary with no source object WITHOUT --strict-summary" "$(enf "$D")" 2

	D=$(mkcase "noevidence-$_m" "$_m")
	jq 'del(.evidence)' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	check "$_m rejects a summary with no evidence object WITHOUT the flag" "$(enf "$D")" 2

	D=$(mkcase "badversion-$_m" "$_m")
	jq '.version = "0.9"' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	check "$_m rejects an unsupported summary version WITHOUT the flag" "$(enf "$D")" 2

	D=$(mkcase "badstatus-$_m" "$_m")
	jq '.tools.gitleaks.status = "totally-fine"' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	check "$_m rejects an unknown tool status WITHOUT the flag" "$(enf "$D")" 2

	# Passing the legacy flag must produce the SAME verdict — it can no longer strengthen or
	# weaken a production mode.
	D=$(mkcase "flagparity-$_m" "$_m")
	jq 'del(.source)' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	check "$_m: --strict-summary changes nothing (parity)" "$(enf "$D" --strict-summary)" 2
done
# report-only keeps the flag as an opt-in.
D=$(mkcase flag-ro report-only)
jq 'del(.source)' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
check "report-only tolerates a missing source object by default" "$(enf "$D")" 0
check "report-only + --strict-summary opts into the full validation" "$(enf "$D" --strict-summary)" 2

# ---------------------------------------------------------------------------
# 5. #222 — unsafe_docker uses the same strict count parser as every other gate.
# ---------------------------------------------------------------------------
for _v in '-3' '3.5' '"many"' 'true' 'null'; do
	D=$(mkcase "udcount-$(printf '%s' "$_v" | tr -c 'A-Za-z0-9' '_')" baseline)
	jq ".summary.unsafe_docker = $_v" "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
	_rc=$(enf "$D")
	case "$_v" in
		'null')
			# An absent/null count with the gate enabled is the separate evidence-contract
			# question (#219); what must never happen is a silent clean PASS on a malformed
			# value, which the four cases above cover.
			[ "$_rc" = 0 ] || [ "$_rc" = 2 ] && pass "unsafe_docker null count: handled ($_rc)" || fail "unsafe_docker null count produced $_rc" ;;
		*)
			check "a malformed unsafe_docker count ($_v) fails closed" "$_rc" 2 ;;
	esac
done
D=$(mkcase udvalid baseline)
jq '.summary.unsafe_docker = 2' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
check "a real unsafe_docker count still fails the gate (not exit 2)" "$(enf "$D")" 1

# The generic count gates keep their existing strict behaviour — one parser, one invariant.
D=$(mkcase generic baseline)
jq '.summary.critical_vulnerabilities = -1' "$D/s.json" > "$D/tmp" && mv "$D/tmp" "$D/s.json"
check "a malformed generic count still fails closed" "$(enf "$D")" 2

# --- second-reviewer round: the key check must not be optional ----------------
# The lexical scan accepts ANY SENTINEL_SHIELD_FAIL_ON_* / _PROJECT_* name, so the resolver
# JSON is what makes the key set authoritative. Treating it as optional meant deleting or
# corrupting it removed the check entirely.
K="$WORK/keyset"; rm -rf "$K"; mkdir -p "$K"
sh "$RESOLVE" --mode baseline --output-dir "$K" --format all >/dev/null 2>&1
jq '.tools = {"tests":{"status":"pass"}}' "$ROOT/templates/security-summary.example.json" > "$K/s.json"
krun() { _c=0; sh "$ENFORCE" --gates-env "$K/sentinel-shield-gates.env" --summary "$K/s.json" \
	--output-dir "$K" --format json >"$K/log" 2>&1 || _c=$?; printf '%s' "$_c"; }
check "control: env + resolver JSON enforce cleanly" "$(krun)" 0
printf 'not json at all\n' > "$K/sentinel-shield-gates.json"
check "a malformed resolver JSON is refused, never ignored" "$(krun)" 2
grep -q 'never a reason to fall back' "$K/log" && pass "  and says why it cannot be ignored" || fail "  without explaining why"
sh "$RESOLVE" --mode baseline --output-dir "$K" --format all >/dev/null 2>&1
check "  regenerating it restores the clean run" "$(krun)" 0
printf 'SENTINEL_SHIELD_FAIL_ON_SECRETS_TYPO=true\n' >> "$K/sentinel-shield-gates.env"
check "an unknown FAIL_ON_* key is refused (JSON present)" "$(krun)" 2
sh "$RESOLVE" --mode baseline --output-dir "$K" --format all >/dev/null 2>&1
printf 'SENTINEL_SHIELD_PROJECT_WHATEVER=x\n' >> "$K/sentinel-shield-gates.env"
check "an unknown PROJECT_* metadata key is refused" "$(krun)" 2

# The env-only flow (--format env) stays supported, but its key set is validated against the
# engine's own gate registry instead of a wildcard prefix — otherwise deleting the JSON
# removed the check entirely.
sh "$RESOLVE" --mode baseline --output-dir "$K" --format env >/dev/null 2>&1
check "  --format env leaves no stale sibling artifact" \
	"$([ -e "$K/sentinel-shield-gates.json" ] && echo stale || echo clean)" "clean"
check "an env-only resolution still enforces" "$(krun)" 0
printf 'SENTINEL_SHIELD_FAIL_ON_SECRETS_TYPO=true\n' >> "$K/sentinel-shield-gates.env"
check "an unknown FAIL_ON_* key is refused with NO JSON present" "$(krun)" 2
grep -q 'gate registry' "$K/log" && pass "  naming the registry it was checked against" || fail "  without naming the registry"

printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '288-enforcement-input-contract: ALL CHECKS PASSED\n'
	exit 0
fi
printf '288-enforcement-input-contract: FAILURES PRESENT\n'
exit 1
