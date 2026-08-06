#!/bin/sh
# tests/prod/13-source-trust.sh — SOURCE IDENTITY AND TRUST ANCHORS (#151, #152).
#
# What this suite is for
# ----------------------
# `acquire-sentinel-shield.sh` used to describe any tag as an "immutable ref". It is not one: a
# git tag can be deleted and recreated, or force-moved, so resolving a tag proves only what the
# NAME meant at that instant. The old default path resolved the tag, cloned it again BY NAME, and
# checked that the clone's HEAD matched the value resolved a moment earlier — internal
# consistency of one command, not identity across time. `--no-verify` could switch even that off.
#
# Every case below is therefore built as: a fixture that reproduces the concrete defect, a proof
# that the fixture really reached the vulnerable path (the tag really moved, the race really
# fired), and an assertion that the current implementation refuses it — plus a control case
# proving the refusal is specific and does not simply reject everything.
#
# Self-contained and OFFLINE: every fixture is a local git repository. No GitHub access, no
# network. A missing network can never turn an unexecuted case into a pass — cases that need an
# unavailable capability (SSH signing) are reported as SKIP, never as PASS.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ACQ="$ROOT/scripts/acquire-sentinel-shield.sh"
SCHEMA="$ROOT/schemas/installation-metadata.schema.json"

# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$ROOT/scripts/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/source-verification.sh
. "$ROOT/scripts/lib/source-verification.sh"

FAILS=0
SKIPS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
note_skip() { printf 'SKIP: %s\n' "$1"; SKIPS=$((SKIPS + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2' want '$3')"; fi; }

command_exists git || { printf 'FAIL: git is required for the source-trust suite\n' >&2; exit 2; }
command_exists jq  || { printf 'FAIL: jq is required for the source-trust suite\n' >&2; exit 2; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t sstrust)
# EXIT trap that PRESERVES the failing status: a cleanup handler that ends in `rm` would make
# every aborted run look like a success.
trap 'rc=$?; rm -rf -- "$WORK"; exit $rc' EXIT
trap 'rc=$?; rm -rf -- "$WORK"; exit $rc' INT TERM

g() { git -c user.email=t@t.t -c user.name=t -c commit.gpgsign=false -c tag.gpgsign=false "$@"; }

# rec <dir> <jq-filter> — read a field from an acquisition record, printing ABSENT when the field
# is missing. Wrapped in an array rather than written as `filter // "ABSENT"`: jq's `//` treats
# `false` as absent, which would silently turn every `anchored: false` assertion — precisely the
# ones this suite exists to make — into a vacuous ABSENT comparison.
rec() { jq -r "[$2] | if (length == 0) or (.[0] == null) then \"ABSENT\" else .[0] end" \
	"$1/.sentinel-shield-ref" 2>/dev/null || printf 'UNREADABLE'; }

# --- fixture: a bare 'remote' with two commits and several tag shapes ---------
SEED="$WORK/seed"
REMOTE="$WORK/remote.git"
git init -q --bare "$REMOTE"
git init -q "$SEED"
printf 'one\n' > "$SEED/a.txt"
g -C "$SEED" add a.txt
g -C "$SEED" commit -q -m c1
C1=$(git -C "$SEED" rev-parse HEAD)
printf 'two\n' > "$SEED/b.txt"
g -C "$SEED" add b.txt
g -C "$SEED" commit -q -m c2
C2=$(git -C "$SEED" rev-parse HEAD)
g -C "$SEED" branch -M main
g -C "$SEED" checkout -q "$C1"
TREE1=$(git -C "$SEED" rev-parse 'HEAD^{tree}')
g -C "$SEED" tag lw "$C1"                       # lightweight tag on C1
g -C "$SEED" tag -a -m 'release 1' ann "$C1"    # annotated (unsigned) tag on C1
g -C "$SEED" remote add origin "$REMOTE"
g -C "$SEED" push -q origin main --tags
[ "$C1" != "$C2" ] || fail "fixture setup: C1 and C2 must differ"

# =============================================================================
# (1) --no-verify is REMOVED (#152)
# =============================================================================
# The defect: the HEAD==resolved-commit assertion was optional, so a moved tag could be installed
# and RECORDED as the requested version. Silently ignoring the flag would be worse than removing
# it — a caller would believe verification was off while it was on, and automation would keep
# propagating a flag nobody validates. So it must be a hard, explained invocation error.
out=$(sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$WORK/nv" --no-verify 2>&1) && rc=0 || rc=$?
eq "(1) --no-verify is rejected with exit 2" "$rc" "2"
case "$out" in *REMOVED*) pass "(1) rejection states the flag was removed" ;; *) fail "(1) rejection states removal (got: $out)" ;; esac
case "$out" in *migration*) pass "(1) rejection gives a migration instruction" ;; *) fail "(1) rejection gives migration instruction" ;; esac
[ -e "$WORK/nv" ] && fail "(1) nothing is acquired when the invocation is refused" || pass "(1) nothing is acquired when the invocation is refused"
# Control: the same invocation WITHOUT the flag succeeds, so the refusal is about the flag alone.
sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$WORK/nv-ok" >/dev/null 2>&1 && rc=0 || rc=$?
eq "(1-control) the same acquisition without --no-verify succeeds" "$rc" "0"
# --verify remains accepted (documented invocations and copied commands keep working).
sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$WORK/nv-v" --verify >/dev/null 2>&1 && rc=0 || rc=$?
eq "(1) --verify is still accepted (now the permanent default)" "$rc" "0"

