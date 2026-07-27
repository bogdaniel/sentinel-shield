#!/bin/sh
# Sentinel Shield — approved scanner-image contract validator.
#
# config/scanner-images.json is the single approved list of container images the shipped
# workflow templates may execute, each recorded with the tag it was resolved from and the
# immutable digest that tag pointed at. This enforces it.
#
# It exists because `owasp/dependency-check:latest` shipped as a production DEFAULT: the
# scanner implementation could change with no repository change, no review, and no way to
# reproduce an evidence run from the workflow source alone.
#
# Modes:
#   contract   Shape + internal consistency of config/scanner-images.json.
#   templates  Every SENTINEL_SHIELD_*_IMAGE default in every shipped template equals the
#              approved reference; no template executes a mutable tag; `default_pin: digest`
#              images are shipped as repository@sha256:… and nothing else.
#   registry   OPT-IN, NETWORK: re-resolve each recorded tag and report digest drift. This
#              never rewrites the contract — drift is a review decision, not an auto-bump.
#   show       Print the approved reference for one variable (for scripts/tests).
#   all        contract + templates (default; `registry` stays opt-in because it needs network).
#
# READ-ONLY. Exit: 0 ok; 1 contract violated; 2 invalid invocation / malformed contract;
#                 3 required tool unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

usage() {
	cat <<'EOF'
Usage:
  validate-scanner-images.sh [contract|templates|registry|all] [--contract <file>] [--repo-root <dir>]
  validate-scanner-images.sh show --var SENTINEL_SHIELD_<TOOL>_IMAGE [--contract <file>]

READ-ONLY. `registry` performs network requests; every other mode is offline.
EOF
}

MODE="all"
case "${1:-}" in
	contract | templates | registry | show | all) MODE="$1"; shift ;;
	-h | --help) usage; exit 0 ;;
	-*) ;;
	"") ;;
	*) log_error "unknown mode: $1"; usage >&2; exit 2 ;;
esac

CONTRACT=""
VAR=""
while [ $# -gt 0 ]; do
	case "$1" in
		--contract) CONTRACT="${2:?--contract requires a value}"; shift 2 ;;
		--repo-root) REPO_ROOT=$(CDPATH= cd -- "${2:?--repo-root requires a value}" && pwd); shift 2 ;;
		--var) VAR="${2:?--var requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required but was not found"; exit 3; }
