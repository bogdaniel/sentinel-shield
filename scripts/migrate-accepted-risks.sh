#!/bin/sh
# Sentinel Shield — explicit accepted-risk migration, legacy (v1 / v1.1) -> schema v2.
#
# Accepted risks are EXECUTABLE POLICY: a record can stop a gate from failing. So this tool
# never rewrites a consumer's file in place, never guesses a value, and never invents an
# approval. It reads a legacy file, reports every transformation, and writes a NEW file that
# it validates before the caller sees it.
#
# What it will NOT do, by design:
#   * invent `approved_at` — an approval date is the record of a human decision, and a
#     migration that manufactures one launders unapproved suppression into approved policy.
#     Records lacking one migrate as `status: pending` (they suppress nothing) and are listed
#     as needing human completion;
#   * resolve an ambiguous record — one whose narrowing fields cannot be mapped without a
#     judgement call is refused, named, and left to a person;
#   * touch the source file.
#
# Usage:
#   migrate-accepted-risks.sh --input <legacy.json> --output <v2.json> [--force] [--dry-run]
#   migrate-accepted-risks.sh --input <legacy.json> --report          # what would change
#
# Exit: 0 migrated (or dry-run clean) · 1 manual intervention required · 2 invalid invocation
#       or unusable input · 3 required tool unavailable.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/control-waivers.sh
. "$SCRIPT_DIR/lib/control-waivers.sh"

INPUT=""; OUTPUT=""; FORCE=0; DRY=0; REPORT=0
usage() {
	printf 'Usage: migrate-accepted-risks.sh --input <legacy.json> --output <v2.json> [--force] [--dry-run]\n'
	printf '       migrate-accepted-risks.sh --input <legacy.json> --report\n'
}
while [ $# -gt 0 ]; do
	case "$1" in
		--input) INPUT="${2:?--input requires a value}"; shift 2 ;;
		--output) OUTPUT="${2:?--output requires a value}"; shift 2 ;;
		--force) FORCE=1; shift ;;
		--dry-run) DRY=1; shift ;;
		--report) REPORT=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

command_exists jq || { log_error "jq is required"; exit 3; }
ss_have_sha256 || { log_error "a SHA-256 tool (sha256sum/shasum) is required to record the source digest"; exit 3; }
[ -n "$INPUT" ] || { log_error "--input is required"; usage >&2; exit 2; }
[ -f "$INPUT" ] || { log_error "--input not found: $INPUT"; exit 2; }
[ -L "$INPUT" ] && { log_error "--input is a symlink: $INPUT (refusing to read policy through a link)"; exit 2; }
[ -s "$INPUT" ] || { log_error "--input is empty: $INPUT"; exit 2; }
if [ "$REPORT" -eq 0 ] && [ "$DRY" -eq 0 ]; then
	[ -n "$OUTPUT" ] || { log_error "--output is required (this tool never rewrites the input in place)"; usage >&2; exit 2; }
fi
if [ -n "$OUTPUT" ] && [ "$OUTPUT" = "$INPUT" ]; then
	log_error "--output must differ from --input: the source is preserved until the migrated file validates"
	exit 2
fi

jq -e . "$INPUT" >/dev/null 2>&1 || { log_error "--input is not valid JSON: $INPUT"; exit 2; }

# The source is read ONCE and pinned by digest, so a file edited mid-migration is detected
# rather than half-consumed.
SRC_DIGEST=$(ss_sha256_file "$INPUT") || { log_error "could not hash the input"; exit 2; }
TMPSRC=$(mktemp) || exit 2
trap 'rm -f -- "$TMPSRC" ${TMPOUT:+"$TMPOUT"} 2>/dev/null || true' EXIT INT TERM HUP
cp -- "$INPUT" "$TMPSRC" || { log_error "could not read the input"; exit 2; }
_recheck=$(ss_sha256_file "$TMPSRC") || { log_error "could not hash the input copy"; exit 2; }
[ "$_recheck" = "$SRC_DIGEST" ] || { log_error "the input changed while it was being read — re-run when it is stable"; exit 2; }

SRC_VERSION=$(jq -r '(.version // "") | tostring' "$TMPSRC")
case "$SRC_VERSION" in
	1 | 1.1) : ;;
	2) log_error "'$INPUT' already declares schema version \"2\" — nothing to migrate"; exit 2 ;;
	"") log_error "'$INPUT' declares no schema version; the version selects how it is read and is never inferred"; exit 2 ;;
	*) log_error "'$INPUT' declares unsupported schema version \"$SRC_VERSION\" (legacy \"1\" or \"1.1\" expected)"; exit 2 ;;
