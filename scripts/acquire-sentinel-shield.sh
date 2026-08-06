#!/bin/sh
# Sentinel Shield — trusted source acquisition (v2; source-identity model #151/#152).
#
# The single canonical mechanism every install/update prompt and doc uses to obtain a
# Sentinel Shield checkout. It acquires a repository at a TAG or a full 40-hex commit SHA
# only — moving branches (main/master, or any non-tag/non-SHA ref) are REFUSED. Credentials
# are NEVER embedded in URLs or printed; authentication is delegated out-of-band (public
# HTTPS, the `gh` CLI's git credential helper, or SSH keys).
#
# SOURCE IDENTITY IS NOT A REF NAME (#151). A git tag can be deleted and recreated or
# force-moved, so a tag NAME is a *request*, not an identity. This command therefore records
# the requested ref, the resolved commit, and the resolved tree as three SEPARATE values, and
# labels the acquisition with an explicit TRUST ANCHOR:
#   requested-commit  the caller asked for a full 40-hex SHA — the request IS the anchor.
#   expected-tree     --verify-source tree-checksum matched a caller-supplied tree id.
#   signed-tag        an annotated tag verified against a caller-supplied TRUSTED SIGNER
#                     policy (--trusted-signers / --revoked-signers).
# A tag acquired with NONE of the above is recorded as trust level `resolved-ref` with
# anchored=false. It is a point-in-time resolution, and this command never calls it immutable.
# `--require-trust anchored` (or SENTINEL_SHIELD_REQUIRE_TRUST=anchored) makes an unanchored
# acquisition FAIL CLOSED — the setting production/release automation must use.
#
# THE HEAD/ref CONSISTENCY CHECK IS NOT OPTIONAL (#152). `--no-verify` has been REMOVED and is
# now a hard invocation error with a migration message; there is no unsafe development mode, so
# no record can ever be emitted for an unverified checkout. Acquisition also fetches and checks
# out the EXACT resolved object rather than re-resolving a mutable name, and independently
# re-verifies the fetched ref->commit relationship, so a tag that moves BETWEEN resolution and
# fetch is detected and fails closed rather than being silently installed.
#
# Output contract:
#   exit 0  -> success; the resolved commit SHA is printed to stdout
#   exit 1  -> generic error (reserved)
#   exit 2  -> invalid invocation / bad args / MOVING-BRANCH (non-immutable ref) rejected
#   exit 3  -> required tool unavailable (git, jq, or `gh` for --transport gh)
#   exit 4  -> fetch / ref-resolution / verification failure (fails CLOSED)
#   exit 5  -> SOURCE TRUST INCIDENT: a moved tag, a ref that changed between resolution and
#              fetch, or a required trust anchor that could not be established (fails CLOSED)
#
# Usage: sh scripts/acquire-sentinel-shield.sh --repository <owner/repo|url|path>
#            --ref <tag|40-hex-sha> --destination <dir>
#            [--transport https|ssh|gh] [--verify] [--require-trust any|anchored]
#            [--trusted-signers <file>] [--revoked-signers <file>]
#            [--reuse-existing] [--cleanup]
#   --repository  owner/repo shorthand (resolved per --transport), OR an explicit remote
#                 (https://, ssh://, git@host:..., or a local path) used verbatim.
#   --ref         A tag, or a full 40-hex commit SHA. Branch names and short SHAs are
#                 REJECTED (exit 2). A tag alone is NOT an immutability anchor — see above.
#   --destination The checkout directory (the ONLY path mutated in the consumer project).
#   --transport   Remote scheme for owner/repo shorthand: https (default), ssh, or gh.
#   --verify      Accepted for compatibility; the HEAD==resolved-commit assertion is now
#                 ALWAYS performed and cannot be disabled.
#   --reuse-existing  Reuse a present checkout whose HEAD already matches instead of fetching.
#   --cleanup     Remove the destination first (may be used alone to just clean up).
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/source-verification.sh
. "$SCRIPT_DIR/lib/source-verification.sh"
# shellcheck source=scripts/lib/release-authz.sh
. "$SCRIPT_DIR/lib/release-authz.sh"   # ra_bounded: cap remote git/gh operations where timeout(1) exists
# Ceiling (seconds) for a single remote git/gh operation so a hung/unreachable remote cannot stall
# install/update forever. Generous by default (large-repo clones); override via the env var.
: "${GIT_NET_TIMEOUT:=300}"

