#!/bin/sh
# Sentinel Shield audit wrapper — TruffleHog secret detection (#101).
#
# TruffleHog emits NEWLINE-DELIMITED JSON: one object per finding, not a JSON document. Two
# consequences the previous stub got wrong in opposite directions.
#
# First, the stream is not a document. Feeding it to a generic JSON validator either fails on a
# multi-finding stream or, worse, accepts a single forged object because it happens to parse. Each
# line is validated as an object in its own right, and a truncated final line is a TRUNCATED
# STREAM, not an empty result — the difference between "no secrets" and "we stopped reading".
#
# Second, the report is about secrets. Raw detector payloads are never copied into evidence: the
# normalized report carries counts and locations, and the transaction's diagnostics are redacted.
#
# VERIFIED vs UNVERIFIED is preserved rather than collapsed. An unverified finding is still a
# finding; it is the gate's business which of the two it acts on.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/redaction.sh
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=scripts/lib/scanner-transaction.sh
. "$SS_LIB_DIR/scanner-transaction.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"

OUT="${1:-reports/raw/trufflehog.json}"
st_begin trufflehog "$OUT" || exit 1
ST_TARGET="${SENTINEL_SHIELD_TRUFFLEHOG_TARGET:-.}"
ST_TARGET_MODE="filesystem"

command_exists trufflehog || { st_fail "$ST_STATE_UNAVAILABLE" "no local 'trufflehog' binary"; exit 0; }
ST_EXECUTOR="local-binary"; ST_BINPATH=$(command -v trufflehog)
ST_VERSION=$(trufflehog --version 2>&1 | awk 'NR==1{print $NF}') || ST_VERSION=""

st_execute scanner-run trufflehog filesystem --json --no-update "$ST_TARGET"
[ "$ST_EXIT" = "timeout" ] && { st_fail "$ST_STATE_TIMEOUT" "trufflehog exceeded its bounded runtime"; exit 0; }
# 0 = completed, 183 = completed WITH findings (TruffleHog's documented findings exit).
case "$ST_EXIT" in
0|183) : ;;
*)     st_fail "$ST_STATE_ERROR" "trufflehog exited $ST_EXIT — operational failure, not a secret verdict"; exit 0 ;;
esac

_th_stream="$(st_workspace)/stream.ndjson"
cp -f "$ST_STDOUT" "$_th_stream" 2>/dev/null || { st_fail "$ST_STATE_ERROR" "trufflehog produced no stream"; exit 0; }
sc_trufflehog_validate_stream "$_th_stream" || { st_fail "$ST_STATE_ERROR" "trufflehog stream rejected: ${SC_REASON:-unknown}"; exit 0; }

# NORMALIZE WITHOUT COPYING SECRETS. Detector name, verification status and location only — never
# .Raw, .RawV2 or the redacted payload fields.
if ! jq -s '{contract:"sentinel-shield/trufflehog@1",
             findings: (map({detector:(.DetectorName // "unknown"),
                             verified:(.Verified // false),
                             file:((.SourceMetadata.Data.Filesystem.file) // (.SourceMetadata.Data.Git.file) // "unknown")})),
             counts:{total:length,
                     verified:(map(select(.Verified == true)) | length),
                     unverified:(map(select(.Verified != true)) | length)}}' \
	"$_th_stream" > "$(st_report_path)" 2>/dev/null; then
	st_fail "$ST_STATE_ERROR" "could not normalize the trufflehog stream"
	exit 0
fi
if [ "${SC_COUNT:-0}" -gt 0 ]; then st_publish "$ST_STATE_FINDINGS"; else st_publish "$ST_STATE_CLEAN"; fi
exit 0
