#!/bin/sh
# Sentinel Shield production test — the scanner conformance matrix (#96-#105).
#
# LAYER 2 OF THREE, TABLE-DRIVEN.
#
# Ten adapters, five scenarios, one suite. Every expected state is read from
# config/scanner-contracts.json rather than written here, so a scanner whose semantics differ
# declares that in its row instead of forking a test body. Onboarding a scanner is a table row.
#
# WHAT THIS SUITE DOES NOT DO. It does not re-prove the shared lifecycle -- tests/prod/308 does
# that once, through a probe adapter with a one-field validator. Here the only lifecycle claim is
# that each real adapter PARTICIPATES in it. Nor does it prove tool-specific semantics: that a
# Grype image reference is refused, or that OSV separates no-targets from clean, is Layer 3's job
# (tests/prod/310). A matrix that claimed those would be claiming coverage it does not exercise.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
. "$ROOT/tests/lib/assert.sh"
. "$ROOT/tests/lib/scanner-fake.sh"
TABLE="$ROOT/config/scanner-contracts.json"

assert_precondition "jq is available" command -v jq
assert_precondition "the contract table exists" test -f "$TABLE"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# ===========================================================================
# MATRIX INTEGRITY, BEFORE ANY SCENARIO RUNS.
#
# A conformance matrix that silently covers nine of ten rows, or exercises one scanner twice under
# two names, reports success while proving less than it claims. Each defect below is refused.
# ===========================================================================
ROWS=$(jq -r '.scanners | length' "$TABLE")
assert_true "the table declares at least one scanner row (rows=$ROWS)" test "$ROWS" -gt 0

_dupes=$(jq -r '[.scanners[].tool] | group_by(.) | map(select(length > 1) | .[0]) | join(" ")' "$TABLE")
assert_equal "producer keys are unique — no row can shadow another" "" "$_dupes"

_dup_out=$(jq -r '[.scanners[].output] | group_by(.) | map(select(length > 1) | .[0]) | join(" ")' "$TABLE")
assert_equal "no two rows publish to the same output path" "" "$_dup_out"

_scenarios=$(jq -r '.scenarios | join(" ")' "$TABLE")
assert_true "the table declares the scenario set" test -n "$_scenarios"

# Every row must resolve to a real adapter and a real validator. An unknown validator name would
# make a row's rejection meaningless -- it would fail for being unresolvable, not for its contract.
jq -r '.scanners[] | [.tool, .adapter, .validator, .binary, .output] | @tsv' "$TABLE" > "$TMP/rows"
_bad_adapter=""; _bad_validator=""; _n_rows=0
while IFS="$(printf '\t')" read -r _tool _adapter _validator _binary _output; do
	[ -n "$_tool" ] || continue
	_n_rows=$((_n_rows + 1))
	[ -f "$ROOT/$_adapter" ] || _bad_adapter="$_bad_adapter $_tool:$_adapter"
	grep -qE "^$_validator\(\)" "$ROOT/scripts/lib/scanner-contracts.sh" || _bad_validator="$_bad_validator $_tool:$_validator"
done < "$TMP/rows"
assert_equal "every row resolves to an adapter that exists" "" "$_bad_adapter"
assert_equal "every row resolves to a declared tool-specific validator" "" "$_bad_validator"
assert_equal "every declared row was read" "$ROWS" "$_n_rows"

# Each adapter must actually use the shared transaction. Without this a row could pass the matrix
# with a private lifecycle of its own, which is the duplication this batch removed.
_not_shared=""
while IFS="$(printf '\t')" read -r _tool _adapter _rest; do
	[ -n "$_tool" ] || continue
	grep -q 'scanner-transaction.sh' "$ROOT/$_adapter" || _not_shared="$_not_shared $_tool"
done < "$TMP/rows"
assert_equal "every adapter participates in the shared transaction" "" "$_not_shared"

# ===========================================================================
# THE MATRIX. Every row, every scenario, expectations read from the row.
# ===========================================================================
EXERCISED="$TMP/exercised"; : > "$EXERCISED"
_matrix_fail=0

