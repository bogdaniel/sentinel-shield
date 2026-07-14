#!/bin/sh
# Sentinel Shield — quality-policy loader (POSIX sh, source; do not execute).
#
# Reads a consuming project's .sentinel-shield/quality-policy.yaml (thresholds for the
# engineering-quality runners: coverage / mutation / complexity / duplication / dead-code).
# Same parser strategy as scripts/resolve-gates.sh: mikefarah yq v4 if present, else a
# limited awk flatten of the CANONICAL (2-space, no anchors/flow/block-scalars) format.
#
# FAIL CLOSED: when the policy file is EXPLICITLY present but malformed (unparseable YAML,
# advanced YAML the fallback cannot read, a non-numeric threshold, or a non-boolean flag)
# the loader/accessors exit 2. An ABSENT policy is not an error — accessors return the
# caller-supplied default (a runner then uses its documented built-in thresholds).
#
# Requires scripts/lib/sentinel-shield-common.sh already sourced (log_*, command_exists,
# bool_value).
#
# Usage:
#   . scripts/lib/quality-policy.sh
#   qp_load .sentinel-shield/quality-policy.yaml
#   line_min=$(qp_num quality.coverage.line_min 80)
#   fail_dec=$(qp_bool quality.coverage.fail_on_decrease false)
#   base=$(qp_get quality.coverage.baseline_file)

QP_FILE=""; QP_FLAT=""; QP_USE_YQ=0; QP_PRESENT=0

# qp_load <file> — select the parser, validate presence + basic well-formedness.
qp_load() {
	QP_FILE="$1"; QP_FLAT=""; QP_USE_YQ=0; QP_PRESENT=0
	[ -n "$QP_FILE" ] && [ -f "$QP_FILE" ] || return 0
	QP_PRESENT=1

	if command_exists yq && yq --version 2>/dev/null | grep -Eq 'mikefarah|version v4'; then
		QP_USE_YQ=1
		yq e '.' "$QP_FILE" >/dev/null 2>&1 || { log_error "quality-policy: malformed YAML: $QP_FILE"; exit 2; }
		_qp_validate
		return 0
	fi

	# Fallback: tabs are illegal YAML indentation; advanced YAML needs mikefarah yq.
	if grep -q "$(printf '\t')" "$QP_FILE" 2>/dev/null; then
		log_error "quality-policy: tab indentation is not valid YAML: $QP_FILE"; exit 2
	fi
	if grep -v '^[[:space:]]*#' "$QP_FILE" \
		| grep -Eq '(^|[[:space:]])&[A-Za-z0-9_]|:[[:space:]]*\*[A-Za-z0-9_]|:[[:space:]]*[{[]|:[[:space:]]*[|>]([[:space:]]|$)'; then
		log_error "quality-policy uses advanced YAML (anchors/aliases/inline collections/block scalars). Install mikefarah yq v4 or simplify to the canonical 2-space format: $QP_FILE"
		exit 2
	fi
	QP_FLAT=$(awk '
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
			ci = index(content, ":")
			if (ci == 0) next
			key = substr(content, 1, ci - 1); val = substr(content, ci + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
			sub(/[[:space:]]+#.*$/, "", val); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
			for (k = depth; k <= 50; k++) stack[k] = ""
			stack[depth] = key
			if (val != "") print joinpath(depth) "=" val
		}
	' "$QP_FILE") || { log_error "quality-policy: cannot parse $QP_FILE"; exit 2; }

	# Validate every KNOWN threshold up-front, in the MAIN shell, so a malformed value
	# fails closed (exit 2). Accessors below run inside $(...) where `exit` would only
	# kill the subshell — so all fail-closed validation must happen here.
	_qp_validate
}

# _qp_check_num <key> <value> <min> <max> <int:0|1> — exit 2 unless value is a finite,
# unsigned decimal (or integer when int=1) within [min,max]. Rejects 1.2.3, ..., -1, 101,
# NaN, empty, and a stray dot — the char-class check alone was too loose.
_qp_check_num() {
	awk -v v="$2" -v min="$3" -v max="$4" -v isint="$5" 'BEGIN{
		if (v !~ /^[0-9]+(\.[0-9]+)?$/) exit 1
		x = v + 0
		if (x < min || x > max) exit 1
		if (isint == 1 && v ~ /\./) exit 1
		exit 0
	}' </dev/null 2>/dev/null || {
		if [ "$5" = "1" ]; then log_error "quality-policy: $1 must be an integer in $3..$4, got '$2'"
		else log_error "quality-policy: $1 must be a finite number in $3..$4, got '$2'"; fi
		exit 2
	}
}

