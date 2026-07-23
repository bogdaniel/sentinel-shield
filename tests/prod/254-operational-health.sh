#!/bin/sh
# tests/prod/254-operational-health.sh — OPERATIONAL OBSERVABILITY + HEALTH enforcement.
#
# Proves scripts/health.sh reports a correct rolled-up health verdict with STABLE reason codes for
# each production failure mode, that OFFLINE health checks never touch the network, that the ONLY
# network check is bounded (Task 1) with a DISTINCT timeout result, that the transaction journal
# verifier (Task 2) drives journal integrity, and that the redaction library (Task 4) keeps secrets
# and repo-local paths out of the machine-readable report. It also proves the normalized
# operational-event model (scripts/lib/operational-events.sh) emits a correlated JSONL stream across
# a failed install AND its recovery, conforming to schemas/operational-event.schema.json.
#
# Required cases (1)-(12) are labelled inline. Self-contained, NETWORK-FREE (the connectivity probe
# is exercised via an injected local command). jq is required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
HEALTH="$ROOT/scripts/health.sh"
LIB_COMMON="$ROOT/scripts/lib/sentinel-shield-common.sh"
LIB_RD="$ROOT/scripts/lib/redaction.sh"
LIB_IM="$ROOT/scripts/lib/installation-metadata.sh"
LIB_OE="$ROOT/scripts/lib/operational-events.sh"
EVENT_SCHEMA="$ROOT/schemas/operational-event.schema.json"
HEALTH_SCHEMA="$ROOT/schemas/health-report.schema.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n'; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t sshealtht)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

# Source libraries into THIS shell for fixture construction + in-process event assertions.
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$LIB_COMMON"
# shellcheck source=scripts/lib/redaction.sh
. "$LIB_RD"
# shellcheck source=scripts/lib/installation-metadata.sh
. "$LIB_IM"
# shellcheck source=scripts/lib/operational-events.sh
. "$LIB_OE"

# fresh_fixture — mkdir a UNIQUE adopted target with a VALID installation.json; echo its path.
# Uses mktemp -d (not a counter): a counter incremented inside this command-substitution subshell
# would be lost in the parent, silently reusing one directory across fixtures.
fresh_fixture() {
	_f=$(mktemp -d "$WORK/fx.XXXXXX")
	mkdir -p "$_f/.sentinel-shield"
	im_write "$_f" "2.0.0" "baseline" "1" "config-only" "" "${1:-}" "" "" "" >/dev/null 2>&1
	printf '%s' "$_f"
}

# run_health [VAR=VALUE...] [-- ] [flags...] — run the CLI against $FX; sets HRC (exit), report at
# $WORK/report.json. Any leading NAME=VALUE tokens are applied ONLY inside a subshell, so an env
# override for one case can never leak into a later case (a prefix assignment on a shell FUNCTION
# would otherwise persist in the calling shell).
run_health() {
	HRC=0
	(
		while :; do
			case "${1:-}" in
				*=*) export "$1"; shift ;;
				*) break ;;
			esac
		done
		exec sh "$HEALTH" --target "$FX" "$@"
	) >"$WORK/report.json" 2>/dev/null || HRC=$?
}
hstatus() { jq -r '.status' "$WORK/report.json"; }
hreasons() { jq -c '.reason_codes' "$WORK/report.json"; }
# has_reason <code> — true if the report's reason_codes contains <code>.
has_reason() { jq -e --arg r "$1" '.reason_codes | index($r) != null' "$WORK/report.json" >/dev/null 2>&1; }
# check_reason <name> — print the reason_code recorded for check <name>.
check_reason() { jq -r --arg n "$1" '.checks[] | select(.name==$n) | .reason_code' "$WORK/report.json"; }

