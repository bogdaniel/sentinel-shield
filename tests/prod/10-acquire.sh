#!/bin/sh
# tests/prod/10-acquire.sh — scripts/acquire-sentinel-shield.sh contract.
# Self-contained, no network: builds a LOCAL bare repo (with a tag + a branch) as the
# 'remote'. Asserts: (a) a moving-branch ref is rejected (exit 2), (b) a full 40-hex SHA
# ref is accepted, (c) --help lists every flag, (d) no token ever appears in output.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ACQ="$ROOT/scripts/acquire-sentinel-shield.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssacq)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

# A bogus token planted in the environment; it must NEVER surface in any output.
TOKEN="ghp_SUPERSECRETTOKEN0xDEADBEEF"
export GITHUB_TOKEN="$TOKEN"
export GH_TOKEN="$TOKEN"

# --- build a throwaway 'remote': bare repo with main + an immutable tag --------
REMOTE="$WORK/remote.git"
SEED="$WORK/seed"
git init -q --bare "$REMOTE"
git init -q "$SEED"
git -C "$SEED" -c user.email=t@t.t -c user.name=t commit -q --allow-empty -m init
git -C "$SEED" branch -M main
git -C "$SEED" tag v1.0.0
git -C "$SEED" remote add origin "$REMOTE"
git -C "$SEED" push -q origin main --tags
SHA=$(git -C "$SEED" rev-parse HEAD)

# (a) moving-branch ref is rejected with exit 2.
out=$(sh "$ACQ" --repository "$REMOTE" --ref main --destination "$WORK/co_a" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 2 ]; then pass "(a) moving-branch ref rejected with exit 2"
else fail "(a) moving-branch ref rejected with exit 2 (got rc=$rc)"; fi
case "$out" in *moving*|*refus*|*immutable*) pass "(a) rejection message explains immutability" ;;
	*) fail "(a) rejection message explains immutability (got: $out)" ;; esac
[ -e "$WORK/co_a" ] && fail "(a) destination must not be created on rejection" || pass "(a) no destination created on rejection"

# (b) a full 40-hex SHA ref is accepted (shape-valid) and checks out that commit.
out_b=$(sh "$ACQ" --repository "$REMOTE" --ref "$SHA" --destination "$WORK/co_b" --verify 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" = 0 ]; then pass "(b) full-SHA ref accepted (exit 0)"
else fail "(b) full-SHA ref accepted (got rc=$rc)"; fi
if [ "$out_b" = "$SHA" ]; then pass "(b) resolved commit printed equals the requested SHA"
else fail "(b) resolved commit printed equals the requested SHA (got '$out_b')"; fi
if [ -f "$WORK/co_b/.sentinel-shield-ref" ]; then pass "(b) ref record written"
else fail "(b) ref record written"; fi

# A short / non-40-hex hex string is NOT a SHA and (not being a tag) is rejected exit 2.
out=$(sh "$ACQ" --repository "$REMOTE" --ref "abc123" --destination "$WORK/co_short" 2>&1) && rc=0 || rc=$?
if [ "$rc" = 2 ]; then pass "(b') short/non-immutable ref rejected with exit 2"
else fail "(b') short/non-immutable ref rejected with exit 2 (got rc=$rc)"; fi

# A valid tag is accepted (exit 0) — confirms tags are not over-rejected.
out_t=$(sh "$ACQ" --repository "$REMOTE" --ref v1.0.0 --destination "$WORK/co_tag" 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$out_t" = "$SHA" ]; then pass "(b'') immutable tag accepted -> resolved commit"
else fail "(b'') immutable tag accepted -> resolved commit (rc=$rc out='$out_t')"; fi

# (c) --help / usage lists every flag.
help=$(sh "$ACQ" --help 2>&1)
miss=""
for flag in --repository --ref --destination --transport --verify --reuse-existing --cleanup; do
	case "$help" in *"$flag"*) ;; *) miss="$miss $flag" ;; esac
done
if [ -z "$miss" ]; then pass "(c) --help lists all flags"
else fail "(c) --help missing flags:$miss"; fi

# (d) no token ever appears in any output (rejection, success, help, ref record).
all_out=$(printf '%s\n%s\n%s\n%s\n%s\n' "$out" "$out_b" "$out_t" "$help" "$(cat "$WORK/co_b/.sentinel-shield-ref" 2>/dev/null || true)")
case "$all_out" in
	*"$TOKEN"*) fail "(d) token leaked into output" ;;
	*) pass "(d) no token in any output" ;;
esac

# --reuse-existing: a second call against a matching checkout reuses it (exit 0).
out_r=$(sh "$ACQ" --repository "$REMOTE" --ref v1.0.0 --destination "$WORK/co_tag" --reuse-existing 2>/dev/null) && rc=0 || rc=$?
if [ "$rc" = 0 ] && [ "$out_r" = "$SHA" ]; then pass "(e) --reuse-existing reuses a matching checkout"
else fail "(e) --reuse-existing reuses a matching checkout (rc=$rc out='$out_r')"; fi

# --cleanup removes the destination.
sh "$ACQ" --destination "$WORK/co_tag" --cleanup >/dev/null 2>&1 || true
[ -e "$WORK/co_tag" ] && fail "(f) --cleanup removes the destination" || pass "(f) --cleanup removes the destination"

[ "$FAILS" -eq 0 ] || exit 1
exit 0
