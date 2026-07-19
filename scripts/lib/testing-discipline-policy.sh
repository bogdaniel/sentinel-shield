#!/bin/sh
# Sentinel Shield — testing-discipline policy loader (POSIX sh, source; do not execute).
#
# Reads a consuming project's .sentinel-shield/testing-discipline-policy.yaml (which TDD
# proxies apply, where production/test/spec/acceptance code lives, whether BDD/ATDD evidence
# is REQUIRED). Same parser strategy as scripts/lib/architecture-policy.sh and
# scripts/lib/quality-policy.sh: mikefarah yq v4 if present, else a limited awk flatten of the
# CANONICAL (2-space, no anchors/flow/block-scalars) format. yq is NOT required.
#
# FAIL CLOSED: when the policy file is EXPLICITLY present but malformed (unparseable YAML,
# advanced YAML the fallback cannot read, a non-boolean known flag, or a present-but-EMPTY
# known field) the loader exits 2. An ABSENT policy is not an error — accessors return the
# caller-supplied default (a runner then uses its documented built-in behavior).
#
# Scope honesty (docs/testing-discipline-governance.md): this policy declares which testing
# discipline EVIDENCE is expected. It cannot prove that developers wrote tests first — TDD is
# a workflow, not a static property of a final code snapshot. What is enforced here are
# PROXIES (production change without test change, changed-line coverage, missing/empty test
# evidence, mutation testing, focused-test guards) plus BDD/ATDD evidence that a suite ran.
#
# Requires scripts/lib/sentinel-shield-common.sh already sourced (log_*, command_exists,
# bool_value).
#
# Usage:
#   . scripts/lib/testing-discipline-policy.sh
#   td_load .sentinel-shield/testing-discipline-policy.yaml
#   td_enabled || echo "testing discipline governance off"
#   td_bool  testing_discipline.tdd.require_test_change_for_production_change true
#   td_list  testing_discipline.tdd.production_paths

TD_FILE=""; TD_FLAT=""; TD_USE_YQ=0; TD_PRESENT=0

# Known BOOLEAN fields — validated at load, fail closed when present-but-empty/non-boolean.
TD_BOOL_KEYS="testing_discipline.enabled \
testing_discipline.tdd.enabled testing_discipline.tdd.require_test_change_for_production_change \
testing_discipline.bdd.enabled testing_discipline.bdd.require_behavior_specs \
testing_discipline.atdd.enabled testing_discipline.atdd.require_acceptance_evidence"

# Known LIST fields — validated at load: a present-but-EMPTY list key fails closed, because
# "production_paths:" with nothing under it would silently classify every file as ignorable.
TD_LIST_KEYS="testing_discipline.tdd.production_paths testing_discipline.tdd.test_paths \
testing_discipline.tdd.ignore_paths testing_discipline.bdd.spec_paths \
testing_discipline.atdd.acceptance_paths"

