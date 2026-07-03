#!/bin/sh
# tests/prod/12-source-verification.sh — scripts/lib/source-verification.sh contract +
# acquire-sentinel-shield.sh --verify-source integration. Self-contained, network-free: builds
# LOCAL git fixtures (unsigned annotated tag, lightweight tag, stub-signed annotated tag) and a
# throwaway bare 'remote'. Asserts the EXPLICIT verification contract:
#   * sv_assert_commit: rejects missing/malformed/mismatched commit; accepts the true HEAD.
#   * tree-record RECORDS the HEAD tree (never labelled verified); tree-checksum COMPARES against
#     a required expected tree and FAILS CLOSED on mismatch / missing expectation.
#   * signature mode fails closed for lightweight + unsigned annotated tags; a good signature
#     that targets the WRONG commit fails commit identity (never bypasses commit/tree checks).
#   * every mode independently asserts HEAD == expected commit FIRST.
# The cryptographic primitive is stubbed (a fake gpg.program) so the git verify-tag machinery is
# exercised end-to-end without provisioning a signing identity; a real gpg path runs when present.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ACQ="$ROOT/scripts/acquire-sentinel-shield.sh"

. "$ROOT/scripts/lib/sentinel-shield-common.sh"
. "$ROOT/scripts/lib/source-verification.sh"

