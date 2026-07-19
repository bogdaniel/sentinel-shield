#!/bin/sh
# Sentinel Shield runner — dependency-cruiser (JS/TS structural-boundary producer, v2.1.0).
#
# Detects forbidden module dependencies (feature/layer boundaries, orphan modules, cycles).
# It is one architecture producer: it does not prove Clean Architecture or DDD correctness.
#
# Package manager is detected from the LOCKFILE (package-lock.json -> npm, pnpm-lock.yaml ->
# pnpm, yarn.lock -> yarn); npx is never forced on a pnpm/yarn project.
#
# Honest statuses: unavailable (binary absent) / not-configured (no rule config) /
# execution-error (ran but no valid JSON) / native report preserved. Never a faked clean run.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/../lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/architecture-evidence.sh
. "$SCRIPT_DIR/../lib/architecture-evidence.sh"
# shellcheck source=scripts/lib/architecture-policy.sh
. "$SCRIPT_DIR/../lib/architecture-policy.sh"

OUT="reports/raw/dependency-cruiser.json"
CONFIG=""
POLICY=".sentinel-shield/architecture-policy.yaml"
PATHS=""

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: dependency-cruiser.sh [--output <path>] [--config <path>] [--policy <path>]
                             [--paths "<dir> <dir>"] [<output>]
Run dependency-cruiser and write its JSON report (or an honest non-evidence status).
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUT="${2:?--output requires a value}"; shift 2 ;;
		--config) CONFIG="${2:?--config requires a value}"; shift 2 ;;
		--policy) POLICY="${2:?--policy requires a value}"; shift 2 ;;
		--paths) PATHS="${2:?--paths requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		--*) usage >&2; log_error "unknown argument: $1"; exit 2 ;;
		*) OUT="$1"; shift ;;
	esac
done

ensure_dir "$(dirname -- "$OUT")"

ap_load "$POLICY"
if ap_present; then
	if ! ap_enabled; then arch_write_status "$OUT" dependency-cruiser disabled "architecture governance disabled in $POLICY"; exit 0; fi
	if ! ap_tool_enabled dependency_cruiser true; then arch_write_status "$OUT" dependency-cruiser disabled "dependency_cruiser disabled in $POLICY"; exit 0; fi
	[ -n "$CONFIG" ] || CONFIG=$(ap_get architecture.tools.dependency_cruiser.config)
fi

# Binary: project-local bin first, then the lockfile's package manager.
PM=$(arch_pkg_manager)
if [ -x node_modules/.bin/depcruise ]; then
	RUN="node_modules/.bin/depcruise"
elif command_exists depcruise; then
	RUN="depcruise"
elif [ -d node_modules ] && command_exists "$PM"; then
	RUN="$(arch_pkg_exec "$PM") depcruise"
else
	arch_write_status "$OUT" dependency-cruiser unavailable "depcruise not found (node_modules/.bin/depcruise, global depcruise, or $PM exec)"
	exit 0
fi

if [ -n "$CONFIG" ]; then
	if [ ! -f "$CONFIG" ]; then
		arch_write_status "$OUT" dependency-cruiser not-configured "configured dependency-cruiser config not found: $CONFIG"; exit 0
	fi
else
	for _c in .dependency-cruiser.js .dependency-cruiser.cjs .dependency-cruiser.mjs .dependency-cruiser.json; do
		if [ -f "$_c" ]; then CONFIG="$_c"; break; fi
	done
	if [ -z "$CONFIG" ]; then
		arch_write_status "$OUT" dependency-cruiser not-configured "no dependency-cruiser config found (.dependency-cruiser.js|.cjs|.mjs|.json)"; exit 0
	fi
fi

# Sources: --paths, then the policy's bounded-context paths, then whichever of src/app/lib exists.
if [ -z "$PATHS" ] && ap_present; then
	PATHS=$(ap_get architecture.bounded_contexts.paths 2>/dev/null || true)
fi
if [ -z "$PATHS" ]; then
	for _d in src app lib; do
		[ -d "$_d" ] && PATHS="$PATHS $_d"
	done
	PATHS=${PATHS# }
fi
if [ -z "$PATHS" ]; then
	arch_write_status "$OUT" dependency-cruiser not-configured "no source directory to cruise (looked for src, app, lib)"; exit 0
fi

TMP="$OUT.tmp"
# depcruise exits non-zero when it FINDS violations — validity of the JSON decides evidence.
# shellcheck disable=SC2086  # RUN and PATHS are intentionally word-split argument lists
$RUN $PATHS --config "$CONFIG" --output-type json > "$TMP" 2>/dev/null || true

if [ ! -s "$TMP" ] || ! jq -e . "$TMP" >/dev/null 2>&1; then
	rm -f "$TMP"
	arch_write_status "$OUT" dependency-cruiser execution-error "dependency-cruiser ran but produced no valid JSON report"
	exit 0
fi

jq --arg c "$CONFIG" 'if type=="object" then . + {producer:"dependency-cruiser", config:$c} else . end' "$TMP" > "$OUT" 2>/dev/null \
	|| mv "$TMP" "$OUT"
rm -f "$TMP"
log_info "dependency-cruiser: report written to $OUT (config=$CONFIG, paths=$PATHS)"
exit 0