# usage — print CLI usage/help to stdout (lists every flag).
usage() {
	cat <<'EOF'
Usage: acquire-sentinel-shield.sh --repository <owner/repo|url|path> --ref <tag|40-hex-sha> --destination <dir>
                                  [--transport https|ssh|gh] [--verify] [--require-trust any|anchored]
                                  [--trusted-signers <file>] [--revoked-signers <file>]
                                  [--reuse-existing] [--cleanup]
  --repository <owner/repo|url|path>  Source repo: owner/repo shorthand or an explicit remote/local path.
  --ref <tag|40-hex-sha>              Tag or full 40-hex SHA; moving branches are refused. A tag NAME is a
                                      request, NOT an immutable identity — anchor it (see --require-trust).
  --destination <dir>                 Checkout directory (the only path mutated).
  --transport https|ssh|gh            Remote scheme for owner/repo shorthand (default: https).
  --verify                            Accepted for compatibility. HEAD == resolved-commit is ALWAYS asserted
                                      and can no longer be disabled (--no-verify was REMOVED).
  --require-trust any|anchored        'anchored' (production/release) FAILS CLOSED (exit 5) unless the
                                      acquisition carries a real trust anchor: a requested 40-hex commit,
                                      a matched --expected-tree, or a signed tag accepted by
                                      --trusted-signers. Default 'any' (env: SENTINEL_SHIELD_REQUIRE_TRUST).
  --trusted-signers <file>            Trusted-signer policy for --verify-source signature: an OpenSSH
                                      allowed-signers file, and/or a list of accepted GPG fingerprints
                                      (one per line, '#' comments). Without it a good signature proves only
                                      that SOME key git trusts signed the tag — it is NOT a trust anchor.
  --revoked-signers <file>            Revoked signers (same formats). A match FAILS CLOSED.
  --verify-source <mode>              OPTIONAL extra verification of the acquired checkout (default none):
                                        tree-record            RECORD the deterministic HEAD tree id (NOT a check).
                                        tree-checksum          compare HEAD tree to --expected-tree; fail closed.
                                        signature              verify a signed annotated tag (GPG or SSH); fail closed.
                                        tree-checksum+signature  both. (deprecated alias: checksum -> tree-record.)
                                      Every mode ALSO asserts HEAD == the resolved commit first.
  --expected-tree <40-hex>            REQUIRED with tree-checksum modes: the expected HEAD tree object id.
  --reuse-existing                    Reuse a present matching checkout instead of re-cloning.
  --cleanup                           Remove the destination first (or alone, just clean up).
  -h, --help                          Print this help and exit 0.
EOF
}

# write_source_record <dest> <repo_kind> <repository|""> <ref> <commit> <ref_kind> — record the
# acquisition in the NORMALIZED, privacy-preserving shape (SHARED CONTRACT 1; see
# schemas/installation-metadata.schema.json), schema_version 2. NO credentials and NO local/home
# paths are ever persisted: a local-path source records repository=null. repository_kind is
# github|url|local; ref_kind is the authoritative tag|sha classification.
#
# SERIALIZER-BACKED (#151/#152): the document is produced by `jq -n` from typed arguments, never
# by string concatenation — hand-rolled escaping cannot round-trip a ref/repository containing a
# quote, backslash, newline, or control character, and a metadata record that mis-escapes is a
# trust record that cannot be parsed. jq is therefore REQUIRED (exit 3 when absent); every reader
# of this record (doctor.sh, install-baseline.sh) already requires it.
#
# The record separates the three values a source identity is made of — the REQUESTED ref, the
# RESOLVED commit, and the RESOLVED tree — and states the trust anchor explicitly. Globals read:
#   VMETHOD          none|tree-record|tree-checksum|signature|tree-checksum+signature
#   RESOLVED_TREE    the HEAD tree object id of the acquired checkout (always recorded)
#   TREE_EXP/CALC    caller-supplied expected tree (tree-checksum only) / computed tree
#   SIG_STATUS/…     good + mechanism/tag_object/peeled_commit (signature modes only)
#   TRUST_LEVEL      resolved-ref | requested-commit | expected-tree | signed-tag
#   TRUST_ANCHORED   JSON true/false — whether identity is anchored outside the ref namespace
#   TRUST_ANCHORS    space-separated anchor tokens actually established
#   SIGNER_ID        stable, non-secret signer id (fingerprint/principal), signature modes only
#   SIGNER_POLICY    trusted-signers-file | ambient-git-trust (signature modes only)
#   VERIFIED_AT      RFC3339 UTC timestamp of the verification
# tree-record NEVER records a tree_expected — an uncompared value is a RECORD, not a match.
# The write is atomic within the destination (temp file + rename), so a reader never observes a
# half-written trust record.
write_source_record() {
	command_exists jq || {
		log_error "acquire: jq is required to serialize the acquisition record (install jq; every reader of .sentinel-shield-ref already requires it)"
		return 3
	}
	_rec_tmp="$1/.sentinel-shield-ref.$$"
	jq -n \
		--arg rkind "$2" --arg repo "$3" --arg rf "$4" --arg commit "$5" --arg kind "$6" \
		--arg vm "${VMETHOD:-none}" --arg tree "${RESOLVED_TREE:-}" \
		--arg texp "${TREE_EXP:-}" --arg tcalc "${TREE_CALC:-}" \
		--arg sstat "${SIG_STATUS:-}" --arg smech "${SIG_MECH:-}" \
		--arg tagobj "${TAG_OBJ:-}" --arg peeled "${PEELED:-}" \
		--arg level "${TRUST_LEVEL:-resolved-ref}" --arg anchors "${TRUST_ANCHORS:-}" \
		--arg signer "${SIGNER_ID:-}" --arg spolicy "${SIGNER_POLICY:-}" \
		--arg vat "${VERIFIED_AT:-}" --argjson anchored "${TRUST_ANCHORED:-false}" \
		'{schema_version: 2,
		  repository_kind: $rkind,
		  repository: (if $repo == "" then null else $repo end),
		  ref: $rf,
		  resolved_commit: $commit,
		  ref_kind: $kind,
		  verification_method: $vm,
		  trust: ({ level: $level,
		            anchored: $anchored,
		            anchors: ($anchors | split(" ") | map(select(length > 0))),
		            verified_at: $vat }
		          + (if $signer  == "" then {} else { signer: $signer } end)
		          + (if $spolicy == "" then {} else { signer_policy: $spolicy } end))}
		 + (if $tree   == "" then {} else { resolved_tree: $tree } end)
		 + (if $texp   == "" then {} else { tree_expected: $texp } end)
		 + (if $tcalc  == "" then {} else { tree_calculated: $tcalc } end)
		 + (if $sstat  == "" then {} else { signature_status: $sstat,
		                                    signature_mechanism: (if $smech == "" then "unknown" else $smech end) } end)
		 + (if $tagobj == "" then {} else { tag_object: $tagobj } end)
		 + (if $peeled == "" then {} else { peeled_commit: $peeled } end)' > "$_rec_tmp" || {
		rm -f -- "$_rec_tmp" 2>/dev/null || true
		log_error "acquire: cannot serialize the acquisition record for $1/.sentinel-shield-ref"; return 1
	}
	mv -- "$_rec_tmp" "$1/.sentinel-shield-ref" || {
		rm -f -- "$_rec_tmp" 2>/dev/null || true
		log_error "acquire: cannot write ref record to $1/.sentinel-shield-ref"; return 1
	}
}