FAILS=0
SKIPS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
note_skip() { printf 'SKIP: %s\n' "$1"; SKIPS=$((SKIPS + 1)); }
# ok_if <desc> <cmd...> — pass iff the command succeeds (exit 0).
ok_if() { _d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$_d"; else fail "$_d"; fi; }
# fail_if <desc> <cmd...> — pass iff the command FAILS (non-zero) — fail-closed assertions.
fail_if() { _d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$_d (unexpectedly succeeded)"; else pass "$_d"; fi; }

command_exists git || { note_skip "git unavailable — source-verification tests skipped"; exit 0; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t sssv)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

# --- build a local checkout with two commits + tags --------------------------
REPO="$WORK/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
printf 'one\n' > "$REPO/a.txt"
git -C "$REPO" add a.txt
git -C "$REPO" commit -q -m c1
C1=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" tag lw            # lightweight tag on C1
git -C "$REPO" tag -a -m 'annotated unsigned' ann   # annotated (unsigned) tag on C1
printf 'two\n' > "$REPO/b.txt"
git -C "$REPO" add b.txt
git -C "$REPO" commit -q -m c2
C2=$(git -C "$REPO" rev-parse HEAD)
# Reset HEAD back to C1 so the checkout HEAD == C1 (the ref we verify against).
git -C "$REPO" checkout -q "$C1"
TREE1=$(git -C "$REPO" rev-parse 'HEAD^{tree}')

# --- sv_is_hex40 -------------------------------------------------------------
ok_if   "sv_is_hex40 accepts a 40-hex commit" sv_is_hex40 "$C1"
fail_if "sv_is_hex40 rejects a short hex"      sv_is_hex40 "abc123"
fail_if "sv_is_hex40 rejects a non-hex string" sv_is_hex40 "z000000000000000000000000000000000000000"
fail_if "sv_is_hex40 rejects empty"            sv_is_hex40 ""

# --- sv_assert_commit (TASK 2: independent commit assertion) -----------------
ok_if   "sv_assert_commit accepts the true HEAD commit"      sv_assert_commit "$REPO" "$C1"
ok_if   "sv_assert_commit is case-insensitive"              sv_assert_commit "$REPO" "$(printf '%s' "$C1" | tr 'a-f' 'A-F')"
fail_if "sv_assert_commit rejects a mismatched commit"       sv_assert_commit "$REPO" "$C2"
fail_if "sv_assert_commit rejects a malformed commit"        sv_assert_commit "$REPO" "not-a-sha"
fail_if "sv_assert_commit rejects a missing commit"          sv_assert_commit "$REPO" ""

# --- tree-record vs tree-checksum (TASK 1) -----------------------------------
_m=$(sv_verify "$REPO" ann "$C1" tree-record) && _rc=0 || _rc=$?
if [ "$_rc" = 0 ] && [ "$_m" = "tree-record" ]; then pass "tree-record records + returns 'tree-record'"; else fail "tree-record (rc=$_rc m='$_m')"; fi
# deprecated alias 'checksum' behaves as tree-record.
_m=$(sv_verify "$REPO" ann "$C1" checksum) && _rc=0 || _rc=$?
if [ "$_rc" = 0 ] && [ "$_m" = "tree-record" ]; then pass "checksum alias maps to tree-record"; else fail "checksum alias (rc=$_rc m='$_m')"; fi

# tree-checksum REQUIRES an expected tree; a matching tree passes, a wrong one fails CLOSED.
_m=$(sv_verify "$REPO" ann "$C1" tree-checksum "$TREE1") && _rc=0 || _rc=$?
if [ "$_rc" = 0 ] && [ "$_m" = "tree-checksum" ]; then pass "tree-checksum MATCH passes"; else fail "tree-checksum MATCH (rc=$_rc m='$_m')"; fi
sv_verify "$REPO" ann "$C1" tree-checksum "0000000000000000000000000000000000000000" >/dev/null 2>&1 && _rc=0 || _rc=$?
if [ "$_rc" = 1 ]; then pass "tree-checksum MISMATCH fails closed (exit 1)"; else fail "tree-checksum MISMATCH (rc=$_rc)"; fi
sv_verify "$REPO" ann "$C1" tree-checksum >/dev/null 2>&1 && _rc=0 || _rc=$?
if [ "$_rc" = 2 ]; then pass "tree-checksum without expected tree is an invalid invocation (exit 2)"; else fail "tree-checksum missing expected (rc=$_rc)"; fi
sv_verify "$REPO" ann "$C1" tree-checksum "deadbeef" >/dev/null 2>&1 && _rc=0 || _rc=$?
if [ "$_rc" = 2 ]; then pass "tree-checksum with non-40-hex expected tree rejected (exit 2)"; else fail "tree-checksum malformed expected (rc=$_rc)"; fi

# commit-identity is asserted FIRST: a valid tree expectation but wrong commit still fails.
sv_verify "$REPO" ann "$C2" tree-checksum "$TREE1" >/dev/null 2>&1 && _rc=0 || _rc=$?
if [ "$_rc" = 1 ]; then pass "tree-checksum + wrong expected commit fails commit identity"; else fail "tree-checksum wrong commit (rc=$_rc)"; fi

# invalid mode -> exit 2.
sv_verify "$REPO" ann "$C1" bogus-mode >/dev/null 2>&1 && _rc=0 || _rc=$?
if [ "$_rc" = 2 ]; then pass "unknown mode rejected (exit 2)"; else fail "unknown mode (rc=$_rc)"; fi

# --- signature mode: fail-closed for lightweight + unsigned annotated (TASK 3) -
fail_if "signature fails for a lightweight tag"        sv_verify "$REPO" lw  "$C1" signature
fail_if "signature fails for an unsigned annotated tag" sv_verify "$REPO" ann "$C1" signature
fail_if "sv_verify_signature: lightweight tag rejected" sv_verify_signature "$REPO" lw "$C1"
fail_if "sv_verify_signature: unsigned annotated rejected" sv_verify_signature "$REPO" ann "$C1"

# --- signature mode: stub-signed annotated tag (git verify-tag machinery) -----
# Build a REAL tag object carrying a PGP signature block, pointing at C1, and configure a fake
# gpg.program that emits a GOODSIG so git verify-tag exercises its full parse/verify path.
STUB="$WORK/fake-gpg"
cat > "$STUB" <<'EOF'
#!/bin/sh
# Minimal gpg stub: locate --status-fd, emit a GOODSIG/VALIDSIG on it, succeed.
fd=1
_prev=""
for a in "$@"; do
	case "$_prev" in --status-fd) fd=$a ;; esac
	case "$a" in --status-fd=*) fd=${a#--status-fd=} ;; esac
	_prev=$a
done
cat >/dev/null 2>&1 || true
eval "exec 9>&$fd" 2>/dev/null || exec 9>&2
{
	printf '[GNUPG:] NEWSIG\n'
	printf '[GNUPG:] GOODSIG DEADBEEFDEADBEEF Test Signer <t@t.t>\n'
	printf '[GNUPG:] VALIDSIG DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF 2020-01-01 0 4 0 1 8 00 DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF\n'
	printf '[GNUPG:] TRUST_ULTIMATE 0 pgp\n'
} >&9 2>/dev/null || true
exit 0
EOF
chmod +x "$STUB"

make_stub_tag() { # <tagname> <target-commit>
	_payload="$WORK/tagobj-$1"
	{
		printf 'object %s\n' "$2"
		printf 'type commit\n'
		printf 'tag %s\n' "$1"
		printf 'tagger Test <t@t.t> 0 +0000\n'
		printf '\n'
		printf 'stub signed tag\n'
		printf -- '-----BEGIN PGP SIGNATURE-----\n'
		printf '\n'
		printf 'ZmFrZXNpZwo=\n'
		printf -- '-----END PGP SIGNATURE-----\n'
	} > "$_payload"
	_obj=$(git -C "$REPO" hash-object -t tag -w --stdin < "$_payload")
	git -C "$REPO" update-ref "refs/tags/$1" "$_obj"
}
make_stub_tag sig1 "$C1"   # signed tag targeting C1 (correct)
make_stub_tag sig2 "$C2"   # signed tag targeting C2 (wrong, for identity check)
git -C "$REPO" config gpg.program "$STUB"

# If the git+stub combination yields a good verification, run the good-path assertions;
# otherwise skip only the crypto-success cases (fail-closed cases above still cover TASK 3).
if git -C "$REPO" verify-tag sig1 >/dev/null 2>&1; then
	ok_if   "signature: good stub-signed tag targeting correct commit verifies" sv_verify_signature "$REPO" sig1 "$C1"
	ok_if   "sv_verify signature mode passes for good tag + correct commit"       sv_verify "$REPO" sig1 "$C1" signature
	# A GOOD signature MUST NOT bypass commit identity: sig1 targets C1, expect C2 -> fail.
	fail_if "signature: good tag but wrong expected commit fails identity"        sv_verify_signature "$REPO" sig1 "$C2"
	# sig2 targets C2; the checkout HEAD is C1, so sv_verify's HEAD assertion fails first.
	fail_if "sv_verify signature: HEAD assertion fails when expected != HEAD"      sv_verify "$REPO" sig2 "$C2" signature
	# mechanism classification is 'gpg' for a GNUPG-status verifier.
	_mech=$(sv_signature_mechanism "$REPO" sig1)
	if [ "$_mech" = "gpg" ]; then pass "sv_signature_mechanism classifies GNUPG status as 'gpg'"; else fail "sv_signature_mechanism (got '$_mech')"; fi
	# tree-checksum+signature: both must hold.
	ok_if   "tree-checksum+signature passes when tree matches + sig good"          sv_verify "$REPO" sig1 "$C1" tree-checksum+signature "$TREE1"
	fail_if "tree-checksum+signature fails when tree mismatches"                   sv_verify "$REPO" sig1 "$C1" tree-checksum+signature "0000000000000000000000000000000000000000"
else
	note_skip "git verify-tag + gpg stub not viable in this environment — crypto-success signature cases skipped (fail-closed cases still asserted)"
fi

# --- acquire integration: tree-record + tree-checksum (fail closed) ----------
REMOTE="$WORK/remote.git"
git init -q --bare "$REMOTE"
git -C "$REPO" remote add origin "$REMOTE" 2>/dev/null || git -C "$REPO" remote set-url origin "$REMOTE"
git -C "$REPO" push -q origin "refs/tags/ann:refs/tags/ann"
git -C "$REPO" push -q origin "$C1:refs/heads/main" 2>/dev/null || true

# tree-record via acquire: record written, verification_method=tree-record, tree_calculated set,
# and NO tree_expected (an uncompared record must never claim an expectation).
D1="$WORK/acq-record"
out=$(sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$D1" --verify --verify-source tree-record 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" = 0 ]; then pass "acquire tree-record succeeds (exit 0)"; else fail "acquire tree-record (rc=$rc)"; fi
if command_exists jq && [ -f "$D1/.sentinel-shield-ref" ]; then
	_vm=$(jq -r '.verification_method' "$D1/.sentinel-shield-ref")
	_tc=$(jq -r '.tree_calculated // ""' "$D1/.sentinel-shield-ref")
	_te=$(jq -r '.tree_expected // "ABSENT"' "$D1/.sentinel-shield-ref")
	assert_eq_str() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2' want '$3')"; fi; }
	assert_eq_str "acquire tree-record: verification_method" "$_vm" "tree-record"
	assert_eq_str "acquire tree-record: tree_calculated == HEAD tree" "$_tc" "$TREE1"
	assert_eq_str "acquire tree-record: NO tree_expected recorded" "$_te" "ABSENT"
else
	note_skip "jq/ref-record unavailable — acquire tree-record record fields not asserted"
fi

# tree-checksum via acquire: --expected-tree required; matching passes + records BOTH ids.
D2="$WORK/acq-checksum"
out=$(sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$D2" --verify-source tree-checksum --expected-tree "$TREE1" 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" = 0 ]; then pass "acquire tree-checksum MATCH succeeds"; else fail "acquire tree-checksum MATCH (rc=$rc)"; fi
if command_exists jq && [ -f "$D2/.sentinel-shield-ref" ]; then
	_vm=$(jq -r '.verification_method' "$D2/.sentinel-shield-ref")
	_tc=$(jq -r '.tree_calculated // ""' "$D2/.sentinel-shield-ref")
	_te=$(jq -r '.tree_expected // ""' "$D2/.sentinel-shield-ref")
	if [ "$_vm" = "tree-checksum" ] && [ "$_tc" = "$TREE1" ] && [ "$_te" = "$TREE1" ]; then
		pass "acquire tree-checksum records BOTH expected + calculated tree ids (equal)"
	else
		fail "acquire tree-checksum record (vm='$_vm' calc='$_tc' exp='$_te')"
	fi
fi

# tree-checksum without --expected-tree is rejected at invocation (exit 2), nothing cloned.
D3="$WORK/acq-noexp"
sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$D3" --verify-source tree-checksum >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" = 2 ]; then pass "acquire tree-checksum without --expected-tree rejected (exit 2)"; else fail "acquire tree-checksum missing expected (rc=$rc)"; fi
[ -e "$D3" ] && fail "acquire: no destination created on invalid invocation" || pass "acquire: no destination created on invalid invocation"

# tree-checksum with a WRONG expected tree fails CLOSED (exit 4) after clone.
D4="$WORK/acq-wrong"
sh "$ACQ" --repository "$REMOTE" --ref ann --destination "$D4" --verify-source tree-checksum --expected-tree "0000000000000000000000000000000000000000" >/dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" = 4 ]; then pass "acquire tree-checksum MISMATCH fails closed (exit 4)"; else fail "acquire tree-checksum MISMATCH (rc=$rc)"; fi

printf '\n12-source-verification: %d skip(s), %d failure(s)\n' "$SKIPS" "$FAILS"
[ "$FAILS" -eq 0 ] || exit 1
exit 0
