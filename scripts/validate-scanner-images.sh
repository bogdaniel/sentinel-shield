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

APPROVED_REFS=$(jq -r '.images[].default_reference' "$CONTRACT" 2>/dev/null || printf '')

# image_operands <file> — every image a workflow actually executes.
#
# Two shapes carry one: the operand of `docker run` (after its flags), and a job/service
# `image:` key. Comment lines are documentation and are skipped. Quotes are stripped so
# `"${VAR}"` and `${VAR}` are the same operand.
image_operands() {
	grep -v '^[[:space:]]*#' "$1" 2>/dev/null | awk '
		BEGIN { q = sprintf("%c", 39) }          # a literal single quote, unquotable inline
		function emit(tok) {
			gsub("^[\"" q "]+", "", tok)
			gsub("[\"" q "]+$", "", tok)
			sub(/\\$/, "", tok)
			if (tok != "" && tok !~ /^\$\{\{/) print tok
		}
		# a job or service `image:` key
		/^[[:space:]]*image:[[:space:]]*[^[:space:]]/ {
			line = $0
			sub(/^[[:space:]]*image:[[:space:]]*/, "", line)
			sub(/[[:space:]]*#.*$/, "", line)
			emit(line); next
		}
		# the operand of `docker run`, skipping flags and the values they take
		/docker[[:space:]]+run/ {
			n = split($0, t, /[[:space:]]+/)
			start = 0
			for (i = 1; i < n; i++) if (t[i] == "docker" && t[i+1] == "run") { start = i + 2; break }
			if (!start) next
			for (i = start; i <= n; i++) {
				tok = t[i]
				if (tok == "" || tok == "\\") continue
				# A BARE `$VAR` (no braces) is a shell expansion of flags in these templates
				# (e.g. `$MOUNTS` holding several -v pairs), not an image. Skip it and keep
				# looking. If one ever did hold the image, the token after it would be read
				# instead and reported as unapproved — noisy, but the fail-closed direction.
				if (substr(tok, 1, 1) == "$" && substr(tok, 2, 1) != "{") continue
				if (substr(tok, 1, 1) == "-") {
					if (tok ~ /^(-v|-w|-e|-u|-p|--volume|--workdir|--env|--user|--publish|--entrypoint|--name|--network|--mount)$/) i++
					continue
				}
				emit(tok); break
			}
		}' | sort -u
}

# ref_canonical <image-ref> — the comparable form of a reference.
#
# `repo:tag@sha256:X` and `repo@sha256:X` are the SAME immutable reference: when both a tag and
# a digest are present the daemon resolves the digest, and the tag is a readability annotation.
# Comparing the spellings literally reported a correctly pinned combined reference as drift, so
# every comparison in this file goes through here rather than keeping three copies of the rule.
ref_canonical() {
	case "$1" in
		*@sha256:*) : ;;
		*) printf '%s' "$1"; return ;;
	esac
	_rc_pre=${1%%@*}          # repository[:tag]
	_rc_dig=${1#*@}           # sha256:…
	# Drop a TAG if there is one — and only a tag. `${ref%%:*}` cut at the FIRST colon, which
	# on a ported registry is the port: registry.example.com:5000/team/img:v1@sha256:… became
	# registry.example.com@sha256:…, silently discarding the repository path and leaving two
	# different images on the same host indistinguishable. The tag separator is the `:` after
	# the last `/`, the same rule ref_tag uses.
	case "${_rc_pre##*/}" in
		*:*) _rc_pre=${_rc_pre%:*} ;;
	esac
	printf '%s@%s' "$_rc_pre" "$_rc_dig"
}

# ref_tag <image-ref> — the tag part of repo:tag, empty for a digest ref or a bare repo.
#
# The tag separator is only a `:` that appears AFTER the last `/`. A registry host may carry
# a port — `registry.example.com:5000/team/img` — and matching the last `:` in the whole
# reference reads that port as the tag ('5000/team/img'), so a private-registry image was
# tag-checked against a string that is not a tag at all.
ref_tag() {
	case "$1" in *@sha256:*) printf ''; return ;; esac
	_rt_last=${1##*/}
	case "$_rt_last" in
		*:*) printf '%s' "${_rt_last##*:}" ;;
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

	# `pass` used to run unconditionally right after this loop, so a report could carry both
	# DECLARED_TEMPLATE_MISSING and "declared templates exist". Only report the pass when
	# nothing failed, matching check_templates().
	_decl_ok=1
	# (#251) One template path per LINE, not word-split command substitution.
	_tmpls=$(jq -r '.templates[]' "$CONTRACT")
	while IFS= read -r _t; do
		[ -n "$_t" ] || continue
		[ -f "$REPO_ROOT/$_t" ] || { fail "DECLARED_TEMPLATE_MISSING — $_t is declared in the contract but does not exist"; _decl_ok=0; }
	done <<VSI_DECL
$_tmpls
VSI_DECL
	# `[ … ] && pass` as the LAST command makes the function's exit status the test's. Under
	# `set -eu` a missing declared template therefore killed the whole script here: the
	# summary never printed and, in `all` mode, check_templates never ran — the run reported
	# less than it had already found. Kept as an `if` so the status is the `pass`, not the test.
	if [ "$_decl_ok" -eq 1 ]; then pass "declared templates exist"; fi
}