while IFS="$(printf '\t')" read -r TOOL ADAPTER VALIDATOR BINARY OUTPUT; do
	[ -n "$TOOL" ] || continue
	CLEAN=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .fakes.clean' "$TABLE")
	FIND=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .fakes.findings' "$TABLE")
	MALF=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .fakes.malformed' "$TABLE")
	WRITES=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .writes' "$TABLE")
	FEXIT=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .findings_exit' "$TABLE")

	for SCEN in clean findings malformed fail missing; do
		WANT=$(jq -r --arg t "$TOOL" --arg s "$SCEN" '.scanners[] | select(.tool==$t) | .expected[$s]' "$TABLE")
		D="$TMP/$TOOL-$SCEN"
		P=$(sf_project "$D")
		case "$SCEN" in
		clean)     PAY="$CLEAN" ;;
		findings)  PAY="$FIND" ;;
		malformed) PAY="$MALF" ;;
		*)         PAY="" ;;
		esac
		if [ "$SCEN" = "missing" ]; then mkdir -p "$D/bin"; else sf_make "$D" "$BINARY" "$WRITES" "$SCEN" "$PAY" "$FEXIT" >/dev/null; fi
		# Row-declared setup and environment: a scanner needing a policy directory or an image ref
		# says so in the table rather than in a special case here.
		for _f in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .setup_files[]?' "$TABLE"); do
			mkdir -p "$P/$(dirname "$_f")"; printf 'package main\n' > "$P/$_f"
		done
		set -- ; for _e in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .env[]?' "$TABLE"); do set -- "$@" "$_e"; done
		sf_plant_stale "$P" "$OUTPUT"
		sf_run "$P" "$D/bin" "$ROOT/$ADAPTER" "$OUTPUT" "$@" || :

		GOT=$(sf_state "$P" "$OUTPUT")
		# Every diagnostic names the producer key AND the scenario, so a matrix failure is
		# attributable without re-running anything.
		assert_equal "[$TOOL/$SCEN] reaches the state its contract row declares" "$WANT" "$GOT"
		assert_false "[$TOOL/$SCEN] stale evidence does not survive" sf_stale_survived "$P" "$OUTPUT"
		assert_equal "[$TOOL/$SCEN] no owned workspace remains" "0" "$(sf_temp_left "$P")"
		# Only a completed scan may leave a report standing.
		case "$WANT" in
		completed-*) assert_true  "[$TOOL/$SCEN] a completed scan publishes its report" test -f "$P/$OUTPUT" ;;
		*)           assert_false "[$TOOL/$SCEN] a non-completed state publishes nothing" test -f "$P/$OUTPUT" ;;
		esac
		printf '%s\n' "$TOOL" >> "$EXERCISED"
	done

	# HOST ISOLATION, per row. With no fake present the adapter must report unavailable — never a
	# result obtained from a scanner that happens to be installed on this machine. This is asserted
	# per row because it has already gone wrong twice during this batch.
	D="$TMP/$TOOL-hostiso"; P=$(sf_project "$D"); mkdir -p "$D/bin"
	set -- ; for _e in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .env[]?' "$TABLE"); do set -- "$@" "$_e"; done
	sf_run "$P" "$D/bin" "$ROOT/$ADAPTER" "$OUTPUT" "$@" || :
	_iso=$(sf_state "$P" "$OUTPUT")
	assert_false "[$TOOL/host-isolation] no result is obtained from a host-installed scanner" \
		test "$_iso" = "completed-clean" -o "$_iso" = "completed-findings"
done < "$TMP/rows"

# ===========================================================================
# COVERAGE: the matrix must have exercised every declared row. A row added to the table and never
# run would otherwise sit there looking like coverage.
# ===========================================================================
_ex_rows=$(sort -u "$EXERCISED" | grep -c . || true)
assert_equal "every declared contract row was exercised by the matrix" "$ROWS" "$_ex_rows"
_ex_runs=$(grep -c . "$EXERCISED" || true)
assert_equal "every row ran the full scenario set" "$((ROWS * 5))" "$_ex_runs"

# A row cannot accidentally exercise another scanner: each adapter's published path is the one its
# own row declares, and no two rows share a path (asserted above).
_wrong_path=""
while IFS="$(printf '\t')" read -r _tool _adapter _v _b _out; do
	[ -n "$_tool" ] || continue
	grep -qF "$_out" "$ROOT/$_adapter" || _wrong_path="$_wrong_path $_tool"
