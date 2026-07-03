#!/bin/sh
# Sentinel Shield production test — scanner provenance + checksum + health (NN=221).
#
# Exercises the v2 scanner-hardening surface:
#   (A) checksum verification / reject-on-mismatch in scripts/lib/isolated-tools.sh
#       (isolated_tool_verify_checksum, isolated_tool_fetch_verified).
#   (B) scripts/audits/tool-provenance-audit.sh: records tool acquisition provenance
#       and FAILS CLOSED on a checksum mismatch or an unverifiable (checksum-less)
#       download; conforms to schemas/tool-provenance-audit.schema.json.
#   (C) the OSV and Grype collectors surface a `health` state
#       (ok | findings | no-targets | scanner-error | parser-error) and a `provenance`
#       object so an EMPTY report is distinguishable from a scanner that DID NOT RUN.
#
# A skip is not a pass: every assertion checks a specific value / exit code.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
AUDIT="$ROOT/scripts/audits/tool-provenance-audit.sh"
OSV="$ROOT/scripts/collectors/osv-scanner.sh"
GRYPE="$ROOT/scripts/collectors/grype.sh"
SCHEMA="$ROOT/schemas/tool-provenance-audit.schema.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required for this suite" >&2; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

# A helper that sources the libs then runs a library function passed as argv, so a
# function that calls die() exits THIS subshell (not the whole test).
HELPER="$WORK/lib-run.sh"
cat > "$HELPER" <<EOF
#!/bin/sh
set -eu
. "$ROOT/scripts/lib/sentinel-shield-common.sh"
. "$ROOT/scripts/lib/isolated-tools.sh"
"\$@"
EOF

# --- (A) checksum verify + fetch reject-on-mismatch --------------------------
ART="$WORK/artifact.bin"
printf 'sentinel-shield trusted payload\n' > "$ART"
REALSHA=$(sh "$HELPER" isolated_tool_sha256 "$ART" 2>/dev/null || true)
WRONGSHA="0000000000000000000000000000000000000000000000000000000000000000"

if [ -z "$REALSHA" ]; then
	fail "isolated_tool_sha256 produced no digest (no hasher available?)"
else
	pass "isolated_tool_sha256 computed a digest"
	if sh "$HELPER" isolated_tool_verify_checksum "$ART" "$REALSHA" >/dev/null 2>&1; then
		pass "verify_checksum accepts a matching digest"
	else
		fail "verify_checksum rejected a matching digest"
	fi
	if sh "$HELPER" isolated_tool_verify_checksum "$ART" "$WRONGSHA" >/dev/null 2>&1; then
		fail "verify_checksum accepted a MISMATCHED digest (should reject)"
	else
		pass "verify_checksum rejects a mismatched digest"
	fi
fi

# fetch_verified over a file:// URL (offline). Requires curl or wget; else skip cleanly.
if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
	DEST_BAD="$WORK/dl-bad.bin"
	if sh "$HELPER" isolated_tool_fetch_verified "file://$ART" "$DEST_BAD" "$WRONGSHA" >/dev/null 2>&1; then
		fail "fetch_verified accepted a mismatched download (should reject)"
	else
		[ ! -e "$DEST_BAD" ] \
			&& pass "fetch_verified rejects mismatch AND removes the forged file" \
			|| fail "fetch_verified rejected but left the forged file at $DEST_BAD"
	fi
	DEST_OK="$WORK/dl-ok.bin"
	if sh "$HELPER" isolated_tool_fetch_verified "file://$ART" "$DEST_OK" "$REALSHA" >/dev/null 2>&1; then
		[ -f "$DEST_OK" ] \
			&& pass "fetch_verified accepts a matching download and keeps the file" \
			|| fail "fetch_verified reported success but no file at $DEST_OK"
	else
		fail "fetch_verified rejected a matching download"
	fi
else
	printf 'INFO: no curl/wget; skipping fetch_verified download path (verify path still covered)\n'
fi

# --- (B) tool-provenance-audit: reject checksum mismatch / missing checksum ---
[ -x "$AUDIT" ] || fail "provenance audit not executable: $AUDIT"
[ -f "$SCHEMA" ] && jq -e . "$SCHEMA" >/dev/null 2>&1 \
	&& pass "provenance audit schema is present and jq-valid" \
	|| fail "provenance audit schema missing or not jq-valid: $SCHEMA"

FOOBIN="$WORK/foo-bin"
printf '#!/bin/sh\necho "foo 1.2.3"\n' > "$FOOBIN"
chmod +x "$FOOBIN"
FOOSHA=$(sh "$HELPER" isolated_tool_sha256 "$FOOBIN" 2>/dev/null || true)

