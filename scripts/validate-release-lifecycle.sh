#!/bin/sh
# Sentinel Shield — release lifecycle validator: GENERATE the upgrade-validation and
# rollback-validation reports the release-authorization gate consumes (GATE 8 / GATE 9).
#
# The engine's upgrade (install -> sync) and rollback (fail-closed transactional recovery)
# are exercised end-to-end by the prod suites (120/121/251) and self-test; this is the
# missing GENERATOR that runs the SAME real operations at release-assembly time and emits a
# ra_gate_ok-shaped attestation. It NEVER fabricates a result: result is "pass" only when
# every real check below holds, "fail" otherwise (and the report still records each check).
#
# Everything runs in throwaway temp targets with NO network and NO mutation of the repo.
#
#   --kind upgrade   install a baseline, edit a PROJECT-owned file + introduce managed drift,
#                    then sync (the upgrade op) and prove: managed files update, project-owned
#                    files are preserved, and the from->to upgrade plans cleanly (plan-upgrade).
#   --kind rollback  install with a deterministic mid-operation fault (SENTINEL_SHIELD_FAULT_AFTER),
#                    then --recover and prove: the interrupted op is detected, recovery clears the
#                    lock, a pre-existing project file survives, and --apply works again after.
#
# Usage:
#   validate-release-lifecycle.sh --kind upgrade|rollback --source-commit <40hex>
#       [--from <ver>] [--to <ver>] [--profile <name>] [--output <path>]
#
# Exit: 0 result=pass; 1 result=fail (a real check failed); 2 invalid invocation.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

KIND=""; SOURCE_COMMIT=""; FROM=""; TO=""; PROFILE="laravel-react-docker"; OUTPUT=""
while [ $# -gt 0 ]; do
	case "$1" in
		--kind) KIND="${2:?--kind requires a value}"; shift 2 ;;
		--source-commit) SOURCE_COMMIT="${2:?--source-commit requires a value}"; shift 2 ;;
		--from) FROM="${2:?--from requires a value}"; shift 2 ;;
		--to) TO="${2:?--to requires a value}"; shift 2 ;;
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		-h | --help)
			echo "Usage: validate-release-lifecycle.sh --kind upgrade|rollback --source-commit <40hex> [--from <ver>] [--to <ver>] [--profile <name>] [--output <path>]"
			exit 0 ;;
		*) log_error "validate-release-lifecycle: unknown argument: $1"; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required but was not found"; exit 2; }
case "$KIND" in upgrade | rollback) ;; *) log_error "--kind must be 'upgrade' or 'rollback'"; exit 2 ;; esac
printf '%s' "$SOURCE_COMMIT" | grep -Eq '^[0-9a-f]{40}$' || { log_error "--source-commit must be 40 lowercase hex"; exit 2; }

INSTALL="$SCRIPT_DIR/install-baseline.sh"
SYNC="$SCRIPT_DIR/sync-baseline.sh"
PLAN="$SCRIPT_DIR/plan-upgrade.sh"
for _s in "$INSTALL" "$SYNC" "$PLAN"; do
	[ -f "$_s" ] || { log_error "missing lifecycle script: $_s (fail closed)"; exit 2; }
done

CHECKS=$(mktemp 2>/dev/null || mktemp -t vrl)
WORK=$(mktemp -d 2>/dev/null || mktemp -d -t vrl)
trap 'rm -rf "$CHECKS" "$WORK"' EXIT INT TERM
FAILS=0

# add_check <name> <ok-exit> <detail> — ok-exit 0 => pass, anything else => fail.
add_check() {
	if [ "$2" = "0" ]; then _st=pass; else _st=fail; FAILS=$((FAILS + 1)); fi
	jq -nc --arg n "$1" --arg s "$_st" --arg d "${3:-}" '{name:$n, status:$s, detail:$d}' >> "$CHECKS"
}