done < "$TMP/rows"
assert_equal "each adapter names its own row's output path" "" "$_wrong_path"

# ===========================================================================
# SCENARIO DIMENSIONS (Cluster B).
#
# 308 owns the exhaustive shared mechanics. These prove that the adapters whose live criteria
# NAME a scenario actually route through them. Applicability is declared per row, so the matrix
# never claims coverage a scanner's criteria did not ask for.
# ===========================================================================
VOCAB=$(jq -r '.scenario_dimensions.vocabulary | join(" ")' "$TABLE")
assert_true "the scenario vocabulary is declared" test -n "$VOCAB"

# Every declared dimension is in the closed vocabulary, and every vocabulary entry has at least
# one participating row -- a dimension nothing exercises is an empty promise.
_bad_dim=""; _unused=""
for _d in $VOCAB; do
	_n=$(jq -r --arg d "$_d" '[.scanners[] | select(.dimensions | index($d))] | length' "$TABLE")
	[ "$_n" -gt 0 ] || _unused="$_unused $_d"
done
for _d in $(jq -r '.scanners[].dimensions[]' "$TABLE" | sort -u); do
	case " $VOCAB " in *" $_d "*) : ;; *) _bad_dim="$_bad_dim $_d" ;; esac
done
assert_equal "no row declares a dimension outside the vocabulary" "" "$_bad_dim"
assert_equal "no vocabulary dimension has zero participating rows" "" "$_unused"
_dupdim=$(jq -r '[.scanners[] | select((.dimensions | length) != (.dimensions | unique | length)) | .tool] | join(" ")' "$TABLE")
assert_equal "no row declares a duplicate dimension" "" "$_dupdim"

DIM_RUN="$TMP/dims-run"; : > "$DIM_RUN"

# --- version probe: bounded, and never decisive ------------------------------------
#
# THE REGRESSION THIS CAUGHT. Master's grype.sh bounded its version probe through bp_run --
# "a hung binary can no longer stall the scan indefinitely". Migrating ten adapters onto the
# shared transaction bounded the SCAN and left the probe a plain command substitution, so a
# binary hanging on --version stalled the adapter before st_execute was ever reached. This
# dimension found it by hanging, and a leftover process argv confirmed it:
#   /bin/sh .../dim-to-syft/bin/syft --version
#
# The OUTER WATCHDOG IS CONTAINMENT, NOT EVIDENCE. If it fires, the internal scanner-version
# bound did not, and that is a failure -- asserted explicitly below.
VERSION_WD=8
jq -r '.scanners[] | select(.dimensions | index("timeout")) | [.tool,.adapter,.binary,.output,.writes,(.fakes.clean)] | @tsv' "$TABLE" > "$TMP/dim-timeout"
while IFS="$(printf '\t')" read -r TOOL ADAPTER BINARY OUTPUT WRITES CLEAN; do
	[ -n "$TOOL" ] || continue
	D="$TMP/vp-$TOOL"; P=$(sf_project "$D")
	sf_make_version_hang "$D" "$BINARY" "$WRITES" "$CLEAN" 0 >/dev/null
	for _f in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .setup_files[]?' "$TABLE"); do
		mkdir -p "$P/$(dirname "$_f")"; printf 'package main\n' > "$P/$_f"
	done
	set -- ; for _e in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .env[]?' "$TABLE"); do set -- "$@" "$_e"; done
	_uv=$(printf '%s' "$TOOL" | tr '[:lower:]-' '[:upper:]_')
	sf_plant_stale "$P" "$OUTPUT"
	sf_watchdog "$D/wd" "$VERSION_WD" sf_run "$P" "$D/bin" "$ROOT/$ADAPTER" "$OUTPUT" "$@" \
		"SENTINEL_SHIELD_${_uv}_TIMEOUT_SECONDS=1" "SENTINEL_SHIELD_SCANNER_VERSION_TIMEOUT_SECONDS=1" || :
	assert_false "[$TOOL/version-timeout] the internal bound fired, not the outer watchdog" \
		sf_watchdog_fired "$D/wd"
	assert_true "[$TOOL/version-timeout] the fake entered version mode" test -f "$D/version-entered"
	assert_true "[$TOOL/version-timeout] the adapter asked for the tool's own version flag" \
		grep -qE '^(--version|version|-v)$' "$D/version-argv"
	_vp=$(jq -r '.scanner.version // "-"' "$P/${OUTPUT%.json}.provenance.json" 2>/dev/null || printf '-')
	assert_equal "[$TOOL/version-timeout] the version is recorded as unknown" "unknown" "$_vp"
	# THE POINT: a version is metadata. Failing to read it must not decide the scan's outcome.
	assert_equal "[$TOOL/version-timeout] the scan still reached its own verdict" \
		"completed-clean" "$(sf_state "$P" "$OUTPUT")"
	assert_equal "[$TOOL/version-timeout] no owned workspace remains" "0" "$(sf_temp_left "$P")"
	printf 'timeout\n' >> "$DIM_RUN"
