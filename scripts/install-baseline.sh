#!/bin/sh
# Sentinel Shield — profile-driven baseline installer (v0.1.11).
# POSIX sh. SAFE BY DEFAULT: dry-run unless --apply; never overwrites a managed file
# without --force; NEVER creates/overwrites project-local risk decisions
# (.sentinel-shield/accepted-risks.json, phpstan-baseline.neon, ...).
#
# Reads a profile manifest (profiles/<name>/profile.manifest.json or
# profiles/combinations/<name>.manifest.json) and installs its files/workflows/docs into
# a consuming project. The consuming project does NOT copy workflow logic by hand.
#
# Usage:
#   sh scripts/install-baseline.sh --target <dir>                         # dry-run, default profile
#   sh scripts/install-baseline.sh --target <dir> --apply
#   sh scripts/install-baseline.sh --target <dir> --profile laravel --mode baseline --apply
#   sh scripts/install-baseline.sh --target <dir> --apply --force         # overwrite managed files
#   sh scripts/install-baseline.sh --target <dir> --recover               # roll back an interrupted run
#
# Defaults: --profile laravel-react-docker  --mode report-only
#
# TRANSACTIONAL SAFETY (--apply only): a complete plan is emitted before any mutation;
# every file is snapshotted before it is overwritten; a transaction marker is written to
# .sentinel-shield/operation-lock.json for the duration; on failure/interruption the
# snapshotted files are restored automatically. A lock left behind by an ungraceful kill
# (SIGKILL/power loss) is DETECTED on the next --apply and recovered with --recover.
# Installation metadata (.sentinel-shield/installation.json, schema_version "2") is written
# ATOMICALLY (temp + mv) and never partially. accepted-risks.json and project-owned files
# are never written.
#
# Exit codes:
#   0 success (dry-run plan, apply, or recovery)
#   1 gate/findings failure (e.g. require-existing: a required tool's executable is absent)
#   2 invalid config/input (bad args, missing jq, no manifest, not a directory)
#   3 required tool unavailable (require-existing: a one-of group has no present alternative)
#   4 execution error / interrupted prior operation (stale operation-lock; run --recover)
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/compat-resolver.sh
. "$SCRIPT_DIR/lib/compat-resolver.sh"
# shellcheck source=scripts/lib/installation-metadata.sh
. "$SCRIPT_DIR/lib/installation-metadata.sh"
# Opt-in machine-readable envelope (a no-op unless `--output json` is passed).
# Sourced defensively: the envelope layer is an optional add-on, so the command
# still works if the lib is absent (e.g. a minimal copied tree in a test fixture).
if [ -f "$SCRIPT_DIR/lib/output-contract.sh" ]; then
  # shellcheck source=scripts/lib/output-contract.sh
  . "$SCRIPT_DIR/lib/output-contract.sh"
  oc_intercept "install-baseline" "$0" "$@"
fi

TARGET=""; APPLY=0; FORCE=0; PROFILE="laravel-react-docker"; MODE="report-only"
TOOL_MODE="config-only"; EMIT_PLAN=""; EMIT_INSTALL_PLAN=""; NONINTERACTIVE=0; RECOVER=0
VERSION="${SENTINEL_SHIELD_VERSION:-2.0.0}"

