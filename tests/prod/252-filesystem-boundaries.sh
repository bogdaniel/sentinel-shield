#!/bin/sh
# tests/prod/252-filesystem-boundaries.sh — FILESYSTEM TRUST-BOUNDARY enforcement.
#
# Proves scripts/lib/filesystem-safety.sh (and its archive-safety.sh case-collision extension):
# every project-mutation surface is guarded by a canonical, symlink-free, length-bounded path
# that physically stays inside a verified operation-owned root, is the object shape we expect
# (a regular file — never a device/FIFO/socket/unexpected hard link), carries restrictive
# permissions, is never group/world-writable when it holds sensitive metadata, and is deleted
# recursively ONLY when provably operation-owned. Every check fails CLOSED with a STABLE reason
# token cataloged in schemas/filesystem-safety-reasons.schema.json.
#
# Required cases (1)-(12) are labelled inline. For each attack we assert BOTH the fail-closed
# refusal (NEGATIVE) and a legitimate positive control (POSITIVE) so the hardening never breaks
# real use, plus at least one failure-injection where a primitive is unavailable/degraded.
# Self-contained, NETWORK-FREE. jq is required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB_COMMON="$ROOT/scripts/lib/sentinel-shield-common.sh"
LIB_FS="$ROOT/scripts/lib/filesystem-safety.sh"
LIB_ARCHIVE="$ROOT/scripts/lib/archive-safety.sh"
REASON_SCHEMA="$ROOT/schemas/filesystem-safety-reasons.schema.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n'; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssfsb)
cleanup() { chmod -R u+rwx "$WORK" 2>/dev/null || true; rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

IS_ROOT=0; [ "$(id -u 2>/dev/null || echo 0)" = "0" ] && IS_ROOT=1

# Source the library into THIS shell for in-process unit assertions.
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$LIB_COMMON"
# shellcheck source=scripts/lib/filesystem-safety.sh
. "$LIB_FS"
# shellcheck source=scripts/lib/archive-safety.sh
. "$LIB_ARCHIVE"

# mk_root — a fresh CANONICAL directory (resolves through any /tmp symlink) to act as a trust root.
mk_root() {
	_d=$(mktemp -d "$WORK/r.XXXXXX" 2>/dev/null || mktemp -d -t ssfsb)
	CDPATH= cd -P -- "$_d" && pwd -P
}

# ============================================================================
# Schema present + jq-valid, and the code's reason catalog MATCHES the schema enum exactly
# (structural, jq-based — no ajv). A drift between fs_reason_codes and the schema fails here.
# ============================================================================
jq -e . "$REASON_SCHEMA" >/dev/null 2>&1 && pass "reason-code schema is jq-valid" || fail "reason-code schema jq-valid"
CODE_LIST=$(fs_reason_codes | LC_ALL=C sort)
SCHEMA_LIST=$(jq -r '.properties.reason_codes.items.enum[]' "$REASON_SCHEMA" | LC_ALL=C sort)
[ "$CODE_LIST" = "$SCHEMA_LIST" ] \
	&& pass "fs_reason_codes matches the schema enum exactly (no drift)" \
	|| fail "fs_reason_codes vs schema enum drift"
# The schema is a CLOSED object; a well-formed instance validates structurally.
INSTANCE=$(jq -n --argjson rc "$(fs_reason_codes | jq -R . | jq -s .)" '{schema:"filesystem-safety-reasons", reason_codes:$rc}')
if printf '%s' "$INSTANCE" | jq -e '
	(.schema == "filesystem-safety-reasons") and
	(.reason_codes | type == "array" and (length > 0)) and
	(.reason_codes | all(type == "string"))
' >/dev/null 2>&1; then
	pass "a fs_reason_codes instance conforms to the reason-code schema"
else
	fail "reason-code instance conforms"
fi

# ============================================================================
# (1) TARGET ROOT IS A SYMLINK — fs_canonical_root refuses (FS_ROOT_SYMLINK).
# ============================================================================
REAL=$(mk_root); ln -s "$REAL" "$WORK/rootlink"
r=$(fs_canonical_root "$WORK/rootlink") && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_ROOT_SYMLINK" ]; } \
	&& pass "(1) a symlinked target root is refused (FS_ROOT_SYMLINK)" || fail "(1) symlinked root refused (rc=$rc r=$r)"
c=$(fs_canonical_root "$REAL") && rc=0 || rc=$?
{ [ "$rc" = 0 ] && [ "$c" = "$REAL" ]; } \
	&& pass "(1+) a real directory root canonicalises cleanly" || fail "(1+) real root canonicalises (rc=$rc c=$c)"
r=$(fs_canonical_root "$REAL/does-not-exist") && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_ROOT_NOT_DIR" ]; } \
	&& pass "(1-fi) a non-directory root is refused (FS_ROOT_NOT_DIR)" || fail "(1-fi) non-dir root refused (r=$r)"

# ============================================================================
# (2) METADATA DIR IS A SYMLINK — fs_contained refuses a symlinked component (FS_SYMLINK_COMPONENT).
# ============================================================================
T=$(mk_root); OUT=$(mk_root)
ln -s "$OUT" "$T/.sentinel-shield"                 # metadata dir swapped to a symlink to outside
r=$(fs_contained "$T" ".sentinel-shield/operation-lock.json") && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_SYMLINK_COMPONENT" ]; } \
	&& pass "(2) a symlinked metadata dir is refused (FS_SYMLINK_COMPONENT)" || fail "(2) symlinked metadata dir refused (r=$r)"
T2=$(mk_root); mkdir "$T2/.sentinel-shield"
r=$(fs_contained "$T2" ".sentinel-shield/operation-lock.json") && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(2+) a real metadata path is contained" || fail "(2+) real metadata contained (r=$r)"

# ============================================================================
# (3) METADATA FILE IS A FIFO — fs_assert_regular refuses a non-regular object (FS_SPECIAL_FILE).
# ============================================================================
T=$(mk_root); mkdir "$T/.sentinel-shield"
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$T/.sentinel-shield/operation-lock.json" 2>/dev/null; then
	r=$(fs_assert_regular "$T/.sentinel-shield/operation-lock.json") && rc=0 || rc=$?
	{ [ "$rc" != 0 ] && [ "$r" = "FS_SPECIAL_FILE" ]; } \
		&& pass "(3) a FIFO metadata file is refused (FS_SPECIAL_FILE)" || fail "(3) FIFO metadata refused (r=$r)"
	rm -f "$T/.sentinel-shield/operation-lock.json"
else
	pass "(3) mkfifo unavailable — FIFO case skipped (documented degrade)"
fi
printf '{}' > "$T/.sentinel-shield/operation-lock.json"
fs_assert_regular "$T/.sentinel-shield/operation-lock.json" && pass "(3+) a real regular metadata file is accepted" || fail "(3+) regular metadata accepted"
ln -s /etc/hosts "$T/.sentinel-shield/linkfile"
r=$(fs_assert_regular "$T/.sentinel-shield/linkfile") && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_IS_SYMLINK" ]; } \
	&& pass "(3-fi) a symlinked metadata file is refused (FS_IS_SYMLINK)" || fail "(3-fi) symlink metadata refused (r=$r)"

# ============================================================================
# (4) OPERATION LOCK IS A HARD LINK — fs_assert_single_link refuses (FS_UNEXPECTED_HARDLINK).
# ============================================================================
T=$(mk_root); mkdir "$T/.sentinel-shield"
LK="$T/.sentinel-shield/operation-lock.json"; printf '{"state":"active"}' > "$LK"
ln "$LK" "$WORK/alias-to-lock"                     # a second hard link to the same inode
# A determinable count >= 2 is rejected in STRICT mode (the value security-sensitive callers pass).
r=$(fs_assert_single_link "$LK" strict) && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_UNEXPECTED_HARDLINK" ]; } \
	&& pass "(4) a hard-linked operation lock is refused in strict mode (FS_UNEXPECTED_HARDLINK)" || fail "(4) hard-link lock refused (r=$r)"
# A determinable count >= 2 is rejected in ADVISORY mode TOO — a real extra link is never a degrade.
r=$(fs_assert_single_link "$LK" advisory) && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_UNEXPECTED_HARDLINK" ]; } \
	&& pass "(4) a hard-linked lock is refused in advisory mode too (determinable danger)" || fail "(4) advisory hard-link refused (r=$r)"
rm -f "$WORK/alias-to-lock"
# (4+) exactly one link -> pass in STRICT mode (the legitimate positive control).
r=$(fs_assert_single_link "$LK" strict) && rc=0 || rc=$?
[ "$rc" = 0 ] && pass "(4+) a single-link lock is accepted in strict mode" || fail "(4+) single-link lock accepted (rc=$rc r=$r)"
# Default mode is STRICT: no argument behaves exactly like strict for a single-link file.
fs_assert_single_link "$LK" && pass "(4+) default mode (no arg) accepts a single-link lock" || fail "(4+) default-mode single-link accepted"

# ----------------------------------------------------------------------------
# (4-fi) HARD-LINK INSPECTION UNAVAILABLE — fail closed in STRICT, warn/pass in ADVISORY.
# We shadow `ls` via PATH (a fresh child sh so PATH resolution is deterministic and un-hashed;
# awk and every other tool still resolve from the inherited PATH) with three broken variants:
# a missing/unusable ls, a malformed line, and an unsupported-platform line whose link-count
# field this parser cannot read. In every case the link count is UNDETERMINABLE.
# ----------------------------------------------------------------------------
FAKEBIN_MISSING="$WORK/fakebin-missing"; mkdir -p "$FAKEBIN_MISSING"
# "missing"/unusable ls: emits nothing, exits non-zero -> nlink parses to "" (unavailable).
cat > "$FAKEBIN_MISSING/ls" <<'FLS'
#!/bin/sh
exit 127
FLS
FAKEBIN_MALFORMED="$WORK/fakebin-malformed"; mkdir -p "$FAKEBIN_MALFORMED"
# malformed output: field 2 (the nlink column this parser reads) is non-numeric.
cat > "$FAKEBIN_MALFORMED/ls" <<'FLS'
#!/bin/sh
printf 'this is not a valid ls -ldn line\n'
FLS
FAKEBIN_UNSUPPORTED="$WORK/fakebin-unsupported"; mkdir -p "$FAKEBIN_UNSUPPORTED"
# unsupported-platform format: a line whose 2nd field is not the link count.
cat > "$FAKEBIN_UNSUPPORTED/ls" <<'FLS'
#!/bin/sh
printf -- '-rw------- ? user group 42 Jan 1 00:00 operation-lock.json\n'
FLS
chmod 755 "$FAKEBIN_MISSING/ls" "$FAKEBIN_MALFORMED/ls" "$FAKEBIN_UNSUPPORTED/ls"

# single_link_shadow <fakebin> <mode> <path> -> prints "rc|token" from a fresh child sh whose
# PATH resolves `ls` to the shadow (fresh process = no command-hash carry-over).
single_link_shadow() {
	SS_FAKEBIN="$1" SS_MODE="$2" SS_TARGET="$3" SS_COMMON="$LIB_COMMON" SS_FS="$LIB_FS" \
	sh -c '
		PATH="$SS_FAKEBIN:$PATH"; export PATH
		. "$SS_COMMON"
		. "$SS_FS"
		_r=$(fs_assert_single_link "$SS_TARGET" "$SS_MODE") && _rc=0 || _rc=$?
		printf "%s|%s" "$_rc" "$_r"
	' 2>/dev/null
}

# Sanity: with the real ls, a single-link file resolves cleanly (guards against a broken harness).
out=$(single_link_shadow "$WORK/nonexistent-fakebin" strict "$LK")
[ "$out" = "0|" ] && pass "(4-fi) harness: real ls yields a determinable single-link pass" || fail "(4-fi) harness real-ls sanity (out='$out')"

for variant in "missing:$FAKEBIN_MISSING" "malformed:$FAKEBIN_MALFORMED" "unsupported:$FAKEBIN_UNSUPPORTED"; do
	_vlbl=${variant%%:*}; _vbin=${variant#*:}
	# STRICT: an undeterminable count MUST fail closed with the distinct token.
	out=$(single_link_shadow "$_vbin" strict "$LK")
	[ "$out" = "1|FS_LINK_COUNT_UNAVAILABLE" ] \
		&& pass "(4-fi) strict mode fails closed on $_vlbl ls (FS_LINK_COUNT_UNAVAILABLE)" \
		|| fail "(4-fi) strict $_vlbl fails closed (out='$out')"
	# Default (no explicit mode) is STRICT: same fail-closed outcome.
	out=$(SS_FAKEBIN="$_vbin" SS_MODE="" SS_TARGET="$LK" SS_COMMON="$LIB_COMMON" SS_FS="$LIB_FS" \
		sh -c 'PATH="$SS_FAKEBIN:$PATH"; export PATH; . "$SS_COMMON"; . "$SS_FS"; _r=$(fs_assert_single_link "$SS_TARGET") && _rc=0 || _rc=$?; printf "%s|%s" "$_rc" "$_r"' 2>/dev/null)
	[ "$out" = "1|FS_LINK_COUNT_UNAVAILABLE" ] \
		&& pass "(4-fi) DEFAULT mode fails closed on $_vlbl ls (strict is the default)" \
		|| fail "(4-fi) default $_vlbl fails closed (out='$out')"
	# ADVISORY: an undeterminable count warns and passes (best-effort, non-security surface).
	out=$(single_link_shadow "$_vbin" advisory "$LK")
	[ "$out" = "0|" ] \
		&& pass "(4-fi) advisory mode warns/passes on $_vlbl ls" \
		|| fail "(4-fi) advisory $_vlbl passes (out='$out')"
done

# An unknown/typo mode is treated as STRICT (safe default), never silently downgraded to advisory.
out=$(single_link_shadow "$FAKEBIN_MISSING" bogusmode "$LK")
[ "$out" = "1|FS_LINK_COUNT_UNAVAILABLE" ] \
	&& pass "(4-fi) an unknown mode fails closed like strict (no silent downgrade)" \
	|| fail "(4-fi) unknown mode fails closed (out='$out')"

# The new reason token is present in the code catalog AND the schema enum.
fs_reason_codes | grep -qx 'FS_LINK_COUNT_UNAVAILABLE' \
	&& pass "(4-fi) fs_reason_codes lists FS_LINK_COUNT_UNAVAILABLE" || fail "(4-fi) code catalog has token"
jq -e '.properties.reason_codes.items.enum | index("FS_LINK_COUNT_UNAVAILABLE") != null' "$REASON_SCHEMA" >/dev/null 2>&1 \
	&& pass "(4-fi) the reason schema enumerates FS_LINK_COUNT_UNAVAILABLE" || fail "(4-fi) schema has token"

# ============================================================================
# (5) DESTINATION WORLD-WRITABLE — fs_assert_not_group_world_writable refuses (FS_GROUP_WORLD_WRITABLE).
# ============================================================================
if [ "$IS_ROOT" = 0 ]; then
	T=$(mk_root); mkdir "$T/.sentinel-shield"
	WW="$T/.sentinel-shield/journal.jsonl"; printf 'x\n' > "$WW"; chmod 666 "$WW"
	r=$(fs_assert_not_group_world_writable "$WW") && rc=0 || rc=$?
	{ [ "$rc" != 0 ] && [ "$r" = "FS_GROUP_WORLD_WRITABLE" ]; } \
		&& pass "(5) a world-writable metadata file is refused (FS_GROUP_WORLD_WRITABLE)" || fail "(5) world-writable refused (r=$r)"
	chmod 660 "$WW"                              # rw-rw---- : group-WRITABLE
	r=$(fs_assert_not_group_world_writable "$WW") && rc=0 || rc=$?
	{ [ "$rc" != 0 ] && [ "$r" = "FS_GROUP_WORLD_WRITABLE" ]; } \
		&& pass "(5-fi) a group-writable metadata file is refused too (FS_GROUP_WORLD_WRITABLE)" || fail "(5-fi) group-writable refused (r=$r)"
	chmod 600 "$WW"
	fs_assert_not_group_world_writable "$WW" && pass "(5+) an owner-only metadata file is accepted" || fail "(5+) owner-only accepted"
else
	pass "(5) skipped under root (permission gate not enforceable)"
fi

# ============================================================================
# (6) CASE-FOLDED PATH COLLISION — fs_casefold_collisions detects a clobbering pair (FS_CASE_COLLISION).
# ============================================================================
r=$(printf 'CONFIG.json\nconfig.json\nunique.txt\n' | fs_casefold_collisions) && rc=0 || rc=$?
{ [ "$rc" != 0 ] && printf '%s' "$r" | grep -qx 'CONFIG.json' && printf '%s' "$r" | grep -qx 'config.json'; } \
	&& pass "(6) a case-fold path collision is detected (both members reported)" || fail "(6) case-fold collision detected (rc=$rc r='$r')"
printf 'a.txt\nb.txt\nc.txt\n' | fs_casefold_collisions >/dev/null 2>&1 \
	&& pass "(6+) a case-fold-unique set is accepted" || fail "(6+) unique set accepted"
# Normalisation collision (post-normalise duplicate) is likewise detected.
printf 'dir//x\ndir/x\n' | fs_path_collisions >/dev/null 2>&1 \
	&& fail "(6-fi) normalised duplicate accepted" || pass "(6-fi) a post-normalisation path collision is detected (FS_PATH_COLLISION)"

# ============================================================================
# (7) ARCHIVE EXTRACTS FILES DIFFERING ONLY BY CASE — archive_safety_case_scan rejects.
# ============================================================================
if command -v zipinfo >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
	# Build a zip naming BOTH cases deterministically, independent of the build filesystem's
	# case sensitivity (a real archive can carry entries a case-insensitive FS cannot).
	Z="$WORK/case.zip"
	python3 - "$Z" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("README.md", "A\n")
z.writestr("readme.md", "b\n")
z.close()
PY
	scan=$(archive_safety_case_scan "$Z")
	printf '%s' "$scan" | grep -q '^case-collision:' \
		&& pass "(7) an archive with case-only-differing entries is rejected (case-collision token)" \
		|| fail "(7) archive case collision rejected (scan='$scan')"
	# Positive control: an archive with distinct names produces no case-collision token.
	Z2="$WORK/ok.zip"
	python3 - "$Z2" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1], "w")