done < "$TMP/dim-timeout"

# CONTROLS: a probe that succeeds records a version; a probe that FAILS without hanging records
# unknown and still lets the scan proceed -- so "failed" stays distinguishable from "timed out".
VC="$TMP/vc"; VP=$(sf_project "$VC")
_vc_clean=$(jq -r '.scanners[] | select(.tool=="syft") | .fakes.clean' "$TABLE")
sf_make "$VC" syft file-argument clean "$_vc_clean" 0 >/dev/null
sf_run "$VP" "$VC/bin" "$ROOT/scripts/audits/syft.sh" reports/sbom.spdx.json || :
_vc_v=$(jq -r '.scanner.version // "-"' "$VP/reports/sbom.spdx.provenance.json" 2>/dev/null || printf '-')
assert_false "version CONTROL: a successful probe records a real version, not unknown" \
	test "$_vc_v" = "unknown"
VF="$TMP/vf"; VFP=$(sf_project "$VF")
sf_make_version_fail "$VF" syft file-argument "$_vc_clean" 0 >/dev/null
sf_run "$VFP" "$VF/bin" "$ROOT/scripts/audits/syft.sh" reports/sbom.spdx.json || :
_vf_v=$(jq -r '.scanner.version // "-"' "$VFP/reports/sbom.spdx.provenance.json" 2>/dev/null || printf '-')
assert_equal "version CONTROL: a failed (non-hanging) probe records unknown" "unknown" "$_vf_v"
assert_equal "version CONTROL: and the scan still completes" "completed-clean" "$(sf_state "$VFP" reports/sbom.spdx.json)"
# A missing executable is UNAVAILABLE, never a version problem.
VM="$TMP/vm"; VMP=$(sf_project "$VM"); mkdir -p "$VM/bin"
sf_run "$VMP" "$VM/bin" "$ROOT/scripts/audits/syft.sh" reports/sbom.spdx.json || :
assert_equal "version CONTROL: a missing executable is unavailable, not a version failure" \
	"unavailable" "$(sf_state "$VMP" reports/sbom.spdx.json)"

# SOURCE GUARD, supporting evidence only: no adapter may return to an unbounded probe. The
# behavioural rows above are primary; this catches a reintroduction that never gets executed.
_unbounded=""
for _a in $(jq -r '.scanners[].adapter' "$TABLE"); do
	grep -qE '^[[:space:]]*ST_VERSION=\$\(st_probe_version ' "$ROOT/$_a" || _unbounded="$_unbounded $_a"
done
assert_equal "every adapter probes its version through the bounded helper" "" "$_unbounded"