# usage — print CLI usage/help to stdout.
usage() {
	cat <<'EOF'
Usage: install-baseline.sh --target <dir> [--profile <name>] [--mode <mode>] [--apply] [--force]
                           [--tool-mode <config-only|require-existing|bootstrap-tools>]
                           [--emit-plan <path>] [--non-interactive]
  --target <dir>     Consuming project directory (required).
  --profile <name>   Profile manifest (default: laravel-react-docker). Also: laravel|react|node|docker.
  --mode <mode>      report-only|baseline|strict|regulated (default: report-only) — written into profile.yaml.
  --apply            Actually write files (and, in bootstrap-tools mode, install packages). Default: dry-run.
  --force            Overwrite MANAGED files (overwrite-if-force mode); never touches project-local files.
  --tool-mode <m>    How the profile's tools are provisioned (default: config-only):
                       config-only       install SS files only; do NOT touch composer.json/package.json;
                                         report which required tools are missing (non-fatal).
                       require-existing  install no packages; FAIL preflight if a required tool's
                                         executable is absent (recommended absent -> warning).
                       bootstrap-tools   inspect versions via compat-resolver and print the exact
                                         install plan (dry-run); with --apply, install packages,
                                         validate the lockfile, run tests, and roll back on failure.
  --emit-plan <path> Write the read-only tool resolution plan (JSON) to <path>.
  --emit-install-plan <path> Write the DETERMINISTIC installation plan (JSON) to <path>
                     (schemas/installation-plan.schema.json): the per-file actions this run would take.
  --non-interactive  Never prompt (accepted for CI parity; this installer does not prompt).
  --recover          Roll back an interrupted prior run (restore snapshots, clear the lock) and exit.
  -h, --help         Show help.
Manifest file modes: create-if-missing | overwrite-if-force | sync-managed-block | manual.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--mode) MODE="${2:?--mode requires a value}"; shift 2 ;;
		--apply) APPLY=1; shift ;;
		--force) FORCE=1; shift ;;
		--tool-mode) TOOL_MODE="${2:?--tool-mode requires a value}"; shift 2 ;;
		--emit-plan) EMIT_PLAN="${2:?--emit-plan requires a value}"; shift 2 ;;
		--emit-install-plan) EMIT_INSTALL_PLAN="${2:?--emit-install-plan requires a value}"; shift 2 ;;
		--non-interactive) NONINTERACTIVE=1; shift ;;
		--recover) RECOVER=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "error: unknown argument '$1'" >&2; usage; exit 2 ;;
	esac
done

[ -n "$TARGET" ] || { echo "error: --target is required" >&2; usage; exit 2; }
[ -d "$TARGET" ] || { echo "error: target '$TARGET' is not a directory" >&2; exit 2; }
# Canonicalise the target so the operation-lock 'target'/'snapshot_dir' are canonical
# (CONTRACT(2)) and recovery can compare them against the current canonical target.
TARGET=$(CDPATH= cd -P -- "$TARGET" && pwd -P) || { echo "error: cannot resolve target '$TARGET'" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 2; }

# --- transaction framework (operation-lock + snapshot/restore) ----------------
# Mutation is wrapped in a transaction: before the first write a marker is left at
# .sentinel-shield/operation-lock.json, every overwritten/created file is snapshotted,
# and on failure/interruption the snapshots are restored. A graceful failure auto-rolls
# back and clears the lock; an ungraceful kill leaves the lock for the next run to detect.
SS_DIR="$TARGET/.sentinel-shield"
LOCK="$SS_DIR/operation-lock.json"
TX_OP="install"; TX_SELF="scripts/install-baseline.sh"; TX_ACTIVE=0; TX_SNAP=""
SUM=""; EFFECTIVE=""
# shellcheck source=scripts/lib/transaction.sh
. "$SCRIPT_DIR/lib/transaction.sh"


# ss_cleanup — single EXIT/INT/TERM handler: auto-rollback on failure, then drop temps.
ss_cleanup() {
	_rc=$?
	trap - EXIT INT TERM
	if [ "${TX_ACTIVE:-0}" = "1" ]; then
		log_warn "install: operation failed/interrupted — rolling back snapshotted files."
		tx_rollback
		rm -f "$LOCK" 2>/dev/null || true
		[ -n "${TX_SNAP:-}" ] && rm -rf "$TX_SNAP" 2>/dev/null || true
		TX_ACTIVE=0
		[ "$_rc" -eq 0 ] && _rc=4
	fi
	[ -n "${SUM:-}" ] && rm -f "$SUM" 2>/dev/null || true
	[ -n "${EFFECTIVE:-}" ] && rm -f "$EFFECTIVE" 2>/dev/null || true
	exit "$_rc"
}
trap ss_cleanup EXIT INT TERM