z.writestr("one.md", "1\n")
z.writestr("two.md", "2\n")
z.close()
PY
	scan2=$(archive_safety_case_scan "$Z2")
	if printf '%s' "$scan2" | grep -q '^case-collision:'; then
		fail "(7+) case-unique archive clean (scan='$scan2')"
	else
		pass "(7+) a case-unique archive yields no case-collision token"
	fi
else
	# Failure-injection / degrade: exercise the underlying fold detector directly when no zip tool.
	printf 'README.md\nreadme.md\n' | fs_casefold_collisions >/dev/null 2>&1 \
		&& fail "(7) zip tools absent AND fold detector missed the collision" \
		|| pass "(7) zip tools unavailable — case collision proven via fs_casefold_collisions (documented degrade)"
fi

# ============================================================================
# (8) TEMP DIR POINTS OUTSIDE TRUSTED WORKSPACE — fs_assert_temp_root refuses (FS_TEMP_OUTSIDE_ROOT).
# ============================================================================
WS=$(mk_root); OUTSIDE=$(mk_root)
r=$(fs_assert_temp_root "$WS" "$OUTSIDE") && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_TEMP_OUTSIDE_ROOT" ]; } \
	&& pass "(8) a temp root outside the workspace is refused (FS_TEMP_OUTSIDE_ROOT)" || fail "(8) outside temp refused (r=$r)"
