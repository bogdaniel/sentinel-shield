#!/bin/sh
# Sentinel Shield — MERGE-SAFETY audit for GitHub Actions workflows.
#
# A deterministic, fail-CLOSED gate over the engine CI (.github/workflows/*.yml)
# AND the consumer-facing templates (templates/workflows/*.yml). It flags the
# workflow patterns that let a fork PR (or an unprotected ref) steal secrets,
# gain write access, or publish a release. Complements workflow-runtime-audit
# (bounded/least-privilege/pinned invariants) with attack-pattern detection:
#
#   pull-request-target-checkout — a `pull_request_target` workflow that checks
#                        out UNTRUSTED PR head code (github.event.pull_request.head*,
#                        github.head_ref, refs/pull/…). ppt runs with the base
#                        repo's secrets + token, so building fork code = RCE.
#   fork-pr-write-permission — a workflow reachable by pull_request /
#                        pull_request_target that grants a MUTATING write scope
#                        (contents/packages/pull-requests/issues/id-token/…, or
#                        write-all). security-events: write (SARIF upload) is the
#                        one allowed exception.
#   pull-request-target-secret — a `pull_request_target` workflow references a
#                        custom secret (secrets.* other than GITHUB_TOKEN), which
#                        is exposed to untrusted fork code.
#   mutable-action-ref — a `uses:` not pinned to a full 40-hex commit SHA
#                        (or @sha256: digest / local ./ ref); a moved tag/branch
#                        can swap in malicious code post-review.
#   release-on-unprotected-ref — a publish/release/deploy step reachable from a
#                        pull_request / pull_request_target event (a fork PR could
#                        cut a release). Gate release jobs to tags/dispatch.
#
# Emits BOTH a human report (STDOUT) and a machine report
# (reports/raw/merge-safety-audit.json, per schemas/merge-safety-audit.schema.json).
#
# Usage: merge-safety-audit.sh [--output <path>] [--dir <dir> ...] [files...]
#   default dirs:   .github/workflows templates/workflows
#   default output: reports/raw/merge-safety-audit.json
# Exit: 0 = clean, 1 = one or more findings (fail closed), 2 = config error.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"

ss_require_jq

OUTPUT="reports/raw/merge-safety-audit.json"
DIRS=""
FILES=""
while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--dir) DIRS="$DIRS ${2:?--dir requires a value}"; shift 2 ;;
		-h | --help)
			printf 'Usage: merge-safety-audit.sh [--output <path>] [--dir <dir> ...] [files...]\n'
			exit 0 ;;
		--*) log_error "unknown option: $1"; exit 2 ;;
		*) FILES="$FILES $1"; shift ;;
	esac
done

if [ -z "$FILES" ] && [ -z "$DIRS" ]; then
	DIRS=".github/workflows templates/workflows"
fi
for _d in $DIRS; do
	if [ -d "$_d" ]; then
		FILES="$FILES $(find "$_d" -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)"
	fi
done

ensure_dir "$(dirname "$OUTPUT")"
TMP=$(mktemp); trap 'rm -f "$TMP"' EXIT INT TERM
: > "$TMP"

SCANNED=0

# emit <file> <line> <check> <ref> <message>
emit() {
	printf 'VIOLATION: %s:%s [%s] %s\n' "$1" "$2" "$3" "$5" >&2
	jq -n --arg f "$1" --argjson l "$2" --arg c "$3" --arg r "$4" --arg m "$5" \
		'{file:$f, line:$l, check:$c, ref:$r, message:$m}' >> "$TMP"
}

is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

# strip_comments <file> — echo the file with YAML # comments removed (naive but
# sufficient: our workflows do not embed '#' inside quoted scalars on trigger/
# permission/uses lines). Keeps line count stable is NOT required here.
# trigger_events <file> — print one normalized top-level trigger event per line
# (push, pull_request, pull_request_target, workflow_dispatch, schedule, …),
# handling `on: x`, `on: [a, b]`, and the block form. Comments stripped first.
trigger_events() {
	sed 's/#.*$//' "$1" | awk '
		/^on:/ {
			ino=1
			rest=$0; sub(/^on:[[:space:]]*/,"",rest)
			if (rest ~ /[A-Za-z]/) {
				gsub(/[][,]/," ",rest)
				n=split(rest,a," ")
				for (i=1;i<=n;i++) if (a[i] != "") print a[i]
				ino=0
			}
			next
		}
		ino && /^[A-Za-z]/ { ino=0 }
		ino && /^  [A-Za-z_]+:/ { k=$0; sub(/^  /,"",k); sub(/:.*/,"",k); gsub(/[[:space:]]/,"",k); if (k != "") print k }
	'
}

