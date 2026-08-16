#!/bin/sh
# Sentinel Shield — render docs/producer-completion-contracts.md from the canonical inventory.
#
# The JSON is the single source. This renderer exists so the human-readable table CANNOT be
# maintained beside it: tests/prod/305 regenerates into a temp file and requires a byte-exact
# match with the committed document, so a hand edit to either one fails CI.
#
# Usage: render-producer-contracts.sh [--check]
#   (no args)  write docs/producer-completion-contracts.md
#   --check    render to stdout only; write nothing
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC="$ROOT/config/producer-completion-contracts.json"
OUT="$ROOT/docs/producer-completion-contracts.md"
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 2; }
[ -f "$SRC" ] || { echo "missing $SRC" >&2; exit 2; }

render() {
	jq -r '
	# ONE backslash before a cell pipe. The previous replacement emitted two, which renders a
	# literal backslash beside a pipe that still breaks the cell.
	def esc: gsub("\\|"; "\\|") | gsub("\n"; " ");
	"<!-- GENERATED FILE — DO NOT EDIT.",
	"     Source: config/producer-completion-contracts.json",
	"     Render: scripts/render-producer-contracts.sh",
	"     tests/prod/305 fails if this file and the JSON disagree. -->",
	"",
	"# Producer completion contracts",
	"",
	"Canonical source: [`config/producer-completion-contracts.json`](../config/producer-completion-contracts.json).",
	"Generated for master `" + .generated_for_master + "`.",
	"",
	.purpose,
	"",
	"## How to read this",
	"",
	(.reading_rules | to_entries[] | "- **`" + .key + "`** — " + .value),
	"",
	"## Summary",
	"",
	"| producer key | channel | backends | process observed today | implementation |",
	"| --- | --- | --- | --- | --- |",
	(.producers[] | "| `" + .producer_key + "` | `" + .channel + "` | " +
		([.backends[] | "`" + . + "`"] | join(", ")) + " | " +
		(.current_process_observation.status | esc) + " | **" + .implementation_status + "** |"),
	"",
	"## Contracts",
	"",
	(.producers[] |
		"### `" + .producer_key + "`",
		"",
		"| field | value |",
		"| --- | --- |",
		"| runner | `" + .runner + "` |",
		"| channel | `" + .channel + "` |",
		"| native report | `" + .native_report + "` |",
		"| backends | " + ([.backends[] | "`" + . + "`"] | join(", ")) + " |",
		"| backend selection | " + (.backend_selection | esc) + " |",
		"| current process observation | **" + (.current_process_observation.status | esc) + "** — " +
			((.current_process_observation | to_entries | map(select(.key != "status")) | map(.value | tostring) | join(" ")) | esc) + " |",
		"| current report observation | proves **" + (.current_report_observation.proves | esc) + "** when " +
			(.current_report_observation.condition | esc) + ". Does NOT prove: " +
			(.current_report_observation.does_not_prove | esc) + " |",
		"| upstream exit semantics | **" + (.upstream_exit_semantics.status | esc) + "** — " +
			((.upstream_exit_semantics | to_entries | map(select(.key != "status")) | map(.key + ": " + (.value | tostring)) | join("; ")) | esc) + " |",
		"| normative completion requirement | " + (.normative_completion_requirement | esc) + " |",
		"| timeout handling | " + (.timeout_handling | tostring | esc) + " |",
		"| signal handling | " + (.signal_handling | tostring | esc) + " |",
		"| partial reports possible | " + (.partial_reports_possible | tostring) + " |",
		"| report finalization | " + (.report_finalization_condition | tostring | esc) + " |",
		"| analyzed scope identity | " + (.analyzed_scope_identity | tostring | esc) + " |",
		"| configuration identity | " + (.configuration_identity | tostring | esc) + " |",
		"| target/commit binding | " + (.target_commit_binding | tostring | esc) + " |",
		"| execution record | " + (.execution_record | tostring | esc) + " |",
		"| record/report binding | " + (.record_report_binding | tostring | esc) + " |",
		"| behaviour with no observation | " + (.no_observation_behavior | tostring | esc) + " |",
		"| enforcing-mode requirement | " + (.enforcing_mode_requirement | tostring | esc) + " |",
		"| implementation status | **" + .implementation_status + "** |",
		"| residual gap | " + (.residual_gap | esc) + " |",
		"")
	' "$SRC"
}

# Exactly two accepted forms. Any other argument is refused BEFORE anything is written, so a
# typo cannot silently regenerate or truncate the document.
case "${1:-}" in
"")      : ;;
--check) render; exit 0 ;;
*)       echo "usage: render-producer-contracts.sh [--check]" >&2; exit 2 ;;
esac
[ $# -le 1 ] || { echo "usage: render-producer-contracts.sh [--check]" >&2; exit 2; }

# Render to a temporary file and replace atomically. A failed render must leave the existing
# document byte-identical rather than truncating it, which `render > "$OUT"` would do.
_tmp="$OUT.tmp.$$"
if ! render > "$_tmp" 2>/dev/null; then
	rm -f "$_tmp"
	echo "render failed; $OUT left unchanged" >&2
	exit 1
fi
if [ ! -s "$_tmp" ]; then
	rm -f "$_tmp"
	echo "render produced an empty document; $OUT left unchanged" >&2
	exit 1
fi
mv "$_tmp" "$OUT"
echo "wrote $OUT"