# qp_key_present <dotted.key> — 0 (true) when the key EXISTS in the policy file (even with an
# empty/null value), so a present-but-empty threshold can be rejected rather than silently
# defaulted. yq mode is exact; the awk fallback can only see keys that carried a value (a
# quoted-empty `x: ""` is present with value `""` and is caught by the numeric check anyway).
qp_key_present() {
	[ "$QP_PRESENT" -eq 1 ] || return 1
	_leaf=${1##*.}; _parent=${1%.*}
	if [ "$QP_USE_YQ" -eq 1 ]; then
		_p=$(yq e ".$_parent | has(\"$_leaf\")" "$QP_FILE" 2>/dev/null || printf 'false')
		[ "$_p" = "true" ]
	else
		printf '%s\n' "$QP_FLAT" | awk -F= -v k="$1" '$1==k{f=1} END{exit f?0:1}'
	fi
}

# _qp_num_field <key> <min> <max> <int:0|1> — validate a numeric threshold: reject present-but-
# empty (exit 2), validate range/format for a present value, ignore a truly-absent key (default).
_qp_num_field() {
	_v=$(qp_get "$1")
	if [ -z "$_v" ]; then
		if qp_key_present "$1"; then log_error "quality-policy: $1 must not be empty"; exit 2; fi
		return 0
	fi
	_qp_check_num "$1" "$_v" "$2" "$3" "$4"
}

# _qp_validate — exit 2 when a present, known numeric/boolean field is malformed.
_qp_validate() {
	[ "$QP_PRESENT" -eq 1 ] || return 0
	# Percentages / scores: finite number in 0..100.
	for _k in quality.coverage.line_min quality.coverage.branch_min \
		quality.coverage.method_min quality.coverage.class_min \
		quality.coverage.changed_lines_min \
		quality.mutation.min_score quality.duplication.max_percentage; do
		_qp_num_field "$_k" 0 100 0
	done
	# Integer thresholds >= 1 (complexity + maintainability sizes).
	for _k in quality.complexity.max_cyclomatic_complexity quality.complexity.max_cognitive_complexity \
		quality.maintainability.max_file_lines quality.maintainability.max_function_lines; do
		_qp_num_field "$_k" 1 100000 1
	done
	for _k in quality.coverage.enabled quality.coverage.fail_on_decrease \
		quality.mutation.enabled quality.complexity.enabled \
		quality.duplication.enabled quality.dead_code.enabled; do
		_v=$(qp_get "$_k") || true
		[ -n "$_v" ] || continue
		bool_value "$_v" >/dev/null 2>&1 || { log_error "quality-policy: $_k must be a boolean, got '$_v'"; exit 2; }
	done
}

# qp_present — 0 (true) when a policy file was loaded.
qp_present() { [ "$QP_PRESENT" -eq 1 ]; }

# qp_get <dotted.key> — scalar value, or empty when absent/no-policy.
qp_get() {
	[ "$QP_PRESENT" -eq 1 ] || return 0
	if [ "$QP_USE_YQ" -eq 1 ]; then
		_v=$(yq e ".$1" "$QP_FILE" 2>/dev/null || true); [ "$_v" = "null" ] && _v=""; printf '%s' "$_v"
	else
		printf '%s\n' "$QP_FLAT" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}'
	fi
}

# qp_num <dotted.key> <default> — numeric value, or the default when absent. Malformed
# values were already rejected (exit 2) by _qp_validate at load time.
qp_num() {
	_v=$(qp_get "$1"); [ -n "$_v" ] && printf '%s' "$_v" || printf '%s' "$2"
}

# qp_bool <dotted.key> <default> — normalized true/false, or the default when absent.
qp_bool() {
	_v=$(qp_get "$1")
	if [ -n "$_v" ]; then bool_value "$_v"; else printf '%s' "$2"; fi
}