# acquire_prior_record <dest> <field> — read a field from a PRE-EXISTING acquisition record at
# <dest>/.sentinel-shield-ref, or print nothing. Used to detect a MOVED TAG (#151) before the
# destination is touched. Never fails the caller: an absent, unreadable, or malformed record
# simply yields no prior identity to compare against.
acquire_prior_record() {
	[ -f "$1/.sentinel-shield-ref" ] || return 0
	command_exists jq || return 0
	jq -r "$2 // empty" "$1/.sentinel-shield-ref" 2>/dev/null || true
}

# acquire_assert_not_moved <dest> <repo_norm> <ref> <expected_commit> — FAIL CLOSED (exit 5) when
# this destination previously recorded the SAME repository and the SAME tag name resolving to a
# DIFFERENT commit. That is a moved-tag incident: the requested version is unchanged but the code
# behind it is not, which is precisely the failure a tag name cannot rule out (#151).
# Only compared for ref_kind=tag: a 40-hex SHA request cannot move by construction.
# The operator resolves it deliberately — inspect the change, then either re-pin to the new commit
# SHA or discard the old checkout with a standalone `--cleanup` before re-acquiring. There is no
# flag that suppresses this check, because a flag would be exactly how it gets suppressed.
acquire_assert_not_moved() {
	_pm_prior_kind=$(acquire_prior_record "$1" '.ref_kind')
	[ "$_pm_prior_kind" = "tag" ] || return 0
	_pm_prior_ref=$(acquire_prior_record "$1" '.ref')
	[ "$_pm_prior_ref" = "$3" ] || return 0
	_pm_prior_repo=$(acquire_prior_record "$1" '.repository')
	[ "$_pm_prior_repo" = "$2" ] || return 0
	_pm_prior_commit=$(acquire_prior_record "$1" '.resolved_commit')
	[ -n "$_pm_prior_commit" ] || return 0
	[ "$_pm_prior_commit" = "$4" ] && return 0
	log_error "acquire: MOVED-TAG INCIDENT — tag '$3' previously resolved to $_pm_prior_commit at this destination but now resolves to $4."
	log_error "acquire: the requested version did not change but the code behind it did; a tag name is not an immutable identity."
	log_error "acquire: refusing to install silently. Inspect the difference, then either pin --ref $4 (a commit SHA cannot move) or discard the old checkout with: sh scripts/acquire-sentinel-shield.sh --destination <dir> --cleanup"
	exit 5
}