# --- path-spaces: the target survives as ONE argument -------------------------------
# One controlled value carries a space, a tab, a Unicode character and shell metacharacters at
# once: each property is provable from the same argv, and separate cases would only multiply runs
# without improving attribution.
ODD_TARGET='dir with space	tab-é-$(touch /tmp/ss-pwned);|&'
jq -r '.scanners[] | select(.dimensions | index("path-spaces")) | [.tool,.adapter,.binary,.output,.writes] | @tsv' "$TABLE" > "$TMP/dim-path"
while IFS="$(printf '\t')" read -r TOOL ADAPTER BINARY OUTPUT WRITES; do
	[ -n "$TOOL" ] || continue
	D="$TMP/dim-path-$TOOL"; P=$(sf_project "$D")
	CLEAN=$(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .fakes.clean' "$TABLE")
	sf_make "$D" "$BINARY" "$WRITES" clean "$CLEAN" 0 >/dev/null
	# The fake records its argv so the test inspects what the adapter actually passed.
	printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/argv"\n' "$D" > "$D/bin/argv-probe"
	sed -i.bak "2i\\
printf '%s\\\\n' \"\$@\" > \"$D/argv\"
" "$D/bin/$BINARY" 2>/dev/null || :
	rm -f "$D/bin/$BINARY.bak"
	set -- ; for _e in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .env[]?' "$TABLE"); do set -- "$@" "$_e"; done
	_uv=$(printf '%s' "$TOOL" | tr '[:lower:]-' '[:upper:]_')
	case "$TOOL" in
	syft)     set -- "$@" "SENTINEL_SHIELD_SYFT_TARGET=$ODD_TARGET" ;;
	conftest) set -- "$@" "SENTINEL_SHIELD_CONFTEST_TARGET=$ODD_TARGET" ;;
	grype)    set -- "$@" "SENTINEL_SHIELD_GRYPE_TARGET=$ODD_TARGET" "SENTINEL_SHIELD_GRYPE_MODE=fs" ;;
	esac
	for _f in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .setup_files[]?' "$TABLE"); do
		mkdir -p "$P/$(dirname "$_f")"; printf 'package main\n' > "$P/$_f"
	done
	sf_run "$P" "$D/bin" "$ROOT/$ADAPTER" "$OUTPUT" "$@" || :
	if [ -f "$D/argv" ]; then
		assert_true "[$TOOL/path-spaces] the hostile target arrived as ONE argument" \
			grep -qF "$ODD_TARGET" "$D/argv"
		assert_false "[$TOOL/path-spaces] no shell expansion occurred" test -e /tmp/ss-pwned
	else
		assert_true "[$TOOL/path-spaces] the fake recorded an argument vector to inspect" test -f "$D/argv"
	fi
	printf 'path-spaces\n' >> "$DIM_RUN"
done < "$TMP/dim-path"

# --- wrong target: the configured target is what reaches the scanner ------------------
# A scanner that silently examines something other than the requested target produces evidence
# about the wrong subject. The fake records its argv, so the assertion is what the adapter
# actually passed rather than what it intended to pass.
jq -r '.scanners[] | select(.dimensions | index("wrong-target")) | [.tool,.adapter,.binary,.output,.writes,(.fakes.clean)] | @tsv' "$TABLE" > "$TMP/dim-wrongtarget"
while IFS="$(printf '\t')" read -r TOOL ADAPTER BINARY OUTPUT WRITES CLEAN; do
	[ -n "$TOOL" ] || continue
	D="$TMP/dim-wt-$TOOL"; P=$(sf_project "$D")
	sf_make "$D" "$BINARY" "$WRITES" clean "$CLEAN" 0 >/dev/null
	_wt_path="$D/bin/$BINARY"
	{ printf '#!/bin/sh\n'; printf 'printf "%%s\\n" "$@" > "%s/argv"\n' "$D"; tail -n +2 "$_wt_path"; } > "$_wt_path.new"
	mv -f "$_wt_path.new" "$_wt_path"; chmod +x "$_wt_path"
	set -- ; for _e in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .env[]?' "$TABLE"); do set -- "$@" "$_e"; done
	case "$TOOL" in
	syft) set -- "$@" "SENTINEL_SHIELD_SYFT_TARGET=intended-subject-dir" ;;
	esac
	sf_run "$P" "$D/bin" "$ROOT/$ADAPTER" "$OUTPUT" "$@" || :
	assert_true "[$TOOL/wrong-target] the fake recorded the argument vector" test -f "$D/argv"
	assert_true "[$TOOL/wrong-target] the CONFIGURED target reached the scanner" \
		grep -qF 'intended-subject-dir' "$D/argv"
	assert_false "[$TOOL/wrong-target] no different target was substituted" \
		grep -qF 'dir:.' "$D/argv"
	printf 'wrong-target\n' >> "$DIM_RUN"
