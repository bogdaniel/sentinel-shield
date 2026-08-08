#!/bin/sh
# Sentinel Shield — canonical profile-manifest schema + semantic validator (#248).
#
# WHY THIS EXISTS
#
# Before this library, every consumer of a profile manifest validated it with
# `jq -e . <file>` — "is this parseable JSON" — and the resolver additionally
# checked one field, `tools[*].policy`, against an enum. Nothing else was
# checked ANYWHERE at runtime:
#
#   * `profiles/profile.manifest.schema.json` existed but was applied only inside
#     one `if command_exists check-jsonschema` branch of scripts/self-test.sh.
#     `check-jsonschema` is not a dependency of this engine and is not installed
#     in CI, so that branch logged "SKIPPING" and the schema validated nothing.
#   * The schema itself had drifted from the manifests it describes: shipped
#     profiles use `tools[*].audit`, `notes`, and four top-level
#     `recommended_*_tools` keys that the schema did not declare — and
#     `toolPolicy` is `additionalProperties: false`, so every shipped profile
#     would have FAILED its own schema had anything ever run it.
#   * `tools[*].report`, `runner`, `audit`, `config.path`, `executable[]` and the
#     entry-list `source`/`target` are strings that reach shell `for` loops,
#     unquoted command substitution, path probes and `-x` tests. A value with
#     whitespace, a glob character, a leading `-` or a `..` segment changes what
#     the engine executes or reads.
#   * `one_of_groups` are DERIVED (a one-of tool that is nobody's alternative).
#     A manifest whose one-of tools all list each other therefore produces ZERO
#     groups — the requirement disappears silently rather than failing closed.
#   * `fallback_order[0]` decides what bootstrap-profile-tools.sh INSTALLS. It
#     was never checked against `alternatives`.
#
# So: one authoritative validator, mandatory, run on EVERY manifest in the
# inheritance DAG and at the arbitrary-manifest entry point, BEFORE any field of
# that manifest is read or merged. `profiles/profile.manifest.schema.json` stays
# the published JSON-Schema face of the same contract and is held in lockstep
# with this file by tests/prod/300-profile-manifest-schema.sh — if the two ever
# disagree about an enum, an allowlist, a pattern or the supported version, that
# suite fails.
#
# ROLES
#   policy   the composition surface: identity, versions, extends, tools. Used by
#            the resolver and by any consumer that only composes tool policy.
#   install  everything in `policy` PLUS the install/sync surface the published
#            schema requires (`files`). Used by install/sync/upgrade/migrate and
#            by the repository audit over shipped profiles, so no shipped
#            manifest escapes the full published schema.
#
# Source this file; it defines functions only. A CLI wrapper lives at
# scripts/validate-profile-manifest.sh.
#
# stdout = nothing (ps_manifest_errors prints diagnostics on stdout by design;
# ps_validate_manifest logs to stderr). Exit: 2 = invalid manifest / bad usage.
#
# No top-level `set -eu`: this file is sourced and must not mutate the sourcing
# shell's options. Every caller sets its own.

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_PROFILE_SCHEMA_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_PROFILE_SCHEMA_LOADED=1

# Source the shared library if the caller has not already done so. When run as a
# CLI, $0 points at the wrapper in scripts/; when sourced from scripts/lib/, $0
# may point at either. Mirrors the $0-based locator used across the engine.
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	_ps_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	if [ -f "$_ps_d/sentinel-shield-common.sh" ]; then
		. "$_ps_d/sentinel-shield-common.sh"
	elif [ -f "$_ps_d/lib/sentinel-shield-common.sh" ]; then
		. "$_ps_d/lib/sentinel-shield-common.sh"
	else
		printf '%s\n' "[sentinel-shield][error] profile-schema: cannot locate sentinel-shield-common.sh; source it first." >&2
		exit 2
	fi
fi

# --- the contract ------------------------------------------------------------
# Every constant below is asserted equal to its counterpart in
# profiles/profile.manifest.schema.json by tests/prod/300-profile-manifest-schema.sh.

# The ONLY tool-policy version this engine can execute.
PS_TOOL_POLICY_VERSION=2
# Basename of the one schema a manifest may claim to conform to.
PS_SCHEMA_BASENAME='profile.manifest.schema.json'
# Canonical identifier grammar for profiles, tool keys, one-of group keys,
# alternatives and category labels (#251 partial: validated BEFORE the value is
# used to build a path or is stored in a space-delimited shell set).
PS_ID_PATTERN='^[a-z0-9][a-z0-9-]*$'
PS_ID_MAXLEN=64