# --recover is a standalone mode: restore + clear the lock, then exit.
[ "$RECOVER" -eq 1 ] && tx_recover

case "$MODE" in report-only|baseline|strict|regulated) ;; *) echo "error: invalid --mode '$MODE'" >&2; exit 2 ;; esac
case "$TOOL_MODE" in config-only|require-existing|bootstrap-tools) ;; *) echo "error: invalid --tool-mode '$TOOL_MODE'" >&2; usage; exit 2 ;; esac

# Resolve the manifest path from the profile name.
MANIFEST=""
for cand in "profiles/$PROFILE/profile.manifest.json" "profiles/combinations/$PROFILE.manifest.json"; do
	[ -f "$ROOT/$cand" ] && { MANIFEST="$ROOT/$cand"; break; }
done
[ -n "$MANIFEST" ] || { echo "error: no manifest for profile '$PROFILE' (looked in profiles/$PROFILE/ and profiles/combinations/)" >&2; exit 2; }
jq -e . "$MANIFEST" >/dev/null 2>&1 || { echo "error: manifest is not valid JSON: $MANIFEST" >&2; exit 2; }

# Installation-metadata inputs (schema_version "2"). profile_schema = the manifest's
# tool_policy_version. repository/resolved_commit are recorded only when known and carry
# NO credentials: read the credential-free ref record acquire-sentinel-shield.sh writes, or
# the SENTINEL_SHIELD_* env, then DROP any repository value with userinfo ('@').
PROFILE_SCHEMA=$(jq -r '.tool_policy_version // 0' "$MANIFEST" 2>/dev/null || echo 0)
REPOSITORY="${SENTINEL_SHIELD_REPOSITORY:-}"
RESOLVED_COMMIT="${SENTINEL_SHIELD_RESOLVED_COMMIT:-}"
# repository_kind (Finding 6 / CONTRACT(1)): github|url|local. For a local source the
# ref record carries repository=null and repository_kind="local" — the local PATH is
# NEVER persisted. `// empty` collapses a JSON null repository to "" so no path leaks.
REPOSITORY_KIND="${SENTINEL_SHIELD_REPOSITORY_KIND:-}"
if [ -f "$ROOT/.sentinel-shield-ref" ]; then
	[ -n "$REPOSITORY" ] || REPOSITORY=$(jq -r '.repository // empty' "$ROOT/.sentinel-shield-ref" 2>/dev/null || true)
	[ -n "$RESOLVED_COMMIT" ] || RESOLVED_COMMIT=$(jq -r '.resolved_commit // empty' "$ROOT/.sentinel-shield-ref" 2>/dev/null || true)
	[ -n "$REPOSITORY_KIND" ] || REPOSITORY_KIND=$(jq -r '.repository_kind // empty' "$ROOT/.sentinel-shield-ref" 2>/dev/null || true)