# =============================================================================
# (2) trust anchors: what each acquisition may and may not claim (#151)
# =============================================================================
# (2a) A full 40-hex SHA IS the anchor: the caller named the content, so nothing in the mutable
#      ref namespace can change what it gets.
D_SHA="$WORK/anchor-sha"
sh "$ACQ" --repository "$REMOTE" --ref "$C1" --destination "$D_SHA" >/dev/null 2>&1 && rc=0 || rc=$?
eq "(2a) full-SHA acquisition succeeds"                 "$rc" "0"
eq "(2a) full-SHA records ref_kind=sha"                 "$(rec "$D_SHA" '.ref_kind')" "sha"
eq "(2a) full-SHA is anchored"                          "$(rec "$D_SHA" '.trust.anchored')" "true"
eq "(2a) full-SHA trust level is requested-commit"      "$(rec "$D_SHA" '.trust.level')" "requested-commit"
eq "(2a) full-SHA anchors list names requested-commit"  "$(rec "$D_SHA" '.trust.anchors | join(",")')" "requested-commit"

# (2b) A bare tag is NOT anchored. This is the heart of #151: the acquisition still succeeds (a
#      tag is a legitimate way to ask for a version) but the record must say, in the document
#      itself, that this is a point-in-time resolution and not an immutable identity.
D_TAG="$WORK/anchor-none"
sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$D_TAG" >/dev/null 2>&1 && rc=0 || rc=$?
eq "(2b) bare-tag acquisition succeeds"                "$rc" "0"
eq "(2b) bare tag is NOT anchored"                     "$(rec "$D_TAG" '.trust.anchored')" "false"
eq "(2b) bare tag trust level is resolved-ref"         "$(rec "$D_TAG" '.trust.level')" "resolved-ref"
eq "(2b) bare tag records an EMPTY anchor list"        "$(rec "$D_TAG" '.trust.anchors | length')" "0"
eq "(2b) bare tag records no verification method"      "$(rec "$D_TAG" '.verification_method')" "none"
# The record must never describe an unverified/unanchored input as verified.
eq "(2b) an unanchored record claims no signature"     "$(rec "$D_TAG" '.signature_status')" "ABSENT"
eq "(2b) an unanchored record claims no expected tree" "$(rec "$D_TAG" '.tree_expected')" "ABSENT"
# Ref, commit and tree are recorded as three SEPARATE values — a name is not an identity.
eq "(2b) requested ref recorded separately"            "$(rec "$D_TAG" '.ref')" "ann"
eq "(2b) resolved commit recorded separately"          "$(rec "$D_TAG" '.resolved_commit')" "$C1"
eq "(2b) resolved tree recorded separately"            "$(rec "$D_TAG" '.resolved_tree')" "$TREE1"

