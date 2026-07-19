#!/bin/sh
# Sentinel Shield — architecture-policy loader (POSIX sh, source; do not execute).
#
# Reads a consuming project's .sentinel-shield/architecture-policy.yaml (which architecture
# producers are enabled, where their configs live, which style is claimed). Same parser
# strategy as scripts/lib/quality-policy.sh: mikefarah yq v4 if present, else a limited awk
# flatten of the CANONICAL (2-space, no anchors/flow/block-scalars) format. yq is NOT required.
#
# FAIL CLOSED: when the policy file is EXPLICITLY present but malformed (unparseable YAML,
# advanced YAML the fallback cannot read, a non-boolean known flag, or a present-but-EMPTY
# known field) the loader exits 2. An ABSENT policy is not an error — accessors return the
# caller-supplied default (a runner then uses its documented built-in behavior).
#
# Scope note (docs/architecture-governance.md): this policy declares which architecture
# EVIDENCE producers apply. It does not prove Clean Architecture / DDD correctness — the
# producers detect dependency-boundary violations only.
#
# Requires scripts/lib/sentinel-shield-common.sh already sourced (log_*, command_exists,
# bool_value).
#
# Usage:
#   . scripts/lib/architecture-policy.sh
#   ap_load .sentinel-shield/architecture-policy.yaml
#   ap_enabled     || echo "architecture governance off"
#   dep=$(ap_bool architecture.tools.deptrac.enabled true)
#   cfg=$(ap_get  architecture.tools.deptrac.config)

AP_FILE=""; AP_FLAT=""; AP_USE_YQ=0; AP_PRESENT=0

# Known BOOLEAN fields — validated at load, fail closed when present-but-empty/non-boolean.
AP_BOOL_KEYS="architecture.enabled architecture.evidence_required \
architecture.bounded_contexts.enabled \
architecture.tools.deptrac.enabled architecture.tools.php_arkitect.enabled \
architecture.tools.architecture_tests.enabled architecture.tools.dependency_cruiser.enabled \
architecture.tools.eslint_boundaries.enabled"

# Known SCALAR fields — validated at load, fail closed when present-but-empty.
AP_SCALAR_KEYS="architecture.style \
architecture.tools.deptrac.config architecture.tools.php_arkitect.config \
architecture.tools.architecture_tests.command \
architecture.tools.dependency_cruiser.config architecture.tools.eslint_boundaries.config"