check_templates() {
	printf 'scanner-images: templates\n'
	_seen=0
	# (#251) One template path per LINE, not word-split command substitution.
	_tmpls=$(jq -r '.templates[]' "$CONTRACT")
	while IFS= read -r _t; do
		[ -n "$_t" ] || continue
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
			if [ "$(ref_canonical "$_val")" = "$_approved" ]; then
				pass "$_t: $_var pins the approved reference"
			else
				fail "IMAGE_DRIFT — $_t sets $_var='$_val' but the approved reference is '$_approved'"
			fi
		done <<EOF
$(grep -E '^[[:space:]]*SENTINEL_SHIELD_[A-Z0-9_]*_IMAGE:' "$REPO_ROOT/$_t" 2>/dev/null || true)
EOF

		# ---- EXECUTION sweep -------------------------------------------------------------
		# Everything above inspects DECLARATIONS (`VAR: value`). A template does not execute
		# a declaration, it executes a command — and an image named inline, as a literal or
		# as a `${VAR:-default}` fallback, was never inspected by any of it. This file's own
		# header promises "no template executes a mutable tag"; until this sweep existed that
		# was a documented contract with nothing enforcing it, and a moving tag shipped in
		# exactly that position.
		for _v in $VARS; do
			# A template that READS a contract variable it never DECLARES runs whatever the
			# inline fallback says, while the declaration sweep sees nothing to check.
			if grep -q "\${$_v" "$REPO_ROOT/$_t" 2>/dev/null &&
				! grep -Eq "^[[:space:]]*$_v:" "$REPO_ROOT/$_t" 2>/dev/null; then
				_seen=$((_seen + 1))
				fail "IMAGE_VAR_UNDECLARED — $_t reads \$$_v but never declares it, so the inline fallback is what actually executes, not the approved reference"
			fi

			_erepo=$(jq -r --arg v "$_v" '.images[$v].repository // ""' "$CONTRACT")
			_eapproved=$(jq -r --arg v "$_v" '.images[$v].default_reference // ""' "$CONTRACT")
			[ -n "$_erepo" ] || continue
			_ere=$(printf '%s' "$_erepo" | sed 's/[.[\*^$]/\\&/g')
			# Every reference to an approved repository ANYWHERE in the file — whole-line
			# comments excluded, those are documentation — must be the approved reference.
			while IFS= read -r _occ; do
				[ -n "$_occ" ] || continue
				_seen=$((_seen + 1))
				[ "$(ref_canonical "$_occ")" = "$_eapproved" ] && continue
				_otag=$(ref_tag "$_occ")
				if [ -n "$_otag" ] && tag_is_mutable "$_otag"; then
					fail "MUTABLE_TAG_EXECUTED — $_t executes '$_occ'; '$_otag' is a moving tag, so the scanner can change with no repository change and no review"
				else
					fail "IMAGE_DRIFT_EXECUTED — $_t executes '$_occ' but the approved reference for $_v is '$_eapproved'"
				fi
			done <<EOF
$(grep -v '^[[:space:]]*#' "$REPO_ROOT/$_t" 2>/dev/null |
	grep -oE "${_ere}(:[A-Za-z0-9._-]+)?(@sha256:[0-9a-f]+)?" 2>/dev/null | sort -u || true)
EOF
		done

		# ---- OPERAND sweep: what is actually being RUN, whatever it is ------------------
		# Everything above starts from the approved contract and looks for those repositories
		# in the file. That can only ever find drift in an image we ALREADY approved — an
		# entirely unknown image has no repository pattern to search for, so
		# `docker run … evilcorp/backdoor:latest` in a shipped template passed cleanly.
		#
		# This sweep runs the other way round: take every image OPERAND the template executes
		# and require it to be an approved reference. Unknown is a violation, which is the
		# only way an allowlist can actually mean something.
		while IFS= read -r _op; do
			[ -n "$_op" ] || continue
			# `${VAR}` / `${VAR:-default}`: the variable itself is checked by the declaration
			# and reference sweeps above; here we check the DEFAULT, and that the variable is
			# a contract variable at all rather than an arbitrary name.
			case "$_op" in
				'${'*)
					_opv=${_op#'${'}; _opv=${_opv%\}}
					case "$_opv" in
						*:-*) _opd=${_opv#*:-}; _opv=${_opv%%:-*} ;;
						*) _opd="" ;;
					esac
					if ! printf '%s\n' "$VARS" | grep -qxF "$_opv"; then
						_seen=$((_seen + 1))
						fail "IMAGE_VAR_UNKNOWN — $_t executes an image from \$$_opv, which is not a variable in the approved scanner-image contract; an image chosen by an unrecognised variable is outside the allowlist entirely"
						continue
					fi
					[ -n "$_opd" ] || continue
					_opa=$(jq -r --arg v "$_opv" '.images[$v].default_reference // ""' "$CONTRACT")
					_seen=$((_seen + 1))
					[ "$_opd" = "$_opa" ] && continue
					fail "IMAGE_DRIFT_EXECUTED — $_t runs \${$_opv:-$_opd}, but the approved reference for $_opv is '$_opa'"
					continue ;;
			esac
			# A literal operand. It must be one of the approved references.
			#
			# `repo:tag@sha256:X` is accepted as equivalent to `repo@sha256:X`: when both are
			# present the DIGEST is what the daemon resolves, so the reference is immutable
			# and the tag is a readability annotation. Normalise before comparing rather than
			# rejecting a spelling that is exactly as strong.
			_seen=$((_seen + 1))
			if printf '%s\n' "$APPROVED_REFS" | grep -qxF "$(ref_canonical "$_op")"; then continue; fi
			_optag=$(ref_tag "$_op")
			if [ -n "$_optag" ] && tag_is_mutable "$_optag"; then
				fail "IMAGE_NOT_APPROVED — $_t executes '$_op', which is not in the approved scanner-image contract at all (and '$_optag' is a moving tag)"
			else
				fail "IMAGE_NOT_APPROVED — $_t executes '$_op', which is not in the approved scanner-image contract at all"
			fi
		done <<EOF
$(image_operands "$REPO_ROOT/$_t")
EOF
	done <<VSI_TEMPLATES
$_tmpls
VSI_TEMPLATES
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