fi
# Only the three known kinds are persisted; anything else is dropped.
case "$REPOSITORY_KIND" in github|url|local) ;; *) REPOSITORY_KIND="" ;; esac
# A local source never persists a repository value (it has no credential-free remote ref).
[ "$REPOSITORY_KIND" = "local" ] && REPOSITORY=""
# Persist repository/resolved_commit ONLY when they match a safe, credential-free shape
# (do not rely on im_validate, which checks structure, not these values):
#   - strip any URL query/fragment, then DROP any value carrying userinfo ('@'),
#     an absolute path, or a shape that is not a URL or owner/repo slug;
#   - resolved_commit must be a 7–64 char hex object name or it is dropped.
REPOSITORY=${REPOSITORY%%[#?]*}
case "$REPOSITORY" in
	"") ;;
	*@*) REPOSITORY="" ;;                            # userinfo/credential (or scp-style) — never persist
	http://*|https://*|git://*|ssh://*) ;;          # recognised URL forms
	/*) REPOSITORY="" ;;                             # absolute path is not a repo reference
	.|..|./*|../*) REPOSITORY="" ;;                  # leading ./ or ../ relative path — never a repo slug
	*/./*|*/../*|*/.|*/..) REPOSITORY="" ;;          # embedded/trailing './' or '../' traversal segment
	*/*) ;;                                          # owner/repo (or host/owner/repo) slug
	*) REPOSITORY="" ;;                              # no recognisable repo shape
esac
case "$RESOLVED_COMMIT" in
	"") ;;
	*[!0-9a-fA-F]*) RESOLVED_COMMIT="" ;;            # non-hex content
	*) _rc_len=${#RESOLVED_COMMIT}
		{ [ "$_rc_len" -ge 7 ] && [ "$_rc_len" -le 64 ]; } || RESOLVED_COMMIT="" ;;
esac

# Tool audits consume the COMPOSED effective profile (Blocker 4) — NOT the raw
# manifest — so combination profiles validate their full php+node tool set and
# one-of groups, identical to scripts/resolve-effective-profile.sh. The resolver
# exits 2 on unknown/invalid profiles.
EFFECTIVE=$(mktemp 2>/dev/null || mktemp -t ssinstall)
cr_effective_profile "$ROOT" "$PROFILE" "$TARGET" > "$EFFECTIVE"

[ "$APPLY" -eq 0 ] && echo "DRY-RUN (no files written). Re-run with --apply." || echo "APPLY mode."
echo "Profile:  $PROFILE   ($MANIFEST)"
echo "Mode:     $MODE"
echo "Source:   $ROOT"
echo "Target:   $TARGET"
echo "Force:    $([ "$FORCE" -eq 1 ] && echo yes || echo no)"
echo "Tool-mode:$TOOL_MODE"
echo "------------------------------------------------------------"

# tool_audit <strict> — inspect required/recommended tools that declare an executable.
# strict=1: FAIL (exit 1) when a required tool's executable is absent (require-existing).
# strict=0: only report absent required tools (config-only). Tools without an executable[]
# (external/CI-provided scanners such as gitleaks/semgrep) are not validated locally.
tool_audit() {
	_strict="$1"; _missing=""; _warn=""; _disabled=""; _oneof_unsat=""
	[ -f "$TARGET/.sentinel-shield/installation.json" ] \
		&& _disabled=$(jq -r '(.disabled_tools // [])[]' "$TARGET/.sentinel-shield/installation.json" 2>/dev/null || true)
	_keys=$(cr_tool_keys "$EFFECTIVE")
	_oifs=$IFS
	IFS='
'
	for _k in $_keys; do
		IFS=$_oifs
		[ -n "$_k" ] || { IFS='
'; continue; }
		if printf '%s\n' "$_disabled" | grep -qx "$_k"; then IFS='
'; continue; fi
		_pol=$(cr_tool_policy "$EFFECTIVE" "$_k")
		_exes=$(cr_tool_executables "$EFFECTIVE" "$_k")
		[ -n "$_exes" ] || { IFS='
'; continue; }
		if ! cr_tool_detected "$TARGET" "$EFFECTIVE" "$_k"; then
			case "$_pol" in
				required) _missing="$_missing $_k" ;;
				recommended) _warn="$_warn $_k" ;;
			esac
		fi
		IFS='
'
	done
	IFS=$_oifs
	# one-of groups: a group is satisfied when the resolver selected a present member.
	for _g in $(jq -r '(.one_of_groups // {}) | keys[]' "$EFFECTIVE" 2>/dev/null || true); do
		_sel=$(jq -r --arg g "$_g" '.one_of_groups[$g].selected // ""' "$EFFECTIVE")
		[ -n "$_sel" ] && [ "$_sel" != "null" ] || _oneof_unsat="$_oneof_unsat $_g"
	done
	[ -n "$_warn" ] && echo "tool-audit: recommended tools absent (warning):$_warn" >&2
	if [ -n "$_missing" ]; then
		if [ "$_strict" = "1" ]; then
			echo "error: require-existing: required tools absent (no executable found):$_missing" >&2
			echo "       install them, or use --tool-mode bootstrap-tools, before installing the baseline." >&2
			exit 1
		fi
		echo "tool-audit: required tools absent (config-only does not install them):$_missing"
	else
		echo "tool-audit: all required tools with executables are present."
	fi
	# one-of: none-present under require-existing is a missing required dependency (exit 3).
	if [ -n "$_oneof_unsat" ]; then
		if [ "$_strict" = "1" ]; then
			echo "error: require-existing: one-of group(s) unsatisfied (no alternative present):$_oneof_unsat" >&2
			echo "       install one alternative, or use --tool-mode bootstrap-tools, before installing the baseline." >&2
			exit 3
		fi
		echo "tool-audit: one-of group(s) unsatisfied (config-only does not install them):$_oneof_unsat"
	fi
}

# --emit-plan: write the read-only resolver plan (JSON) by delegating to resolve-tool-plan.sh,
# which now resolves the COMPOSED effective profile (named OR combinations/<name>).
if [ -n "$EMIT_PLAN" ]; then
	if sh "$SCRIPT_DIR/resolve-tool-plan.sh" --profile "$PROFILE" --target "$TARGET" --format json > "$EMIT_PLAN" 2>/dev/null; then
		echo "Tool plan written: $EMIT_PLAN"
	else
		echo "warn: could not emit tool plan to '$EMIT_PLAN' (profile '$PROFILE' could not be resolved)." >&2
		rm -f "$EMIT_PLAN" 2>/dev/null || true
	fi
fi

# require-existing: validate BEFORE writing any files; fail fast if a required tool is absent.
[ "$TOOL_MODE" = "require-existing" ] && tool_audit 1

# Protected (never created/overwritten) — manifest never_touch + hard defaults.
PROTECT=" .sentinel-shield/accepted-risks.json phpstan-baseline.neon "
for p in $(jq -r '(.never_touch // [])[]' "$MANIFEST" 2>/dev/null); do PROTECT="$PROTECT$p "; done

is_protected() { case "$PROTECT" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# emit_install_plan <path> — write a DETERMINISTIC installation-plan JSON
# (schemas/installation-plan.schema.json): the read-only per-file (mode, action, source, target)
# decisions this run WOULD make, sorted by target, plus the protected set. No timestamps, no
# secrets, fixed key order — two runs with the same profile/flags/target are byte-identical.
emit_install_plan() {
	_eip_out="$1"; _eip_ops=$(mktemp)
	jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | "\(.mode)\t\(.source)\t\(.target)"' "$MANIFEST" \
	| while IFS="$(printf '\t')" read -r _m _s _t; do
		[ -n "$_s" ] || continue
		if is_protected "$_t" || [ "$(basename "$_t")" = "accepted-risks.json" ]; then
			_act="protected"
		else
			case "$_m" in
				manual) _act="manual" ;;
				create-if-missing) if [ -e "$TARGET/$_t" ]; then _act="skip-existing"; else _act="create"; fi ;;
				overwrite-if-force|sync-managed-block)
					if [ -e "$TARGET/$_t" ]; then
						if [ "$FORCE" -eq 1 ]; then _act="overwrite-managed"; else _act="skip-managed-no-force"; fi
					else _act="create"; fi ;;
				*) _act="manual" ;;
			esac
		fi
		jq -cn --arg mode "$_m" --arg action "$_act" --arg source "$_s" --arg target "$_t" \
			'{mode:$mode, action:$action, source:$source, target:$target}'
	done | jq -s 'sort_by(.target)' > "$_eip_ops"
	_eip_prot=$(printf '%s' "$PROTECT" | tr ' ' '\n' | sed '/^$/d' | sort -u | jq -R . | jq -s .)
	jq -n \
		--slurpfile ops "$_eip_ops" \
		--argjson protected "$_eip_prot" \
		--arg profile "$PROFILE" \
		--arg mode "$MODE" \
		--argjson apply "$([ "$APPLY" -eq 1 ] && echo true || echo false)" \
		--argjson force "$([ "$FORCE" -eq 1 ] && echo true || echo false)" \
		'{schema_version:"1", generator:"install-baseline", profile:$profile, mode:$mode, apply:$apply, force:$force, protected:$protected, operations:$ops[0]}' \
		> "$_eip_out" || { rm -f "$_eip_ops"; log_error "could not write installation plan to '$_eip_out'"; return 1; }
	rm -f "$_eip_ops"
	echo "Installation plan written: $_eip_out"
}
[ -n "$EMIT_INSTALL_PLAN" ] && emit_install_plan "$EMIT_INSTALL_PLAN"

# Results accumulate in a temp file (the entry loop runs in a subshell via the pipe).
SUM=$(mktemp); : > "$SUM"

do_entry() { # do_entry <source> <target> <mode>
	_src="$ROOT/$1"; _tgt="$TARGET/$2"; _mode="$3"
	if is_protected "$2" || [ "$(basename "$2")" = "accepted-risks.json" ]; then
		echo "PROTECTED (project-local, never written): $2"; echo protect >> "$SUM"; return
	fi
	if [ ! -e "$_src" ]; then echo "skip (missing in Sentinel Shield): $1"; echo skip >> "$SUM"; return; fi
	case "$_mode" in
		manual) echo "MANUAL (copy yourself if wanted): $1 -> $2"; echo manual >> "$SUM"; return ;;
		create-if-missing)
			if [ -e "$_tgt" ]; then echo "skip (exists, project-owned): $2"; echo skip >> "$SUM"; return; fi ;;
		overwrite-if-force|sync-managed-block)
			if [ -e "$_tgt" ] && [ "$FORCE" -eq 0 ]; then
				echo "skip (managed, exists; use --force to update): $2"; echo managed >> "$SUM"; return
			fi ;;
		*) echo "skip (unknown mode '$_mode'): $2"; echo skip >> "$SUM"; return ;;
	esac
	if [ "$APPLY" -eq 0 ]; then echo "would write [$_mode]: $1 -> $2"; echo created >> "$SUM"; return; fi
	tx_snapshot "$2"
	mkdir -p "$(dirname "$_tgt")"
	cp "$_src" "$_tgt"
	tx_journal "mutation" "$2" "wrote managed file [mode=$_mode]"
	if [ "$(basename "$2")" = "profile.yaml" ]; then
		awk -v m="$MODE" 'BEGIN{d=0} /^  mode: / && !d {sub(/^  mode: .*/, "  mode: " m); d=1} {print}' "$_tgt" > "$_tgt.tmp" && mv "$_tgt.tmp" "$_tgt"
	fi
	echo "wrote [$_mode]: $2"; echo created >> "$SUM"
	# Test-only fault seam: simulate a mid-operation crash after a chosen file is written so
	# transactional rollback can be exercised deterministically. Inert unless the env is set.
	if [ -n "${SENTINEL_SHIELD_FAULT_AFTER:-}" ] && [ "$2" = "$SENTINEL_SHIELD_FAULT_AFTER" ]; then
		echo "fault-injection: simulated failure after writing $2" >&2
		exit 1
	fi
}