done < "$TMP/dim-wrongtarget"

# --- operational / database / api failure remain distinct from clean ------------------
for _dim in operational-failure database-failure api-failure; do
	case "$_dim" in operational-failure) _mode=fail ;; database-failure) _mode=dbfail ;; *) _mode=apifail ;; esac
	jq -r --arg d "$_dim" '.scanners[] | select(.dimensions | index($d)) | [.tool,.adapter,.binary,.output,.writes] | @tsv' "$TABLE" > "$TMP/dim-$_dim"
	while IFS="$(printf '\t')" read -r TOOL ADAPTER BINARY OUTPUT WRITES; do
		[ -n "$TOOL" ] || continue
		D="$TMP/dim-$_dim-$TOOL"; P=$(sf_project "$D")
		sf_make "$D" "$BINARY" "$WRITES" "$_mode" "" 0 >/dev/null
		for _f in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .setup_files[]?' "$TABLE"); do
			mkdir -p "$P/$(dirname "$_f")"; printf 'package main\n' > "$P/$_f"
		done
		set -- ; for _e in $(jq -r --arg t "$TOOL" '.scanners[] | select(.tool==$t) | .env[]?' "$TABLE"); do set -- "$@" "$_e"; done
		sf_plant_stale "$P" "$OUTPUT"
		sf_run "$P" "$D/bin" "$ROOT/$ADAPTER" "$OUTPUT" "$@" || :
		_st=$(sf_state "$P" "$OUTPUT")
		# The point of the dimension: a database or API failure must never read as a scan result.
		assert_false "[$TOOL/$_dim] is not reported as a completed scan" \
			test "$_st" = "completed-clean" -o "$_st" = "completed-findings" -o "$_st" = "completed-no-targets"
		assert_false "[$TOOL/$_dim] no report is published" test -f "$P/$OUTPUT"
		printf '%s\n' "$_dim" >> "$DIM_RUN"
	done < "$TMP/dim-$_dim"
done

# Every declared row-dimension pair was actually executed.
_declared_pairs=$(jq -r '[.scanners[] | .dimensions[]] | length' "$TABLE")
_run_pairs=$(grep -c . "$DIM_RUN" || true)
assert_equal "every declared row-dimension pair was executed" "$_declared_pairs" "$_run_pairs"

# ===========================================================================
# THE ABANDONED TRIVY SPELLING CANNOT SATISFY THE EVIDENCE CONTRACT (#99).
#
# scripts/audits/trivy-fs.sh and scripts/audits/trivy-image.sh BOTH defaulted to
# reports/raw/trivy.json, so a filesystem scan and an image scan overwrote each other and no
# consumer could tell which scan it was reading. Three CI workflows wrote fs results there while a
# fourth wrote an image result to the same name. Meanwhile profiles and the scheduled workflow
# expected reports/raw/trivy-fs.json -- a path no producer wrote.
#
# The two scanners now have two paths. These assertions keep it that way.
_fs_out=$(jq -r '.scanners[] | select(.tool=="trivy-fs") | .output' "$TABLE")
assert_equal "the filesystem scanner's canonical path names its scan type" "reports/raw/trivy-fs.json" "$_fs_out"
assert_false "no active producer still writes the ambiguous bare spelling" \
	grep -rq 'reports/raw/trivy\.json' "$ROOT/scripts/audits"
assert_false "no active collector still reads it" \
	grep -rq 'reports/raw/trivy\.json' "$ROOT/scripts/collectors"
assert_false "no profile or workflow still names it" \
	grep -rq 'reports/raw/trivy\.json' "$ROOT/profiles" "$ROOT/.github/workflows" "$ROOT/templates"
# The two Trivy producers must not converge again. A shared path is what made the evidence
# unattributable in the first place.
_img_out=$(grep -oE 'reports/raw/trivy[a-z-]*\.json' "$ROOT/scripts/audits/trivy-image.sh" | head -1)
assert_false "the filesystem and image scanners do not share an output path" test "$_fs_out" = "$_img_out"

assert_summary "scanner-conformance ($ROWS rows x 5 scenarios, expectations derived from the contract table)"
