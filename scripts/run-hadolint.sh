#!/bin/sh
# Sentinel Shield — multi-Dockerfile Hadolint runner (global discovery).
#
# Discovers all Dockerfile-like files in the project, runs Hadolint against each, and
# merges the JSON arrays into ONE reports/raw/hadolint.json that the hadolint collector
# parses (it counts error+warning -> unsafe_docker). Path info is preserved per finding.
#
# Discovery (generated/cache dirs are pruned, never scanned):
#   ./Dockerfile, ./Dockerfile.*
#   docker/**/Dockerfile,  docker/**/Dockerfile.*
#   .docker/**/Dockerfile, .docker/**/Dockerfile.*
#
# Behavior:
#   - No Dockerfiles found      -> skip cleanly, write NOTHING, exit 0
#                                  (collector then marks hadolint 'unavailable').
#   - One or more found         -> scan all, merge, write the output file.
#   - Hadolint cannot run / a file yields non-JSON -> error; the bad file is NOT counted
#     as empty. If NO file produced valid JSON, write NOTHING and exit 1 (unavailable) —
#     never fake an empty [] report on unexpected failure. A genuine "0 findings" run
#     DOES write [] (that is a real clean result, not a fake).
#
# Hadolint source: local `hadolint` binary if on PATH, else `docker run hadolint/hadolint`.
# Pin the image to a digest in production (see docs/pinned-ci-references guidance).
set -eu

OUTPUT="reports/raw/hadolint.json"
CONFIG=""
LIST_ONLY=0
HADOLINT_IMAGE="${SENTINEL_SHIELD_HADOLINT_IMAGE:-hadolint/hadolint}"

usage() {
	cat <<'EOF'
Usage: run-hadolint.sh [--output <path>] [--config <hadolint.yaml>] [--list]
Discover all Dockerfile-like files, run Hadolint on each, merge into one JSON report.
  --output <path>   merged report path (default: reports/raw/hadolint.json)
  --config <file>   Hadolint config to pass (default: auto — hadolint.yaml/.hadolint.yaml)
  --list            print discovered Dockerfiles (one per line) and exit; run nothing
Exit: 0 ok / skipped-clean; 1 Hadolint could not run; 2 config/tooling error.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--config) CONFIG="${2:?--config requires a value}"; shift 2 ;;
		--list) LIST_ONLY=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) usage >&2; echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

# --- discover ---------------------------------------------------------------
# Root-level Dockerfile / Dockerfile.* (POSIX sh: guard literal globs with -f).
discover() {
	for f in Dockerfile Dockerfile.*; do
		[ -f "$f" ] && printf '%s\n' "./$f"
	done
	# docker/ and .docker/ trees — prune generated/cache dirs as a safety net.
	for d in docker .docker; do
		[ -d "$d" ] || continue
		find "$d" \
			-type d \( -name node_modules -o -name vendor -o -name .git \
				-o -name dist -o -name build -o -name coverage \) -prune -o \
			-type f \( -name Dockerfile -o -name 'Dockerfile.*' \) -print
	done
}

# De-dup, stable order.
FILES=$(discover | sort -u)

if [ "$LIST_ONLY" -eq 1 ]; then
	[ -n "$FILES" ] && printf '%s\n' "$FILES"
	exit 0
fi

if [ -z "$FILES" ]; then
	echo "run-hadolint: no Dockerfile-like files found; skipping (hadolint stays unavailable)." >&2
	exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "run-hadolint: jq is required to merge reports." >&2; exit 2; }

# --- hadolint invocation ----------------------------------------------------
# Auto-detect a config file when not given (hadolint only auto-loads .hadolint.*).
if [ -z "$CONFIG" ]; then
	for c in hadolint.yaml hadolint.yml .hadolint.yaml .hadolint.yml; do
		[ -f "$c" ] && { CONFIG="$c"; break; }
	done
fi

HAVE_LOCAL=0
HAVE_DOCKER=0
command -v hadolint >/dev/null 2>&1 && HAVE_LOCAL=1
command -v docker   >/dev/null 2>&1 && HAVE_DOCKER=1
if [ "$HAVE_LOCAL" -eq 0 ] && [ "$HAVE_DOCKER" -eq 0 ]; then
	echo "run-hadolint: neither 'hadolint' nor 'docker' is available; cannot scan." >&2
	exit 1
fi

# Run hadolint on one file, emitting a JSON array on stdout. Findings make hadolint
# exit non-zero — that is expected, NOT a failure; we keep the JSON.
run_one() {
	_f=$1
	if [ "$HAVE_LOCAL" -eq 1 ]; then
		if [ -n "$CONFIG" ]; then
			hadolint --no-fail -f json --config "$CONFIG" "$_f" 2>/dev/null
		else
			hadolint --no-fail -f json "$_f" 2>/dev/null
		fi
	else
		if [ -n "$CONFIG" ]; then
			docker run --rm -v "$PWD:/repo" -w /repo "$HADOLINT_IMAGE" \
				hadolint --no-fail -f json --config "$CONFIG" "$_f" 2>/dev/null
		else
			docker run --rm -v "$PWD:/repo" -w /repo "$HADOLINT_IMAGE" \
				hadolint --no-fail -f json "$_f" 2>/dev/null
		fi
	fi
}

ensure_dir() { d=$(dirname "$1"); [ -d "$d" ] || mkdir -p "$d"; }
ensure_dir "$OUTPUT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
ANY_VALID=0
FAILED=0
i=0
for f in $FILES; do
	i=$((i + 1))
	out=$(run_one "$f" || true)
	if printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
		printf '%s' "$out" > "$TMP/part-$i.json"
		ANY_VALID=1
	else
		echo "run-hadolint: Hadolint produced no valid JSON for '$f' (not counted as empty)." >&2
		FAILED=1
	fi
done

if [ "$ANY_VALID" -eq 0 ]; then
	# Nothing parseable at all — Hadolint failed unexpectedly. Do NOT fake an empty report.
	echo "run-hadolint: no valid Hadolint output produced; leaving '$OUTPUT' absent (unavailable)." >&2
	exit 1
fi

# Merge all per-file arrays into one (preserves each finding's .file path).
jq -s 'add' "$TMP"/part-*.json > "$OUTPUT"
echo "run-hadolint: scanned $i Dockerfile(s) -> $OUTPUT ($(jq 'length' "$OUTPUT") findings)$( [ "$FAILED" -eq 1 ] && echo ' [some files failed; see warnings]')"
exit 0