PS_POLICIES='required recommended optional one-of disabled external'
PS_MISSING_BEHAVIORS='fail warn info skip'
PS_CONFIG_CLASSIFICATIONS='managed create-if-missing manual-template never-touch project-owned'
PS_ENTRY_MODES='create-if-missing merge-required-lines overwrite-if-force sync-managed-block manual'
PS_PACKAGE_SCOPES='dev prod'
# `selection` is emitted into one_of_groups and consumed by nothing else today;
# any other value would be silently ignored, so only the implemented one is legal.
PS_SELECTIONS='prefer-existing'

# Top-level keys. Anything else is rejected: an unknown key is either a typo that
# silently does nothing, or a field a newer engine understands and this one does
# not. There is deliberately no `x-` extension escape hatch.
PS_TOP_KEYS='$schema profile description stacks files workflows docs never_touch required_scripts recommended_raw_reports recommended_main_gate_tools recommended_pr_fast_tools recommended_scheduled_tools tool_notes tool_policy_version extends tools'
# Per-tool keys.
PS_TOOL_KEYS='policy category packages executable runner report audit notes missing_behavior requires alternatives execution config selection fallback_order'
PS_PACKAGE_KEYS='name scope compatibility'
PS_EXECUTION_KEYS='pr main scheduled'
PS_CONFIG_KEYS='path classification'
PS_ENTRY_KEYS='source target mode'

ps__die_cfg() { log_error "profile-schema: $*"; exit 2; }

# ps_valid_id <string> — true when the string is a canonical identifier. Used by
# callers that must validate a name BEFORE they build a filesystem path from it.
ps_valid_id() {
	case "${1:-}" in
		'') return 1 ;;
		*[!a-z0-9-]*) return 1 ;;
		-*) return 1 ;;
	esac
	[ "${#1}" -le "$PS_ID_MAXLEN" ] || return 1
	return 0
}

# The ENGINE root — the tree that ships scripts/ — captured at source time from
# $0. `runner` and `audit` are paths into the ENGINE, not into whatever directory
# happens to hold profiles/: a caller may point EP_REPO_ROOT at a fixture tree of
# profiles while the runners it names still live in the real engine.
__SENTINEL_SHIELD_PS_ENGINE_ROOT=""
_ps_d0=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || _ps_d0="$PWD"
for _ps_c in "$_ps_d0/../.." "$_ps_d0/.." "$_ps_d0" "$PWD"; do
	if [ -f "$_ps_c/scripts/lib/profile-schema.sh" ]; then
		__SENTINEL_SHIELD_PS_ENGINE_ROOT=$(CDPATH= cd -- "$_ps_c" && pwd)
		break
	fi
done
unset _ps_d0 _ps_c

# ps_engine_root — the tree whose scripts/ a `runner`/`audit` path resolves
# against. PS_REPO_ROOT overrides it explicitly (release packaging validates a
# self-contained packaged tree). Non-zero when no engine tree can be located, in
# which case the existence check is skipped rather than guessed at.
ps_engine_root() {
	if [ -n "${PS_REPO_ROOT:-}" ] && [ -d "${PS_REPO_ROOT}/scripts" ]; then
		(CDPATH= cd -- "$PS_REPO_ROOT" && pwd); return 0
	fi
	[ -n "$__SENTINEL_SHIELD_PS_ENGINE_ROOT" ] && { printf '%s\n' "$__SENTINEL_SHIELD_PS_ENGINE_ROOT"; return 0; }
	return 1
}

# ps_repo_root — the tree that holds profiles/ (used by the CLI's --all sweep).
# Honours PS_REPO_ROOT, then EP_REPO_ROOT, then a $0-relative search.
ps_repo_root() {
	for _c in "${PS_REPO_ROOT:-}" "${EP_REPO_ROOT:-}"; do
		[ -n "$_c" ] && [ -d "$_c/profiles" ] && { (CDPATH= cd -- "$_c" && pwd); return 0; }
	done
	_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	for _c in "$_d/../.." "$_d/.." "$_d" "$PWD"; do
		[ -d "$_c/profiles" ] && { (CDPATH= cd -- "$_c" && pwd); return 0; }
	done
	return 1
}

