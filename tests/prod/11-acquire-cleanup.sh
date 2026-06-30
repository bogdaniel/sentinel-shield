#!/bin/sh
# tests/prod/11-acquire-cleanup.sh — BLOCKER 1 (destructive-destination guard) + FINDING 6
# (record path-privacy) for scripts/acquire-sentinel-shield.sh.
#
# Self-contained and NETWORK-FREE: a local bare repo is the only "remote".
# CRITICAL: every unsafe-path assertion proves the SCRIPT REFUSES (exit 2) and that a
# sentinel inside/at the would-be-deleted target STILL EXISTS afterward — a test must never
# actually rm an unsafe path.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ACQ="$ROOT/scripts/acquire-sentinel-shield.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssacq11)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

# A throwaway local "remote": bare repo with an immutable tag.
REMOTE="$WORK/remote.git"
SEED="$WORK/seed"
git init -q --bare "$REMOTE"
git init -q "$SEED"
git -C "$SEED" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m init
git -C "$SEED" branch -M main
git -C "$SEED" tag v1.0.0
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin main --tags >/dev/null 2>&1
SHA=$(git -C "$SEED" rev-parse HEAD)

# refuse_keep <label> <existing-sentinel-path> -- run --cleanup on "$@" (after the label
# + sentinel), assert exit 2 AND the sentinel still exists.
# Usage: refuse_keep "<label>" "<sentinel>" <acquire-args...>
refuse_keep() {
	_label=$1; _sentinel=$2; shift 2
	out=$(sh "$ACQ" "$@" --cleanup 2>&1) && rc=0 || rc=$?
	if [ "$rc" = 2 ]; then pass "$_label refused with exit 2"
	else fail "$_label refused with exit 2 (got rc=$rc; out=$out)"; fi
	if [ -e "$_sentinel" ] || [ -L "$_sentinel" ]; then pass "$_label deleted nothing (sentinel survives)"
	else fail "$_label deleted nothing (sentinel MISSING: $_sentinel)"; fi
}

# --- UNSAFE destinations: refuse (exit 2), delete nothing ----------------------

# (1) empty destination.
out=$(sh "$ACQ" --destination "" --cleanup 2>&1) && rc=0 || rc=$?
if [ "$rc" = 2 ]; then pass "(1) empty destination refused with exit 2"
else fail "(1) empty destination refused with exit 2 (got rc=$rc)"; fi

# (2) '.' — the current directory. Run from a sentinel-bearing temp dir.
DOT="$WORK/dotdir"; mkdir -p "$DOT"; : > "$DOT/SENTINEL"
out=$( (cd "$DOT" && sh "$ACQ" --destination . --cleanup) 2>&1 ) && rc=0 || rc=$?
if [ "$rc" = 2 ]; then pass "(2) '.' (CWD) refused with exit 2"
else fail "(2) '.' (CWD) refused with exit 2 (got rc=$rc)"; fi
[ -e "$DOT/SENTINEL" ] && pass "(2) '.' deleted nothing" || fail "(2) '.' deleted nothing"

# (3) '..' — the parent directory.
DEEP="$WORK/deep/sub"; mkdir -p "$DEEP"; : > "$WORK/deep/SENTINEL"
out=$( (cd "$DEEP" && sh "$ACQ" --destination .. --cleanup) 2>&1 ) && rc=0 || rc=$?
if [ "$rc" = 2 ]; then pass "(3) '..' (parent) refused with exit 2"
else fail "(3) '..' (parent) refused with exit 2 (got rc=$rc)"; fi
[ -e "$WORK/deep/SENTINEL" ] && pass "(3) '..' deleted nothing" || fail "(3) '..' deleted nothing"

# (4) '/' — the filesystem root.
out=$(sh "$ACQ" --destination / --cleanup 2>&1) && rc=0 || rc=$?
if [ "$rc" = 2 ]; then pass "(4) '/' refused with exit 2"
else fail "(4) '/' refused with exit 2 (got rc=$rc)"; fi
[ -d / ] && pass "(4) '/' still present" || fail "(4) '/' still present"

# (5) $HOME.
refuse_keep "(5) \$HOME" "$HOME" --destination "$HOME"

# (6) the current/source repo root (SCRIPT_DIR/..). Prove the script file survives.
refuse_keep "(6) source repo root" "$ROOT/scripts/acquire-sentinel-shield.sh" --destination "$ROOT"

# (7) the parent of the repo (an ancestor of the CWD when run from inside the repo).
out=$( (cd "$ROOT" && sh "$ACQ" --destination "$(dirname "$ROOT")" --cleanup) 2>&1 ) && rc=0 || rc=$?
if [ "$rc" = 2 ]; then pass "(7) parent-of-repo refused with exit 2"
else fail "(7) parent-of-repo refused with exit 2 (got rc=$rc)"; fi
[ -e "$ROOT/scripts/acquire-sentinel-shield.sh" ] && pass "(7) parent-of-repo deleted nothing" || fail "(7) parent-of-repo deleted nothing"

# (8) a symlink pointing AT the repo root — must be refused, never followed to rm its target.
LINK="$WORK/link_to_repo"; ln -s "$ROOT" "$LINK"
out=$(sh "$ACQ" --destination "$LINK" --cleanup 2>&1) && rc=0 || rc=$?
if [ "$rc" = 2 ]; then pass "(8) symlink destination refused with exit 2"
else fail "(8) symlink destination refused with exit 2 (got rc=$rc)"; fi
[ -L "$LINK" ] && pass "(8) symlink not removed" || fail "(8) symlink not removed"
[ -e "$ROOT/scripts/acquire-sentinel-shield.sh" ] && pass "(8) symlink target intact" || fail "(8) symlink target intact"