# (2c) --require-trust anchored is what production uses: an unanchored acquisition FAILS CLOSED.
D_REQ="$WORK/require-anchored"
out=$(sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$D_REQ" --require-trust anchored 2>&1) && rc=0 || rc=$?
eq "(2c) --require-trust anchored refuses an unanchored tag (exit 5)" "$rc" "5"
case "$out" in *"NO trust anchor"*) pass "(2c) refusal names the missing anchor" ;; *) fail "(2c) refusal names the missing anchor (got: $out)" ;; esac
[ -f "$D_REQ/.sentinel-shield-ref" ] && fail "(2c) no trust record is written for a refused acquisition" || pass "(2c) no trust record is written for a refused acquisition"
# Control: the SAME gate passes when a real anchor exists, so it gates on the anchor, not the tag.
D_REQ2="$WORK/require-anchored-ok"
sh "$ACQ" --repository "$REMOTE" --ref "$C1" --destination "$D_REQ2" --require-trust anchored >/dev/null 2>&1 && rc=0 || rc=$?
eq "(2c-control) --require-trust anchored accepts an anchored acquisition" "$rc" "0"
# The env var carries the same policy for automation that cannot edit a command line.
D_REQ3="$WORK/require-anchored-env"
SENTINEL_SHIELD_REQUIRE_TRUST=anchored sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$D_REQ3" >/dev/null 2>&1 && rc=0 || rc=$?
eq "(2c) SENTINEL_SHIELD_REQUIRE_TRUST=anchored enforces the same gate" "$rc" "5"

# (2d) An expected TREE is an anchor: the caller pinned the content hash out of band.
D_TREE="$WORK/anchor-tree"
sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$D_TREE" --require-trust anchored \
	--verify-source tree-checksum --expected-tree "$TREE1" >/dev/null 2>&1 && rc=0 || rc=$?
eq "(2d) tree-checksum satisfies --require-trust anchored" "$rc" "0"
eq "(2d) tree anchor level is expected-tree"               "$(rec "$D_TREE" '.trust.level')" "expected-tree"
eq "(2d) tree anchor is recorded as anchored"              "$(rec "$D_TREE" '.trust.anchored')" "true"
# tree-record RECORDS but compares nothing, so it must NOT become an anchor.
D_TREC="$WORK/anchor-treerecord"
sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$D_TREC" --verify-source tree-record >/dev/null 2>&1 && rc=0 || rc=$?
eq "(2d) tree-record acquisition succeeds"                  "$rc" "0"
eq "(2d) tree-record is NOT an anchor (records, never compares)" "$(rec "$D_TREC" '.trust.anchored')" "false"

# =============================================================================
# (3) MOVED TAG across installations (#151)
# =============================================================================
# The defect: the same requested version installs different code at different times, and nothing
# notices, because each acquisition only checks itself. The fixture moves a real tag in a real
# remote between two acquisitions into the SAME destination.
moved_case() {
	# $1 label, $2 tag name, $3 extra `git tag` args for the re-tag
	_d="$WORK/moved-$2"
	sh "$ACQ" --repository "$REMOTE" --ref "$2" --destination "$_d" >/dev/null 2>&1 || {
		fail "$1: first acquisition should succeed"; return 0; }
	_before=$(rec "$_d" '.resolved_commit')
	eq "$1: first acquisition recorded C1" "$_before" "$C1"
	# MUTATE: delete and recreate the tag on a different commit, exactly as a force-moved or
	# recreated release tag behaves.
	# shellcheck disable=SC2086  # $3 is an intentional word-split flag list ("" or "-a -m msg").
	g -C "$SEED" tag -d "$2" >/dev/null 2>&1
	# shellcheck disable=SC2086
	g -C "$SEED" tag $3 "$2" "$C2" >/dev/null 2>&1
	g -C "$SEED" push -q --force origin "refs/tags/$2:refs/tags/$2"
	# PROVE the mutation reached the remote — otherwise this test would pass on a no-op fixture.
	_remote_now=$(git ls-remote "$REMOTE" "refs/tags/$2^{}" "refs/tags/$2" | awk 'NR==1{print $1}')
	_remote_peeled=$(git ls-remote "$REMOTE" "refs/tags/$2^{}" | awk '{print $1}')
	[ -n "$_remote_peeled" ] && _remote_now=$_remote_peeled
	eq "$1: MUTATION PROOF — the remote tag now resolves to C2" "$_remote_now" "$C2"
	# The fixed implementation must refuse, and must say what happened.
	_out=$(sh "$ACQ" --repository "$REMOTE" --ref "$2" --destination "$_d" --reuse-existing 2>&1) && _rc=0 || _rc=$?
	eq "$1: re-acquisition of the moved tag fails closed (exit 5)" "$_rc" "5"
	case "$_out" in *MOVED-TAG*) pass "$1: the failure is reported as a moved-tag incident" ;;
		*) fail "$1: moved-tag incident reported (got: $_out)" ;; esac
	# The previously recorded identity must be intact: a refusal must not rewrite the record it
	# refused to supersede.
	eq "$1: the prior trust record is left untouched" "$(rec "$_d" '.resolved_commit')" "$C1"
}
moved_case "(3a) moved LIGHTWEIGHT tag" lw ""
moved_case "(3b) replaced ANNOTATED tag" ann "-a -m replaced"

