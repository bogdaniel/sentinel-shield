#!/bin/sh
# Sentinel Shield production test — release-artifact VERIFICATION (NN=241).
#
# Exercises scripts/verify-release-artifacts.sh + scripts/lib/archive-safety.sh. The
# GitHub API is MOCKED through a stubbed GH_BIN (network-free): the stub serves an
# artifact list and, for a *.../zip request, streams a fixture archive. Proves:
#   * a clean artifact verifies (ownership, expiration, integrity, inventory, digests,
#     embedded commit);
#   * every malicious fixture (path traversal, absolute path, symlink escape, duplicate
#     path, oversize zip bomb) is REJECTED with its precise reason;
#   * ownership mismatch and expiration are rejected;
#   * --require-embedded-commit and --min-files are enforced.
# Malicious fixtures live under tests/fixtures/archives/ (see that README); the clean
# fixture is built at runtime with `zip` so the suite needs no python3.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VERIFY="$ROOT/scripts/verify-release-artifacts.sh"
FXDIR="$ROOT/tests/fixtures/archives"
FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command_exists() { command -v "$1" >/dev/null 2>&1; }
for t in unzip zipinfo jq zip; do
	command_exists "$t" || { printf 'FAIL: required tool missing: %s\n' "$t" >&2; exit 1; }
done

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssartver)
trap 'rm -rf "$WORK"' EXIT INT TERM

A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa   # engine commit expected embedded

# Build a CLEAN fixture at runtime (embeds the commit; two files) with zip.
mkdir -p "$WORK/clean/reports"
printf 'sentinel-shield build at %s\n' "$A" > "$WORK/clean/reports/summary.txt"
printf '{"sbom":true}\n' > "$WORK/clean/reports/sbom.json"
( cd "$WORK/clean" && zip -q -r "$WORK/clean.zip" reports )