esac

TODAY=$(cw_today_utc) || { log_error "no trusted UTC date available"; exit 3; }

# --- classify every record ----------------------------------------------------------------
# Emitted per record: <id>|<disposition>|<detail>
#   ok            migrates unchanged in meaning
#   pending       approved but with no authorisation date -> migrates as pending
#   manual        cannot be migrated without a human decision
CLASSIFY=$(jq -r '
	def known: ["id","gate","scope","status","owner","reason","mitigation","created_at",
		"approved_at","expires_at","review_at","approved_by","severity","category","scanner",
		"rule_id","rule_ids","files","components","fingerprints","finding_id","issue",
		"incident","emergency","supersedes"];
	(.risks // []) | to_entries[]
	| .key as $i | .value as $r
	| (($r.id // "") | tostring) as $rid
	| if ($r | type) != "object" then "\($i)|manual|record is not an object"
	  elif ($rid | length) == 0 then "\($i)|manual|record has no id; an identity cannot be invented"
	  elif ([ $r | keys[] | select(. as $k | known | index($k) | not) ] | length) > 0 then
		"\($rid)|manual|carries field(s) v2 does not define: \([ $r | keys[] | select(. as $k | known | index($k) | not) ] | join(" ")) — decide whether each was meant to narrow this record (rename it) or is metadata (move it under extensions)"
	  elif (($r.status // "") | length) == 0 then "\($rid)|manual|no status"
	  elif (([ "pending","approved","rejected","expired","superseded" ] | index($r.status)) | not) then
		"\($rid)|manual|unknown status \"\($r.status)\""
	  elif (($r.expires_at // "") | length) == 0 then "\($rid)|manual|no expires_at"
	  elif ($r.status == "approved") and ((($r.approved_at // "") | length) == 0) then
		"\($rid)|pending|approved with no approved_at — migrated as pending; a human must record when it was authorised"
	  else "\($rid)|ok|" end' "$TMPSRC" 2>/dev/null) || {
	log_error "could not read the legacy records"; exit 2; }

MANUAL=$(printf '%s\n' "$CLASSIFY" | awk -F'|' '$2 == "manual"')
PENDING=$(printf '%s\n' "$CLASSIFY" | awk -F'|' '$2 == "pending"')
# `printf '%s\n' ""` yields one empty line, so `grep -c ''` reports 1 for "nothing".
# Count non-empty lines instead.
nlines() { printf '%s\n' "$1" | grep -c '[^[:space:]]' || true; }
OKC=$(nlines "$(printf '%s\n' "$CLASSIFY" | awk -F'|' '$2 == "ok"')")

printf 'accepted-risk migration report\n'
printf '  source:        %s (schema %s)\n' "$INPUT" "$SRC_VERSION"
printf '  source digest: %s\n' "$SRC_DIGEST"
printf '  records:       %s\n' "$(jq '(.risks // []) | length' "$TMPSRC")"
printf '  migrate as-is: %s\n' "$OKC"
printf '  -> pending:    %s\n' "$(nlines "$PENDING")"
printf '  need a human:  %s\n' "$(nlines "$MANUAL")"
if [ -n "$PENDING" ]; then
	printf '\nTransformed (approval NOT invented):\n'
	printf '%s\n' "$PENDING" | while IFS='|' read -r _id _d _why; do
		[ -n "$_id" ] || continue
		printf '  %-24s status: approved -> pending\n' "$_id"
		printf '  %-24s reason: %s\n' "" "$_why"
	done
fi
if [ -n "$MANUAL" ]; then
	printf '\nManual intervention required:\n'
	printf '%s\n' "$MANUAL" | while IFS='|' read -r _id _d _why; do
		[ -n "$_id" ] || continue
		printf '  %-24s %s\n' "$_id" "$_why"
	done
fi

if [ -n "$MANUAL" ]; then
	printf '\n'
	log_error "migration refused: $(nlines "$MANUAL") record(s) cannot be migrated without a human decision. Nothing was written; '$INPUT' is unchanged."
	exit 1
fi

[ "$REPORT" -eq 1 ] && { printf '\nreport only; nothing written\n'; exit 0; }

# --- build the v2 document ----------------------------------------------------------------
# Deterministic: records keep their input order, keys are emitted in a fixed order, and the
# only added values are the migration provenance and the pending downgrade.
TMPOUT=$(mktemp) || exit 2
jq --arg today "$TODAY" --arg srcv "$SRC_VERSION" --arg dig "$SRC_DIGEST" \
	--arg ts "$(timestamp_utc)" '
	def clean: with_entries(select(.value != null and .value != ""));
	{
		version: "2",
		generated_at: $ts,
		migrated_from: { source_version: $srcv, migrated_at: $ts, source_digest: $dig,
			tool: "migrate-accepted-risks.sh" },
		risks: [ (.risks // [])[]
			| . as $r
			# An approved record with no authorisation date becomes PENDING: it suppresses
			# nothing until a human records when it was approved.
			| (if ($r.status == "approved") and ((($r.approved_at // "") | length) == 0)
			   then "pending" else $r.status end) as $st
			| {
				id: $r.id,
				gate: $r.gate,
				scope: ($r.scope // "finding"),
				status: $st,
				owner: $r.owner,
				reason: $r.reason,
				mitigation: $r.mitigation,
				created_at: ($r.created_at // $r.approved_at // $r.expires_at),
				approved_at: $r.approved_at,
				expires_at: $r.expires_at,
				review_at: $r.review_at,
				approval: (if ($r.approved_by // "") != "" then
					{ approved_by: $r.approved_by, authority: "migrated-from-legacy-record" }
					else null end),
				severity: $r.severity,
				category: $r.category,
				scanner: $r.scanner,
				rule_id: $r.rule_id,
				rule_ids: $r.rule_ids,
				files: $r.files,
				components: $r.components,
				fingerprints: $r.fingerprints,
				finding_id: $r.finding_id,
				issue: $r.issue,
				incident: $r.incident,
				emergency: $r.emergency,
				supersedes: $r.supersedes
			  } | clean ]
	}' "$TMPSRC" > "$TMPOUT" || { log_error "could not build the migrated document"; exit 2; }

# The migrated document must itself be valid before anyone sees it.
jq -e '(.version == "2") and ((.risks | type) == "array")' "$TMPOUT" >/dev/null 2>&1 \
	|| { log_error "the migrated document failed its own validation; nothing was written"; exit 2; }
_lost=$(( $(jq '(.risks // []) | length' "$TMPSRC") - $(jq '(.risks // []) | length' "$TMPOUT") ))
[ "$_lost" -eq 0 ] || { log_error "the migration would drop $_lost record(s); refusing"; exit 2; }

if [ "$DRY" -eq 1 ]; then
	printf '\n--- migrated document (dry run; nothing written) ---\n'
	cat "$TMPOUT"
	exit 0
fi

# --- publish ------------------------------------------------------------------------------
if [ -e "$OUTPUT" ] || [ -L "$OUTPUT" ]; then
	[ "$FORCE" -eq 1 ] || { log_error "--output already exists: $OUTPUT (pass --force to replace it)"; exit 2; }
	[ -L "$OUTPUT" ] && { log_error "--output is a symlink: $OUTPUT (refusing to write policy through a link)"; exit 2; }
	[ -f "$OUTPUT" ] || { log_error "--output exists and is not a regular file: $OUTPUT"; exit 2; }
fi
_odir=$(dirname -- "$OUTPUT")
[ -d "$_odir" ] || { log_error "output directory does not exist: $_odir"; exit 2; }
_stage=$(mktemp "$_odir/.accepted-risks.migrate.XXXXXX") || { log_error "could not stage the output"; exit 2; }
cat "$TMPOUT" > "$_stage" || { rm -f -- "$_stage"; log_error "could not write the staged output"; exit 2; }
jq -e . "$_stage" >/dev/null 2>&1 || { rm -f -- "$_stage"; log_error "the staged output is not valid JSON"; exit 2; }
chmod 644 "$_stage" 2>/dev/null || true
mv -- "$_stage" "$OUTPUT" || { rm -f -- "$_stage"; log_error "could not publish the migrated file"; exit 2; }

printf '\n'
log_info "migrated: $INPUT (schema $SRC_VERSION) -> $OUTPUT (schema 2)"
log_info "the source file is unchanged; review the result, then point --accepted-risks at it"
if [ -n "$PENDING" ]; then
	log_warn "$(nlines "$PENDING") record(s) migrated as PENDING and suppress nothing until a human records their approval date"
	exit 1
fi
exit 0