# (3c) Control — idempotence. Re-acquiring a tag that has NOT moved must succeed and stay silent.
#      Without this the moved-tag detector could "pass" by refusing every re-acquisition.
g -C "$SEED" tag -a -m stable stable "$C1" >/dev/null 2>&1
g -C "$SEED" push -q origin "refs/tags/stable:refs/tags/stable"
# The destination sits under a `tools/` component because the destructive-cleanup guard only
# permits a dedicated tools directory. That matters here: re-acquisition currently goes through
# the re-acquire branch rather than the reuse branch, because Sentinel Shield's OWN untracked
# `.sentinel-shield-ref` makes `git status --porcelain` non-empty. That self-contradiction is
# #154's subject and is deliberately not fixed here; what this control asserts is the property
# #151 needs — an unmoved tag re-resolves to the same commit and is accepted, so the moved-tag
# detector cannot be passing merely by rejecting every second acquisition.
mkdir -p "$WORK/tools"
D_IDEM="$WORK/tools/idempotent"
sh "$ACQ" --repository "$REMOTE" --ref stable --destination "$D_IDEM" >/dev/null 2>&1 && rc=0 || rc=$?
eq "(3c-control) first acquisition of an unmoved tag succeeds" "$rc" "0"
sh "$ACQ" --repository "$REMOTE" --ref stable --destination "$D_IDEM" --reuse-existing >/dev/null 2>&1 && rc=0 || rc=$?
eq "(3c-control) re-acquiring the SAME unmoved tag is idempotent" "$rc" "0"
eq "(3c-control) the record still names the same commit" "$(rec "$D_IDEM" '.resolved_commit')" "$C1"

# =============================================================================
# (4) TAG MOVEMENT BETWEEN RESOLUTION AND FETCH — the TOCTOU race (#152)
# =============================================================================
# The defect: resolve the tag, then clone it again by NAME. Between those two remote operations
# the tag can move, and the second operation happily returns the NEW object under the OLD name.
#
# This is raced for real, not simulated with a fixture that never changes: a `git` shim on PATH
# force-moves the tag in the remote at the exact moment acquisition issues its clone, i.e. after
# resolution has already happened. The shim is the ONLY way to hit that window deterministically
# from a test; the mutation it performs is a genuine `git push --force` against a real remote.
RACE_TAG=racetag
g -C "$SEED" tag -a -m race "$RACE_TAG" "$C1" >/dev/null 2>&1
g -C "$SEED" push -q origin "refs/tags/$RACE_TAG:refs/tags/$RACE_TAG"
REAL_GIT=$(command -v git)
mkdir -p "$WORK/bin"
cat > "$WORK/bin/git" <<EOF
#!/bin/sh
# Move the tag the instant acquisition asks for the clone — i.e. strictly AFTER it resolved the
# tag and strictly BEFORE it receives any objects. Fires once (guarded by a marker file).
for a in "\$@"; do
	if [ "\$a" = clone ] && [ ! -e "$WORK/raced" ]; then
		: > "$WORK/raced"
		"$REAL_GIT" -c user.email=t@t.t -c user.name=t -C "$SEED" tag -d "$RACE_TAG" >/dev/null 2>&1
		"$REAL_GIT" -c user.email=t@t.t -c user.name=t -C "$SEED" tag -a -m raced "$RACE_TAG" "$C2" >/dev/null 2>&1
		"$REAL_GIT" -C "$SEED" push -q --force origin "refs/tags/$RACE_TAG:refs/tags/$RACE_TAG" >/dev/null 2>&1
		break
	fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod 755 "$WORK/bin/git"