# gh stub. Defaults assigned separately (brace-in-default caveat, see 92/240).
BIN="$WORK/gh"
cat > "$BIN" <<'EOF'
#!/bin/sh
p="$2"
list="${MOCK_LIST:-}"; [ -n "$list" ] || list='{"artifacts":[]}'
case "$p" in
  */actions/runs/*/artifacts) printf '%s\n' "$list" ;;
  */actions/artifacts/*/zip)  [ -n "${MOCK_ZIP:-}" ] && cat "$MOCK_ZIP" || exit 1 ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$BIN"

# A standard single-artifact list owned by run 5001, unexpired.
mklist() { # mklist [id] [name] [expired] [owner-run]
  printf '{"artifacts":[{"id":%s,"name":"%s","expired":%s,"size_in_bytes":123,"workflow_run":{"id":%s}}]}' \
    "${1:-42}" "${2:-reports}" "${3:-false}" "${4:-5001}"
}

# run_verify <report-out> <list-json> <zip> [extra-args...]
run_verify() {
  _out="$1"; _list="$2"; _zip="$3"; shift 3
  GH_BIN="$BIN" MOCK_LIST="$_list" MOCK_ZIP="$_zip" \
    sh "$VERIFY" --repo org/engine --run 5001 --commit "$A" --output "$_out" "$@"
}

# reject_case <fixture> <reason-substr> <desc> — assert exit 1 + reason present.
reject_case() {
  _fx="$1"; _reason="$2"; _desc="$3"
  _out="$WORK/r.json"; _rc=0
  run_verify "$_out" "$(mklist)" "$FXDIR/$_fx" >/dev/null 2>&1 || _rc=$?
  if [ "$_rc" != 1 ]; then fail "$_desc (expected exit 1, got $_rc)"; return; fi
  if [ "$(jq -r '.status' "$_out")" != fail ]; then fail "$_desc (report status not 'fail')"; return; fi
  if [ "$(jq -r '.artifacts[0].verified' "$_out")" != false ]; then fail "$_desc (artifact marked verified)"; return; fi
  if jq -e --arg r "$_reason" '.artifacts[0].reasons | any(startswith($r))' "$_out" >/dev/null 2>&1; then
    pass "$_desc"
  else
    fail "$_desc (reason '$_reason' not present -> $(jq -c '.artifacts[0].reasons' "$_out"))"
  fi
}

# ---------- CLEAN: fully verified ----------
OUT="$WORK/clean-report.json"; RC=0
run_verify "$OUT" "$(mklist)" "$WORK/clean.zip" >/dev/null 2>&1 || RC=$?
if [ "$RC" = 0 ] && [ "$(jq -r '.status' "$OUT")" = pass ]; then
  pass "clean: verifier exits 0 and status=pass"
else
  fail "clean: expected pass (rc=$RC, status=$(jq -r '.status' "$OUT" 2>/dev/null))"
fi
if [ "$(jq -r '.artifacts[0].verified' "$OUT")" = true ] \
   && [ "$(jq -r '.artifacts[0].ownership_ok' "$OUT")" = true ] \
   && [ "$(jq -r '.artifacts[0].archive_safe' "$OUT")" = true ] \
   && [ "$(jq -r '.artifacts[0].file_count' "$OUT")" = 2 ] \
   && [ "$(jq -r '.artifacts[0].embedded_commit_found' "$OUT")" = true ]; then
  pass "clean: record shows ownership/integrity/inventory/embedded-commit all OK"
else
  fail "clean: record incomplete -> $(jq -c '.artifacts[0]' "$OUT")"
fi
# Every contained file carries a SHA-256, and the artifact carries a zip SHA-256.
if jq -e '(.artifacts[0].sha256 | test("^[0-9a-f]{64}$"))
          and (.artifacts[0].files | length == 2)
          and (.artifacts[0].files | all(.sha256 | test("^[0-9a-f]{64}$")))' "$OUT" >/dev/null 2>&1; then
  pass "clean: artifact and per-file SHA-256 digests are present and well-formed"
else
  fail "clean: digests missing/malformed -> $(jq -c '.artifacts[0]|{sha256,files}' "$OUT")"
fi

# ---------- MALICIOUS: each fixture rejected on its own reason ----------
reject_case traversal.zip      path-traversal  "traversal: '..' entry rejected"
reject_case absolute.zip       absolute-path   "absolute: '/'-anchored entry rejected"
reject_case symlink-escape.zip symlink         "symlink-escape: symlink entry rejected"
reject_case duplicate-path.zip duplicate-path  "duplicate-path: repeated entry rejected"

# oversize needs a small cap so the ~1 MiB bomb trips it.
OUT="$WORK/big.json"; RC=0
run_verify "$OUT" "$(mklist)" "$FXDIR/oversize.zip" --max-bytes 500000 >/dev/null 2>&1 || RC=$?
if [ "$RC" = 1 ] && jq -e '.artifacts[0].reasons | any(startswith("oversize"))' "$OUT" >/dev/null 2>&1; then
  pass "oversize: zip-bomb archive rejected (uncompressed size cap)"
else
  fail "oversize: expected exit 1 with 'oversize' reason (rc=$RC -> $(jq -c '.artifacts[0].reasons' "$OUT" 2>/dev/null))"
fi

# ---------- OWNERSHIP: artifact belongs to a different run ----------
OUT="$WORK/own.json"; RC=0
run_verify "$OUT" "$(mklist 42 reports false 9999)" "$WORK/clean.zip" >/dev/null 2>&1 || RC=$?
if [ "$RC" = 1 ] && jq -e '.artifacts[0].reasons | any(startswith("run-ownership-mismatch"))' "$OUT" >/dev/null 2>&1; then
  pass "ownership: artifact owned by another run is rejected"
else
  fail "ownership: expected ownership-mismatch rejection (rc=$RC)"
fi

# ---------- EXPIRATION: expired artifact ----------
OUT="$WORK/exp.json"; RC=0
run_verify "$OUT" "$(mklist 42 reports true 5001)" "$WORK/clean.zip" >/dev/null 2>&1 || RC=$?
if [ "$RC" = 1 ] && jq -e '.artifacts[0].reasons | index("expired")' "$OUT" >/dev/null 2>&1; then
  pass "expiration: an expired artifact is rejected"
else
  fail "expiration: expected 'expired' rejection (rc=$RC)"
fi

# ---------- REQUIRE-EMBEDDED-COMMIT: clean zip but wrong expected commit ----------
OUT="$WORK/emb.json"; RC=0
GH_BIN="$BIN" MOCK_LIST="$(mklist)" MOCK_ZIP="$WORK/clean.zip" \
  sh "$VERIFY" --repo org/engine --run 5001 \
    --commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --require-embedded-commit --output "$OUT" >/dev/null 2>&1 || RC=$?
if [ "$RC" = 1 ] && jq -e '.artifacts[0].reasons | index("embedded-commit-missing")' "$OUT" >/dev/null 2>&1; then
  pass "embedded-commit: a required commit not present in the archive is rejected"
else
  fail "embedded-commit: expected 'embedded-commit-missing' (rc=$RC)"
fi

# ---------- MIN-FILES: require more files than the archive contains ----------
OUT="$WORK/minf.json"; RC=0
run_verify "$OUT" "$(mklist)" "$WORK/clean.zip" --min-files 5 >/dev/null 2>&1 || RC=$?
if [ "$RC" = 1 ] && jq -e '.artifacts[0].reasons | any(startswith("too-few-files"))' "$OUT" >/dev/null 2>&1; then
  pass "min-files: an archive below the required inventory count is rejected"
else
  fail "min-files: expected 'too-few-files' rejection (rc=$RC)"
fi

if [ "$FAILS" -gt 0 ]; then printf '\n%d assertion(s) failed\n' "$FAILS" >&2; exit 1; fi
exit 0