# B1: mismatch -> fail closed with a checksum-mismatch violation.
O1="$WORK/prov-mismatch.json"
if SENTINEL_SHIELD_FOO_BINARY="$FOOBIN" SENTINEL_SHIELD_FOO_SHA256="$WRONGSHA" \
	sh "$AUDIT" --output "$O1" foo >/dev/null 2>&1; then
	fail "provenance audit exited 0 on a checksum mismatch (should fail closed)"
else
	if [ "$(jq -r '.status' "$O1" 2>/dev/null)" = "fail" ] \
		&& [ "$(jq -r '[.violations[].check]|unique|join(",")' "$O1")" = "checksum-mismatch" ] \
		&& [ "$(jq -r '.records[0].source' "$O1")" = "local-binary" ] \
		&& [ "$(jq -r '.records[0].binary.checksum_verified' "$O1")" = "false" ]; then
		pass "provenance audit fails closed on checksum-mismatch (record marks verified=false)"
	else
		fail "provenance audit mismatch report malformed: $(jq -c '{status,violations,r:.records[0].binary}' "$O1" 2>/dev/null || echo '?')"
	fi
fi

# B2: correct checksum -> pass, verified=true.
O2="$WORK/prov-ok.json"
if [ -n "$FOOSHA" ] && SENTINEL_SHIELD_FOO_BINARY="$FOOBIN" SENTINEL_SHIELD_FOO_SHA256="$FOOSHA" \
	sh "$AUDIT" --output "$O2" foo >/dev/null 2>&1; then
	[ "$(jq -r '.status' "$O2")" = "pass" ] \
		&& [ "$(jq -r '.records[0].binary.checksum_verified' "$O2")" = "true" ] \
		&& pass "provenance audit passes with a matching checksum (verified=true)" \
		|| fail "provenance audit ok-case report malformed: $(jq -c '{status,r:.records[0].binary}' "$O2")"
else
	fail "provenance audit exited non-zero with a matching checksum"
fi

# B3: download URL with NO checksum -> missing-checksum violation (fail closed).
O3="$WORK/prov-missing.json"
if SENTINEL_SHIELD_BAR_URL="file://$ART" sh "$AUDIT" --output "$O3" bar >/dev/null 2>&1; then
	fail "provenance audit exited 0 for a checksum-less download (should fail closed)"
else
	[ "$(jq -r '[.violations[].check]|unique|join(",")' "$O3")" = "missing-checksum" ] \
		&& [ "$(jq -r '.records[0].source' "$O3")" = "download" ] \
		&& pass "provenance audit fails closed on a checksum-less download (missing-checksum)" \
		|| fail "provenance audit missing-checksum report malformed: $(jq -c '{v:.violations,s:.records[0].source}' "$O3")"
fi

# B4: unresolved tool -> recorded, no violation.
O4="$WORK/prov-unresolved.json"
if sh "$AUDIT" --output "$O4" nonexistent-scanner-xyz >/dev/null 2>&1; then
	[ "$(jq -r '.status' "$O4")" = "pass" ] \
		&& [ "$(jq -r '.records[0].source' "$O4")" = "unresolved" ] \
		&& [ "$(jq -r '.records[0].resolved' "$O4")" = "false" ] \
		&& pass "provenance audit records an unresolved tool without failing" \
		|| fail "provenance audit unresolved-case malformed: $(jq -c '{status,r:.records[0]}' "$O4")"
else
	fail "provenance audit failed on an unresolved (advisory) tool"
fi

# --- (C) collector health states + provenance --------------------------------
# run_collector <collector> <input-json-content|__MISSING__> <extra jq assert> <label> \
#               <expected-status> <expected-health>  [provenance-sidecar-content]
osv_case() {
	_name=$1; _content=$2; _xstatus=$3; _xhealth=$4; _sidecar=${5:-}
	_in="$WORK/osv-$_name.json"
	if [ "$_content" = "__MISSING__" ]; then
		: # do not create the file
	else
		printf '%s' "$_content" > "$_in"
	fi
	if [ -n "$_sidecar" ]; then printf '%s' "$_sidecar" > "$WORK/osv-$_name.provenance.json"; fi
	_rc=0
	_out=$(sh "$OSV" --input "$_in" --tool-name osv_scanner 2>/dev/null) || _rc=$?
	# fail-closed contract: an unparseable report must exit 2; all other health states exit 0
	if [ "$_xhealth" = parser-error ]; then _xrc=2; else _xrc=0; fi
	if [ "$_rc" = "$_xrc" ]; then pass "osv $_name -> exit $_rc (fail-closed contract)"; else fail "osv $_name -> exit $_rc, wanted $_xrc"; fi
	if [ -z "$_out" ]; then fail "osv collector produced no report for $_name"; return; fi
	_gs=$(printf '%s' "$_out" | jq -r '.status')
	_gh=$(printf '%s' "$_out" | jq -r '.tool_report.health')
	if [ "$_gs" = "$_xstatus" ] && [ "$_gh" = "$_xhealth" ]; then
		pass "osv $_name -> status=$_gs health=$_gh"
	else
		fail "osv $_name -> got status=$_gs health=$_gh, wanted status=$_xstatus health=$_xhealth"
	fi
	LAST_OUT=$_out
}

