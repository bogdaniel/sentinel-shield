#!/bin/sh
# Sentinel Shield production test — release FINALIZATION / tagging (NN=243).
#
# Exercises scripts/finalize-release-evidence.sh, the two-commit tag decider. Uses a
# HERMETIC throwaway git repo (no network, no shared state) with three commits:
#   c0  engine_commit (CI-validated source)
#   c1  a metadata-ONLY descendant of c0 (touches evidence/releases + CHANGELOG)
#   c2  a descendant of c0 that also changes an executable script (forbidden)
# Proves:
#   * source-tag targets engine_commit and, by default, creates NO tag (dry-run);
#   * source-tag --execute creates exactly that tag at engine_commit;
#   * metadata-tag accepts a metadata-only release_commit and targets it;
#   * metadata-tag REJECTS a release_commit that changes non-metadata (exit 2);
#   * a non-descendant / unknown / unresolvable commit fails closed (exit 1);
#   * an already-existing tag is refused.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
FIN="$ROOT/scripts/finalize-release-evidence.sh"
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command_exists() { command -v "$1" >/dev/null 2>&1; }
command_exists git || { printf 'FAIL: git is required for this test\n' >&2; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssfinal)
trap 'rm -rf "$WORK"' EXIT INT TERM

# --- build a hermetic git repo ----------------------------------------------
GR="$WORK/repo"; mkdir -p "$GR"
git -C "$GR" init -q
git -C "$GR" config user.email t@example.com
git -C "$GR" config user.name tester
git -C "$GR" config commit.gpgsign false
mkdir -p "$GR/scripts" "$GR/evidence/releases"
printf '#!/bin/sh\necho v1\n' > "$GR/scripts/tool.sh"
printf 'engine\n' > "$GR/CHANGELOG.md"
printf '{"v":0}\n' > "$GR/evidence/releases/v2.0.0-beta.2.json"
git -C "$GR" add -A; git -C "$GR" commit -qm c0
C0=$(git -C "$GR" rev-parse HEAD)

# c1: metadata-only descendant (evidence + CHANGELOG only)
printf '{"v":1}\n' > "$GR/evidence/releases/v2.0.0-beta.2.json"
printf 'engine\nnotes\n' > "$GR/CHANGELOG.md"
git -C "$GR" add -A; git -C "$GR" commit -qm c1-metadata
C1=$(git -C "$GR" rev-parse HEAD)

# c2: descendant of c0 that also edits an executable script (forbidden). Branch off c0.
git -C "$GR" checkout -q -b tainted "$C0"
printf '#!/bin/sh\necho v2\n' > "$GR/scripts/tool.sh"
printf '{"v":2}\n' > "$GR/evidence/releases/v2.0.0-beta.2.json"
git -C "$GR" add -A; git -C "$GR" commit -qm c2-code-change
C2=$(git -C "$GR" rev-parse HEAD)
git -C "$GR" checkout -q master 2>/dev/null || git -C "$GR" checkout -q main 2>/dev/null || true

# An orphan commit that is NOT a descendant of c0 (independent root) for the ancestry test.
git -C "$GR" checkout -q --orphan lonely
git -C "$GR" rm -rqf . >/dev/null 2>&1 || true
printf 'x\n' > "$GR/README.md"; git -C "$GR" add -A; git -C "$GR" commit -qm lonely
CX=$(git -C "$GR" rev-parse HEAD)
git -C "$GR" checkout -q master 2>/dev/null || git -C "$GR" checkout -q main 2>/dev/null || true

# --- evidence files ----------------------------------------------------------
mkev() { # mkev <file> <engine> <release-or-empty>
	{
		printf '{ "version":"2.0.0-beta.2","stage":"beta","release_scope":"engine-only","engine_commit":"%s"' "$2"
		[ -n "$3" ] && printf ',"release_commit":"%s"' "$3"
		printf ',"engine_ci":[],"consumer_runs":[],"required_evidence":{"laravel":false,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false} }\n'
	} > "$1"
}

fin() { sh "$FIN" --repo-root "$GR" "$@"; }

# ---------- source-tag: dry-run targets engine_commit, creates NO tag --------
mkev "$WORK/ev-src.json" "$C0" ""
OUT="$WORK/o.txt"; RC=0
fin --evidence "$WORK/ev-src.json" --mode source-tag --tag v-src >"$OUT" 2>/dev/null || RC=$?
if [ "$RC" = 0 ] && grep -q "TAG TARGET: $C0" "$OUT"; then
	pass "source-tag: dry-run prints engine_commit as the exact target"
else
	fail "source-tag: expected target $C0 (rc=$RC)"
fi
if ! git -C "$GR" rev-parse -q --verify refs/tags/v-src >/dev/null 2>&1; then
	pass "source-tag: dry-run created NO tag (safe by default)"
else
	fail "source-tag: dry-run created a tag without --execute"
fi

# ---------- source-tag --execute: creates the tag at engine_commit -----------
RC=0
fin --evidence "$WORK/ev-src.json" --mode source-tag --tag v-src --execute >/dev/null 2>&1 || RC=$?
if [ "$RC" = 0 ] && [ "$(git -C "$GR" rev-parse -q refs/tags/v-src^{commit} 2>/dev/null)" = "$C0" ]; then
	pass "source-tag --execute: created tag at engine_commit"