# ============================================================================
# Schemas present + jq-valid.
# ============================================================================
jq -e . "$EVENT_SCHEMA" >/dev/null 2>&1 && pass "operational-event schema is jq-valid" || fail "operational-event schema jq-valid"
jq -e . "$HEALTH_SCHEMA" >/dev/null 2>&1 && pass "health-report schema is jq-valid" || fail "health-report schema jq-valid"

# Event-model vocabulary matches the schema enums EXACTLY (no drift; structural, jq-based).
_drift_ok=1
for pair in \
	"command:oe_commands" "phase:oe_phases" "event_type:oe_event_types" \
	"severity:oe_severities" "status:oe_statuses" "retryability:oe_retryabilities"; do
	_field="${pair%%:*}"; _fn="${pair#*:}"
	_code=$($_fn | LC_ALL=C sort)
	_schema=$(jq -r --arg f "$_field" '.properties[$f].enum[]' "$EVENT_SCHEMA" | LC_ALL=C sort)
	[ "$_code" = "$_schema" ] || { _drift_ok=0; printf 'drift in %s\n' "$_field" >&2; }
done
[ "$_drift_ok" = 1 ] \
	&& pass "operational-event enums match the code vocabulary exactly (no drift)" \
	|| fail "operational-event enum/code drift"

# ============================================================================
# (1) HEALTHY CLEAN INSTALL — every check healthy or skipped; exit 0.
# ============================================================================
FX=$(fresh_fixture)
run_health
if [ "$HRC" -eq 0 ] && [ "$(hstatus)" = "healthy" ] && [ "$(hreasons)" = "[]" ]; then
	pass "(1) a clean install reports healthy (exit 0, no actionable reasons)"
else
	fail "(1) clean install healthy (exit=$HRC status=$(hstatus) reasons=$(hreasons))"
fi
# The report conforms structurally to the CLOSED health-report schema.
if jq -e '
	(.schema == "health-report") and (.schema_version == "1") and
	(.target | test("^target:")) and
	(.mode | .offline == true and .network_checked == false) and
	(.status == "healthy") and
	(.checks | type == "array" and (length == 14)) and
	(.summary | has("healthy") and has("degraded") and has("unhealthy") and has("unknown") and has("skipped"))
' "$WORK/report.json" >/dev/null 2>&1; then
	pass "(1) health report conforms to the health-report schema"
else
	fail "(1) health report conforms to schema"
fi
# The report carries NO raw target path (identity is a non-reversible hash).
if grep -Fq "$FX" "$WORK/report.json"; then fail "(1) report leaked the raw target path"; else pass "(1) report carries no raw target path"; fi

# Every reason_code + check name the report emits is within the schema's closed enums (drift guard).
_reasons=$(jq -r '.checks[].reason_code' "$WORK/report.json")
_bad=0
for r in $_reasons; do
	jq -e --arg r "$r" '.properties.checks.items.properties.reason_code.enum | index($r) != null' "$HEALTH_SCHEMA" >/dev/null 2>&1 || _bad=1
done
[ "$_bad" = 0 ] && pass "(1) every emitted reason_code is in the schema enum (no drift)" || fail "(1) reason_code/schema drift"

# ============================================================================
# (2) STALE TRANSACTION — an interrupted lock owned by a foreign host is stale => unhealthy.
# ============================================================================
FX=$(fresh_fixture)
cat > "$FX/.sentinel-shield/operation-lock.json" <<J
{"schema_version":"1","operation":"install","target":"$FX","started_at":"2020-01-01T00:00:00Z","pid":999999,"snapshot_dir":"$FX/.sentinel-shield/.txn-x","state":"active","hostname":"a-different-host-that-is-not-here"}
J
run_health
{ [ "$HRC" -eq 2 ] && [ "$(hstatus)" = unhealthy ] && has_reason operation_stale; } \
	&& pass "(2) a stale/interrupted operation lock reports unhealthy=operation_stale" \
	|| fail "(2) stale transaction (exit=$HRC status=$(hstatus) reasons=$(hreasons))"