# acquire_run_source_verify <dir> <ref> <expected> <ref_kind> — run OPTIONAL source verification
# per the global VERIFY_SOURCE and EXPECTED_TREE, then COMPUTE THE TRUST ANCHOR SET. Sets the
# record globals consumed by write_source_record: VMETHOD (normalized method; "none" when
# disabled), RESOLVED_TREE (always), TREE_EXP/TREE_CALC (tree modes), SIG_STATUS/SIG_MECH/
# TAG_OBJ/PEELED/SIGNER_ID/SIGNER_POLICY (signature modes), and TRUST_LEVEL/TRUST_ANCHORED/
# TRUST_ANCHORS/VERIFIED_AT. FAILS CLOSED (exit 4) on any verification failure.
#
# THE ANCHOR RULES (#151) — an anchor is a binding that exists OUTSIDE the mutable ref namespace:
#   requested-commit  the caller named a full 40-hex SHA; the request itself pins the content.
#   expected-tree     the caller supplied a tree id and it matched exactly.
#   signed-tag        a good signature whose signer was accepted by an EXPLICIT trusted-signer
#                     policy. A good signature under AMBIENT git trust (whatever keys happen to
#                     be in the local keyring, with no policy file) is recorded honestly but is
#                     NOT an anchor: it proves someone signed the tag, not that the release
#                     signer did.
# With no anchor the level is `resolved-ref` and anchored=false — an honest statement that this
# is a point-in-time resolution of a name that can move.
acquire_run_source_verify() {
	VMETHOD="none"; TREE_EXP=""; TREE_CALC=""; SIG_STATUS=""; SIG_MECH=""; TAG_OBJ=""; PEELED=""
	SIGNER_ID=""; SIGNER_POLICY=""; TRUST_ANCHORS=""; TRUST_ANCHORED="false"; TRUST_LEVEL="resolved-ref"
	VERIFIED_AT=$(timestamp_utc)
	RESOLVED_TREE=$(sv_tree_checksum "$1" 2>/dev/null || true)

	if [ "$VERIFY_SOURCE" != "none" ]; then
		VMETHOD=$(sv_verify "$1" "$2" "$3" "$VERIFY_SOURCE" "$EXPECTED_TREE") || {
			log_error "acquire: source verification (--verify-source $VERIFY_SOURCE) FAILED — fail closed"; exit 4; }
		case "$VMETHOD" in
			*tree-record* | *tree-checksum*) TREE_CALC="$RESOLVED_TREE" ;;
		esac
		case "$VMETHOD" in
			*tree-checksum*) TREE_EXP=$(printf '%s' "$EXPECTED_TREE" | tr 'A-F' 'a-f') ;;
		esac
		case "$VMETHOD" in
			*signature*)
				SIG_STATUS="good"
				SIG_MECH=$(sv_signature_mechanism "$1" "$2" 2>/dev/null || printf 'unknown')
				TAG_OBJ=$(sv_tag_object "$1" "$2")
				PEELED=$(sv_tag_peeled_commit "$1" "$2")
				SIGNER_ID=$(sv_signer_identity "$1" "$2" 2>/dev/null || true)
				if [ -n "$TRUSTED_SIGNERS" ]; then
					SIGNER_POLICY="trusted-signers-file"
				else
					SIGNER_POLICY="ambient-git-trust"
				fi
				;;
		esac
	fi

	# --- anchor set ---------------------------------------------------------
	if [ "$4" = "sha" ]; then
		TRUST_ANCHORS="$TRUST_ANCHORS requested-commit"
	fi
	case "$VMETHOD" in
		*tree-checksum*) TRUST_ANCHORS="$TRUST_ANCHORS expected-tree" ;;
	esac
	if [ "$SIGNER_POLICY" = "trusted-signers-file" ]; then
		TRUST_ANCHORS="$TRUST_ANCHORS signed-tag"
	elif [ "$SIGNER_POLICY" = "ambient-git-trust" ]; then
		log_warn "acquire: the tag signature verified against AMBIENT git trust (no --trusted-signers policy) — recorded, but NOT counted as a trust anchor: it does not prove WHICH identity signed the release"
	fi
	TRUST_ANCHORS=$(printf '%s' "$TRUST_ANCHORS" | sed 's/^ *//')
	# Strongest established anchor names the level (signed-tag > expected-tree > requested-commit).
	case " $TRUST_ANCHORS " in
		*" signed-tag "*)       TRUST_LEVEL="signed-tag";       TRUST_ANCHORED="true" ;;
		*" expected-tree "*)    TRUST_LEVEL="expected-tree";    TRUST_ANCHORED="true" ;;
		*" requested-commit "*) TRUST_LEVEL="requested-commit"; TRUST_ANCHORED="true" ;;
		*)                      TRUST_LEVEL="resolved-ref";     TRUST_ANCHORED="false" ;;
	esac

	# --- production trust gate ---------------------------------------------
	if [ "$REQUIRE_TRUST" = "anchored" ] && [ "$TRUST_ANCHORED" != "true" ]; then
		log_error "acquire: --require-trust anchored, but this acquisition has NO trust anchor (level=$TRUST_LEVEL)."
		log_error "acquire: a tag name resolved at one moment in time is not an immutable identity. Anchor it with ONE of:"
		log_error "acquire:   --ref <40-hex commit SHA>"
		log_error "acquire:   --verify-source tree-checksum --expected-tree <40-hex tree id>"
		log_error "acquire:   --verify-source signature --trusted-signers <allowed-signers file>"
		exit 5
	fi
}