# Emit the COMPLETE plan BEFORE any mutation: every manifest entry + the protected set.
echo "PLAN ($([ "$APPLY" -eq 1 ] && echo APPLY || echo dry-run)) — operations to be evaluated"
echo "      (managed files are overwritten only with --force; protected files are never written):"
jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | "  - [\(.mode)] \(.source) -> \(.target)"' "$MANIFEST"
echo "  protected (never written):$PROTECT"
echo "------------------------------------------------------------"

# Open the transaction (apply only): snapshot/restore + operation-lock. A stale lock from a
# prior ungraceful kill is detected here and blocks until --recover.
if [ "$APPLY" -eq 1 ]; then
	tx_detect_stale
	tx_begin
fi

# Process files + workflows + docs. Use a here-doc feed so do_entry runs in THIS shell
# (the $SUM counters persist).
ENTRIES=$(jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | "\(.source)\t\(.target)\t\(.mode)"' "$MANIFEST")
OLDIFS=$IFS
printf '%s\n' "$ENTRIES" | while IFS="$(printf '\t')" read -r s t m; do
	[ -n "$s" ] || continue
	do_entry "$s" "$t" "$m"
done
IFS=$OLDIFS

# compute_tools — fill ENABLED_NL/DISABLED_NL (newline lists) from the effective profile.
compute_tools() {
	_en=""; _dis=""
	_keys=$(cr_tool_keys "$EFFECTIVE")
	_o=$IFS; IFS='
'
	for _k in $_keys; do
		IFS=$_o
		[ -n "$_k" ] || { IFS='
'; continue; }
		_pol=$(cr_tool_policy "$EFFECTIVE" "$_k")
		if [ "$_pol" = "disabled" ]; then _dis="$_dis$_k
"; IFS='
'; continue; fi
		_exes=$(cr_tool_executables "$EFFECTIVE" "$_k")
		if [ -z "$_exes" ] || cr_tool_detected "$TARGET" "$EFFECTIVE" "$_k"; then _en="$_en$_k
"; fi
		IFS='
'
	done
	IFS=$_o
	ENABLED_NL=$(printf '%s' "$_en" | sort -u | sed '/^$/d')
	DISABLED_NL=$(printf '%s' "$_dis" | sort -u | sed '/^$/d')
}

# ss_write_installation — ATOMICALLY (temp + mv) write the schema_version "2" record.
ss_write_installation() {
	_out="$SS_DIR/installation.json"
	ensure_dir "$SS_DIR"
	_now=$(timestamp_utc); _installed_at="$_now"
	if [ -f "$_out" ]; then
		_prev=$(jq -r '.installed_at // empty' "$_out" 2>/dev/null || true)
		[ -n "$_prev" ] && _installed_at="$_prev"
	fi
	tx_snapshot ".sentinel-shield/installation.json"
	_tmp="$_out.tmp.$$"
	jq -n \
		--arg version "$VERSION" \
		--arg profile "$PROFILE" \
		--argjson profile_schema "${PROFILE_SCHEMA:-0}" \
		--arg tool_mode "$TOOL_MODE" \
		--arg installed_at "$_installed_at" \
		--arg updated_at "$_now" \
		--arg repository "$REPOSITORY" \
		--arg repository_kind "$REPOSITORY_KIND" \
		--arg resolved_commit "$RESOLVED_COMMIT" \
		--arg managed "$MANAGED_NL" \
		--arg owned "$PROJECT_NL" \
		--arg enabled "$ENABLED_NL" \
		--arg disabled "$DISABLED_NL" '
		def lines($s): ($s | split("\n") | map(select(length > 0)));
		{
			schema_version: "2",
			version: $version,
			profile: $profile,
			profile_schema: $profile_schema,
			tool_mode: $tool_mode,
			installed_at: $installed_at,
			updated_at: $updated_at,
			managed_files: lines($managed),
			project_owned_files: lines($owned),
			enabled_tools: lines($enabled),
			disabled_tools: lines($disabled)
		}
		+ (if ($repository_kind | length) > 0 then {repository_kind: $repository_kind} else {} end)
		+ (if ($repository | length) > 0 then {repository: $repository} else {} end)
		+ (if ($resolved_commit | length) > 0 then {resolved_commit: $resolved_commit} else {} end)
		' > "$_tmp" || { log_error "could not serialise installation.json"; rm -f "$_tmp" 2>/dev/null || true; return 1; }
	im_validate "$_tmp" >/dev/null 2>&1 || { log_error "produced a non-conforming installation.json"; rm -f "$_tmp" 2>/dev/null || true; return 1; }
	tx_journal "validation" ".sentinel-shield/installation.json" "installation record conforms to schema_version 2"
	mv -- "$_tmp" "$_out"
	log_info "installation-metadata: wrote $_out (schema_version 2)"
}

# Record installation metadata (apply only), then close the transaction. The metadata
# write is part of the transaction so a failure here also rolls back.
if [ "$APPLY" -eq 1 ]; then
	MANAGED_NL=$(jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | select(.mode=="overwrite-if-force" or .mode=="sync-managed-block") | .target' "$MANIFEST" | sort -u | sed '/^$/d')
	PROJECT_NL=$(jq -r '((.files // []) + (.workflows // []) + (.docs // []))[] | select(.mode=="create-if-missing") | .target' "$MANIFEST" | sort -u | sed '/^$/d')
	for _pl in .sentinel-shield/accepted-risks.json phpstan-baseline.neon .sentinel-shield/profile.yaml; do
		[ -e "$TARGET/$_pl" ] && PROJECT_NL=$(printf '%s\n%s' "$PROJECT_NL" "$_pl")
	done
	PROJECT_NL=$(printf '%s\n' "$PROJECT_NL" | sort -u | sed '/^$/d')
	ENABLED_NL=""; DISABLED_NL=""; compute_tools
	ss_write_installation || { log_error "install: failed to record installation metadata."; exit 4; }
	tx_commit
fi

echo "------------------------------------------------------------"
echo "Required upstream scripts (live in Sentinel Shield; the workflow calls them via SENTINEL_SHIELD_PATH):"
jq -r '(.required_scripts // [])[] | "  - " + .' "$MANIFEST"
echo "Recommended raw reports the pipeline produces: $(jq -r '(.recommended_raw_reports // []) | join(", ")' "$MANIFEST")"
echo "------------------------------------------------------------"
echo "SUMMARY: created/would-create=$(grep -c '^created' "$SUM" 2>/dev/null || echo 0)  managed-skipped=$(grep -c '^managed' "$SUM" 2>/dev/null || echo 0)  skipped=$(grep -c '^skip' "$SUM" 2>/dev/null || echo 0)  manual=$(grep -c '^manual' "$SUM" 2>/dev/null || echo 0)  protected=$(grep -c '^protect' "$SUM" 2>/dev/null || echo 0)"
echo "Project-local files NEVER touched: accepted-risks.json, phpstan-baseline.neon (+ manifest never_touch)."
if [ "$APPLY" -eq 0 ]; then
	echo "Dry-run complete. Re-run with --apply to write; add --force to update managed files (workflow)."
else
	echo "Install complete. Next:"
	echo "  1. Review .sentinel-shield/profile.yaml (mode=$MODE) + project metadata."
	echo "  2. Set SENTINEL_SHIELD_REPOSITORY + a pinned SENTINEL_SHIELD_REF in .github/workflows/sentinel-shield.yml."
	echo "  3. Copy .sentinel-shield/accepted-risks.example.json -> accepted-risks.json ONLY when accepting a risk (owner-approved)."
	echo "  4. Run the pipeline (push/PR or workflow_dispatch)."
fi

# --- tool provisioning (per --tool-mode) ------------------------------------
echo "------------------------------------------------------------"
case "$TOOL_MODE" in
	config-only)
		echo "tool-mode=config-only: dependency files (composer.json/package.json) left untouched."
		tool_audit 0
		;;
	require-existing)
		echo "tool-mode=require-existing: required tools validated above; no packages installed."
		;;
	bootstrap-tools)
		echo "tool-mode=bootstrap-tools: delegating to bootstrap-profile-tools.sh ($([ "$APPLY" -eq 1 ] && echo 'apply' || echo 'dry-run'))."
		if [ "$APPLY" -eq 1 ]; then
			sh "$SCRIPT_DIR/bootstrap-profile-tools.sh" --profile "$PROFILE" --target "$TARGET" --apply \
				|| { echo "error: tool bootstrap failed (dependency files were rolled back)." >&2; exit 1; }
		else
			sh "$SCRIPT_DIR/bootstrap-profile-tools.sh" --profile "$PROFILE" --target "$TARGET" --dry-run \
				|| { echo "error: tool bootstrap planning failed." >&2; exit 1; }
		fi
		;;
esac