osv_case findings   '{"results":[{"packages":[{"vulnerabilities":[{"id":"CVE-1"}]}]}]}' fail            findings
osv_case notargets  '{"results":[]}'                                                    pass            no-targets
osv_case clean      '{"results":[{"packages":[{"vulnerabilities":[]}]}]}'               pass            ok
osv_case missing    '__MISSING__'                                                       unavailable     scanner-error
osv_case badjson    'this is not json'                                                  execution-error parser-error

# provenance from a sidecar: proves 'empty report' is distinguishable from 'did not run'.
osv_case withprov   '{"results":[]}'  pass  no-targets \
	'{"tool":"osv-scanner","source":"local-binary","version":"9.9.9","vulnerability_db":{"timestamp":"2025-05-05T00:00:00Z"},"image":null,"binary":null,"recorded_at":"2025-05-05T00:00:00Z"}'
if [ "$(printf '%s' "$LAST_OUT" | jq -r '.tool_report.provenance.scanner_version')" = "9.9.9" ] \
	&& [ "$(printf '%s' "$LAST_OUT" | jq -r '.tool_report.provenance.vulnerability_db.timestamp')" = "2025-05-05T00:00:00Z" ]; then
	pass "osv collector surfaces scanner_version + db timestamp from the provenance sidecar"
else
	fail "osv collector did not surface sidecar provenance: $(printf '%s' "$LAST_OUT" | jq -c '.tool_report.provenance')"
fi

# Grype: findings + ok, with native-descriptor provenance (version + db.built).
GIN_F="$WORK/grype-findings.json"
printf '%s' '{"matches":[{"vulnerability":{"severity":"Critical"}}],"descriptor":{"name":"grype","version":"0.74.0","db":{"built":"2024-01-01T00:00:00Z"}}}' > "$GIN_F"
GO=$(sh "$GRYPE" --input "$GIN_F" --tool-name grype 2>/dev/null) || fail "grype collector crashed (findings)"
if [ "$(printf '%s' "$GO" | jq -r '.status')" = "fail" ] \
	&& [ "$(printf '%s' "$GO" | jq -r '.tool_report.health')" = "findings" ] \
	&& [ "$(printf '%s' "$GO" | jq -r '.tool_report.critical')" = "1" ]; then
	pass "grype findings -> status=fail health=findings critical=1"
else
	fail "grype findings malformed: $(printf '%s' "$GO" | jq -c '{status,tr:.tool_report}')"
fi

GIN_OK="$WORK/grype-ok.json"
printf '%s' '{"matches":[],"descriptor":{"name":"grype","version":"0.74.0","db":{"built":"2024-01-01T00:00:00Z"}}}' > "$GIN_OK"
GO2=$(sh "$GRYPE" --input "$GIN_OK" --tool-name grype 2>/dev/null) || fail "grype collector crashed (ok)"
if [ "$(printf '%s' "$GO2" | jq -r '.status')" = "pass" ] \
	&& [ "$(printf '%s' "$GO2" | jq -r '.tool_report.health')" = "ok" ] \
	&& [ "$(printf '%s' "$GO2" | jq -r '.tool_report.provenance.scanner_version')" = "0.74.0" ] \
	&& [ "$(printf '%s' "$GO2" | jq -r '.tool_report.provenance.vulnerability_db.timestamp')" = "2024-01-01T00:00:00Z" ]; then
	pass "grype ok -> health=ok with scanner_version + db timestamp from native descriptor"
else
	fail "grype ok malformed: $(printf '%s' "$GO2" | jq -c '{status,h:.tool_report.health,p:.tool_report.provenance}')"
fi

if [ "$FAILS" -gt 0 ]; then
	printf '\n%d assertion(s) failed\n' "$FAILS" >&2
	exit 1
fi
exit 0