# acquire_sanitize_url <url> — strip userinfo, query, and fragment from an explicit remote
# URL so no secret/identity is persisted in the ref record (privacy). Path is preserved.
acquire_sanitize_url() {
	_u=$1
	_u=${_u%%#*}    # drop #fragment
	_u=${_u%%\?*}   # drop ?query
	case "$_u" in
		*://*)
			_sch=${_u%%://*}
			_rest=${_u#*://}
			_host=${_rest%%/*}
			_path=${_rest#"$_host"}
			case "$_host" in *@*) _host=${_host#*@} ;; esac   # drop userinfo@
			_u="$_sch://$_host$_path"
			;;
		*@*:*)
			_u=${_u#*@}   # scp-form git@host:path -> host:path
			;;
	esac
	printf '%s' "$_u"
}

# acquire_canonical <path> — canonical absolute path WITHOUT requiring <path> to exist:
# resolve the (existing) parent dir, then append the basename. Echoes nothing and returns
# 1 when the parent cannot be resolved, so the caller can fail closed.
acquire_canonical() {
	_ap=$1
	_par=$(dirname -- "$_ap")
	_bas=$(basename -- "$_ap")
	_cpar=$(CDPATH= cd -- "$_par" 2>/dev/null && pwd -P) || return 1
	case "$_cpar" in
		/) printf '/%s' "$_bas" ;;
		*) printf '%s/%s' "$_cpar" "$_bas" ;;
	esac
}

# acquire_validate_destination <path> — the SINGLE destructive-destination guard called
# before EVERY `rm -rf "$DEST"`. It deletes NOTHING; on any unsafe path it logs and
# exit 2. Refuses: empty; '/'; '.'/'..'; a path with a '..' component; a symlink (never
# followed — at most the symlink itself, which we still refuse here); the CWD; $HOME; the
# Sentinel Shield SOURCE repo root (SCRIPT_DIR/..); a known consumer TARGET root
# (SENTINEL_SHIELD_TARGET_ROOT); and any ancestor of the CWD. PERMITS only a dedicated
# tools dir, proven by CANONICAL CONTAINMENT (never basename matching alone): a canonical
# path whose basename is '.sentinel-shield-tools' or that sits under a 'tools/' dir.
acquire_validate_destination() {
	_d=$1
	[ -n "$_d" ] || { log_error "acquire: refusing to remove an empty destination"; exit 2; }
	case "/$_d/" in
		*/../*) log_error "acquire: refusing destination with unresolved '..' traversal: $_d"; exit 2 ;;
	esac
	case "$_d" in
		/ | . | ..) log_error "acquire: refusing unsafe destination: $_d"; exit 2 ;;
	esac
	if [ -L "$_d" ]; then
		log_error "acquire: refusing to delete a symlink destination (will not follow): $_d"; exit 2
	fi
	_canon=$(acquire_canonical "$_d") || {
		log_error "acquire: cannot resolve destination parent — refusing: $_d"; exit 2; }
	[ "$_canon" != "/" ] || { log_error "acquire: refusing to remove '/'"; exit 2; }

	_cwd=$(pwd -P)
	_home=""
	if [ -n "${HOME:-}" ]; then
		_home=$(CDPATH= cd -- "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")
	fi
	_src=$(CDPATH= cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P || printf '')
	_tgt=""
	if [ -n "${SENTINEL_SHIELD_TARGET_ROOT:-}" ]; then
		_tgt=$(CDPATH= cd -- "$SENTINEL_SHIELD_TARGET_ROOT" 2>/dev/null && pwd -P \
			|| printf '%s' "$SENTINEL_SHIELD_TARGET_ROOT")
	fi
	for _bad in "$_cwd" "$_home" "$_src" "$_tgt"; do
		[ -n "$_bad" ] || continue
		if [ "$_canon" = "$_bad" ]; then
			log_error "acquire: refusing to remove a protected path: $_d"; exit 2
		fi
	done
	# An ancestor of the CWD (DEST physically contains the current directory).
	case "$_cwd/" in
		"$_canon"/*) log_error "acquire: refusing to remove an ancestor of the current directory: $_d"; exit 2 ;;
	esac

	# PERMIT only a dedicated tools dir (canonical containment).
	_base=$(basename -- "$_canon")
	[ "$_base" = ".sentinel-shield-tools" ] && return 0
	case "$_canon" in
		*/tools/*) return 0 ;;
	esac
	log_error "acquire: refusing to delete a non-tools destination (only '.sentinel-shield-tools' or a path under a 'tools/' dir may be removed): $_d"
	exit 2
}

REPO=""
REF=""
DEST=""
TRANSPORT="https"
VERIFY_SOURCE="none"
EXPECTED_TREE=""
TRUSTED_SIGNERS=""
REVOKED_SIGNERS=""
REQUIRE_TRUST="${SENTINEL_SHIELD_REQUIRE_TRUST:-any}"
VMETHOD="none"
RESOLVED_TREE=""
TREE_EXP=""
TREE_CALC=""
SIG_STATUS=""
SIG_MECH=""
TAG_OBJ=""
PEELED=""
SIGNER_ID=""
SIGNER_POLICY=""
TRUST_LEVEL="resolved-ref"
TRUST_ANCHORED="false"
TRUST_ANCHORS=""
VERIFIED_AT=""
REUSE=0
CLEANUP=0
while [ $# -gt 0 ]; do
	case "$1" in
		--repository) REPO="${2:?--repository requires a value}"; shift 2 ;;
		--ref) REF="${2:?--ref requires a value}"; shift 2 ;;
		--destination)
			[ $# -ge 2 ] || { log_error "acquire: --destination requires a value"; exit 2; }
			DEST="$2"; shift 2 ;;
		--transport) TRANSPORT="${2:?--transport requires a value}"; shift 2 ;;
		# --verify is the permanent default; the flag stays accepted so documented and copied
		# invocations keep working, but it no longer selects anything.
		--verify) shift ;;
		--no-verify)
			# REMOVED (#152). Silently ignoring it would be the worst outcome: a caller that asked
			# to skip verification would believe it had, while automation kept propagating the flag.
			log_error "acquire: --no-verify has been REMOVED — the HEAD == resolved-commit assertion is not optional."
			log_error "acquire: it created a time-of-check/time-of-use gap: the tag was resolved, then cloned by NAME, and a tag that moved in between was accepted and recorded as the requested version."
			log_error "acquire: migration: drop the flag. Acquisition now fetches the EXACT resolved object and re-verifies the ref->commit relationship, so the check costs nothing and cannot be skipped."
			exit 2 ;;
		--verify-source) VERIFY_SOURCE="${2:?--verify-source requires a value}"; shift 2 ;;
		--expected-tree) EXPECTED_TREE="${2:?--expected-tree requires a value}"; shift 2 ;;
		--trusted-signers) TRUSTED_SIGNERS="${2:?--trusted-signers requires a value}"; shift 2 ;;
		--revoked-signers) REVOKED_SIGNERS="${2:?--revoked-signers requires a value}"; shift 2 ;;
		--require-trust) REQUIRE_TRUST="${2:?--require-trust requires a value}"; shift 2 ;;
		--reuse-existing) REUSE=1; shift ;;
		--cleanup) CLEANUP=1; shift ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "acquire: unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

case "$TRANSPORT" in
	https | ssh | gh) ;;
	*) log_error "acquire: invalid --transport '$TRANSPORT' (https|ssh|gh)"; exit 2 ;;
esac
case "$REQUIRE_TRUST" in
	any | anchored) ;;
	*) log_error "acquire: invalid --require-trust '$REQUIRE_TRUST' (any|anchored)"; exit 2 ;;
esac
# A signer-policy file that cannot be read is a policy that is NOT in force — never degrade to
# ambient trust silently; refuse the invocation instead.
for _sf in "$TRUSTED_SIGNERS" "$REVOKED_SIGNERS"; do
	[ -n "$_sf" ] || continue
	[ -f "$_sf" ] && [ -r "$_sf" ] || { log_error "acquire: signer policy file is missing or unreadable: $_sf"; exit 2; }
done
case "$VERIFY_SOURCE" in
	*signature*) ;;
	*)
		[ -z "$TRUSTED_SIGNERS" ] && [ -z "$REVOKED_SIGNERS" ] || {
			log_error "acquire: --trusted-signers/--revoked-signers are only meaningful with --verify-source signature[+…]"; exit 2; } ;;
esac
export SV_TRUSTED_SIGNERS="$TRUSTED_SIGNERS"
export SV_REVOKED_SIGNERS="$REVOKED_SIGNERS"
case "$VERIFY_SOURCE" in
	none | tree-record | tree-checksum | signature | tree-checksum+signature) ;;
	checksum)
		# Deprecated alias retained for backward compatibility: record-only, never "verified".
		log_warn "acquire: --verify-source 'checksum' is a deprecated alias for 'tree-record' (records the HEAD tree id; it is NOT a comparison)"
		VERIFY_SOURCE="tree-record" ;;
	*) log_error "acquire: invalid --verify-source '$VERIFY_SOURCE' (none|tree-record|tree-checksum|signature|tree-checksum+signature)"; exit 2 ;;
esac
# tree-checksum modes REQUIRE a 40-hex expected tree; --expected-tree is meaningless elsewhere.
case "$VERIFY_SOURCE" in
	*tree-checksum*)
		[ -n "$EXPECTED_TREE" ] || { log_error "acquire: --verify-source $VERIFY_SOURCE requires --expected-tree <40-hex>"; exit 2; }
		printf '%s' "$EXPECTED_TREE" | grep -qE '^[0-9a-fA-F]{40}$' || { log_error "acquire: --expected-tree must be a full 40-hex tree object id"; exit 2; } ;;
	*)
		[ -z "$EXPECTED_TREE" ] || { log_error "acquire: --expected-tree is only valid with --verify-source tree-checksum[+signature]"; exit 2; } ;;
esac
[ -n "$DEST" ] || { log_error "acquire: --destination is required"; usage >&2; exit 2; }

# --cleanup may be used ALONE (no repo/ref) to just remove the destination and exit.
if [ "$CLEANUP" = 1 ] && [ -z "$REPO" ] && [ -z "$REF" ]; then
	acquire_validate_destination "$DEST"
	rm -rf -- "$DEST"
	log_info "acquire: removed destination: $DEST"
	exit 0
fi

[ -n "$REPO" ] || { log_error "acquire: --repository is required"; usage >&2; exit 2; }
[ -n "$REF" ] || { log_error "acquire: --ref is required"; usage >&2; exit 2; }
command_exists git || { log_error "acquire: git not found (required)"; exit 3; }
# Checked UP FRONT, not at write time: the acquisition record is the trust record, and finishing a
# fetch only to discover we cannot serialize its provenance would leave an unattributed checkout.
command_exists jq || { log_error "acquire: jq not found (required to serialize the acquisition trust record)"; exit 3; }

# --- resolve the remote URL (NO credentials are ever embedded) ----------------
# An explicit remote (scheme://, git@host:..., or a local/relative path) is used verbatim;
# an owner/repo shorthand is expanded per --transport.
USE_GH=0
# Refuse credential-bearing http(s) remotes (userinfo: token@ or user:token@) BEFORE
# any branch accepts them — a secret must never be embedded, logged, or persisted.
case "$REPO" in
	http://*@* | https://*@*)
		log_error "acquire: refusing credential-bearing remote URL (userinfo not allowed; authenticate out-of-band)"; exit 2 ;;
	http://*[?#]* | https://*[?#]*)
		log_error "acquire: refusing http(s) remote URL with query/fragment (strip ?query/#fragment from the remote)"; exit 2 ;;
esac
# REPO_KIND/REPO_NORM are the NORMALIZED provenance recorded in .sentinel-shield-ref:
#   github -> owner/repo ; url -> sanitized URL ; local -> null (path is NEVER persisted).
REPO_KIND=""
REPO_NORM=""
case "$REPO" in
	*://* | git@*:*)
		URL="$REPO"; REPO_KIND="url"; REPO_NORM=$(acquire_sanitize_url "$REPO") ;;
	/* | ./* | ../*)
		URL="$REPO"; REPO_KIND="local"; REPO_NORM="" ;;
	*/*)
		# A path-like input that exists on disk is a LOCAL path (e.g. tmp/remote.git),
		# used verbatim; never rewrite it to a GitHub URL. Otherwise it is owner/repo.
		if [ -e "$REPO" ]; then
			URL="$REPO"; REPO_KIND="local"; REPO_NORM=""
		else
			case "$TRANSPORT" in
				ssh) URL="git@github.com:$REPO.git" ;;
				gh) URL="https://github.com/$REPO.git"; USE_GH=1 ;;
				*) URL="https://github.com/$REPO.git" ;;
			esac
			REPO_KIND="github"; REPO_NORM="$REPO"
		fi ;;
	*)
		log_error "acquire: invalid --repository '$REPO' (expected owner/repo, a URL, or a path)"; exit 2 ;;