else
	fail "source-tag --execute: tag not created at engine_commit (rc=$RC)"
fi

# ---------- source-tag: existing tag is refused ------------------------------
RC=0
fin --evidence "$WORK/ev-src.json" --mode source-tag --tag v-src >/dev/null 2>&1 || RC=$?
if [ "$RC" = 2 ]; then pass "source-tag: an already-existing tag is refused (exit 2)"; else fail "source-tag: expected refusal exit 2, got $RC"; fi

# ---------- metadata-tag: metadata-only release_commit accepted --------------
mkev "$WORK/ev-meta.json" "$C0" "$C1"
OUT="$WORK/om.txt"; RC=0
fin --evidence "$WORK/ev-meta.json" --mode metadata-tag --tag v-meta >"$OUT" 2>/dev/null || RC=$?
if [ "$RC" = 0 ] && grep -q "TAG TARGET: $C1" "$OUT"; then
	pass "metadata-tag: a metadata-only descendant is accepted and targeted"
else
	fail "metadata-tag: expected accept with target $C1 (rc=$RC)"
fi
if ! git -C "$GR" rev-parse -q --verify refs/tags/v-meta >/dev/null 2>&1; then
	pass "metadata-tag: dry-run created NO tag"
else
	fail "metadata-tag: dry-run created a tag without --execute"
fi

# ---------- metadata-tag --execute: creates the tag at release_commit --------
RC=0
fin --evidence "$WORK/ev-meta.json" --mode metadata-tag --tag v-meta --execute >/dev/null 2>&1 || RC=$?
if [ "$RC" = 0 ] && [ "$(git -C "$GR" rev-parse -q refs/tags/v-meta^{commit} 2>/dev/null)" = "$C1" ]; then
	pass "metadata-tag --execute: created tag at release_commit"
else
	fail "metadata-tag --execute: tag not created at release_commit (rc=$RC)"
fi

# ---------- metadata-tag: non-metadata (script) change REJECTED --------------
mkev "$WORK/ev-bad.json" "$C0" "$C2"
RC=0
fin --evidence "$WORK/ev-bad.json" --mode metadata-tag --tag v-bad >/dev/null 2>&1 || RC=$?
if [ "$RC" = 2 ]; then
	pass "metadata-tag: a release_commit that changes an executable is rejected (exit 2)"
else
	fail "metadata-tag: expected VIOLATION exit 2, got $RC"
fi
if ! git -C "$GR" rev-parse -q --verify refs/tags/v-bad >/dev/null 2>&1; then
	pass "metadata-tag: no tag created for a rejected release_commit"
else
	fail "metadata-tag: a tag was created despite a violation"
fi

# ---------- metadata-tag: non-descendant release_commit fails closed ---------
mkev "$WORK/ev-nd.json" "$C0" "$CX"
RC=0
fin --evidence "$WORK/ev-nd.json" --mode metadata-tag --tag v-nd >/dev/null 2>&1 || RC=$?
if [ "$RC" = 1 ]; then pass "metadata-tag: a non-descendant release_commit fails closed (exit 1)"; else fail "metadata-tag: expected exit 1, got $RC"; fi

# ---------- metadata-tag: missing release_commit fails closed ----------------
mkev "$WORK/ev-nr.json" "$C0" ""
RC=0
fin --evidence "$WORK/ev-nr.json" --mode metadata-tag --tag v-nr >/dev/null 2>&1 || RC=$?
if [ "$RC" = 1 ]; then pass "metadata-tag: absent release_commit fails closed (exit 1)"; else fail "metadata-tag: expected exit 1, got $RC"; fi

# ---------- source-tag: unknown engine_commit fails closed -------------------
mkev "$WORK/ev-unk.json" "unknown" ""
# hand-craft: engine_commit=unknown is only valid with empty evidence; write directly.
cat > "$WORK/ev-unk.json" <<EOF
{ "version":"2.0.0-beta.2","stage":"beta","release_scope":"engine-only","engine_commit":"unknown","engine_ci":[],"consumer_runs":[],"required_evidence":{"laravel":false,"symfony":false,"php_library":false,"node_react":false,"combined_profile":false,"bootstrap_apply":false,"rollback_npm":false,"rollback_pnpm":false,"rollback_yarn":false} }
EOF
RC=0
fin --evidence "$WORK/ev-unk.json" --mode source-tag --tag v-unk >/dev/null 2>&1 || RC=$?
if [ "$RC" = 1 ]; then pass "source-tag: unknown engine_commit fails closed (exit 1)"; else fail "source-tag: expected exit 1, got $RC"; fi

# ---------- invocation: bad mode => exit 2 -----------------------------------
RC=0
fin --evidence "$WORK/ev-src.json" --mode bogus --tag v-x >/dev/null 2>&1 || RC=$?
if [ "$RC" = 2 ]; then pass "invocation: an invalid --mode is rejected (exit 2)"; else fail "invocation: expected exit 2, got $RC"; fi

if [ "$FAILS" -gt 0 ]; then printf '\n%d assertion(s) failed\n' "$FAILS" >&2; exit 1; fi
exit 0