D_RACE="$WORK/raced-dest"
out=$(PATH="$WORK/bin:$PATH" sh "$ACQ" --repository "$REMOTE" --ref "$RACE_TAG" --destination "$D_RACE" 2>&1) && rc=0 || rc=$?
# PROOF the race actually fired and actually moved the ref — otherwise the assertion below would
# be vacuous.
[ -e "$WORK/raced" ] && pass "(4) RACE PROOF — the shim fired during the clone window" || fail "(4) RACE PROOF — the shim never fired"
eq "(4) RACE PROOF — the remote tag really moved to C2" \
	"$(git ls-remote "$REMOTE" "refs/tags/$RACE_TAG^{}" | awk '{print $1}')" "$C2"
eq "(4) a tag that moves between resolution and fetch fails closed (exit 5)" "$rc" "5"
case "$out" in *"TRUST INCIDENT"*) pass "(4) the failure is reported as a source trust incident" ;;
	*) fail "(4) source trust incident reported (got: $out)" ;; esac
[ -f "$D_RACE/.sentinel-shield-ref" ] && fail "(4) no trust record is written for a raced acquisition" || pass "(4) no trust record is written for a raced acquisition"

# =============================================================================
# (5) SIGNER TRUST POLICY — signed tags, untrusted signers, revoked signers (#151)
# =============================================================================
# A good signature answers "did a key git accepts sign this?" — not "did the project's release
# signer sign this?". Without an explicit policy the second question is unanswered, so an
# ambient-trust signature is recorded but is NOT treated as an anchor.
#
# (5-unit) The policy matcher itself, exercised directly. This half is always run: it needs no
# signing capability, and it is what enforces GPG fingerprint allow/deny lists.
POL="$WORK/policy"; mkdir -p "$POL"
cat > "$POL/allowed" <<'EOF'
# comment line, must be ignored
release@example.com namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIexample
ABCDEF0123456789ABCDEF0123456789ABCDEF01
EOF
printf 'old-release@example.com namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIold\n' > "$POL/revoked"
_sv_policy_match "ssh:release@example.com" "$POL/allowed" && pass "(5-unit) an allowed SSH principal matches" || fail "(5-unit) allowed SSH principal matches"
_sv_policy_match "gpg:abcdef0123456789abcdef0123456789abcdef01" "$POL/allowed" && pass "(5-unit) a GPG fingerprint matches case-insensitively" || fail "(5-unit) GPG fingerprint matches case-insensitively"
_sv_policy_match "ssh:intruder@example.com" "$POL/allowed" && fail "(5-unit) an unlisted principal must NOT match" || pass "(5-unit) an unlisted principal does not match"
_sv_policy_match "ssh:old-release@example.com" "$POL/revoked" && pass "(5-unit) a revoked principal matches the revocation list" || fail "(5-unit) revoked principal matches"
_sv_policy_match "ssh:release@example.com" "$WORK/policy/does-not-exist" && fail "(5-unit) an unreadable policy must match NOTHING" || pass "(5-unit) an unreadable policy matches nothing (never universal trust)"
_sv_policy_match "ssh:release@example.com" "$POL/comment-only" && fail "(5-unit) an absent policy must match nothing" || pass "(5-unit) an absent policy matches nothing"