esac
if [ "$USE_GH" = 1 ]; then
	command_exists gh || { log_error "acquire: gh not found (required for --transport gh)"; exit 3; }
fi

# --- classify the ref: SHA, tag, or rejected (moving branch / unknown) --------
# Resolution uses anonymous `git ls-remote`; for owner/repo over gh the configured git
# credential helper authorizes it. KIND in {sha,tag}; EXPECTED is the immutable commit.
KIND=""
EXPECTED=""
if printf '%s' "$REF" | grep -qE '^[0-9a-fA-F]{40}$'; then
	KIND="sha"
	EXPECTED=$(printf '%s' "$REF" | tr 'A-F' 'a-f')
else
	TAG_OUT=$(ra_bounded "$GIT_NET_TIMEOUT" git ls-remote "$URL" "refs/tags/$REF" "refs/tags/$REF^{}" 2>/dev/null) || {
		if [ "${RA_TIMEOUT:-0}" = 1 ]; then log_error "acquire: resolving ref '$REF' at $URL timed out after ${GIT_NET_TIMEOUT}s"; else log_error "acquire: cannot reach remote to resolve ref '$REF' at $URL"; fi
		exit 4
	}
	# Prefer the peeled (^{}) commit for annotated tags; fall back to the direct line.
	EXPECTED=$(printf '%s\n' "$TAG_OUT" | awk -v r="refs/tags/$REF" '
		$2 == r "^{}" { peeled = $1 }
		$2 == r { direct = $1 }
		END { if (peeled != "") print peeled; else print direct }')
	if [ -n "$EXPECTED" ]; then
		KIND="tag"
	else
		# Not a tag. If it is a branch, name it explicitly; either way it is non-immutable.
		if [ -n "$(ra_bounded "$GIT_NET_TIMEOUT" git ls-remote --heads "$URL" "$REF" 2>/dev/null)" ]; then
			log_error "acquire: ref '$REF' is a moving branch — refusing (use an immutable tag or full 40-hex SHA)"
		else
			log_error "acquire: ref '$REF' is not a tag and not a full 40-hex SHA — refusing (immutable refs only)"
		fi
		exit 2
	fi
fi

# --- MOVED-TAG detection, BEFORE the destination is touched -------------------
# Ordered ahead of --cleanup deliberately: an automation that always passes --cleanup would
# otherwise erase the only evidence that the tag used to mean something else. The deliberate
# escape is a standalone `--cleanup` run, which is a separate, explicit operator decision.
if [ "$KIND" = "tag" ]; then
	acquire_assert_not_moved "$DEST" "$REPO_NORM" "$REF" "$EXPECTED"
fi

# --- reuse / cleanup of an existing destination -------------------------------
if [ "$CLEANUP" = 1 ]; then
	acquire_validate_destination "$DEST"
	rm -rf -- "$DEST"
fi
if [ -e "$DEST" ]; then
	if [ "$REUSE" = 1 ] && [ -d "$DEST/.git" ]; then
		CUR=$(git -C "$DEST" rev-parse HEAD 2>/dev/null || true)
		# Reuse only when HEAD already matches the resolved commit AND the worktree is clean.
		# NOTE (#154, tracked separately): `git status --porcelain` is a cleanliness HINT, not an
		# integrity proof — it does not report ignored files, nested repositories, or repo-local
		# git configuration. This reuse gate is strengthened in the reuse-verification batch; it
		# is deliberately NOT widened here so the trust-anchor change stays reviewable.
		if [ -n "$CUR" ] && [ "$CUR" = "$EXPECTED" ] && [ -z "$(git -C "$DEST" status --porcelain 2>/dev/null)" ]; then
			log_info "acquire: reusing existing checkout at $DEST (HEAD=$CUR)"
			acquire_run_source_verify "$DEST" "$REF" "$EXPECTED" "$KIND"
			write_source_record "$DEST" "$REPO_KIND" "$REPO_NORM" "$REF" "$CUR" "$KIND" || exit $?
			printf '%s\n' "$CUR"
			exit 0
		fi
		log_warn "acquire: existing checkout HEAD does not match resolved commit; re-acquiring"
		acquire_validate_destination "$DEST"
		rm -rf -- "$DEST"
	else
		log_error "acquire: destination exists: $DEST (pass --reuse-existing or --cleanup)"
		exit 2
	fi
fi

# --- fetch, then TRUST ONLY THE OBJECT ----------------------------------------
# The transport is still asked for the ref by name (that is the only cheap way to get a shallow
# tag fetch), but NOTHING the transport returns is trusted on the strength of that name. What the
# remote sent is compared against the object resolved a moment earlier, and the working tree is
# then checked out by OBJECT ID, never by name. A tag that moves between the two operations is
# therefore detected and fails closed (#152) instead of being installed as the requested version.
if [ "$KIND" = "tag" ]; then
	if [ "$USE_GH" = 1 ]; then
		ra_bounded "$GIT_NET_TIMEOUT" gh repo clone "$REPO" "$DEST" -- --depth 1 --branch "$REF" --single-branch >&2 || {
			[ "${RA_TIMEOUT:-0}" = 1 ] && log_error "acquire: gh clone of tag '$REF' timed out after ${GIT_NET_TIMEOUT}s" || log_error "acquire: gh clone of tag '$REF' failed"; exit 4; }
	else
		ra_bounded "$GIT_NET_TIMEOUT" git clone --quiet --depth 1 --branch "$REF" --single-branch "$URL" "$DEST" || {
			[ "${RA_TIMEOUT:-0}" = 1 ] && log_error "acquire: clone of tag '$REF' timed out after ${GIT_NET_TIMEOUT}s" || log_error "acquire: clone of tag '$REF' failed"; exit 4; }
	fi
	# INDEPENDENT re-verification of the ref -> commit relationship, in the fetched repository.
	FETCHED=$(git -C "$DEST" rev-parse --verify --quiet "refs/tags/$REF^{commit}" 2>/dev/null || true)
	if [ -z "$FETCHED" ]; then
		log_error "acquire: tag '$REF' is absent from the fetched repository — cannot confirm the ref->commit relationship (fail closed)"
		exit 4
	fi
	if [ "$FETCHED" != "$EXPECTED" ]; then
		log_error "acquire: SOURCE TRUST INCIDENT — tag '$REF' resolved to $EXPECTED before the fetch but the fetched repository carries it at $FETCHED."
		log_error "acquire: the ref moved between resolution and fetch (time-of-check/time-of-use). Refusing to install either object."
		log_error "acquire: re-run pinned to the object you intend: --ref $EXPECTED (or --ref $FETCHED after reviewing the change)."
		exit 5
	fi
	git -C "$DEST" checkout --quiet --detach "$EXPECTED" || {
		log_error "acquire: checkout of commit $EXPECTED failed"; exit 4; }
else
	# A bare SHA cannot be shallow-fetched portably; full-clone then detach to the commit.
	if [ "$USE_GH" = 1 ]; then
		ra_bounded "$GIT_NET_TIMEOUT" gh repo clone "$REPO" "$DEST" -- --no-checkout >&2 || {
			[ "${RA_TIMEOUT:-0}" = 1 ] && log_error "acquire: gh clone timed out after ${GIT_NET_TIMEOUT}s" || log_error "acquire: gh clone failed"; exit 4; }
	else
		ra_bounded "$GIT_NET_TIMEOUT" git clone --quiet --no-checkout "$URL" "$DEST" || {
			[ "${RA_TIMEOUT:-0}" = 1 ] && log_error "acquire: clone timed out after ${GIT_NET_TIMEOUT}s" || log_error "acquire: clone failed"; exit 4; }
	fi
	git -C "$DEST" cat-file -e "$EXPECTED^{commit}" 2>/dev/null || {
		log_error "acquire: commit $EXPECTED not found in $REPO"; exit 4; }
	git -C "$DEST" checkout --quiet --detach "$EXPECTED" || {
		log_error "acquire: checkout of commit $EXPECTED failed"; exit 4; }
fi

RESOLVED=$(git -C "$DEST" rev-parse HEAD 2>/dev/null) || {
	log_error "acquire: cannot read checkout HEAD in $DEST"; exit 4; }

# --- HEAD identity: NON-OPTIONAL, no flag can disable it ----------------------
if [ "$RESOLVED" != "$EXPECTED" ]; then
	log_error "acquire: verification FAILED — HEAD ($RESOLVED) != resolved ref commit ($EXPECTED)"
	exit 4
fi

acquire_run_source_verify "$DEST" "$REF" "$EXPECTED" "$KIND"
write_source_record "$DEST" "$REPO_KIND" "$REPO_NORM" "$REF" "$RESOLVED" "$KIND" || exit $?
if [ "$TRUST_ANCHORED" = "true" ]; then
	log_info "acquire: $REPO @ $REF -> $RESOLVED (trust: $TRUST_LEVEL; anchors: $TRUST_ANCHORS; checkout: $DEST)"
else
	log_warn "acquire: $REPO @ $REF -> $RESOLVED acquired WITHOUT a trust anchor (trust level: resolved-ref). A tag name can be moved; this records what '$REF' meant at $VERIFIED_AT, not an immutable identity. Use --require-trust anchored for production."
fi
printf '%s\n' "$RESOLVED"
exit 0