# td_load <file> — select the parser, validate presence + basic well-formedness.
td_load() {
	TD_FILE="$1"; TD_FLAT=""; TD_USE_YQ=0; TD_PRESENT=0
	[ -n "$TD_FILE" ] && [ -f "$TD_FILE" ] || return 0
	TD_PRESENT=1

	if command_exists yq && yq --version 2>/dev/null | grep -Eq 'mikefarah|version v4'; then
		TD_USE_YQ=1
		yq e '.' "$TD_FILE" >/dev/null 2>&1 || { log_error "testing-discipline-policy: malformed YAML: $TD_FILE"; exit 2; }
		_td_validate
		return 0
	fi

	# Fallback: tabs are illegal YAML indentation; advanced YAML needs mikefarah yq.
	if grep -q "$(printf '\t')" "$TD_FILE" 2>/dev/null; then
		log_error "testing-discipline-policy: tab indentation is not valid YAML: $TD_FILE"; exit 2
	fi
	if grep -v '^[[:space:]]*#' "$TD_FILE" \
		| grep -Eq '(^|[[:space:]])&[A-Za-z0-9_]|:[[:space:]]*\*[A-Za-z0-9_]|:[[:space:]]*[{[]|:[[:space:]]*[|>]([[:space:]]|$)'; then
		log_error "testing-discipline-policy uses advanced YAML (anchors/aliases/inline collections/block scalars). Install mikefarah yq v4 or simplify to the canonical 2-space format: $TD_FILE"
		exit 2
	fi
	# Flatten to `path=value` for scalars and `path.[]=value` for list items, so list-valued
	# policy fields (production_paths, test_paths, …) are readable without yq.
	TD_FLAT=$(awk '
		function joinpath(last,    i, p) {
			p = ""
			for (i = 0; i <= last; i++) { if (stack[i] == "") continue; p = (p == "") ? stack[i] : p "." stack[i] }
			return p
		}
		{
			line = $0
			if (line ~ /^[[:space:]]*#/) next
			if (line ~ /^[[:space:]]*$/) next
			match(line, /^ */); indent = RLENGTH; depth = int(indent / 2)
			content = substr(line, indent + 1)
			if (substr(content, 1, 2) == "- ") {
				val = substr(content, 3)
				sub(/[[:space:]]+#.*$/, "", val); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
				if (length(val) >= 2 && ((substr(val,1,1) == "\"" && substr(val,length(val),1) == "\"") \
				    || (substr(val,1,1) == "'"'"'" && substr(val,length(val),1) == "'"'"'"))) {
					val = substr(val, 2, length(val) - 2)
				}
				print joinpath(depth - 1) ".[]=" val
				next
			}
			ci = index(content, ":")
			if (ci == 0) next
			key = substr(content, 1, ci - 1); val = substr(content, ci + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
			sub(/[[:space:]]+#.*$/, "", val); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
			# Strip ONE layer of matching surrounding quotes so this fallback agrees with yq:
			# `enabled: ""` is an EMPTY value in both parsers (and therefore fails closed as a
			# present-but-empty known field), not the 2-character string `""`.
			if (length(val) >= 2 && ((substr(val,1,1) == "\"" && substr(val,length(val),1) == "\"") \
			    || (substr(val,1,1) == "'"'"'" && substr(val,length(val),1) == "'"'"'"))) {
				val = substr(val, 2, length(val) - 2)
			}
			for (k = depth; k <= 50; k++) stack[k] = ""
			stack[depth] = key
			# Emit EVERY present scalar key, even one with an empty value (e.g. `enabled:`), as
			# `path=`, so td_key_present can detect a present-but-empty field in the yq-less
			# fallback and _td_validate can fail it closed instead of defaulting.
			print joinpath(depth) "=" val
		}
	' "$TD_FILE") || { log_error "testing-discipline-policy: cannot parse $TD_FILE"; exit 2; }

	# Validate every KNOWN field up-front, in the MAIN shell, so a malformed value fails closed
	# (exit 2). Accessors below run inside $(...) where `exit` would only kill the subshell — so
	# all fail-closed validation must happen here.
	_td_validate
}

# td_key_present <dotted.key> — 0 (true) when the key EXISTS in the policy file (even with an
# empty/null value), so a present-but-empty field can be rejected rather than silently
# defaulted. yq mode is exact; the awk fallback sees every key that carried a `key:` line.
td_key_present() {
	[ "$TD_PRESENT" -eq 1 ] || return 1
	_leaf=${1##*.}; _parent=${1%.*}
	if [ "$TD_USE_YQ" -eq 1 ]; then
		_p=$(yq e ".$_parent | has(\"$_leaf\")" "$TD_FILE" 2>/dev/null || printf 'false')
		[ "$_p" = "true" ]
	else
		printf '%s\n' "$TD_FLAT" | awk -F= -v k="$1" '$1==k{f=1} END{exit f?0:1}'
	fi
}

# _td_validate — exit 2 when a present, known field is empty or (for booleans) malformed.
_td_validate() {
	[ "$TD_PRESENT" -eq 1 ] || return 0
	for _k in $TD_BOOL_KEYS; do
		_v=$(td_get "$_k") || true
		if [ -z "$_v" ]; then
			if td_key_present "$_k"; then log_error "testing-discipline-policy: $_k must not be empty"; exit 2; fi
			continue
		fi
		bool_value "$_v" >/dev/null 2>&1 || { log_error "testing-discipline-policy: $_k must be a boolean, got '$_v'"; exit 2; }
	done
	for _k in $TD_LIST_KEYS; do
		if td_key_present "$_k" && [ -z "$(td_list "$_k")" ]; then
			log_error "testing-discipline-policy: $_k is present but empty (remove the key to use the built-in defaults)"; exit 2
		fi
	done
}

# td_present — 0 (true) when a policy file was loaded.
td_present() { [ "$TD_PRESENT" -eq 1 ]; }

# td_get <dotted.key> — scalar value, or empty when absent/no-policy.
td_get() {
	[ "$TD_PRESENT" -eq 1 ] || return 0
	if [ "$TD_USE_YQ" -eq 1 ]; then
		_v=$(yq e ".$1" "$TD_FILE" 2>/dev/null || true); [ "$_v" = "null" ] && _v=""; printf '%s' "$_v"
	else
		printf '%s\n' "$TD_FLAT" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}'
	fi
}

# td_list <dotted.key> — list items, one per line, or nothing when absent/no-policy.
td_list() {
	[ "$TD_PRESENT" -eq 1 ] || return 0
	if [ "$TD_USE_YQ" -eq 1 ]; then
		yq e ".$1[]?" "$TD_FILE" 2>/dev/null || true
	else
		printf '%s\n' "$TD_FLAT" | awk -F= -v k="$1.[]" '$1==k{sub(/^[^=]*=/,"");print}'
	fi
}

# td_list_or <dotted.key> <default-items...> — the policy list when it has items, else the
# caller's built-in default list (one item per line).
td_list_or() {
	_k=$1; shift
	_v=$(td_list "$_k")
	if [ -n "$_v" ]; then printf '%s\n' "$_v"; else for _d in "$@"; do printf '%s\n' "$_d"; done; fi
}

# td_bool <dotted.key> <default> — normalized true/false, or the default when absent.
# Malformed values were already rejected (exit 2) by _td_validate at load time.
td_bool() {
	_v=$(td_get "$1")
	if [ -n "$_v" ]; then bool_value "$_v"; else printf '%s' "$2"; fi
}

# td_enabled — 0 (true) when testing-discipline governance is on (default ON when no policy
# file; the profile still decides which producers are applicable, and the MODE still decides
# whether any of it blocks).
td_enabled() { [ "$(td_bool testing_discipline.enabled true)" = "true" ]; }

# td_tdd_enabled — 0 (true) when the TDD proxy applies. ON by default: changed-file evidence
# needs no extra tooling from the project.
td_tdd_enabled() { td_enabled && [ "$(td_bool testing_discipline.tdd.enabled true)" = "true" ]; }

# td_bdd_required — 0 (true) when BDD behavior-spec evidence is EXPECTED. OFF by default: a
# library must never be forced to carry Gherkin it never asked for
# (docs/bdd-atdd-evidence.md).
td_bdd_required() {
	td_enabled || return 1
	[ "$(td_bool testing_discipline.bdd.enabled false)" = "true" ] || return 1
	[ "$(td_bool testing_discipline.bdd.require_behavior_specs false)" = "true" ]
}

# td_atdd_required — 0 (true) when ATDD acceptance evidence is EXPECTED. OFF by default, for
# the same reason as BDD: browser acceptance suites are an opt-in commitment.
td_atdd_required() {
	td_enabled || return 1
	[ "$(td_bool testing_discipline.atdd.enabled false)" = "true" ] || return 1
	[ "$(td_bool testing_discipline.atdd.require_acceptance_evidence false)" = "true" ]
}
