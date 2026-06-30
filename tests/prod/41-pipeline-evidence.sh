#!/bin/sh
# Sentinel Shield prod test — local pipeline evidence root + raw-evidence manifest +
# concurrency (Findings 7 & 8 for scripts/run-local-pipeline.sh).
#
# Network-free, against a copy of the php-library fixture. Asserts:
#   (1) --output-dir OUTSIDE <target>/reports is rejected (exit 2) — no silent split of the
#       evidence root; an --output-dir INSIDE <target>/reports is accepted (not exit 2);
#   (2) a concurrent run is fail-closed: when the run lock is already held, a second run
#       refuses with exit 4 and does NOT clobber the held lock;
#   (3) the durable raw-evidence manifest records the produced report's SHA-256 (and the
#       required per-tool fields); --purpose release RETAINS the raw report + its hash;
#   (4) --purpose developer cleanup is safe: the raw report is removed but the manifest and
#       its hash SURVIVE;
#   (5) the honest required-tool-unavailable exit 3 is preserved (scanners absent -> not a
#       faked pass).
#
# To get a real raw report in a hermetic env we make the php-syntax runner's tool (`php`)
# available via a fake on the isolated PATH (it always exits 0, so php-syntax writes
# reports/raw/php-syntax.json). The required network scanners (gitleaks/semgrep/...) stay
# absent, so the pipeline still exits 3 honestly.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

PIPELINE="$ROOT/scripts/run-local-pipeline.sh"
FIXTURE="$ROOT/tests/fixtures/projects/php-library"
FAILED=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

command -v jq >/dev/null 2>&1 || { fail "jq is required to run this test"; exit 1; }
[ -f "$PIPELINE" ] || { fail "missing $PIPELINE"; exit 1; }
[ -d "$FIXTURE" ] || { fail "missing fixture $FIXTURE"; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ss41)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

TARGET="$WORK/target"
mkdir -p "$TARGET"
cp -R "$FIXTURE/." "$TARGET/"

# Portable SHA-256 of a file (same digest regardless of tool).
t_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then shasum -a 256 -- "$1" | cut -d' ' -f1
	else openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
}

# --- isolated PATH: scanners absent, but a fake `php` present -----------------
ISOBIN="$WORK/isobin"
mkdir -p "$ISOBIN"
_oifs=$IFS
IFS=:
for _d in $PATH; do
	[ -d "$_d" ] || continue
	for _p in "$_d"/*; do
		[ -f "$_p" ] || continue
		_n=${_p##*/}
		case "$_n" in
			gitleaks | semgrep | trivy | osv-scanner | php) continue ;;
		esac
		[ -e "$ISOBIN/$_n" ] && continue
		ln -s "$_p" "$ISOBIN/$_n" 2>/dev/null || cp -- "$_p" "$ISOBIN/$_n" 2>/dev/null || true
	done
done
IFS=$_oifs
# Fake php: makes the php-syntax runner produce reports/raw/php-syntax.json (always valid).
printf '#!/bin/sh\nexit 0\n' > "$ISOBIN/php"
chmod +x "$ISOBIN/php"

# --- (1) output-root: outside <target>/reports rejected (exit 2) -------------
OUTSIDE="$WORK/outside-reports"
mkdir -p "$OUTSIDE"
rc=0
sh "$PIPELINE" --profile php-library --target "$TARGET" --stage pr \
	--output-dir "$OUTSIDE" --non-interactive >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then
	pass "--output-dir outside <target>/reports rejected with exit 2 (no split evidence root)"
else
	fail "expected exit 2 for out-of-tree --output-dir, got $rc"
fi

# --- (2) concurrency: a held lock makes a second run fail closed (exit 4) -----
LOCK="$TARGET/reports/.pipeline-lock"
mkdir -p "$LOCK"
printf 'held-by-other-run\n' > "$LOCK/sentinel"
rc=0
PATH="$ISOBIN" sh "$PIPELINE" --profile php-library --target "$TARGET" --stage pr \
	--output-dir "$TARGET/reports/locked" --non-interactive >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 4 ]; then
	pass "concurrent run blocked by held lock (fail-closed exit 4)"
else
	fail "expected exit 4 when lock is held, got $rc"
fi
if [ -f "$LOCK/sentinel" ] && grep -q 'held-by-other-run' "$LOCK/sentinel"; then
	pass "held lock not clobbered by the refused run"
else
	fail "the refused run clobbered another run's lock"
fi
rm -rf -- "$LOCK"

# --- (2b) signal traps release the lock AND stop (Finding 6) -----------------
# On INT/TERM the pipeline must release its lock and exit, not merely clean up and keep
# running. Verify statically that the INT/TERM traps invoke exit (the bare EXIT trap stays
# cleanup-only). A live signal race would be flaky, so assert the trap wiring directly.
if grep -Eq "trap '?release_lock; *exit [0-9]+'? INT" "$PIPELINE" &&
	grep -Eq "trap '?release_lock; *exit [0-9]+'? TERM" "$PIPELINE"; then
	pass "INT/TERM traps release the lock and exit (no run-after-interrupt)"