[ -n "$CONTRACT" ] || CONTRACT="$REPO_ROOT/config/scanner-images.json"
[ -f "$CONTRACT" ] || { log_error "scanner-image contract not found: $CONTRACT"; exit 2; }
jq -e . "$CONTRACT" >/dev/null 2>&1 || { log_error "scanner-image contract is not valid JSON: $CONTRACT"; exit 2; }
# Structure BEFORE any mode. A JSON-valid but structurally malformed contract used to reach
# the modes, where a missing `.images` or a record without a digest read as "nothing to
# check" — the contract validated by validating nothing.
_ci_bad=$(jq -r '
	[ (if (.contract | type) != "string" then "contract must be a string" else empty end),
	  (if (.resolved_at | type) != "string" then "resolved_at must be a string" else empty end),
	  (if (.mutable_tags | type) != "array" or ((.mutable_tags | length) == 0) then "mutable_tags must be a non-empty array" else empty end),
	  (if (.images | type) != "object" or ((.images | length) == 0) then "images must be a non-empty object" else empty end),
	  (if (.templates | type) != "array" or ((.templates | length) == 0) then "templates must be a non-empty array" else empty end),
	  ( (.images // {}) | to_entries[]
	    | .key as $k | .value as $v
	    | ( [ "repository","resolved_from","digest","default_pin","default_reference" ]
	        | map(select((($v[.]?) // "") | (type != "string") or (length == 0))) ) as $missing
	    # SHAPE only. The VALUE rules (full-length digest, default_pin enum, template
	    # agreement) belong to `contract` mode, which reports them as contract violations
	    # (exit 1); this pre-check exists so a structurally broken file cannot reach a mode
	    # and validate by having nothing to look at.
	    | if ($v | type) != "object" then "images.\($k) must be an object"
	      elif ($missing | length) > 0 then "images.\($k) missing/empty \($missing | join(","))"
	      else empty end )
	] | join("; ")' "$CONTRACT" 2>/dev/null || printf 'contract could not be validated')
[ -z "$_ci_bad" ] || { log_error "scanner-image contract is structurally invalid: $_ci_bad"; exit 2; }

if [ "$MODE" = show ]; then
	[ -n "$VAR" ] || { log_error "show: --var is required"; exit 2; }
	_r=$(jq -r --arg v "$VAR" '.images[$v].default_reference // ""' "$CONTRACT")
	[ -n "$_r" ] || { log_error "show: '$VAR' is not in the approved scanner-image contract"; exit 1; }
	printf '%s\n' "$_r"
	exit 0
fi

FAILURES=0
pass() { printf '  PASS  %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf '  FAIL  %s\n' "$*"; }

MUTABLE=$(jq -r '.mutable_tags[]' "$CONTRACT" | tr '\n' ' ')
VARS=$(jq -r '.images | keys[]' "$CONTRACT")

# tag_is_mutable <tag> — true when the tag is declared non-immutable.
tag_is_mutable() {
	for _m in $MUTABLE; do
		[ "$1" = "$_m" ] && return 0
	done
	return 1
}

# ref_tag <image-ref> — the tag part of repo:tag, empty for a digest ref or a bare repo.
ref_tag() {
	case "$1" in
		*@sha256:*) printf '' ;;
		*:*) printf '%s' "${1##*:}" ;;
		*) printf '' ;;
	esac
}

check_contract() {
	printf 'scanner-images: contract\n'
	_c=$(jq -r '.contract // ""' "$CONTRACT")
	if [ "$_c" = "sentinel-shield/scanner-images@1" ]; then pass "contract identifier"
	else fail "CONTRACT_UNKNOWN — contract='$_c'"; fi

	for _v in $VARS; do
		_repo=$(jq -r --arg v "$_v" '.images[$v].repository // ""' "$CONTRACT")
		_dig=$(jq -r --arg v "$_v" '.images[$v].digest // ""' "$CONTRACT")
		_pin=$(jq -r --arg v "$_v" '.images[$v].default_pin // ""' "$CONTRACT")
		_ref=$(jq -r --arg v "$_v" '.images[$v].default_reference // ""' "$CONTRACT")
		_from=$(jq -r --arg v "$_v" '.images[$v].resolved_from // ""' "$CONTRACT")

		printf '%s' "$_dig" | grep -Eq '^sha256:[0-9a-f]{64}$' \
			|| fail "DIGEST_MALFORMED — $_v digest='$_dig' (a full sha256:<64hex> is required; an abbreviated digest is not a pin)"
		[ -n "$_from" ] || fail "RESOLVED_FROM_MISSING — $_v does not record the tag its digest was resolved from"
		case "$_ref" in
			"$_repo:"* | "$_repo@"*) ;;
			*) fail "REFERENCE_REPO_MISMATCH — $_v default_reference='$_ref' does not belong to repository '$_repo'" ;;
		esac
		case "$_pin" in
			digest)
				if [ "$_ref" = "$_repo@$_dig" ]; then pass "$_v ships the approved digest pin"
				else fail "DIGEST_PIN_REQUIRED — $_v declares default_pin=digest but default_reference='$_ref' is not '$_repo@$_dig'"; fi ;;
			tag)
				_t=$(ref_tag "$_ref")
				if [ -z "$_t" ]; then fail "TAG_PIN_MALFORMED — $_v declares default_pin=tag but default_reference='$_ref' carries no tag"
				elif tag_is_mutable "$_t"; then fail "MUTABLE_TAG_APPROVED — $_v default_reference='$_ref' uses the mutable tag '$_t'"
				elif [ "$_t" != "$_from" ]; then fail "TAG_RESOLUTION_MISMATCH — $_v ships tag '$_t' but its digest was resolved from '$_from'"
				else pass "$_v ships the immutable tag '$_t' (digest recorded for production)"; fi ;;
			*) fail "PIN_MODE_INVALID — $_v default_pin='$_pin' (digest|tag)" ;;
		esac
	done

	for _t in $(jq -r '.templates[]' "$CONTRACT"); do
		[ -f "$REPO_ROOT/$_t" ] || fail "DECLARED_TEMPLATE_MISSING — $_t is declared in the contract but does not exist"
	done
	pass "declared templates exist"
}

