#!/bin/sh
# Sentinel Shield audit wrapper — Conftest policy evaluation (#98).
#
# WAS a fourteen-line stub: run, `|| true`, exit 0. It could not distinguish a policy VIOLATION
# from "no policies were found" or "the parser failed" — and all three left the previous report
# standing as current evidence.
#
# The distinction Conftest makes hard: an empty result array means BOTH "every target passed" and
# "no target was ever evaluated". Emptiness alone is not proof of a clean run, so this adapter
# records how many results were evaluated and treats a zero-result run as no-targets rather than
# as a pass.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SS_LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck source=scripts/lib/redaction.sh
. "$SS_LIB_DIR/redaction.sh"
# shellcheck source=scripts/lib/scanner-transaction.sh
. "$SS_LIB_DIR/scanner-transaction.sh"
# shellcheck source=scripts/lib/scanner-contracts.sh
. "$SS_LIB_DIR/scanner-contracts.sh"

OUT="${1:-reports/raw/conftest.json}"
st_begin conftest "$OUT" || exit 1
ST_TARGET="${SENTINEL_SHIELD_CONFTEST_TARGET:-.}"
ST_TARGET_MODE="policy-evaluation"
POLICY_DIR="${SENTINEL_SHIELD_CONFTEST_POLICY:-policy}"

command_exists conftest || { st_fail "$ST_STATE_UNAVAILABLE" "no local 'conftest' binary"; exit 0; }
ST_EXECUTOR="local-binary"; ST_BINPATH=$(command -v conftest)
ST_VERSION=$(conftest --version 2>/dev/null | awk 'NR==1{print $NF}') || ST_VERSION=""

# NOT-APPLICABLE is a real answer. Without a policy directory there is nothing to evaluate, and
# reporting that honestly is different from reporting a clean evaluation.
[ -d "$POLICY_DIR" ] || { st_fail "$ST_STATE_NOTAPPLICABLE" "no policy directory '$POLICY_DIR' to evaluate against"; exit 0; }

st_execute scanner-run conftest test --output json --policy "$POLICY_DIR" "$ST_TARGET"
[ "$ST_EXIT" = "timeout" ] && { st_fail "$ST_STATE_TIMEOUT" "conftest exceeded its bounded runtime"; exit 0; }
st_report_from_stdout || { st_fail "$ST_STATE_ERROR" "conftest produced no report on stdout"; exit 0; }

# Conftest's vocabulary: 0 = all passed, 1 = policy violations. Anything else is operational —
# a missing policy, a parse error, a bad flag — and must never read as "no violations".
case "$ST_EXIT" in
0|1) : ;;
*)   st_fail "$ST_STATE_ERROR" "conftest exited $ST_EXIT — operational failure, not a policy result"; exit 0 ;;
esac
sc_conftest_validate "$(st_report_path)" || { st_fail "$ST_STATE_ERROR" "conftest report rejected: ${SC_REASON:-unknown}"; exit 0; }

if [ "${SC_COUNT:-0}" -eq 0 ]; then
	# Zero results with a zero exit: nothing was evaluated. Recorded as no-targets so a consumer
	# cannot mistake "no policy matched any file" for "every file passed".
	st_publish "$ST_STATE_NOTARGETS"
elif [ "$ST_EXIT" = "1" ]; then
	st_publish "$ST_STATE_FINDINGS"
else
	st_publish "$ST_STATE_CLEAN"
fi
exit 0