# ============================================================================
# (3) CORRUPT JOURNAL — a tampered/truncated journal chain => unhealthy (reuses Task 2 verifier).
# ============================================================================
FX=$(fresh_fixture)
printf '{ this is not valid json and breaks the chain\n' > "$FX/.sentinel-shield/transaction-journal.jsonl"
run_health
{ [ "$HRC" -eq 2 ] && has_reason journal_tampered; } \
	&& pass "(3) a corrupt transaction journal reports unhealthy=journal_tampered" \
	|| fail "(3) corrupt journal (exit=$HRC reasons=$(hreasons))"

# ============================================================================
# (4) MISSING REQUIRED TOOL — an absent required tool => unhealthy.
# ============================================================================
FX=$(fresh_fixture)
run_health SENTINEL_SHIELD_HEALTH_REQUIRED_TOOLS="jq a-tool-that-does-not-exist-9z"
{ [ "$HRC" -eq 2 ] && has_reason required_tool_missing; } \
	&& pass "(4) a missing required tool reports unhealthy=required_tool_missing" \
	|| fail "(4) missing required tool (exit=$HRC reasons=$(hreasons))"

# ============================================================================
# (5) STALE SCANNER DATABASE — a very old vulnerability-db => degraded.
# ============================================================================
FX=$(fresh_fixture)
printf '{"scanner_version":"x","vulnerability_db":{"built_epoch":100}}\n' > "$FX/.sentinel-shield/scanner-provenance.json"
run_health
{ [ "$HRC" -eq 1 ] && [ "$(hstatus)" = degraded ] && has_reason scanner_db_stale; } \
	&& pass "(5) a stale scanner database reports degraded=scanner_db_stale" \
	|| fail "(5) stale scanner db (exit=$HRC status=$(hstatus) reasons=$(hreasons))"