else
	fail "INT/TERM traps must release the lock and exit, not just clean up"
fi

# --- (3) --purpose release: raw RETAINED + hash recorded ---------------------
RELOUT="$TARGET/reports/release-out"
mkdir -p "$RELOUT"
rc=0
PATH="$ISOBIN" sh "$PIPELINE" --profile php-library --target "$TARGET" --stage pr \
	--output-dir "$RELOUT" --purpose release --non-interactive >/dev/null 2>&1 || rc=$?

# Honest exit 3 (required scanners absent) — never a faked pass; also proves the in-tree
# --output-dir was ACCEPTED (not rejected with 2).
if [ "$rc" -eq 3 ]; then
	pass "release run honest exit 3 (required scanners absent; in-tree --output-dir accepted)"
else
	fail "expected honest exit 3 for release run, got $rc"
fi

MAN="$RELOUT/raw-evidence-manifest.json"
RAWREP="$TARGET/reports/raw/php-syntax.json"
if [ -f "$MAN" ] && jq -e . "$MAN" >/dev/null 2>&1; then
	pass "raw-evidence manifest written and valid JSON"
else
	fail "raw-evidence manifest missing or invalid: $MAN"
fi

# php-syntax produced a report this run; its SHA-256 must appear in the manifest.
if [ -f "$RAWREP" ]; then
	pass "release: raw report RETAINED (reports/raw/php-syntax.json present)"
else
	fail "release: raw report should be retained but is missing"
fi

_ent=$(jq -c '.tools[] | select(.tool=="php-syntax")' "$MAN" 2>/dev/null || printf '')
if [ -n "$_ent" ]; then
	_mhash=$(printf '%s' "$_ent" | jq -r '.report_sha256 // ""')
	_fhash=""
	[ -f "$RAWREP" ] && _fhash=$(t_sha256 "$RAWREP")
	_status=$(printf '%s' "$_ent" | jq -r '.status // ""')
	_rpath=$(printf '%s' "$_ent" | jq -r '.report_path // ""')
	_pod=$(printf '%s' "$_ent" | jq -r '.preserved_or_deleted // ""')
	if [ -n "$_mhash" ] && [ "$_mhash" = "$_fhash" ]; then
		pass "manifest records the produced report's SHA-256 (matches the on-disk report)"
	else
		fail "manifest sha256 ($_mhash) != on-disk report sha256 ($_fhash)"
	fi
	if [ "$_status" = "ran" ] && [ "$_rpath" = "reports/raw/php-syntax.json" ] && [ "$_pod" = "preserved" ]; then
		pass "manifest entry carries status/report_path/preserved_or_deleted (release=preserved)"
	else
		fail "manifest entry fields wrong: status=$_status report_path=$_rpath preserved=$_pod"
	fi
	# required per-tool fields are all present (auditable provenance).
	if printf '%s' "$_ent" | jq -e 'has("runner") and has("runner_exit") and has("status") and has("report_path") and has("report_sha256") and has("produced_at") and has("preserved_or_deleted") and has("duration")' >/dev/null 2>&1; then
		pass "manifest entry has every required field (runner..duration)"
	else
		fail "manifest entry missing a required field"
	fi
else
	fail "no php-syntax entry in the raw-evidence manifest"
fi

# --- (4) --purpose developer cleanup is safe: report removed, hash survives ---
DEVOUT="$TARGET/reports/dev-out"
mkdir -p "$DEVOUT"
rc=0
PATH="$ISOBIN" sh "$PIPELINE" --profile php-library --target "$TARGET" --stage pr \
	--output-dir "$DEVOUT" --purpose developer --non-interactive >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 3 ]; then
	pass "developer run honest exit 3 (scanners absent)"
else
	fail "expected honest exit 3 for developer run, got $rc"
fi

DMAN="$DEVOUT/raw-evidence-manifest.json"
if [ ! -e "$TARGET/reports/raw" ]; then
	pass "developer default removed the raw report dir"
else
	fail "developer default should remove the raw report dir"
fi
_dhash=$(jq -r '.tools[] | select(.tool=="php-syntax") | .report_sha256 // ""' "$DMAN" 2>/dev/null || printf '')
_dpod=$(jq -r '.tools[] | select(.tool=="php-syntax") | .preserved_or_deleted // ""' "$DMAN" 2>/dev/null || printf '')
if [ -n "$_dhash" ] && [ "$_dpod" = "deleted" ]; then
	pass "developer cleanup: manifest + SHA-256 survive the raw removal (preserved_or_deleted=deleted)"
else
	fail "developer manifest should retain the hash after cleanup (hash=$_dhash pod=$_dpod)"
fi

[ "$FAILED" -eq 0 ] && exit 0 || exit 1