for f in $FILES; do
	[ -f "$f" ] || continue
	SCANNED=$((SCANNED + 1))

	_events=$(trigger_events "$f")
	_has_ppt=0; _has_pr=0
	printf '%s\n' "$_events" | grep -qx 'pull_request_target' && _has_ppt=1
	printf '%s\n' "$_events" | grep -qx 'pull_request' && _has_pr=1
	# fork-reachable = pull_request OR pull_request_target
	_fork_reachable=0
	if [ "$_has_ppt" = 1 ] || [ "$_has_pr" = 1 ]; then
		_fork_reachable=1
	fi

	_ln=0
	while IFS= read -r line || [ -n "$line" ]; do
		_ln=$((_ln + 1))
		_code=$(printf '%s' "$line" | sed 's/[[:space:]]*#.*$//')

		# (4) mutable-action-ref: every uses: pinned to a 40-hex SHA / digest / local.
		_key=$(printf '%s' "$_code" | sed -e 's/^[[:space:]]*//' -e 's/^-[[:space:]]*//')
		case "$_key" in
			uses:*)
				_ref=$(printf '%s' "$_key" | sed -n 's/^uses:[[:space:]]*//p' | tr -d '"'"'"' ')
				if [ -n "$_ref" ]; then
					case "$_ref" in
						./*|.\\*) : ;;
						*@sha256:*) : ;;
						*@*)
							_after=${_ref##*@}
							is_sha "$_after" || emit "$f" "$_ln" "mutable-action-ref" "$_ref" \
								"uses '@$_after' is a mutable tag/branch/short-SHA, not a full 40-hex commit SHA" ;;
						*)
							emit "$f" "$_ln" "mutable-action-ref" "$_ref" \
								"uses has no @ref (defaults to a moving default branch)" ;;
					esac
				fi ;;
		esac

		# (1) pull-request-target-checkout: ppt + checkout of untrusted PR head.
		if [ "$_has_ppt" = 1 ]; then
			case "$_code" in
				*ref:*)
					if printf '%s' "$_code" | grep -Eq 'github\.event\.pull_request\.head|github\.head_ref|refs/pull/|github\.event\.pull_request\.merge_commit'; then
						emit "$f" "$_ln" "pull-request-target-checkout" "$(printf '%s' "$_code" | sed -e 's/^[[:space:]]*//')" \
							"pull_request_target workflow checks out untrusted PR head code (runs fork code with base secrets)"
					fi ;;
			esac
			# (3) pull-request-target-secret: custom secret exposed to fork code.
			if printf '%s' "$_code" | grep -Eq 'secrets\.[A-Za-z0-9_]+'; then
				_sec=$(printf '%s' "$_code" | grep -oE 'secrets\.[A-Za-z0-9_]+' | sed 's/secrets\.//' | head -n1)
				if [ -n "$_sec" ] && [ "$_sec" != "GITHUB_TOKEN" ]; then
					emit "$f" "$_ln" "pull-request-target-secret" "secrets.$_sec" \
						"pull_request_target workflow exposes custom secret '$_sec' to untrusted fork code"
				fi
			fi
		fi

		# (2) fork-pr-write-permission: mutating write scope on a fork-reachable wf.
		if [ "$_fork_reachable" = 1 ]; then
			if printf '%s' "$_code" | grep -Eq '^[[:space:]]*permissions:[[:space:]]*write-all[[:space:]]*$'; then
				emit "$f" "$_ln" "fork-pr-write-permission" "write-all" \
					"fork-reachable workflow grants permissions: write-all"
			elif printf '%s' "$_code" | grep -Eq '^[[:space:]]*(contents|packages|pull-requests|issues|id-token|deployments|actions|statuses|checks|repository-projects|discussions|pages):[[:space:]]*write[[:space:]]*$'; then
				_scope=$(printf '%s' "$_code" | sed -E 's/^[[:space:]]*([a-z-]+):.*/\1/')
				emit "$f" "$_ln" "fork-pr-write-permission" "$_scope: write" \
					"fork-reachable workflow grants '$_scope: write' (secrets/token exposed to PR-triggered runs)"
			fi
		fi

		# (5) release-on-unprotected-ref: publish/deploy reachable from a PR event.
		if [ "$_fork_reachable" = 1 ]; then
			if printf '%s' "$_code" | grep -Eq 'softprops/action-gh-release|ncipollo/release-action|actions/create-release|pypa/gh-action-pypi-publish|JamesIves/github-pages-deploy-action|npm publish|gh release (create|upload)|twine upload|docker push'; then
				emit "$f" "$_ln" "release-on-unprotected-ref" "$(printf '%s' "$_code" | sed -e 's/^[[:space:]]*//')" \
					"publish/release/deploy step is reachable from a pull_request(_target) event (a fork PR could cut a release)"
			fi
		fi
	done < "$f"
done

if [ "$SCANNED" -eq 0 ]; then
	log_error "merge-safety-audit: no workflow files found to scan"
	exit 2
fi

VIOLATIONS=$(jq -s 'length' "$TMP")
_status=pass
[ "$VIOLATIONS" -gt 0 ] && _status=fail

jq -s --arg v "1.0" --arg ts "$(timestamp_utc)" --arg st "$_status" \
	--argjson scanned "$SCANNED" \
	'{version:$v, generated_at:$ts, tool:"merge-safety-audit",
	  files_scanned:$scanned,
	  checks:["pull-request-target-checkout","fork-pr-write-permission","pull-request-target-secret","mutable-action-ref","release-on-unprotected-ref"],
	  status:$st, violation_count:(.|length), violations:.}' "$TMP" > "$OUTPUT"

printf '\nmerge-safety-audit: scanned %d file(s), %d finding(s) -> %s\n' "$SCANNED" "$VIOLATIONS" "$OUTPUT"

if [ "$VIOLATIONS" -gt 0 ]; then
	log_error "merge-safety-audit: FAIL ($VIOLATIONS finding(s))"
	exit 1
fi
log_info "merge-safety-audit: PASS ($SCANNED file(s) clean)"
exit 0