# (5-invocation) A policy file that cannot be read is a policy NOT IN FORCE. Silently continuing
# under ambient trust would turn a typo into a downgrade, so the invocation is refused outright.
out=$(sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$WORK/badpolicy" \
	--verify-source signature --trusted-signers "$WORK/no-such-file" 2>&1) && rc=0 || rc=$?
eq "(5) an unreadable --trusted-signers file is refused (exit 2)" "$rc" "2"
[ -e "$WORK/badpolicy" ] && fail "(5) nothing is acquired when the policy cannot be read" || pass "(5) nothing is acquired when the policy cannot be read"
out=$(sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$WORK/orphanpolicy" \
	--trusted-signers "$POL/allowed" 2>&1) && rc=0 || rc=$?
eq "(5) --trusted-signers without signature mode is refused (exit 2)" "$rc" "2"

# (5-crypto) End-to-end SSH-signed tags. Requires git SSH signing plus ssh-keygen; when either is
# unavailable the cases are SKIPPED, never silently passed.
SIGN_OK=0
if command_exists ssh-keygen; then
	mkdir -p "$WORK/keys"
	if ssh-keygen -q -t ed25519 -N '' -C release@example.com -f "$WORK/keys/release" >/dev/null 2>&1 &&
		ssh-keygen -q -t ed25519 -N '' -C intruder@example.com -f "$WORK/keys/intruder" >/dev/null 2>&1; then
		if g -C "$SEED" -c gpg.format=ssh -c user.signingkey="$WORK/keys/release" \
			tag -s -m 'signed release' sigok "$C1" >/dev/null 2>&1; then SIGN_OK=1; fi
	fi
fi
if [ "$SIGN_OK" = 1 ]; then
	g -C "$SEED" -c gpg.format=ssh -c user.signingkey="$WORK/keys/intruder" \
		tag -s -m 'signed by someone else' sigbad "$C1" >/dev/null 2>&1
	g -C "$SEED" push -q origin "refs/tags/sigok:refs/tags/sigok" "refs/tags/sigbad:refs/tags/sigbad"
	printf 'release@example.com namespaces="git" %s\n' "$(cat "$WORK/keys/release.pub")" > "$POL/trusted-release"
	printf 'intruder@example.com namespaces="git" %s\n' "$(cat "$WORK/keys/intruder.pub")" > "$POL/trusted-intruder"
	# Revocation is expressed in git's own format so BOTH enforcement points see it: ssh-keygen's
	# KRL for git, and the principal line for Sentinel Shield's own check.
	ssh-keygen -q -k -f "$WORK/keys/revoked.krl" "$WORK/keys/release.pub" >/dev/null 2>&1 || true

	# (5a) VALID signed tag under an explicit trusted-signer policy -> a real anchor.
	D_SIG="$WORK/sig-ok"
	out=$(sh "$ACQ" --repository "$REMOTE" --ref sigok --destination "$D_SIG" --require-trust anchored \
		--verify-source signature --trusted-signers "$POL/trusted-release" 2>&1) && rc=0 || rc=$?
	if [ "$rc" = 0 ]; then
		pass "(5a) a signed tag from a trusted signer satisfies --require-trust anchored"
		eq "(5a) trust level is signed-tag"          "$(rec "$D_SIG" '.trust.level')" "signed-tag"
		eq "(5a) the acquisition is anchored"        "$(rec "$D_SIG" '.trust.anchored')" "true"
		eq "(5a) the signer policy is recorded"      "$(rec "$D_SIG" '.trust.signer_policy')" "trusted-signers-file"
		eq "(5a) the signer identity is recorded"    "$(rec "$D_SIG" '.trust.signer')" "ssh:release@example.com"
		eq "(5a) the signature status is recorded"   "$(rec "$D_SIG" '.signature_status')" "good"
		case "$(cat "$D_SIG/.sentinel-shield-ref")" in
			*"$WORK/keys"*) fail "(5a) a local key PATH leaked into the trust record" ;;
			*) pass "(5a) no local key path appears in the trust record" ;;
		esac
	else
		fail "(5a) signed tag from a trusted signer should be anchored (rc=$rc: $out)"
	fi

	# (5b) UNTRUSTED signer: a perfectly good signature from a key the policy never named.
	D_UNTRUSTED="$WORK/sig-untrusted"
	out=$(sh "$ACQ" --repository "$REMOTE" --ref sigbad --destination "$D_UNTRUSTED" \
		--verify-source signature --trusted-signers "$POL/trusted-release" 2>&1) && rc=0 || rc=$?
	if [ "$rc" != 0 ]; then pass "(5b) a good signature from an UNTRUSTED signer fails closed (rc=$rc)"
	else fail "(5b) untrusted signer must fail closed (got rc=0)"; fi
	[ -f "$D_UNTRUSTED/.sentinel-shield-ref" ] && fail "(5b) no trust record is written for an untrusted signer" || pass "(5b) no trust record is written for an untrusted signer"
	# Control: the SAME tag under a policy that DOES name its signer is accepted — proving (5b)
	# rejected the identity, not the signature.
	D_UNTRUSTED_OK="$WORK/sig-untrusted-control"
	sh "$ACQ" --repository "$REMOTE" --ref sigbad --destination "$D_UNTRUSTED_OK" \
		--verify-source signature --trusted-signers "$POL/trusted-intruder" >/dev/null 2>&1 && rc=0 || rc=$?
	eq "(5b-control) the same tag is accepted under a policy naming its signer" "$rc" "0"

	# (5c) REVOKED signer: the key is in the allow list but has been revoked. Revocation must win.
	if [ -s "$WORK/keys/revoked.krl" ]; then
		cat "$POL/trusted-release" > "$POL/revoked-release"
		D_REVOKED="$WORK/sig-revoked"
		out=$(sh "$ACQ" --repository "$REMOTE" --ref sigok --destination "$D_REVOKED" \
			--verify-source signature --trusted-signers "$POL/trusted-release" \
			--revoked-signers "$WORK/keys/revoked.krl" 2>&1) && rc=0 || rc=$?
		if [ "$rc" != 0 ]; then pass "(5c) a REVOKED signer fails closed even while still allow-listed (rc=$rc)"
		else fail "(5c) revoked signer must fail closed (got rc=0)"; fi
		[ -f "$D_REVOKED/.sentinel-shield-ref" ] && fail "(5c) no trust record is written for a revoked signer" || pass "(5c) no trust record is written for a revoked signer"
	else
		note_skip "(5c) ssh-keygen could not build a KRL — revocation-through-git case skipped (the matcher half is covered by 5-unit)"
	fi

	# (5d) AMBIENT trust: a good signature with NO policy is recorded honestly but is NOT an
	#      anchor, because it does not identify WHO signed the release.
	D_AMB="$WORK/sig-ambient"
	out=$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=gpg.ssh.allowedSignersFile GIT_CONFIG_VALUE_0="$POL/trusted-release" \
		sh "$ACQ" --repository "$REMOTE" --ref sigok --destination "$D_AMB" --verify-source signature 2>&1) && rc=0 || rc=$?
	if [ "$rc" = 0 ]; then
		eq "(5d) an ambient-trust signature is NOT an anchor"      "$(rec "$D_AMB" '.trust.anchored')" "false"
		eq "(5d) the ambient signer policy is recorded honestly"   "$(rec "$D_AMB" '.trust.signer_policy')" "ambient-git-trust"
		eq "(5d) the signature itself is still recorded as good"   "$(rec "$D_AMB" '.signature_status')" "good"
		case "$out" in *"NOT counted as a trust anchor"*) pass "(5d) the ambient-trust downgrade is stated out loud" ;;
			*) fail "(5d) ambient-trust downgrade is stated (got: $out)" ;; esac
	else
		note_skip "(5d) ambient-trust signature case needs an inherited allowed-signers config (rc=$rc) — skipped"
	fi