# (9) a path containing '../' that even RESOLVES to a permitted tools dir is still refused
#     (unresolved traversal in the input is rejected before any canonicalization/rm).
mkdir -p "$WORK/trav/.sentinel-shield-tools"; : > "$WORK/trav/.sentinel-shield-tools/SENTINEL"
refuse_keep "(9) '../' traversal input" "$WORK/trav/.sentinel-shield-tools/SENTINEL" \
	--destination "$WORK/trav/sub/../.sentinel-shield-tools"

# --- SAFE destinations: a dedicated tools dir is actually removed ---------------

# (A) standalone cleanup of <tmp>/.sentinel-shield-tools removes it.
TA="$WORK/.sentinel-shield-tools"; mkdir -p "$TA"; : > "$TA/payload"
out=$(sh "$ACQ" --destination "$TA" --cleanup 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$TA" ]; then pass "(A) safe .sentinel-shield-tools cleanup removed the dir"
else fail "(A) safe .sentinel-shield-tools cleanup removed the dir (rc=$rc present=$( [ -e "$TA" ] && echo yes || echo no ))"; fi

# (B) standalone cleanup of <tmp>/tools/sentinel-shield removes it.
TB="$WORK/tools/sentinel-shield"; mkdir -p "$TB"; : > "$TB/payload"
out=$(sh "$ACQ" --destination "$TB" --cleanup 2>&1) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ ! -e "$TB" ]; then pass "(B) safe tools/ subdir cleanup removed the dir"
else fail "(B) safe tools/ subdir cleanup removed the dir (rc=$rc present=$( [ -e "$TB" ] && echo yes || echo no ))"; fi

# (C) cleanup-BEFORE-clone of a safe tools dir succeeds: junk is removed and a checkout lands.
CBC="$WORK/cbc/.sentinel-shield-tools"; mkdir -p "$CBC"; : > "$CBC/STALE"
out=$(sh "$ACQ" --repository "$REMOTE" --ref v1.0.0 --destination "$CBC" --cleanup 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$out" = "$SHA" ] && [ ! -e "$CBC/STALE" ] && [ -f "$CBC/.sentinel-shield-ref" ]; then
	pass "(C) cleanup-before-clone on a safe tools dir succeeded"
else
	fail "(C) cleanup-before-clone on a safe tools dir succeeded (rc=$rc out='$out' stale=$( [ -e "$CBC/STALE" ] && echo yes || echo no ))"
fi

# --- FINDING 6: local-path source records repository_kind=local + repository=null ----------
LOCAL_DEST="$WORK/co_local"
out=$(sh "$ACQ" --repository "$REMOTE" --ref v1.0.0 --destination "$LOCAL_DEST" 2>/dev/null) && rc=0 || rc=$?
REC="$LOCAL_DEST/.sentinel-shield-ref"
if [ "$rc" = 0 ] && [ -f "$REC" ]; then pass "(D) local-path source acquired + ref record written"
else fail "(D) local-path source acquired + ref record written (rc=$rc)"; fi
if jq -e . "$REC" >/dev/null 2>&1; then pass "(D) ref record is valid JSON"
else fail "(D) ref record is valid JSON"; fi
if [ "$(jq -r '.repository_kind' "$REC" 2>/dev/null)" = "local" ]; then pass "(D) repository_kind=local"
else fail "(D) repository_kind=local (got '$(jq -r '.repository_kind' "$REC" 2>/dev/null)')"; fi
if [ "$(jq -r '.repository' "$REC" 2>/dev/null)" = "null" ]; then pass "(D) repository=null"
else fail "(D) repository=null (got '$(jq -r '.repository' "$REC" 2>/dev/null)')"; fi
if [ "$(jq -r '.ref_kind' "$REC" 2>/dev/null)" = "tag" ]; then pass "(D) ref_kind=tag preserved"
else fail "(D) ref_kind=tag preserved (got '$(jq -r '.ref_kind' "$REC" 2>/dev/null)')"; fi
# No local/home path string is EVER persisted in the record.
if grep -F "$WORK" "$REC" >/dev/null 2>&1; then fail "(D) local path leaked into ref record"
else pass "(D) no local path string in ref record"; fi
if [ -n "${HOME:-}" ] && grep -F "$HOME" "$REC" >/dev/null 2>&1; then fail "(D) home path leaked into ref record"
else pass "(D) no home path string in ref record"; fi

# --- FINDING 2: http(s) remote with ?query or #fragment is rejected (exit 2) before clone ---
# A guard URL/dest that must remain untouched proves no clone flow ran.
GUARD="$WORK/finding2-dest"
for BADREMOTE in "https://github.com/o/r.git?foo=bar" "https://github.com/o/r.git#frag" \
	"http://github.com/o/r.git?x=1"; do
	out=$(sh "$ACQ" --repository "$BADREMOTE" --ref v1.0.0 --destination "$GUARD" 2>&1) && rc=0 || rc=$?
	if [ "$rc" = 2 ]; then pass "(E) query/fragment remote refused with exit 2: $BADREMOTE"
	else fail "(E) query/fragment remote refused with exit 2: $BADREMOTE (got rc=$rc; out=$out)"; fi
	if [ ! -e "$GUARD" ]; then pass "(E) no clone attempted for: $BADREMOTE"
	else fail "(E) no clone attempted for: $BADREMOTE (dest created)"; fi
done

[ "$FAILS" -eq 0 ] || exit 1
exit 0