# --- the jq program ----------------------------------------------------------
# One pass, one program, emits ZERO OR MORE error lines on stdout. Every line is
# `CODE key=value ...` — machine-readable, and never echoes a whole manifest.
ps__jq_program() {
	cat <<'PS_JQ'
def idok($s): ($s|type)=="string" and ($s|test($IDPAT)) and (($s|length) <= ($IDMAX|tonumber));
def segs($s): ($s | ltrimstr("/") | [splits("/")]);
def relpath($s): ($s|type)=="string" and ($s|length) > 0 and ($s|length) <= 255
	and ($s|test("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$"))
	and (segs($s) | all(. != "." and . != ".." and . != ""));
def anypath($s): ($s|type)=="string" and ($s|length) > 0 and ($s|length) <= 255
	and ($s|test("^/?[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$"))
	and (segs($s) | all(. != "." and . != ".." and . != ""));
def strlist($v): ($v|type)=="array" and ($v|all(type=="string" and length>0));
def dupes($v): ($v|group_by(.)|map(select(length>1)|.[0])|unique);
def enum($name): ($ENUMS[$name] | split(" "));

($TOPKEYS|split(" ")) as $TOP
| ($TOOLKEYS|split(" ")) as $TK
| ($PKGKEYS|split(" ")) as $PK
| ($EXECKEYS|split(" ")) as $XK
| ($CFGKEYS|split(" ")) as $CK
| ($ENTRYKEYS|split(" ")) as $EK
| . as $m
| [
  # ---- 0. the document itself -------------------------------------------
  (if ($m|type) != "object" then "MANIFEST_NOT_OBJECT type=\($m|type)" else empty end),

  (if ($m|type) == "object" then (

  # ---- 1. unknown top-level fields --------------------------------------
    ($m | keys[] | select(. as $k | ($TOP | index($k)) == null)
      | "UNKNOWN_FIELD field=\(.)"),

  # ---- 2. declared schema ------------------------------------------------
    (if ($m|has("$schema")) then
       (if ($m["$schema"]|type) != "string" then "SCHEMA_NOT_STRING type=\($m["$schema"]|type)"
        elif ($m["$schema"] | split("/") | last) != $SCHEMABASE
          then "UNSUPPORTED_SCHEMA declared=\($m["$schema"]) supported=\($SCHEMABASE) hint=point-$schema-at-profiles/\($SCHEMABASE)"
        else empty end)
     else empty end),

  # ---- 3. profile identity ----------------------------------------------
    (if ($m|has("profile")|not) then "MISSING_REQUIRED_FIELD field=profile"
     elif (idok($m.profile)|not) then "INVALID_IDENTIFIER field=profile value_type=\($m.profile|type) pattern=\($IDPAT)"
     else empty end),

    (if ($m|has("description")) and (($m.description|type) != "string")
       then "FIELD_TYPE field=description expected=string actual=\($m.description|type)" else empty end),

  # ---- 4. string-array fields -------------------------------------------
    ( ["stacks","never_touch","required_scripts","recommended_raw_reports",
       "recommended_main_gate_tools","recommended_pr_fast_tools","recommended_scheduled_tools"][]
      | . as $f
      | if ($m|has($f)) and (strlist($m[$f])|not)
          then "FIELD_TYPE field=\($f) expected=array-of-non-empty-strings actual=\($m[$f]|type)"
        else empty end),

  # ---- 5. tool_notes ------------------------------------------------------
    (if ($m|has("tool_notes")) then
       (if ($m.tool_notes|type) != "object" then "FIELD_TYPE field=tool_notes expected=object actual=\($m.tool_notes|type)"
        else ($m.tool_notes | to_entries[]
              | (if (idok(.key)|not) then "INVALID_IDENTIFIER field=tool_notes.\(.key) pattern=\($IDPAT)" else empty end),
                (if (.value|type) != "string" then "FIELD_TYPE field=tool_notes.\(.key) expected=string actual=\(.value|type)" else empty end))
        end)
     else empty end),

  # ---- 6. entry lists (files / workflows / docs) --------------------------
    ( ["files","workflows","docs"][]
      | . as $f
      | if ($m|has($f)|not) then empty
        elif ($m[$f]|type) != "array" then "FIELD_TYPE field=\($f) expected=array actual=\($m[$f]|type)"
        else ($m[$f] | to_entries[] | .key as $i | .value as $e
              | if ($e|type) != "object" then "FIELD_TYPE field=\($f)[\($i)] expected=object actual=\($e|type)"
                else
                  ($e | keys[] | select(. as $k | ($EK | index($k)) == null)
                    | "UNKNOWN_FIELD field=\($f)[\($i)].\(.)"),
                  (["source","target","mode"][] | . as $r
                    | if ($e|has($r)|not) then "MISSING_REQUIRED_FIELD field=\($f)[\($i)].\($r)" else empty end),
                  (["source","target"][] | . as $p
                    | if ($e|has($p)) and (relpath($e[$p])|not)
                        then "UNSAFE_PATH field=\($f)[\($i)].\($p) reason=not-a-safe-relative-path" else empty end),
                  (if ($e|has("mode")) and ((enum("mode") | index($e.mode)) == null)
                     then "INVALID_ENUM field=\($f)[\($i)].mode value=\($e.mode|tojson) allowed=\($ENUMS["mode"])" else empty end)
                end)
        end),

    (if ($ROLE == "install") and ($m|has("files")|not)
       then "MISSING_REQUIRED_FIELD field=files role=install" else empty end),

  # ---- 7. tool_policy_version -------------------------------------------
    (if ($m|has("tool_policy_version")|not) then
       (if ($m|has("tools")) or ($m|has("extends"))
          then "MISSING_REQUIRED_FIELD field=tool_policy_version hint=a-manifest-that-declares-tools-or-extends-must-declare-the-version-it-was-written-against-add-\"tool_policy_version\":\($TPV)"
        else empty end)
     elif ($m.tool_policy_version|type) != "number" or (($m.tool_policy_version|floor) != $m.tool_policy_version)
       then "FIELD_TYPE field=tool_policy_version expected=integer actual=\($m.tool_policy_version|type)"
     elif $m.tool_policy_version != ($TPV|tonumber)
       then "UNSUPPORTED_TOOL_POLICY_VERSION declared=\($m.tool_policy_version) supported=\($TPV) hint=\(if $m.tool_policy_version < ($TPV|tonumber) then "migrate-with-scripts/migrate-v1.sh-then-set-tool_policy_version-to-\($TPV)" else "this-engine-cannot-execute-a-newer-tool-policy-upgrade-sentinel-shield-or-lower-the-manifest-to-\($TPV)" end)"
     else empty end),

  # ---- 8. extends ---------------------------------------------------------
    (if ($m|has("extends")|not) then empty
     elif ($m.extends|type) != "array" then "FIELD_TYPE field=extends expected=array actual=\($m.extends|type)"
     else
       ($m.extends | to_entries[] | select(idok(.value)|not)
         | "INVALID_IDENTIFIER field=extends[\(.key)] value=\(.value|tojson) pattern=\($IDPAT)"),
       (dupes($m.extends)[] | "DUPLICATE_ENTRY field=extends value=\(.)"),
       (if ($m|has("profile")) and (($m.extends | index($m.profile)) != null)
          then "SELF_REFERENCE field=extends value=\($m.profile)" else empty end)
     end),

  # ---- 9. tools ------------------------------------------------------------
    (if ($m|has("tools")|not) then empty
     elif ($m.tools|type) != "object" then "FIELD_TYPE field=tools expected=object actual=\($m.tools|type)"
     else ($m.tools | to_entries[] | .key as $k | .value as $t
       | (if (idok($k)|not) then "INVALID_IDENTIFIER field=tools.\($k) pattern=\($IDPAT)" else empty end),
         (if ($t|type) != "object" then "FIELD_TYPE field=tools.\($k) expected=object actual=\($t|type)"
          else
            ($t | keys[] | select(. as $x | ($TK | index($x)) == null)
              | "UNKNOWN_FIELD field=tools.\($k).\(.)"),

            # policy (required)
            (if ($t|has("policy")|not) then "MISSING_REQUIRED_FIELD field=tools.\($k).policy"
             elif ((enum("policy") | index($t.policy)) == null)
               then "INVALID_ENUM field=tools.\($k).policy value=\($t.policy|tojson) allowed=\($ENUMS["policy"])"
             else empty end),

            # category
            (if ($t|has("category")) and (idok($t.category)|not)
               then "INVALID_IDENTIFIER field=tools.\($k).category value=\($t.category|tojson) pattern=\($IDPAT)" else empty end),

            # missing_behavior
            (if ($t|has("missing_behavior")) and ((enum("missing_behavior") | index($t.missing_behavior)) == null)
               then "INVALID_ENUM field=tools.\($k).missing_behavior value=\($t.missing_behavior|tojson) allowed=\($ENUMS["missing_behavior"])" else empty end),

            # selection
            (if ($t|has("selection")) and ((enum("selection") | index($t.selection)) == null)
               then "INVALID_ENUM field=tools.\($k).selection value=\($t.selection|tojson) allowed=\($ENUMS["selection"])" else empty end),

            # executable[]
            (if ($t|has("executable")|not) then empty
             elif ($t.executable|type) != "array" then "FIELD_TYPE field=tools.\($k).executable expected=array actual=\($t.executable|type)"
             elif ($t.executable|length) == 0 then "EMPTY_ARRAY field=tools.\($k).executable"
             else
               ($t.executable | to_entries[] | select(anypath(.value)|not)
                 | "UNSAFE_PATH field=tools.\($k).executable[\(.key)] value_type=\(.value|type) reason=whitespace-glob-traversal-or-control-characters-would-reach-an-unquoted-shell-loop"),
               (dupes($t.executable)[] | "DUPLICATE_ENTRY field=tools.\($k).executable value=\(.)")
             end),

            # runner / audit
            (["runner","audit"][] | . as $f
             | if ($t|has($f)|not) then empty
               elif (relpath($t[$f])|not) then "UNSAFE_PATH field=tools.\($k).\($f) value_type=\($t[$f]|type) reason=not-a-safe-repo-relative-path"
               elif ($t[$f]|endswith(".sh")|not) then "INVALID_VALUE field=tools.\($k).\($f) value=\($t[$f]) reason=must-be-a-.sh-script"
               else empty end),

            # report
            (if ($t|has("report")|not) then empty
             elif (($t.report|type) != "string") or ($t.report|test($REPORTPAT)|not)
               then "INVALID_REPORT_PATH field=tools.\($k).report value=\($t.report|tojson) pattern=\($REPORTPAT)"
             else empty end),

            # notes
            (if ($t|has("notes")) and (($t.notes|type) != "string")
               then "FIELD_TYPE field=tools.\($k).notes expected=string actual=\($t.notes|type)" else empty end),

            # packages[]
            (if ($t|has("packages")|not) then empty
             elif ($t.packages|type) != "array" then "FIELD_TYPE field=tools.\($k).packages expected=array actual=\($t.packages|type)"
             elif ($t.packages|length) == 0 then "EMPTY_ARRAY field=tools.\($k).packages"
             else ($t.packages | to_entries[] | .key as $i | .value as $p
               | if ($p|type) != "object" then "FIELD_TYPE field=tools.\($k).packages[\($i)] expected=object actual=\($p|type)"
                 else
                   ($p | keys[] | select(. as $x | ($PK | index($x)) == null)
                     | "UNKNOWN_FIELD field=tools.\($k).packages[\($i)].\(.)"),
                   (if ($p|has("name")|not) then "MISSING_REQUIRED_FIELD field=tools.\($k).packages[\($i)].name"
                    elif ($p.name|type) != "string" or ($p.name|length) == 0
                      then "FIELD_TYPE field=tools.\($k).packages[\($i)].name expected=non-empty-string actual=\($p.name|type)"
                    elif ($p.name|test("^[A-Za-z0-9._@/-]+$")|not)
                      then "INVALID_VALUE field=tools.\($k).packages[\($i)].name value=\($p.name|tojson) reason=unsafe-package-identifier"
                    else empty end),
                   (if ($p|has("scope")) and ((enum("scope") | index($p.scope)) == null)
                      then "INVALID_ENUM field=tools.\($k).packages[\($i)].scope value=\($p.scope|tojson) allowed=\($ENUMS["scope"])" else empty end),
                   (if ($p|has("compatibility")) and ((($p.compatibility|type) != "string") or (($p.compatibility|length) == 0))
                      then "FIELD_TYPE field=tools.\($k).packages[\($i)].compatibility expected=non-empty-string actual=\($p.compatibility|type)" else empty end)
                 end)
             end),

            # execution{}
            (if ($t|has("execution")|not) then empty
             elif ($t.execution|type) != "object" then "FIELD_TYPE field=tools.\($k).execution expected=object actual=\($t.execution|type)"
             else
               ($t.execution | keys[] | select(. as $x | ($XK | index($x)) == null)
                 | "UNKNOWN_FIELD field=tools.\($k).execution.\(.)"),
               ($t.execution | to_entries[] | select((.value|type) != "boolean")
                 | "FIELD_TYPE field=tools.\($k).execution.\(.key) expected=boolean actual=\(.value|type)")
             end),

            # config{}
            (if ($t|has("config")|not) then empty
             elif ($t.config|type) != "object" then "FIELD_TYPE field=tools.\($k).config expected=object actual=\($t.config|type)"
             else
               ($t.config | keys[] | select(. as $x | ($CK | index($x)) == null)
                 | "UNKNOWN_FIELD field=tools.\($k).config.\(.)"),
               (if ($t.config|has("path")) and (relpath($t.config.path)|not)
                  then "UNSAFE_PATH field=tools.\($k).config.path value_type=\($t.config.path|type) reason=not-a-safe-project-relative-path" else empty end),
               (if ($t.config|has("classification")) and ((enum("classification") | index($t.config.classification)) == null)
                  then "INVALID_ENUM field=tools.\($k).config.classification value=\($t.config.classification|tojson) allowed=\($ENUMS["classification"])" else empty end)
             end),

            # requires[] / alternatives[] / fallback_order[] — shape only; the
            # cross-tool references are resolved after composition.
            (["requires","alternatives","fallback_order"][] | . as $f
             | if ($t|has($f)|not) then empty
               elif ($t[$f]|type) != "array" then "FIELD_TYPE field=tools.\($k).\($f) expected=array actual=\($t[$f]|type)"
               elif ($t[$f]|length) == 0 then "EMPTY_ARRAY field=tools.\($k).\($f)"
               else
                 ($t[$f] | to_entries[] | select(idok(.value)|not)
                   | "INVALID_IDENTIFIER field=tools.\($k).\($f)[\(.key)] value=\(.value|tojson) pattern=\($IDPAT)"),
                 (dupes($t[$f])[] | "DUPLICATE_ENTRY field=tools.\($k).\($f) value=\(.)"),
                 (if (($t[$f] | index($k)) != null) then "SELF_REFERENCE field=tools.\($k).\($f) value=\($k)" else empty end)
               end),

            # A gating control that runs at NO stage is a gate that can never
            # fire: it is declared, reported as configured, and never executed.
            # `disabled` and `external` are excluded by definition.
            (if (["required","recommended","one-of"] | index($t.policy)) != null
                and ([ ($t.execution // {}) | to_entries[] | select(.value == true) ] | length) == 0
               then "GATING_TOOL_NEVER_RUNS field=tools.\($k) policy=\($t.policy|tojson) execution=\(($t.execution // null)|tojson) reason=a-gating-control-with-no-execution-stage-set-to-true-is-declared-but-never-run"
             else empty end),

            # one-of requires a non-empty alternatives set; alternatives are
            # meaningless (and silently ignored by the resolver) otherwise.
            (if ($t.policy == "one-of") and ($t|has("alternatives")|not)
               then "MISSING_REQUIRED_FIELD field=tools.\($k).alternatives reason=policy-one-of-without-alternatives-can-never-be-satisfied" else empty end),
            (if ($t.policy != "one-of") and ($t|has("alternatives"))
               then "INVALID_VALUE field=tools.\($k).alternatives reason=only-policy-one-of-may-declare-alternatives-this-tool-is-\($t.policy|tojson)" else empty end),
            (if ($t.policy != "one-of") and ($t|has("fallback_order"))
               then "INVALID_VALUE field=tools.\($k).fallback_order reason=only-policy-one-of-may-declare-a-fallback-order" else empty end),
            (if ($t.policy != "one-of") and ($t|has("selection"))
               then "INVALID_VALUE field=tools.\($k).selection reason=only-policy-one-of-may-declare-a-selection-strategy" else empty end),
            # fallback_order decides what bootstrap-profile-tools.sh INSTALLS
            # (fallback_order[0]); a set that disagrees with alternatives makes
            # the engine install something the profile never offered.
            (if ($t|has("fallback_order")) and ($t|has("alternatives"))
                and (($t.fallback_order|sort) != ($t.alternatives|sort))
               then "ONE_OF_FALLBACK_MISMATCH field=tools.\($k).fallback_order fallback=\($t.fallback_order|tojson) alternatives=\($t.alternatives|tojson)" else empty end)
          end)
       )
     end)
  ) else empty end)
  ]
| .[]
PS_JQ
}

# ps__enums_json — the enum table handed to the jq program.
ps__enums_json() {
	jq -n \
		--arg policy "$PS_POLICIES" \
		--arg mb "$PS_MISSING_BEHAVIORS" \
		--arg cls "$PS_CONFIG_CLASSIFICATIONS" \
		--arg mode "$PS_ENTRY_MODES" \
		--arg scope "$PS_PACKAGE_SCOPES" \
		--arg sel "$PS_SELECTIONS" \
		'{policy:$policy, missing_behavior:$mb, classification:$cls, mode:$mode, scope:$scope, selection:$sel}'
}

# The canonical normalized-report path grammar. Tighter than the old
# `^reports/raw/[^/]+\.json$` on what a segment may contain — that form admitted
# spaces, `$`, backticks, a leading dot and `..`, every one of which reaches a
# shell path probe — and LOOSER on depth, because build-security-summary.sh
# preserves directories under reports/raw/ (#236): `reports/raw/api/gitleaks.json`
# is a supported declaration and must not be rejected. Every segment must start
# with an alphanumeric, so no segment can be `.` or `..`.
PS_REPORT_PATTERN='^reports/raw/[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*\.json$'

# ps_manifest_errors <manifest> [role] — print every violation, one per line, on
# stdout. Returns 0 when the manifest is clean, 1 when it is not, 2 when the file
# cannot be read or parsed (a parse failure is itself reported as a line).
ps_manifest_errors() {
	_ps_f="${1:-}"
	_ps_role="${2:-policy}"
	case "$_ps_role" in policy | install) ;; *) printf 'INVALID_ROLE role=%s allowed=policy,install\n' "$_ps_role"; return 2 ;; esac
	command_exists jq || { printf 'JQ_UNAVAILABLE\n'; return 2; }
	[ -n "$_ps_f" ] || { printf 'MANIFEST_MISSING_ARGUMENT\n'; return 2; }
	[ -f "$_ps_f" ] || { printf 'MANIFEST_NOT_FOUND path=%s\n' "$_ps_f"; return 2; }
	[ -r "$_ps_f" ] || { printf 'MANIFEST_UNREADABLE path=%s\n' "$_ps_f"; return 2; }
	if ! jq -e . "$_ps_f" >/dev/null 2>&1; then
		printf 'MANIFEST_NOT_JSON path=%s\n' "$_ps_f"
		return 2
	fi

	_ps_out=$(jq -r \
		--arg IDPAT "$PS_ID_PATTERN" \
		--arg IDMAX "$PS_ID_MAXLEN" \
		--arg TPV "$PS_TOOL_POLICY_VERSION" \
		--arg SCHEMABASE "$PS_SCHEMA_BASENAME" \
		--arg REPORTPAT "$PS_REPORT_PATTERN" \
		--arg ROLE "$_ps_role" \
		--arg TOPKEYS "$PS_TOP_KEYS" \
		--arg TOOLKEYS "$PS_TOOL_KEYS" \
		--arg PKGKEYS "$PS_PACKAGE_KEYS" \
		--arg EXECKEYS "$PS_EXECUTION_KEYS" \
		--arg CFGKEYS "$PS_CONFIG_KEYS" \
		--arg ENTRYKEYS "$PS_ENTRY_KEYS" \
		--argjson ENUMS "$(ps__enums_json)" \
		"$(ps__jq_program)" "$_ps_f" 2>&1) || {
		printf 'VALIDATOR_FAILED path=%s detail=%s\n' "$_ps_f" "$(printf '%s' "$_ps_out" | tr '\n' ' ')"
		return 2
	}
	[ -n "$_ps_out" ] && printf '%s\n' "$_ps_out"

	# Filesystem contract: a declared runner/audit script must exist in this
	# engine. A manifest that names a runner the engine does not ship resolves
	# happily and then fails at execution time, after the plan has been trusted.
	_ps_fs=""
	if _ps_root=$(ps_engine_root); then
		for _ps_p in $(jq -r '(.tools // {}) | to_entries[] | (.value.runner // empty), (.value.audit // empty)' "$_ps_f" 2>/dev/null); do
			case "$_ps_p" in
				*[!A-Za-z0-9._/-]* | */../* | ../* | */.. | /*) continue ;;   # shape errors already reported above
			esac
			[ -f "$_ps_root/$_ps_p" ] || _ps_fs="${_ps_fs}MISSING_SCRIPT path=$_ps_p reason=declared-runner-or-audit-does-not-exist-in-this-engine
"
		done
	fi
	[ -n "$_ps_fs" ] && printf '%s' "$_ps_fs"

	[ -z "$_ps_out" ] && [ -z "$_ps_fs" ] && return 0
	return 1
}

# ps_validate_manifest <manifest> [role] [context] — FAIL-CLOSED validation. On
# any violation it logs every diagnostic and exits 2; the caller never has to
# remember to check a status.
ps_validate_manifest() {
	_ps_mf="${1:-}"
	_ps_r="${2:-policy}"
	_ps_ctx="${3:-}"
	_ps_errs=$(ps_manifest_errors "$_ps_mf" "$_ps_r") && return 0
	log_error "profile manifest failed validation: ${_ps_mf}${_ps_ctx:+ (${_ps_ctx})}"
	printf '%s\n' "$_ps_errs" | while IFS= read -r _ps_l; do
		[ -n "$_ps_l" ] && log_error "  $_ps_l"
	done
	log_error "  see profiles/profile.manifest.schema.json and docs/profile-manifest-validation.md"
	exit 2
}

# --- composed (cross-manifest) semantics -------------------------------------
# Reference integrity cannot be settled inside one manifest: `alternatives` and
# `requires` may name a tool a PARENT declares. These checks therefore run once,
# on the merged inheritance result, before anything acts on it.
ps__composed_program() {
	cat <<'PS_JQ2'
def dupes($v): ($v|group_by(.)|map(select(length>1)|.[0])|unique);
. as $T
| ($T | keys) as $K
| [ $T | to_entries[] | select(.value.policy == "one-of") | .key ] as $ONEOF
| ([ $T | to_entries[] | select(.value.policy == "one-of") | (.value.alternatives // [])[] ] | unique) as $MEMBERS
| [ $ONEOF[] | select(. as $k | ($MEMBERS | index($k)) == null) ] as $GROUPS
| [
    # 1. every alternatives/requires target must be a declared tool.
    ($T | to_entries[] | .key as $k
      | (["alternatives","requires"][] | . as $f
         | (($T[$k][$f] // [])[] | select(. as $r | ($K | index($r)) == null)
            | "UNRESOLVED_REFERENCE field=tools.\($k).\($f) target=\(.) reason=no-manifest-in-the-inheritance-dag-declares-it"))),

    # 2. a one-of population with NO group is a silently-dropped requirement:
    #    ep__one_of_groups derives groups as "one-of tools nobody lists as an
    #    alternative", so a mutually-referencing set yields zero groups and the
    #    control disappears instead of failing closed.
    (if (($ONEOF|length) > 0) and (($GROUPS|length) == 0)
       then "ONE_OF_NO_GROUP tools=\($ONEOF|sort|tojson) reason=every-one-of-tool-is-listed-as-another-one-of-tools-alternative-so-no-group-is-derived-and-the-requirement-vanishes"
     else empty end),

    # 3. every one-of member belongs to exactly one group.
    ($MEMBERS[] | . as $mem
      | ([ $GROUPS[] | select((($T[.].alternatives // []) | index($mem)) != null) ]) as $owners
      | if ($owners|length) == 0 then "ONE_OF_ORPHAN_MEMBER member=\($mem) reason=listed-as-an-alternative-but-no-derived-group-offers-it"
        elif ($owners|length) > 1 then "ONE_OF_AMBIGUOUS_MEMBER member=\($mem) groups=\($owners|sort|tojson)"
        else empty end),

    # 4. a group's alternatives must themselves be one-of controls: a group that
    #    offers a `disabled` or `optional` member can be "satisfied" by a tool
    #    the profile never gates.
    ($GROUPS[] | . as $g | (($T[$g].alternatives // [])[])
      | select(. as $a | ($K | index($a)) != null)
      | select($T[.].policy != "one-of")
      | "ONE_OF_MEMBER_POLICY group=\($g) member=\(.) policy=\($T[.].policy) expected=one-of"),

    # 5. a group offering a single alternative is a `required` control wearing a
    #    one-of label: it reads as "there is a fallback" and there is none.
    ($GROUPS[] | select((($T[.].alternatives // [])|length) < 2)
      | "ONE_OF_SINGLE_MEMBER group=\(.) alternatives=\($T[.].alternatives|tojson) reason=a-one-of-group-with-fewer-than-two-alternatives-offers-no-choice-declare-it-required"),

    # 6. a member's own alternatives must stay inside its group.
    ($GROUPS[] | . as $g | ($T[$g].alternatives // []) as $S
      | $S[] | . as $mem | select(($K | index($mem)) != null)
      | (($T[$mem].alternatives // [])[])
      | select(. as $a | ($S | index($a)) == null)
      | "ONE_OF_CROSS_GROUP group=\($g) member=\($mem) alternative=\(.) reason=member-offers-an-alternative-outside-its-own-group"),

    # 7. duplicate group keys after composition would collapse in the emitted
    #    one_of_groups object.
    (dupes($GROUPS)[] | "ONE_OF_DUPLICATE_GROUP group=\(.)")
  ]
| .[]
PS_JQ2
}

# ps_validate_composed <tools-json> [context] — FAIL-CLOSED cross-manifest check
# of the merged tools map. Exits 2 on any violation.
ps_validate_composed() {
	_ps_tools="${1:-}"
	_ps_cctx="${2:-}"
	[ -n "$_ps_tools" ] || ps__die_cfg "ps_validate_composed: missing tools JSON."
	_ps_cerr=$(printf '%s' "$_ps_tools" | jq -r "$(ps__composed_program)" 2>&1) \
		|| ps__die_cfg "composed-profile validation failed to run${_ps_cctx:+ (${_ps_cctx})}: $(printf '%s' "$_ps_cerr" | tr '\n' ' ')"
	[ -z "$_ps_cerr" ] && return 0
	log_error "composed profile failed semantic validation${_ps_cctx:+ (${_ps_cctx})}"
	printf '%s\n' "$_ps_cerr" | while IFS= read -r _ps_cl; do
		[ -n "$_ps_cl" ] && log_error "  $_ps_cl"
	done
	exit 2
}