check_templates() {
	printf 'scanner-images: templates\n'
	_seen=0
	for _t in $(jq -r '.templates[]' "$CONTRACT"); do
		[ -f "$REPO_ROOT/$_t" ] || { fail "TEMPLATE_MISSING — $_t"; continue; }
		# Every `SENTINEL_SHIELD_*_IMAGE: <value>` assignment in the file, comments stripped.
		# Commented-out example lines (`# SENTINEL_SHIELD_..._IMAGE: ...`) are documentation,
		# not execution, and are deliberately not matched.
		while IFS= read -r _line; do
			[ -n "$_line" ] || continue
			_var=$(printf '%s' "$_line" | sed -E 's/^[[:space:]]*([A-Z0-9_]+):.*/\1/')
			_val=$(printf '%s' "$_line" | sed -E 's/^[[:space:]]*[A-Z0-9_]+:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]*$//; s/^"(.*)"$/\1/')
			# A value that is a workflow expression (${{ … }}) is consumer-supplied at run
			# time, not a shipped default, and is out of scope for this check.
			case "$_val" in '${{'*) continue ;; esac
			_seen=$((_seen + 1))
			_approved=$(jq -r --arg v "$_var" '.images[$v].default_reference // ""' "$CONTRACT")
			if [ -z "$_approved" ]; then
				fail "IMAGE_NOT_APPROVED — $_t sets $_var='$_val' but that variable is not in the approved scanner-image contract"
				continue
			fi
			_tag=$(ref_tag "$_val")
			if [ -n "$_tag" ] && tag_is_mutable "$_tag"; then
				fail "MUTABLE_TAG_SHIPPED — $_t executes '$_val' by default; '$_tag' is a moving tag (the scanner can change with no repository change)"
				continue
			fi
			if [ "$_val" = "$_approved" ]; then
				pass "$_t: $_var pins the approved reference"
			else
				fail "IMAGE_DRIFT — $_t sets $_var='$_val' but the approved reference is '$_approved'"
			fi
		done <<EOF
$(grep -E '^[[:space:]]*SENTINEL_SHIELD_[A-Z0-9_]*_IMAGE:' "$REPO_ROOT/$_t" 2>/dev/null || true)
EOF
	done
	if [ "$_seen" -eq 0 ]; then
		fail "SWEEP_EMPTY — no scanner-image assignment was inspected in any declared template"
	else
		pass "inspected $_seen scanner-image assignment(s) across the shipped templates"
	fi
}

check_registry() {
	printf 'scanner-images: registry (network)\n'
	command_exists curl || { log_error "registry: curl is required"; exit 3; }
	for _v in $VARS; do
		_repo=$(jq -r --arg v "$_v" '.images[$v].repository // ""' "$CONTRACT")
		_from=$(jq -r --arg v "$_v" '.images[$v].resolved_from // ""' "$CONTRACT")
		_dig=$(jq -r --arg v "$_v" '.images[$v].digest // ""' "$CONTRACT")
		_tok=$(curl -sS -m 30 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${_repo}:pull" 2>/dev/null | jq -r '.token // ""')
		if [ -z "$_tok" ]; then
			fail "REGISTRY_UNREACHABLE — could not obtain a pull token for '$_repo' (fail closed; re-run when the registry is reachable)"
			continue
		fi
		_live=$(curl -sSI -m 30 -H "Authorization: Bearer $_tok" \
			-H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json' \
			"https://registry-1.docker.io/v2/${_repo}/manifests/${_from}" 2>/dev/null |
			tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')
		if [ -z "$_live" ]; then
			fail "REGISTRY_NO_DIGEST — '$_repo:$_from' returned no Docker-Content-Digest"
		elif [ "$_live" = "$_dig" ]; then
			pass "$_repo:$_from still resolves to the recorded digest"
		else
			fail "DIGEST_DRIFT — '$_repo:$_from' now resolves to $_live but the contract records $_dig (review, validate, then update the contract deliberately)"
		fi
	done
}

case "$MODE" in
	contract) check_contract ;;
	templates) check_templates ;;
	registry) check_registry ;;
	all) check_contract; check_templates ;;
esac

printf '\n----\n'
if [ "$FAILURES" -eq 0 ]; then
	printf 'validate-scanner-images: %s PASSED\n' "$MODE"
	exit 0
fi
printf 'validate-scanner-images: %s FAILED (%d violation(s)); fail closed\n' "$MODE" "$FAILURES"
exit 1
