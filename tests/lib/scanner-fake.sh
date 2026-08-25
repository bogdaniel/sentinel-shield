# shellcheck shell=sh
# Sentinel Shield test helper — the reusable executable-fake harness (#96-#105).
#
# WHY ONE HARNESS AND NOT TEN SUITES
#
# The batch needs every scanner adapter checked against the same lifecycle matrix. Hand-authoring
# that per scanner would reproduce, in the tests, exactly the duplication the shared lifecycle was
# built to remove -- ten near-identical suites drifting apart the moment one is edited.
#
# So the matrix is DATA-DRIVEN from config/scanner-contracts.json, and this file turns a table row
# into a real executable fake on PATH. The fake reproduces the tool's DOCUMENTED exit codes and
# native output shapes; it never simulates the adapter under test.
#
# NO NETWORK, EVER. Deterministic production tests must not depend on a registry, a vulnerability
# database or an API being reachable. The fakes make the documented behaviour reproducible offline.

[ -n "${SS_SCANNER_FAKE_SH:-}" ] && return 0
SS_SCANNER_FAKE_SH=1

# sf_make <workdir> <binary> <writes> <mode> <payload> <findings_exit>
#
# writes:  file-argument   the tool writes the report to a path given in its arguments
#          stdout          the tool prints the report on stdout
#          stdout-ndjson   the tool streams newline-delimited JSON on stdout
# mode:    clean | findings | malformed | fail | hang | empty-object
sf_make() {
	_sf_dir=${1:?sf_make: workdir}; _sf_bin=${2:?sf_make: binary}; _sf_writes=${3:?sf_make: writes}
	_sf_mode=${4:?sf_make: mode}; _sf_payload=${5-}; _sf_fexit=${6:-1}
	mkdir -p "$_sf_dir/bin"
	_sf_path="$_sf_dir/bin/$_sf_bin"
	{
		printf '#!/bin/sh\n'
		printf '# executable fake for %s (mode=%s) — reproduces documented exits and native shapes\n' "$_sf_bin" "$_sf_mode"
		case "$_sf_mode" in
		dbfail)
			printf 'printf "%%s\\n" "%s: FATAL: vulnerability database unavailable" >&2\nexit 4\n' "$_sf_bin" ;;
		apifail)
			printf 'printf "%%s\\n" "%s: API rate limit exceeded (403)" >&2\nexit 5\n' "$_sf_bin" ;;
		fail)
			printf 'printf "%%s\\n" "%s: operational failure (database unreachable)" >&2\n' "$_sf_bin"
			printf 'exit 2\n' ;;
		hang)
			# Records its start before blocking: a timeout assertion that cannot show the child
			# ran is proving nothing about the boundary.
			printf 'printf "started\\n" > "%s/child-started"\nwhile : ; do sleep 1; done\n' "$_sf_dir" ;;
		*)
			# The payload is delivered exactly as the real tool would: to a file argument, or on
			# stdout. `--version` is answered first so the adapter's version probe succeeds.
			printf 'case "${1:-}" in --version|version|-v) printf "%s 9.9.9\\n" "%s"; exit 0 ;; esac\n' '%s' "$_sf_bin"
			# THE PAYLOAD IS A HEREDOC, not a quoted assignment. A single-quoted assignment
			# silently truncates any MULTI-LINE payload: the second line becomes a command in
			# the generated fake. That defect made a truncated NDJSON stream look like one valid
			# record, so tests/prod/310's stream cases passed for entirely the wrong reason.
			# A quoted delimiter keeps the body literal, newlines and all.
			printf "_payload=\$(cat <<'SSFAKEPAYLOAD'\n%s\nSSFAKEPAYLOAD\n)\n" "$_sf_payload"
			case "$_sf_writes" in
			file-argument)
				# Find the output path among the arguments the way each tool accepts it.
				printf '_out=""\nfor _a in "$@"; do case "$_a" in spdx-json=*) _out=${_a#spdx-json=} ;; esac; done\n'
				printf '_prev=""\nfor _a in "$@"; do case "$_prev" in -o|--output|-f) _out=$_a ;; esac; _prev=$_a; done\n'
				# `syft -o "spdx-json=PATH"` puts the format AND the path in one -o value, so the
				# generic -o handler above captures the whole token. Strip the format prefix
				# rather than reordering the loops, which would break tools that use plain -o.
				printf '_out=${_out#spdx-json=}\n'
				printf '[ -n "$_out" ] || _out=%s\n' "'/dev/stdout'"
				printf 'printf "%%s" "$_payload" > "$_out"\n' ;;
			*)
				printf 'printf "%%s" "$_payload"\n' ;;
			esac
			case "$_sf_mode" in
			findings) printf 'exit %s\n' "$_sf_fexit" ;;
			*)        printf 'exit 0\n' ;;
			esac ;;
		esac
	} > "$_sf_path"
	chmod +x "$_sf_path"
	printf '%s' "$_sf_path"
}

# sf_project <workdir> — a throwaway project tree with reports/ and reports/raw/ present.
sf_project() {
	_sf_p="${1:?sf_project: workdir}/proj"
	mkdir -p "$_sf_p/reports/raw"
	printf '%s' "$_sf_p"
}

# sf_plant_stale <project> <output-path> — leave a previous report AND provenance on disk, so a
# run that fails can be observed either removing them or leaving them to masquerade as current.
sf_plant_stale() {
	_sf_pr=${1:?}; _sf_out=${2:?}
	mkdir -p "$_sf_pr/$(dirname "$_sf_out")"
	printf '{"stale":"PREVIOUS-RUN-MUST-NOT-SURVIVE"}' > "$_sf_pr/$_sf_out"
	printf '{"stale":"PREVIOUS-PROVENANCE"}' > "$_sf_pr/${_sf_out%.json}.provenance.json"
}

