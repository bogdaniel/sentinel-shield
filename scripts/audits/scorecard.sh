#!/bin/sh
# Sentinel Shield audit wrapper — OpenSSF Scorecard (#100).
#
# Scorecard's failure modes are mostly REMOTE: an expired token, a rate limit, a repository that
# cannot be reached. Every one of them produced a stub exit 0 before, so an authentication failure
# and a repository with genuinely weak practices were indistinguishable — and a LOW SCORE is a
# finding, not an error.
#
# Evidence is bound to repository identity, because a Scorecard report that does not say which
# repository it describes cannot gate anything.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/redaction.sh
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=scripts/lib/scanner-transaction.sh
. "$SS_LIB_DIR/scanner-transaction.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"

OUT="${1:-reports/raw/scorecard.json}"
st_begin scorecard "$OUT" || exit 1
REPO="${SENTINEL_SHIELD_SCORECARD_REPO:-}"
ST_TARGET="$REPO"; ST_TARGET_MODE="repository"

command_exists scorecard || { st_fail "$ST_STATE_UNAVAILABLE" "no local 'scorecard' binary"; exit 0; }
ST_EXECUTOR="local-binary"; ST_BINPATH=$(command -v scorecard)
ST_VERSION=$(scorecard version 2>/dev/null | awk 'NR==1{print $NF}') || ST_VERSION=""
[ -n "$REPO" ] || { st_fail "$ST_STATE_NOTAPPLICABLE" "SENTINEL_SHIELD_SCORECARD_REPO not set — no repository to evaluate"; exit 0; }

st_execute scanner-run scorecard --repo="$REPO" --format=json
[ "$ST_EXIT" = "timeout" ] && { st_fail "$ST_STATE_TIMEOUT" "scorecard exceeded its bounded runtime"; exit 0; }
# Scorecard has no findings exit: a weak repository still exits 0. Any non-zero is operational —
# authentication, rate limiting, or an unreachable repository.
case "$ST_EXIT" in
0) : ;;
*) st_fail "$ST_STATE_ERROR" "scorecard exited $ST_EXIT — authentication, API, rate-limit or repository failure"; exit 0 ;;
esac
st_report_from_stdout || { st_fail "$ST_STATE_ERROR" "scorecard produced no report on stdout"; exit 0; }
sc_scorecard_validate "$(st_report_path)" || { st_fail "$ST_STATE_ERROR" "scorecard report rejected: ${SC_REASON:-unknown}"; exit 0; }

# Identity binding: the report must describe the repository we asked about.
_sc_repo=$(jq -r '.repo.name // ""' "$(st_report_path)" 2>/dev/null) || _sc_repo=""
case "$_sc_repo" in
*"$REPO"*|"$REPO") : ;;
*) st_fail "$ST_STATE_ERROR" "scorecard report describes '$_sc_repo', not the requested '$REPO'"; exit 0 ;;
esac
# A low score is a FINDING. The gate decides what score is acceptable; the adapter only records
# that checks ran and what they said.
_sc_low=$(jq -r '[.checks[] | select(.score >= 0 and .score < 5)] | length' "$(st_report_path)" 2>/dev/null) || _sc_low=0
if [ "${_sc_low:-0}" -gt 0 ]; then st_publish "$ST_STATE_FINDINGS"; else st_publish "$ST_STATE_CLEAN"; fi
exit 0