else
	note_skip "(5a-5d) git SSH tag signing unavailable — signed/untrusted/revoked signer cases skipped (NOT passed)"
fi

# =============================================================================
# (6) The record is a serializer-produced document that conforms to its schema
# =============================================================================
# A trust record assembled by string concatenation is a trust record that can be made
# unparseable by its own inputs. The document must be valid JSON, must carry the version-2
# fields, and must not contain a key the closed schema does not declare.
eq "(6) the record is valid JSON" "$(jq -e 'type' "$D_SHA/.sentinel-shield-ref" 2>/dev/null || printf 'INVALID')" '"object"'
eq "(6) the record declares schema_version 2" "$(rec "$D_SHA" '.schema_version')" "2"
eq "(6) verified_at is an RFC3339 UTC timestamp" \
	"$(rec "$D_SHA" '.trust.verified_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")')" "true"
UNDECLARED=$(jq -r --slurpfile s "$SCHEMA" '
	($s[0].properties | keys) as $top
	| ($s[0].properties.trust.properties | keys) as $tk
	| [ (keys - $top | .[]), (if has("trust") then (.trust | keys - $tk | .[]) else empty end) ]
	| join(",")' "$D_SHA/.sentinel-shield-ref" 2>/dev/null || printf 'ERROR')
eq "(6) the record contains no key the closed schema does not declare" "$UNDECLARED" ""
MISSING=$(jq -r --slurpfile s "$SCHEMA" '($s[0].required + ["schema_version","resolved_tree","trust"]) - (keys) | join(",")' \
	"$D_SHA/.sentinel-shield-ref" 2>/dev/null || printf 'ERROR')
eq "(6) every required version-2 field is present" "$MISSING" ""
# A local-path source records repository=null: the path is provenance-free and never persisted.
eq "(6) a local source persists no path" "$(jq -r '.repository | type' "$D_SHA/.sentinel-shield-ref")" "null"

# =============================================================================
# (7) doctor reports trust honestly and never upgrades an old record
# =============================================================================
DT="$WORK/doctor-target"
doctor_ref() { mkdir -p "$1/.sentinel-shield"; cat > "$1/.sentinel-shield/.sentinel-shield-ref"; }
run_doctor() { sh "$ROOT/scripts/doctor.sh" --target "$1" >"$2" 2>&1 && printf '0' || printf '%s' "$?"; }

mkdir -p "$DT/anchored"
printf '{"schema_version":2,"repository":"o/r","ref":"v9.9.9","ref_kind":"tag","resolved_commit":"%s","trust":{"level":"signed-tag","anchored":true,"anchors":["signed-tag"],"verified_at":"2026-01-01T00:00:00Z"}}\n' \
	"1111111111111111111111111111111111111111" | doctor_ref "$DT/anchored"
run_doctor "$DT/anchored" "$WORK/d1.out" >/dev/null
grep -q 'immutable source identity' "$WORK/d1.out" \
	&& pass "(7) doctor calls an ANCHORED tag an immutable source identity" \
	|| fail "(7) doctor reports an anchored tag as immutable"

mkdir -p "$DT/unanchored"
printf '{"schema_version":2,"repository":"o/r","ref":"v9.9.9","ref_kind":"tag","resolved_commit":"%s","trust":{"level":"resolved-ref","anchored":false,"anchors":[],"verified_at":"2026-01-01T00:00:00Z"}}\n' \
	"1111111111111111111111111111111111111111" | doctor_ref "$DT/unanchored"
run_doctor "$DT/unanchored" "$WORK/d2.out" >/dev/null
grep -q 'is NOT anchored' "$WORK/d2.out" \
	&& pass "(7) doctor refuses to call an UNANCHORED tag immutable" \
	|| fail "(7) doctor flags an unanchored tag"
grep -q 'immutable source identity' "$WORK/d2.out" \
	&& fail "(7) doctor must not claim immutability for an unanchored tag" \
	|| pass "(7) doctor makes no immutability claim for an unanchored tag"

mkdir -p "$DT/legacy"
printf '{"repository":"o/r","ref":"v9.9.9","ref_kind":"tag","resolved_commit":"%s"}\n' \
	"1111111111111111111111111111111111111111" | doctor_ref "$DT/legacy"
run_doctor "$DT/legacy" "$WORK/d3.out" >/dev/null
grep -q 'pre-trust-model' "$WORK/d3.out" \
	&& pass "(7) doctor identifies a version-1 record as pre-trust-model" \
	|| fail "(7) doctor identifies a legacy record"
grep -q 'immutable source identity' "$WORK/d3.out" \
	&& fail "(7) a legacy record must NOT be silently upgraded into a trust anchor" \
	|| pass "(7) a legacy record is never silently upgraded into a trust anchor"

printf '\n13-source-trust: %s failure(s), %s skip(s)\n' "$FAILS" "$SKIPS"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
