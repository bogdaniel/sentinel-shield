# Sentinel Shield — installation metadata (POSIX sh library).
#
# Source this file; do not execute it. It READS and WRITES the install record at
# <target>/.sentinel-shield/installation.json, conforming to
# schemas/installation.schema.json. It carries NO secrets, tokens, or
# environment-specific data — only what sync/upgrade needs to reason about
# managed vs project-owned files and which tools are enabled.
#
# Requires the shared library to be sourced FIRST (for log_*/timestamp_utc), and
# jq for JSON parsing/serialisation:
#   SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
#   . "$SCRIPT_DIR/lib/installation-metadata.sh"
#
# Array-valued fields (managed_files, project_owned_files, enabled_tools,
# disabled_tools) are passed to im_write as NEWLINE-separated strings; blank
# lines are dropped. Use "" for an empty list.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_INSTALL_META_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_INSTALL_META_LOADED=1

# im_path <target> — print the installation.json path for a target project dir.
im_path() {
	[ -n "${1:-}" ] || { log_error "im_path: missing target"; return 2; }
	printf '%s/.sentinel-shield/installation.json' "$1"
}

# im_exists <target> — true if the installation record exists and is non-empty.
im_exists() {
	_im_p=$(im_path "$1") || return 2
	[ -s "$_im_p" ]
}

# im_get <target> <jq-filter> — read a value with a raw jq filter. Empty if the
# record is absent or the filter yields null. Read-only.
im_get() {
	command_exists jq || { log_error "im_get: jq is required"; return 2; }
	_im_p=$(im_path "$1") || return 2
	[ -s "$_im_p" ] || return 0
	jq -r "$2 // empty" "$_im_p" 2>/dev/null || true
}

# Scalar getters.
im_get_version()        { im_get "$1" '.version'; }
im_get_profile()        { im_get "$1" '.profile'; }
im_get_profile_schema() { im_get "$1" '.profile_schema'; }
im_get_tool_mode()      { im_get "$1" '.tool_mode'; }
im_get_installed_at()   { im_get "$1" '.installed_at'; }

# List getters — one item per line.
im_list_managed_files()       { im_get "$1" '(.managed_files // [])[]'; }
im_list_project_owned_files() { im_get "$1" '(.project_owned_files // [])[]'; }
im_list_enabled_tools()       { im_get "$1" '(.enabled_tools // [])[]'; }
im_list_disabled_tools()      { im_get "$1" '(.disabled_tools // [])[]'; }

# im_validate <path> — best-effort conformance check (jq, not a full JSON Schema
# validator): valid JSON, required keys present, correct top-level types, and the
# tool keys match the shared toolKey pattern. Returns non-zero with a logged
# reason on failure. ponytail: jq is the only validator we depend on; deep schema
# validation is out of scope (no ajv/check-jsonschema in this toolchain).
im_validate() {
	command_exists jq || { log_error "im_validate: jq is required"; return 2; }
	[ -s "${1:-}" ] || { log_error "im_validate: missing/empty file '${1:-}'"; return 1; }
	jq -e . "$1" >/dev/null 2>&1 || { log_error "im_validate: invalid JSON in '$1'"; return 1; }
	jq -e '
		(.version | type == "string" and (length > 0)) and
		(.profile | type == "string" and (length > 0)) and
		(.profile_schema | type == "number") and
		(.tool_mode as $tm | ["config-only","require-existing","bootstrap-tools"] | index($tm) != null) and
		(.installed_at | type == "string" and (length > 0)) and
		(.managed_files | type == "array") and
		(.project_owned_files | type == "array") and
		(.enabled_tools | type == "array") and
		(.disabled_tools | type == "array") and
		((.enabled_tools + .disabled_tools) | all(test("^[a-z0-9][a-z0-9-]*$")))
	' "$1" >/dev/null 2>&1 || { log_error "im_validate: '$1' does not conform to installation.schema.json"; return 1; }
	return 0
}

# im_write <target> <version> <profile> <profile_schema> <tool_mode> \
#          <installed_at> <managed_files> <project_owned_files> \
#          <enabled_tools> <disabled_tools>
# Serialise an installation record to <target>/.sentinel-shield/installation.json.
# <installed_at> may be "" to stamp the current UTC time. <profile_schema> may be
# "" (treated as 0). The four list args are newline-separated strings.
im_write() {
	command_exists jq || { log_error "im_write: jq is required"; return 2; }
	[ -n "${1:-}" ]  || { log_error "im_write: missing target"; return 2; }
	[ -n "${2:-}" ]  || { log_error "im_write: missing version"; return 2; }
	[ -n "${3:-}" ]  || { log_error "im_write: missing profile"; return 2; }
	[ -n "${5:-}" ]  || { log_error "im_write: missing tool_mode"; return 2; }

	_im_target="$1"
	_im_schema="${4:-0}"
	[ -n "$_im_schema" ] || _im_schema=0
	_im_at="${6:-}"
	[ -n "$_im_at" ] || _im_at=$(timestamp_utc)

	_im_out=$(im_path "$_im_target") || return 2
	ensure_dir "$(dirname -- "$_im_out")"

	# ATOMIC write: build + validate a temp file in the SAME dir, then mv into place
	# only on success — an interrupted/failed write never leaves a partial
	# installation.json behind.
	_im_tmp="$_im_out.tmp.$$"
	jq -n \
		--arg version "$2" \
		--arg profile "$3" \
		--argjson profile_schema "$_im_schema" \
		--arg tool_mode "$5" \
		--arg installed_at "$_im_at" \
		--arg managed "${7:-}" \
		--arg owned "${8:-}" \
		--arg enabled "${9:-}" \
		--arg disabled "${10:-}" '
		def lines($s): ($s | split("\n") | map(select(length > 0)));
		{
			version: $version,
			profile: $profile,
			profile_schema: $profile_schema,
			tool_mode: $tool_mode,
			installed_at: $installed_at,
			managed_files: lines($managed),
			project_owned_files: lines($owned),
			enabled_tools: lines($enabled),
			disabled_tools: lines($disabled)
		}' > "$_im_tmp" || { log_error "im_write: cannot write '$_im_tmp'"; rm -f "$_im_tmp" 2>/dev/null || true; return 1; }

	im_validate "$_im_tmp" || { log_error "im_write: produced a non-conforming record"; rm -f "$_im_tmp" 2>/dev/null || true; return 1; }
	mv -- "$_im_tmp" "$_im_out" || { log_error "im_write: cannot move into place '$_im_out'"; rm -f "$_im_tmp" 2>/dev/null || true; return 1; }
	log_info "installation-metadata: wrote $_im_out"
}