mkdir -p "$WS/work"
fs_assert_temp_root "$WS" "$WS/work" && pass "(8+) a temp root inside the workspace is accepted" || fail "(8+) inside temp accepted"
# fs_mktemp_dir never consults $TMPDIR: it creates inside the trusted root and stays contained.
d=$(fs_mktemp_dir "$WS") && rc=0 || rc=$?
{ [ "$rc" = 0 ] && [ -d "$d" ] && case "$d/" in "$WS"/*) true ;; *) false ;; esac; } \
	&& pass "(8-fi) fs_mktemp_dir creates a contained 0700 temp under the trusted root" || fail "(8-fi) mktemp_dir contained (rc=$rc d=$d)"

# ============================================================================
# (9) REPORT DESTINATION IS A SYMLINK — fs_atomic_replace refuses to write THROUGH it (FS_IS_SYMLINK).
# ============================================================================
DEST_DIR=$(mk_root); SECRET=$(mk_root); printf 'DO-NOT-CLOBBER\n' > "$SECRET/target"
ln -s "$SECRET/target" "$DEST_DIR/report.json"     # report path swapped to a symlink to outside
printf '{"report":true}\n' > "$WORK/report-src.json"
r=$(fs_atomic_replace "$WORK/report-src.json" "$DEST_DIR/report.json") && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_IS_SYMLINK" ]; } \
	&& pass "(9) a symlinked report destination is refused (FS_IS_SYMLINK)" || fail "(9) symlinked report refused (r=$r)"
[ "$(cat "$SECRET/target")" = "DO-NOT-CLOBBER" ] \
	&& pass "(9) the outside file behind the symlink was NOT clobbered" || fail "(9) outside file untouched"
# Positive control: a real (non-symlink) report destination replaces atomically.
rm -f "$DEST_DIR/report.json"
fs_atomic_replace "$WORK/report-src.json" "$DEST_DIR/report.json" \
	&& [ "$(cat "$DEST_DIR/report.json")" = '{"report":true}' ] \
	&& pass "(9+) a real report destination is replaced atomically" || fail "(9+) real report replaced"

# ============================================================================
# (10) RECURSIVE CLEANUP OF /, EMPTY, HOME, REPO ROOT, OR AN UNOWNED DIR — all REFUSED.
# ============================================================================
OWNED=$(mk_root); mkdir -p "$OWNED/sub/deep"       # a verified operation-owned root
UNOWNED=$(mk_root)
for spec in "slash:/" "empty:" "home:${HOME:-/nonexistent}" "repo:$ROOT" "unowned:$UNOWNED"; do
	_lbl=${spec%%:*}; _tgt=${spec#*:}
	r=$(fs_safe_rmtree "$OWNED" "$_tgt") && rc=0 || rc=$?
	{ [ "$rc" != 0 ] && [ "$r" = "FS_REFUSE_DELETE" ]; } \
		&& pass "(10) recursive delete of '$_lbl' is REFUSED (FS_REFUSE_DELETE)" || fail "(10) delete '$_lbl' refused (rc=$rc r=$r)"
done
[ -d "$ROOT/scripts/lib" ] && pass "(10) the repo root survived every refusal" || fail "(10) repo root survived"
[ -d "$UNOWNED" ] && pass "(10) the unowned dir survived the refusal" || fail "(10) unowned survived"
# A symlinked target is refused (never followed into an unowned tree).
ln -s "$UNOWNED" "$OWNED/linktgt"
r=$(fs_safe_rmtree "$OWNED" "$OWNED/linktgt") && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_REFUSE_DELETE" ]; } && [ -d "$UNOWNED" ] \
	&& pass "(10-fi) a symlinked delete target is refused (unowned tree preserved)" || fail "(10-fi) symlink delete refused (r=$r)"
# POSITIVE control: an operation-owned subtree IS deleted.
fs_safe_rmtree "$OWNED" "$OWNED/sub" && [ ! -d "$OWNED/sub" ] \
	&& pass "(10+) a verified operation-owned subtree is deleted" || fail "(10+) owned subtree deleted"

# ============================================================================
# (11) FILE REPLACED BETWEEN VALIDATION AND WRITE — race detected (FS_RACE_DETECTED).
# ============================================================================
RT=$(mk_root); F="$RT/managed.txt"; printf 'ORIGINAL\n' > "$F"
ID=$(fs_identity "$F")                              # captured at "validation" time
rm -f "$F"; printf 'SWAPPED-LONGER\n' > "$F"        # attacker swaps the inode between check and use
r=$(fs_verify_unchanged "$F" "$ID") && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_RACE_DETECTED" ]; } \
	&& pass "(11) a file swapped between validation and write is detected (FS_RACE_DETECTED)" || fail "(11) race detected (rc=$rc r=$r)"
# Positive control: an unchanged file verifies.
G="$RT/stable.txt"; printf 'STABLE\n' > "$G"; GID=$(fs_identity "$G")
fs_verify_unchanged "$G" "$GID" && pass "(11+) an unchanged file verifies clean" || fail "(11+) unchanged verifies"
# Failure-injection: an in-place rewrite that changes size is caught even if the inode is reused.
H="$RT/inplace.txt"; printf 'aa\n' > "$H"; HID=$(fs_identity "$H"); printf 'aaaaaaaa\n' > "$H"
r=$(fs_verify_unchanged "$H" "$HID") && rc=0 || rc=$?
{ [ "$rc" != 0 ] && [ "$r" = "FS_RACE_DETECTED" ]; } \
	&& pass "(11-fi) an in-place resize is detected as a race too" || fail "(11-fi) in-place resize detected (r=$r)"

# ============================================================================
# (12) EXECUTABLE MODE PRESERVED ONLY WHERE EXPECTED.
# ============================================================================
XD=$(mk_root)
printf '#!/bin/sh\necho hi\n' > "$WORK/exec-src"; chmod 755 "$WORK/exec-src"
printf 'plain data\n' > "$WORK/data-src"           # non-executable source
fs_atomic_replace "$WORK/exec-src" "$XD/hook" && rc=0 || rc=$?
fs_atomic_replace "$WORK/data-src" "$XD/config" && rc2=0 || rc2=$?
{ [ "${rc:-0}" = 0 ] && [ "${rc2:-0}" = 0 ]; } && pass "(12) atomic replace of an exec + a data file both succeed" || fail "(12) atomic replaces succeed"
if [ "$IS_ROOT" = 0 ]; then
	[ -x "$XD/hook" ] && pass "(12) the executable bit is preserved for an intended-executable file" || fail "(12) exec bit preserved"
	[ ! -x "$XD/config" ] && pass "(12) a data file is NOT granted an executable bit" || fail "(12) data file stays non-exec"
else
	# root can traverse/execute regardless; assert the recorded mode bits instead.
	case "$(_fs_mode_str "$XD/hook")" in *x*) pass "(12) exec bit recorded for the executable file (root)" ;; *) fail "(12) exec bit recorded" ;; esac
	case "$(_fs_mode_str "$XD/config")" in -rw-r--r--*|-rw-------*) pass "(12) data file recorded non-exec (root)" ;; *) fail "(12) data file non-exec recorded ($(_fs_mode_str "$XD/config"))" ;; esac
fi
# Failure-injection: fs_apply_secret_mode tightens a data file to owner-only 0600 (the trailing
# ls attribute marker '@'/'+' on some platforms is tolerated by the glob).
fs_apply_secret_mode "$XD/config" >/dev/null 2>&1 && smrc=0 || smrc=$?
[ "$smrc" = 0 ] || fail "(12-fi) fs_apply_secret_mode returned non-zero ($smrc)"
case "$(_fs_mode_str "$XD/config")" in -rw-------*) pass "(12-fi) fs_apply_secret_mode tightens a data file to 0600" ;; *) fail "(12-fi) secret-mode 0600 ($(_fs_mode_str "$XD/config"))" ;; esac

# ============================================================================
# (INTEGRATION) generate-release-manifest.sh applies the report-destination boundary: a
# symlinked --output is refused (release evidence never written THROUGH a link), while a real
# --output is written normally. Exercises the wiring end-to-end, not just the primitive.
# ============================================================================
GRM="$ROOT/scripts/generate-release-manifest.sh"
EVID="$WORK/evidence.json"
printf '{"version":"0.0.0-test","stage":"test","engine_commit":"unknown"}\n' > "$EVID"
# Negative: --output is a symlink to an outside sentinel — must fail closed, sentinel untouched.
SDIR=$(mk_root); SENT=$(mk_root); printf 'EVIDENCE-SENTINEL\n' > "$SENT/outside"
ln -s "$SENT/outside" "$SDIR/manifest.json"
sh "$GRM" --evidence "$EVID" --repo-root "$ROOT" --output "$SDIR/manifest.json" >/dev/null 2>&1 && rc=0 || rc=$?
[ "$rc" = 2 ] && pass "(INT) generate-release-manifest refuses a symlinked --output (exit 2)" || fail "(INT) manifest symlink output refused (rc=$rc)"
[ "$(cat "$SENT/outside")" = "EVIDENCE-SENTINEL" ] \
	&& pass "(INT) the outside file behind the --output symlink was NOT written" || fail "(INT) outside sentinel untouched"
# Positive: a plain --output path is written and is a valid manifest.
rm -f "$SDIR/manifest.json"
sh "$GRM" --evidence "$EVID" --repo-root "$ROOT" --output "$SDIR/manifest.json" >/dev/null 2>&1 && rc=0 || rc=$?
{ [ "$rc" = 0 ] && jq -e '.schema_version=="1" and (.reproducibility.hash|type=="string")' "$SDIR/manifest.json" >/dev/null 2>&1; } \
	&& pass "(INT+) a real --output path yields a valid manifest" || fail "(INT+) real output manifest (rc=$rc)"

# ============================================================================
if [ "$FAILS" -ne 0 ]; then
	printf '\n%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\nAll filesystem-boundary assertions passed.\n'
exit 0