if [ "$KIND" = "upgrade" ]; then
	T="$WORK/up"; mkdir -p "$T"
	_rc=0; sh "$INSTALL" --target "$T" --apply --profile "$PROFILE" >/dev/null 2>&1 || _rc=$?
	add_check "install --apply succeeds" "$_rc" "profile=$PROFILE"
	_wf="$T/.github/workflows/sentinel-shield.yml"
	add_check "install creates the managed workflow" "$([ -f "$_wf" ] && echo 0 || echo 1)" ".github/workflows/sentinel-shield.yml"

	# a PROJECT-owned decision the upgrade must NEVER clobber, plus managed drift to reconcile.
	mkdir -p "$T/.sentinel-shield"
	printf '{"version":"1.1","risks":[{"id":"KEEPME"}]}' > "$T/.sentinel-shield/accepted-risks.json"
	[ -f "$_wf" ] && printf '\n# DRIFT\n' >> "$_wf"

	_rc=0; sh "$SYNC" --target "$T" --apply --force >/dev/null 2>&1 || _rc=$?
	add_check "sync --apply --force succeeds (the upgrade op)" "$_rc" ""
	if [ -f "$_wf" ] && ! grep -q DRIFT "$_wf" 2>/dev/null; then _ok=0; else _ok=1; fi
	add_check "sync reconciles managed drift" "$_ok" "managed workflow rewritten"
	if grep -q KEEPME "$T/.sentinel-shield/accepted-risks.json" 2>/dev/null; then _ok=0; else _ok=1; fi
	add_check "upgrade preserves project-owned accepted-risks.json" "$_ok" "KEEPME survives sync"

	# the from->to delta plans cleanly (READ-ONLY; proves the upgrade path is analyzable).
	if [ -n "$FROM" ] && [ -n "$TO" ]; then
		_rc=0; sh "$PLAN" --from "$FROM" --to "$TO" --profile "$PROFILE" --target "$T" --format json >/dev/null 2>&1 || _rc=$?
		add_check "plan-upgrade $FROM -> $TO succeeds" "$_rc" "read-only upgrade plan"
	fi
else
	T="$WORK/rb"; mkdir -p "$T"
	printf 'PROJECT-SENTINEL\n' > "$T/README.md"  # pre-existing project content that MUST survive

	# discover a mid-sequence managed path to fault after (robust to path changes).
	_disc="$WORK/disc"; mkdir -p "$_disc"
	_paths=$(sh "$INSTALL" --target "$_disc" --apply --profile "$PROFILE" 2>/dev/null | sed -n 's/^wrote \[[^]]*\]: //p')
	_fault=$(printf '%s\n' "$_paths" | sed -n '2p'); [ -n "$_fault" ] || _fault=$(printf '%s\n' "$_paths" | sed -n '1p')
	add_check "install writes managed files (fault target discovered)" "$([ -n "$_fault" ] && echo 0 || echo 1)" "fault-after=${_fault:-none}"

	# deterministic mid-operation crash -> the install's OWN fail-closed transactional rollback
	# fires (tx trap): every file it created is restored/removed before it exits non-zero.
	_rc=0; SENTINEL_SHIELD_FAULT_AFTER="$_fault" sh "$INSTALL" --target "$T" --apply --profile "$PROFILE" >/dev/null 2>&1 || _rc=$?
	add_check "faulted install is interrupted (non-zero exit)" "$([ "$_rc" != "0" ] && echo 0 || echo 1)" "exit=$_rc"
	add_check "interrupted op rolls back the file it had created" "$([ -n "$_fault" ] && [ ! -f "$T/$_fault" ] && echo 0 || echo 1)" "$_fault removed"
	add_check "no operation-lock lingers after rollback" "$([ ! -f "$T/.sentinel-shield/operation-lock.json" ] && echo 0 || echo 1)" "clean rollback"
	add_check "pre-existing project file survives rollback" "$([ "$(cat "$T/README.md" 2>/dev/null)" = "PROJECT-SENTINEL" ] && echo 0 || echo 1)" "README.md intact"

	# operator recovery is safe + idempotent on the already-recovered tree (nothing to undo).
	_rc=0; sh "$INSTALL" --target "$T" --recover >/dev/null 2>&1 || _rc=$?
	add_check "--recover is clean on the recovered tree (exit 0)" "$_rc" ""

	# rollback leaves the project installable again.
	_rc=0; sh "$INSTALL" --target "$T" --apply --profile "$PROFILE" >/dev/null 2>&1 || _rc=$?
	add_check "install --apply works again after rollback" "$_rc" ""
fi

REPORT=$(jq -s --arg k "$KIND" --arg sc "$SOURCE_COMMIT" --arg from "$FROM" --arg to "$TO" --argjson fails "$FAILS" '
	{ schema_version: "1",
	  report: ($k + "-validation"),
	  kind: $k,
	  source_commit: $sc,
	  from: (if $from == "" then null else $from end),
	  to: (if $to == "" then null else $to end),
	  checks: .,
	  complete: true,
	  failure_count: $fails,
	  result: (if $fails == 0 then "pass" else "fail" end) }' "$CHECKS")

if [ -n "$OUTPUT" ]; then
	printf '%s\n' "$REPORT" > "$OUTPUT"
	log_info "validate-release-lifecycle: $KIND $(printf '%s' "$REPORT" | jq -r '.result') ($FAILS failure(s)) -> $OUTPUT"
else
	printf '%s\n' "$REPORT"
fi

[ "$FAILS" -eq 0 ]