# ap_load <file> — select the parser, validate presence + basic well-formedness.
ap_load() {
	AP_FILE="$1"; AP_FLAT=""; AP_USE_YQ=0; AP_PRESENT=0
	[ -n "$AP_FILE" ] && [ -f "$AP_FILE" ] || return 0
	AP_PRESENT=1

	if command_exists yq && yq --version 2>/dev/null | grep -Eq 'mikefarah|version v4'; then
		AP_USE_YQ=1
		yq e '.' "$AP_FILE" >/dev/null 2>&1 || { log_error "architecture-policy: malformed YAML: $AP_FILE"; exit 2; }
		_ap_validate
		return 0
	fi

	# Fallback: tabs are illegal YAML indentation; advanced YAML needs mikefarah yq.
	if grep -q "$(printf '\t')" "$AP_FILE" 2>/dev/null; then
		log_error "architecture-policy: tab indentation is not valid YAML: $AP_FILE"; exit 2
	fi
	if grep -v '^[[:space:]]*#' "$AP_FILE" \
		| grep -Eq '(^|[[:space:]])&[A-Za-z0-9_]|:[[:space:]]*\*[A-Za-z0-9_]|:[[:space:]]*[{[]|:[[:space:]]*[|>]([[:space:]]|$)'; then
		log_error "architecture-policy uses advanced YAML (anchors/aliases/inline collections/block scalars). Install mikefarah yq v4 or simplify to the canonical 2-space format: $AP_FILE"
		exit 2
	fi
	AP_FLAT=$(awk '
		function joinpath(last,    i, p) {
			p = ""
			for (i = 0; i <= last; i++) { if (stack[i] == "") continue; p = (p == "") ? stack[i] : p "." stack[i] }
			return p
		}
		{
			line = $0
			if (line ~ /^[[:space:]]*#/) next
			if (line ~ /^[[:space:]]*$/) next
			# List items (e.g. bounded_contexts.paths) are not scalars: record the PARENT key
			# as present (already emitted by its own line) and skip the item itself.
			if (line ~ /^[[:space:]]*-[[:space:]]/) next
			match(line, /^ */); indent = RLENGTH; depth = int(indent / 2)
			content = substr(line, indent + 1)
			ci = index(content, ":")
			if (ci == 0) next
			key = substr(content, 1, ci - 1); val = substr(content, ci + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
			sub(/[[:space:]]+#.*$/, "", val); gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
			# Strip ONE layer of matching surrounding quotes so this fallback agrees with yq:
			# `command: ""` is an EMPTY value in both parsers (and therefore fails closed as a
			# present-but-empty known field), not the 2-character string `""`.
			if (length(val) >= 2 && ((substr(val,1,1) == "\"" && substr(val,length(val),1) == "\"") \
			    || (substr(val,1,1) == "'"'"'" && substr(val,length(val),1) == "'"'"'"))) {
				val = substr(val, 2, length(val) - 2)
			}
			for (k = depth; k <= 50; k++) stack[k] = ""
			stack[depth] = key
			# Emit EVERY present scalar key, even one with an empty value (e.g. `enabled:`),
			# as `path=`, so ap_key_present can detect a present-but-empty field in the
			# yq-less fallback and _ap_validate can fail it closed instead of defaulting.
			print joinpath(depth) "=" val
		}
	' "$AP_FILE") || { log_error "architecture-policy: cannot parse $AP_FILE"; exit 2; }

	# Validate every KNOWN field up-front, in the MAIN shell, so a malformed value fails
	# closed (exit 2). Accessors below run inside $(...) where `exit` would only kill the
	# subshell — so all fail-closed validation must happen here.
	_ap_validate
}

# ap_key_present <dotted.key> — 0 (true) when the key EXISTS in the policy file (even with an
# empty/null value), so a present-but-empty field can be rejected rather than silently
# defaulted. yq mode is exact; the awk fallback sees every key that carried a `key:` line.
ap_key_present() {
	[ "$AP_PRESENT" -eq 1 ] || return 1
	_leaf=${1##*.}; _parent=${1%.*}
	if [ "$AP_USE_YQ" -eq 1 ]; then
		_p=$(yq e ".$_parent | has(\"$_leaf\")" "$AP_FILE" 2>/dev/null || printf 'false')
		[ "$_p" = "true" ]
	else
		printf '%s\n' "$AP_FLAT" | awk -F= -v k="$1" '$1==k{f=1} END{exit f?0:1}'
	fi
}

# _ap_validate — exit 2 when a present, known field is empty or (for booleans) malformed.
_ap_validate() {
	[ "$AP_PRESENT" -eq 1 ] || return 0
	for _k in $AP_BOOL_KEYS; do
		_v=$(ap_get "$_k") || true
		if [ -z "$_v" ]; then
			if ap_key_present "$_k"; then log_error "architecture-policy: $_k must not be empty"; exit 2; fi
			continue
		fi
		bool_value "$_v" >/dev/null 2>&1 || { log_error "architecture-policy: $_k must be a boolean, got '$_v'"; exit 2; }
	done
	for _k in $AP_SCALAR_KEYS; do
		_v=$(ap_get "$_k") || true
		if [ -z "$_v" ] && ap_key_present "$_k"; then
			log_error "architecture-policy: $_k must not be empty"; exit 2
		fi
	done
}

# ap_present — 0 (true) when a policy file was loaded.
ap_present() { [ "$AP_PRESENT" -eq 1 ]; }

# ap_get <dotted.key> — scalar value, or empty when absent/no-policy.
ap_get() {
	[ "$AP_PRESENT" -eq 1 ] || return 0
	if [ "$AP_USE_YQ" -eq 1 ]; then
		_v=$(yq e ".$1" "$AP_FILE" 2>/dev/null || true); [ "$_v" = "null" ] && _v=""; printf '%s' "$_v"
	else
		printf '%s\n' "$AP_FLAT" | awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}'
	fi
}

# ap_bool <dotted.key> <default> — normalized true/false, or the default when absent.
# Malformed values were already rejected (exit 2) by _ap_validate at load time.
ap_bool() {
	_v=$(ap_get "$1")
	if [ -n "$_v" ]; then bool_value "$_v"; else printf '%s' "$2"; fi
}

# ap_enabled — 0 (true) when architecture governance is on (default ON when no policy file;
# the profile still decides which producers are applicable).
ap_enabled() { [ "$(ap_bool architecture.enabled true)" = "true" ]; }

# ap_tool_enabled <tool-key> <default> — 0 (true) when architecture.tools.<key>.enabled
# resolves true. <tool-key> uses the policy's underscore spelling (e.g. php_arkitect).
ap_tool_enabled() { [ "$(ap_bool "architecture.tools.$1.enabled" "$2")" = "true" ]; }