# ============================================================================
# (6) SOURCE REF MISMATCH — resolved commit != pinned commit => unhealthy.
# ============================================================================
FX=$(fresh_fixture)
A=$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)
B=$(printf 'b%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)
printf '{"ref":"v1.2.3","pinned_commit":"%s","resolved_commit":"%s"}\n' "$A" "$B" > "$FX/.sentinel-shield/source.json"
run_health
{ [ "$HRC" -eq 2 ] && has_reason source_ref_mismatch; } \
	&& pass "(6) a source ref/commit mismatch reports unhealthy=source_ref_mismatch" \
	|| fail "(6) source ref mismatch (exit=$HRC reasons=$(hreasons))"
# The immutable tag ref itself is NOT flagged as moving.
[ "$(check_reason ref_immutability)" = ref_immutable ] \
	&& pass "(6) an immutable tag ref is classified ref_immutable" \
	|| fail "(6) ref immutability classification"

# ============================================================================
# (7) MANAGED-FILE DRIFT — a recorded managed file gone missing => degraded.
# ============================================================================
FX=$(fresh_fixture "managed1.txt")
printf 'content\n' > "$FX/managed1.txt"
# Re-record with the managed file listed, then remove it to force drift.
im_write "$FX" "2.0.0" "baseline" "1" "config-only" "" "managed1.txt" "" "" "" >/dev/null 2>&1
rm -f "$FX/managed1.txt"
run_health
{ [ "$HRC" -eq 1 ] && has_reason managed_file_drift; } \
	&& pass "(7) a missing managed file reports degraded=managed_file_drift" \
	|| fail "(7) managed-file drift (exit=$HRC status=$(hstatus) reasons=$(hreasons))"

# ============================================================================
# (8) UNSUPPORTED PACKAGE MANAGER — recorded unsupported state => degraded.
# ============================================================================
FX=$(fresh_fixture)
printf '{"status":"unsupported"}\n' > "$FX/.sentinel-shield/package-manager.json"
run_health
{ [ "$HRC" -eq 1 ] && has_reason package_manager_unsupported; } \
	&& pass "(8) an unsupported package manager reports degraded=package_manager_unsupported" \
	|| fail "(8) unsupported package manager (exit=$HRC reasons=$(hreasons))"

# ============================================================================
# (9) LOW DISK-SPACE FIXTURE — free space below the configured minimum => unhealthy.
# ============================================================================
FX=$(fresh_fixture)
run_health SENTINEL_SHIELD_HEALTH_DISK_MIN_KB=999999999999
{ [ "$HRC" -eq 2 ] && has_reason disk_space_low; } \
	&& pass "(9) free space below the minimum reports unhealthy=disk_space_low" \
	|| fail "(9) low disk-space (exit=$HRC reasons=$(hreasons))"

# ============================================================================
# (10) OFFLINE MODE — the default performs NO network check; connectivity is skipped.
# ============================================================================
FX=$(fresh_fixture)
# Poison the probe: if the code ever ran it offline, this would flip the result.
run_health SENTINEL_SHIELD_HEALTH_NET_PROBE="exit 3"
if [ "$HRC" -eq 0 ] && [ "$(hstatus)" = healthy ] \
	&& [ "$(check_reason github_connectivity)" = network_not_requested ] \
	&& jq -e '.mode.offline == true and .mode.network_checked == false' "$WORK/report.json" >/dev/null 2>&1; then
	pass "(10) offline mode skips the network check and never runs the probe"
else
	fail "(10) offline mode (exit=$HRC status=$(hstatus) conn=$(check_reason github_connectivity))"
fi

# ============================================================================
# (11) NETWORK-REQUIRED MODE WITH FAILURE — --check-network + a failing/timeout probe => unhealthy,
#      with a DISTINCT timeout reason code for the bounded (Task 1) probe.
# ============================================================================
FX=$(fresh_fixture)
run_health SENTINEL_SHIELD_HEALTH_NET_PROBE="exit 7" --check-network
{ [ "$HRC" -eq 2 ] && has_reason network_unreachable \
	&& jq -e '.mode.network_checked == true' "$WORK/report.json" >/dev/null 2>&1; } \
	&& pass "(11) a failed required connectivity probe reports unhealthy=network_unreachable" \
	|| fail "(11) network-required failure (exit=$HRC reasons=$(hreasons))"
# Distinct BOUNDED-TIMEOUT result: a probe that outlives the timeout => network_timeout, not _unreachable.
FX=$(fresh_fixture)
run_health SENTINEL_SHIELD_HEALTH_NET_TIMEOUT=1 SENTINEL_SHIELD_HEALTH_NET_PROBE="sleep 5" --check-network
{ [ "$HRC" -eq 2 ] && has_reason network_timeout; } \
	&& pass "(11+) a probe that exceeds its bounded timeout reports the DISTINCT network_timeout" \
	|| fail "(11+) bounded network timeout (exit=$HRC reasons=$(hreasons))"

# ============================================================================
# (12) JSONL EVENT CORRELATION — one FAILED install and its recovery share a correlation id, carry
#      DISTINCT operation ids, every line conforms to the schema, and a secret in a next-action hint
#      is REDACTED out of the stream.
# ============================================================================
EVENTS="$WORK/events.jsonl"
GH='ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
(
	SENTINEL_SHIELD_EVENTS=1
	SENTINEL_SHIELD_EVENTS_FILE="$EVENTS"
	SENTINEL_SHIELD_CORRELATION_ID="corr-incident-42"
	export SENTINEL_SHIELD_EVENTS SENTINEL_SHIELD_EVENTS_FILE SENTINEL_SHIELD_CORRELATION_ID
	SENTINEL_SHIELD_OPERATION_ID="op-install-A" oe_emit --command install --phase start \
		--event-type start --status in-progress --reason-code install_begin --component transaction --target "$WORK"
	SENTINEL_SHIELD_OPERATION_ID="op-install-A" oe_emit --command install --phase mutate \
		--event-type error --severity error --status failure --reason-code write_failed \
		--retryability manual --component transaction --target "$WORK" \
		--next-action "recover using token $GH now"
	SENTINEL_SHIELD_OPERATION_ID="op-recover-B" oe_emit --command recovery --phase rollback \
		--event-type complete --status success --reason-code rollback_complete \
		--component transaction --target "$WORK"
)
if [ ! -s "$EVENTS" ]; then
	fail "(12) no events were emitted"
else
	# Every line conforms to the operational-event schema.
	oe_validate_file "$EVENTS" >/dev/null 2>&1 \
		&& pass "(12) every emitted event conforms to the operational-event schema" \
		|| fail "(12) event schema conformance"
	# One shared correlation id across all three events (install failure + recovery).
	_ncorr=$(jq -r '.correlation_id' "$EVENTS" | LC_ALL=C sort -u | wc -l | tr -d ' ')
	_corr=$(jq -r '.correlation_id' "$EVENTS" | sort -u)
	{ [ "$_ncorr" = 1 ] && [ "$_corr" = "corr-incident-42" ]; } \
		&& pass "(12) the failed install and its recovery share ONE correlation id" \
		|| fail "(12) correlation id not shared (n=$_ncorr)"
	# Distinct operation ids for the install vs the recovery.
	_nops=$(jq -r '.operation_id' "$EVENTS" | LC_ALL=C sort -u | wc -l | tr -d ' ')
	[ "$_nops" = 2 ] \
		&& pass "(12) the install and the recovery carry DISTINCT operation ids" \
		|| fail "(12) operation ids not distinct (n=$_nops)"
	# The install failure is a correlatable error event.
	jq -e 'select(.command=="install" and .event_type=="error" and .status=="failure")' "$EVENTS" >/dev/null 2>&1 \
		&& pass "(12) the failed install emitted a correlatable error event" \
		|| fail "(12) install error event missing"
	# The secret in the next-action hint is redacted OUT of the stream.
	if grep -Fq "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789" "$EVENTS"; then
		fail "(12) a secret leaked into the event stream"
	else
		pass "(12) a secret in a next-action hint is redacted out of the event stream"
	fi
	# The stream carries no raw target path (identity is a hash).
	if grep -Fq "$WORK" "$EVENTS"; then fail "(12) event stream leaked the raw target path"; else pass "(12) event stream carries no raw target path"; fi
fi

# Disabled by default: no sink, no events (opt-in contract).
unset SENTINEL_SHIELD_EVENTS SENTINEL_SHIELD_EVENTS_FILE 2>/dev/null || :
oe_emit --command doctor --phase start --reason-code noop_probe >/dev/null 2>&1 \
	&& pass "(12+) oe_emit is a no-op returning success when emission is disabled" \
	|| fail "(12+) disabled oe_emit did not return success"

# ============================================================================
# Invalid event is refused (fail closed) — enum validation.
# ============================================================================
export SENTINEL_SHIELD_EVENTS=1 SENTINEL_SHIELD_EVENTS_FILE="$WORK/reject.jsonl"
_rc=0; oe_emit --command not-a-real-command --phase start --reason-code x >/dev/null 2>&1 || _rc=$?
{ [ "$_rc" -eq 2 ] && [ ! -s "$WORK/reject.jsonl" ]; } \
	&& pass "an event with an out-of-vocabulary command is refused (fail closed, nothing written)" \
	|| fail "invalid event was not refused (rc=$_rc)"
unset SENTINEL_SHIELD_EVENTS SENTINEL_SHIELD_EVENTS_FILE 2>/dev/null || :

# ============================================================================
printf '\n'
if [ "$FAILS" -eq 0 ]; then
	printf 'ALL PASS (254-operational-health)\n'
	exit 0
fi
printf '%s FAIL(s) (254-operational-health)\n' "$FAILS"
exit 1