# sf_stale_survived <project> <output-path> — 0 when the planted report is still current.
sf_stale_survived() {
	[ -f "$1/$2" ] && grep -q 'PREVIOUS-RUN-MUST-NOT-SURVIVE' "$1/$2" 2>/dev/null
}

# sf_state <project> <output-path> — the recorded completion state, or "none".
sf_state() {
	_sf_p="$1/${2%.json}.provenance.json"
	[ -f "$_sf_p" ] || { printf 'none'; return 0; }
	jq -r '.completion.state // "none"' "$_sf_p" 2>/dev/null || printf 'unreadable'
}

# sf_temp_left <project> — count of workspaces the adapter failed to clean up.
sf_temp_left() { find "$1" -name '.ss-tmp.*' 2>/dev/null | wc -l | tr -d ' '; }

# sf_run <project> <fakebin-dir> <adapter> <output> [env...] — run an adapter with ONLY the fake
# on PATH plus the minimal system utilities, so a real installed scanner cannot answer instead.
sf_run() {
	_sf_pr=${1:?}; _sf_bd=${2:?}; _sf_ad=${3:?}; _sf_out=${4:?}; shift 4
	( cd "$_sf_pr" || exit 1
	  PATH="$_sf_bd:/usr/bin:/bin:/usr/sbin:/sbin"
	  export PATH
	  for _sf_e in "$@"; do export "${_sf_e?}"; done
	  sh "$_sf_ad" "$_sf_out" >/dev/null 2>&1 )
	return $?
}

# sf_watchdog <marker-file> <seconds> <cmd> [args...]
#
# CONTAINMENT ONLY, NEVER EVIDENCE. There is no timeout(1) on every supported host, so this runs
# the command in the background with a killer alongside it. If the killer fires it TOUCHES the
# marker, so a test can tell "the internal scanner-version timeout worked" from "the outer
# watchdog rescued a hang". A case that reaches the watchdog is a FAILURE: the marker existing is
# what proves the internal bound did not fire.
#
# Returns the command's own status, or 137 when the watchdog killed it.
sf_watchdog() {
	_sw_marker=${1:?sf_watchdog: marker}; _sw_secs=${2:?sf_watchdog: seconds}
	shift 2
	rm -f "$_sw_marker" 2>/dev/null || :
	"$@" & _sw_pid=$!
	( sleep "$_sw_secs"
	  if kill -0 "$_sw_pid" 2>/dev/null; then
		: > "$_sw_marker"
		# Kill the whole group where the shell supports it, so a hung child dies with its wrapper.
		kill -KILL "-$_sw_pid" 2>/dev/null || kill -KILL "$_sw_pid" 2>/dev/null || :
	  fi ) & _sw_killer=$!
	wait "$_sw_pid" 2>/dev/null; _sw_rc=$?
	kill "$_sw_killer" 2>/dev/null || :
	wait "$_sw_killer" 2>/dev/null || :
	return "$_sw_rc"
}

# sf_watchdog_fired <marker-file> — 0 when the outer watchdog had to intervene.
sf_watchdog_fired() { [ -f "$1" ]; }

# sf_make_version_hang <workdir> <binary> <writes> <payload> <findings_exit>
#
# A fake that answers the SCAN normally but HANGS on its version probe, recording the exact argv
# it was asked for. This is the shape that exposed the unbounded-probe regression: the scan stage
# was bounded and the version stage was not.
sf_make_version_hang() {
	_vh_dir=${1:?}; _vh_bin=${2:?}; _vh_writes=${3:?}; _vh_pay=${4-}; _vh_fx=${5:-1}
	sf_make "$_vh_dir" "$_vh_bin" "$_vh_writes" clean "$_vh_pay" "$_vh_fx" >/dev/null
	_vh_path="$_vh_dir/bin/$_vh_bin"
	{
		printf '#!/bin/sh\n'
		printf '# fake %s: normal scan, HANGING version probe (records the argv it received)\n' "$_vh_bin"
		printf 'case "${1:-}" in\n'
		printf '  --version|version|-v)\n'
		printf '    printf "%%s\\n" "$@" > "%s/version-argv"\n' "$_vh_dir"
		printf '    printf "entered\\n" > "%s/version-entered"\n' "$_vh_dir"
		printf '    while : ; do sleep 1; done ;;\n'
		printf 'esac\n'
		tail -n +3 "$_vh_path"
	} > "$_vh_path.new"
	mv -f "$_vh_path.new" "$_vh_path"; chmod +x "$_vh_path"
	printf '%s' "$_vh_path"
}

# sf_make_version_fail <workdir> <binary> <writes> <payload> <findings_exit> — version probe
# exits non-zero WITHOUT hanging, so "failed probe" stays distinguishable from "timed-out probe".
sf_make_version_fail() {
	_vf_dir=${1:?}; _vf_bin=${2:?}; _vf_writes=${3:?}; _vf_pay=${4-}; _vf_fx=${5:-1}
	sf_make "$_vf_dir" "$_vf_bin" "$_vf_writes" clean "$_vf_pay" "$_vf_fx" >/dev/null
	_vf_path="$_vf_dir/bin/$_vf_bin"
	{
		printf '#!/bin/sh\n'
		printf 'case "${1:-}" in\n'
		printf '  --version|version|-v)\n'
		printf '    printf "%%s\\n" "$@" > "%s/version-argv"\n' "$_vf_dir"
		printf '    printf "probe failed\\n" >&2; exit 3 ;;\n'
		printf 'esac\n'
		tail -n +3 "$_vf_path"
	} > "$_vf_path.new"
	mv -f "$_vf_path.new" "$_vf_path"; chmod +x "$_vf_path"
	printf '%s' "$_vf_path"
}
