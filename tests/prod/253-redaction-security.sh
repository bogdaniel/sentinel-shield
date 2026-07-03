#!/bin/sh
# tests/prod/253-redaction-security.sh — SECRET-HANDLING / REDACTION enforcement.
#
# Proves scripts/lib/redaction.sh removes credentials and repo-local identity from untrusted text
# BEFORE it is displayed or persisted, treats secret VALUES as literals (never as regex), bounds
# untrusted input, isolates external-tool environments, and FAILS CLOSED when a produced artifact
# carries a confirmed secret. The machine-readable redaction report carries counts + categories
# ONLY, never a value.
#
# Required injection cases (1)-(12) are labelled inline; each asserts BOTH removal (NEGATIVE) and a
# legitimate positive/failure-injection control. Self-contained, NETWORK-FREE. jq is required.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB_COMMON="$ROOT/scripts/lib/sentinel-shield-common.sh"
LIB_RD="$ROOT/scripts/lib/redaction.sh"
REPORT_SCHEMA="$ROOT/schemas/redaction-report.schema.json"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null 2>&1 || { printf 'FAIL: jq is required for this test\n'; exit 1; }

WORK=$(mktemp -d 2>/dev/null || mktemp -d -t ssrdt)
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT INT TERM

# Source the library into THIS shell for in-process assertions.
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$LIB_COMMON"
# shellcheck source=scripts/lib/redaction.sh
. "$LIB_RD"

# Stable, obviously-fake tokens (pattern-shaped, never a real credential).
GH='ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
AWS='AKIAIOSFODNN7EXAMPLE'

# ============================================================================
# Schema present + jq-valid, and the code's confirmed-secret category catalog MATCHES the schema
# enum exactly (structural, jq-based — no ajv). Drift between rd_scan_categories and the schema
# fails here.
# ============================================================================
jq -e . "$REPORT_SCHEMA" >/dev/null 2>&1 && pass "redaction-report schema is jq-valid" || fail "redaction-report schema jq-valid"
CODE_CATS=$(rd_scan_category_names | LC_ALL=C sort)
SCHEMA_CATS=$(jq -r '.properties.categories.items.enum[]' "$REPORT_SCHEMA" | LC_ALL=C sort)
[ "$CODE_CATS" = "$SCHEMA_CATS" ] \
	&& pass "rd_scan_categories matches the schema enum exactly (no drift)" \
	|| fail "rd_scan_categories vs schema enum drift"

# A rd_report_json instance conforms structurally to the CLOSED report schema.
REP=$(rd_report_json 3 1 2 '{"aws-access-key":2}' true)
if printf '%s' "$REP" | jq -e '
	(.schema == "redaction-report") and
	(.sensitive_values | has("registered") and has("capped") and has("cap_count") and has("cap_bytes")) and
	(.categories | type == "array" and (length > 0)) and
	(.scan.total_findings == 2) and (.scan.by_category["aws-access-key"] == 2) and
	(.confirmed_secret_present == true)
' >/dev/null 2>&1; then
	pass "a rd_report_json instance conforms to the redaction-report schema"
else
	fail "rd_report_json instance conforms"
fi

# ============================================================================
# (1) TOKEN IN THE ENVIRONMENT — rd_run_isolated drops a non-allowlisted secret var; and a
#     registered env token is redacted from a diagnostic line.
# ============================================================================
OUT=$(SS_TEST_TOKEN="$GH" rd_run_isolated -- sh -c 'printf "%s" "${SS_TEST_TOKEN:-CLEAN}"') || OUT="ERR"
[ "$OUT" = "CLEAN" ] \
	&& pass "(1) a non-allowlisted secret env var is NOT inherited by an isolated child" \
	|| fail "(1) env isolation dropped the secret (got '$OUT')"
OUT2=$(SS_TEST_TOKEN="allowed-value" rd_run_isolated SS_TEST_TOKEN -- sh -c 'printf "%s" "${SS_TEST_TOKEN:-CLEAN}"') || OUT2="ERR"
[ "$OUT2" = "allowed-value" ] \
	&& pass "(1+) an explicitly allowlisted env var IS passed through" \
	|| fail "(1+) allowlisted env var passthrough (got '$OUT2')"
rd_secret_reset
if ! rd_secret_add "$GH" >/dev/null 2>&1; then fail "(1-env) could not register the env token"; fi
RED=$(printf 'env dump line: GITHUB_TOKEN=%s trailing\n' "$GH" | rd_redact_stream)
case "$RED" in *"$GH"*) fail "(1-env) registered env token leaked after redaction" ;; *) pass "(1-env) a registered env token is redacted from a diagnostic line" ;; esac

# ============================================================================
# (2) TOKEN IN COMMAND OUTPUT — pattern-based (NO registration) GitHub-token masking.
# ============================================================================
rd_secret_reset
RED=$(printf 'fatal: remote error, token was ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\n' | rd_redact_stream)
case "$RED" in
	*ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*) fail "(2) command-output token not masked" ;;
	*REDACTED*) pass "(2) an un-registered GitHub token in command output is masked by shape" ;;
	*) fail "(2) command-output token: no redaction marker" ;;
esac

# ============================================================================
# (3) TOKEN IN URL USERINFO — credentials before '@' are stripped.
# ============================================================================
RED=$(printf 'cloning from https://x-access-token:%s@github.com/o/r.git now\n' "$GH" | rd_redact_stream)
case "$RED" in
	*"$GH"*) fail "(3) URL userinfo token leaked" ;;
	*"***REDACTED***@github.com"*) pass "(3) a token in URL userinfo is redacted (creds before '@' stripped)" ;;
	*) fail "(3) URL userinfo not redacted as expected: $RED" ;;
esac

# ============================================================================
# (4) TOKEN IN A QUERY PARAMETER — sensitive query value is stripped.
# ============================================================================
RED=$(printf 'GET https://api.example.com/v1?access_token=%s&page=1 HTTP/1.1\n' "$GH" | rd_redact_stream)
case "$RED" in
	*"$GH"*) fail "(4) query-param token leaked" ;;
	*"access_token=***REDACTED***"*) pass "(4) a token in a query parameter is redacted" ;;
	*) fail "(4) query-param not redacted as expected: $RED" ;;
esac

# ============================================================================
# (5) TOKEN WITH REGEX METACHARACTERS — treated as a LITERAL, never compiled as a pattern.
# ============================================================================
rd_secret_reset
META='a.*b+c(d)[e]|f\g^h$i'
if ! rd_secret_add "$META" >/dev/null 2>&1; then fail "(5) could not register the metacharacter token"; fi
RED=$(printf 'leaked=%s control=axxxbcde end\n' "$META" | rd_redact_stream)
case "$RED" in *"$META"*) fail "(5) metacharacter secret leaked (literal removal failed)" ;; *) : ;; esac
# The control string WOULD match if the secret were interpreted as the regex 'a.*b...'. It must survive.
case "$RED" in
	*"$META"*) : ;;
	*axxxbcde*) pass "(5) a metacharacter token is redacted as a LITERAL (no regex injection; control survives)" ;;
	*) fail "(5) control string was wrongly consumed — secret acted as a regex: $RED" ;;
esac

# ============================================================================
# (6) TOKEN WITH / # & BACKSLASH AND UNICODE — literal redaction survives sed-hostile bytes.
# ============================================================================
rd_secret_reset
SPECIAL='sk-live/AB#CD&EF\GH café-key'
if ! rd_secret_add "$SPECIAL" >/dev/null 2>&1; then fail "(6) could not register the special-char token"; fi
RED=$(printf 'config: secret=%s :: done\n' "$SPECIAL" | rd_redact_stream)
case "$RED" in
	*"$SPECIAL"*) fail "(6) special-char/Unicode secret leaked" ;;
	*"***REDACTED-SECRET***"*) pass "(6) a token with / # & backslash + Unicode is redacted literally" ;;
	*) fail "(6) special-char secret not redacted: $RED" ;;
esac

# ============================================================================
# (7) NESTED PROJECT PATH UNDER HOME — relativized to '~', and an email is masked.
# ============================================================================
rd_secret_reset
RED=$(RD_HOME=/home/tester rd_redact_value 'wrote /home/tester/projects/app/reports/x.json for dev@example.com')
case "$RED" in
	*"/home/tester"*) fail "(7) nested home path leaked" ;;
	*"~/projects/app/reports"*) pass "(7) a nested project path under HOME is relativized to '~'" ;;
	*) fail "(7) home path not relativized: $RED" ;;
esac
case "$RED" in *"dev@example.com"*) fail "(7-email) email not masked" ;; *"***REDACTED-EMAIL***"*) pass "(7-email) an email in a diagnostic is masked" ;; *) fail "(7-email) email handling: $RED" ;; esac

# ============================================================================
# (8) SIGNING-KEY PATH IN A GIT ERROR — SSH key path and GPG homedir are redacted.
# ============================================================================
rd_secret_reset
RED=$(printf 'error: gpg failed: gpg --homedir /home/tester/.gnupg -u KEYID signing key /home/tester/.ssh/id_ed25519 missing\n' | rd_redact_stream)
case "$RED" in *"id_ed25519"*) fail "(8) SSH signing-key path leaked" ;; *"***REDACTED-KEY-PATH***"*) pass "(8) an SSH signing-key path in a git error is redacted" ;; *) fail "(8) key path not redacted: $RED" ;; esac
case "$RED" in *"/.gnupg"*) fail "(8-gpg) GnuPG homedir path leaked" ;; *"***REDACTED-GNUPG-PATH***"*) pass "(8-gpg) a --homedir GnuPG path is redacted" ;; *) fail "(8-gpg) gnupg path: $RED" ;; esac

# ============================================================================
# (9) REGISTRY CREDENTIALS IN PACKAGE-MANAGER OUTPUT — npm authToken and _password stripped.
# ============================================================================
rd_secret_reset
RED=$(printf '//registry.npmjs.org/:_authToken=npm_ABCDEFGHIJKLMNOPQRSTUVWXYZ012 ; _password=hunter2secretpw done\n' | rd_redact_stream)
case "$RED" in *"npm_ABCDEFGHIJKLMNOPQRSTUVWXYZ012"*) fail "(9) npm authToken leaked" ;; *) : ;; esac
case "$RED" in *"hunter2secretpw"*) fail "(9) registry _password leaked" ;; *) : ;; esac
{ case "$RED" in *"_authToken=***REDACTED***"*) true ;; *) false ;; esac; } \
	&& { case "$RED" in *"_password=***REDACTED***"*) true ;; *) false ;; esac; } \
	&& pass "(9) registry credentials in package-manager output are redacted (authToken + password)" \
	|| fail "(9) registry credentials not fully redacted: $RED"

# ============================================================================
# (10) SECRET INSIDE AN UPLOADED ARTIFACT FIXTURE — rd_scan_paths FAILS CLOSED; report has NO value.
# ============================================================================
rd_secret_reset
FIX="$WORK/artifact"; mkdir -p "$FIX/nested"
printf 'harmless header\naws creds %s\n' "$AWS" > "$FIX/config.txt"
printf 'token: %s\n' "$GH" > "$FIX/nested/token.txt"
SCANREP=$(rd_scan_paths "$FIX") && SCANRC=0 || SCANRC=$?
[ "$SCANRC" = 1 ] && pass "(10) rd_scan_paths FAILS CLOSED (exit 1) when an artifact carries a confirmed secret" || fail "(10) artifact scan fail-closed (rc=$SCANRC)"
if printf '%s' "$SCANREP" | jq -e '.confirmed_secret_present == true and (.scan.total_findings >= 2) and (.scan.files_with_secrets == 2)' >/dev/null 2>&1; then
	pass "(10) the redaction report records the confirmed-secret finding counts"
else
	fail "(10) report counts wrong: $SCANREP"
fi
case "$SCANREP" in
	*"$AWS"*|*"$GH"*|*ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*|*IOSFODNN7EXAMPLE*) fail "(10) the report LEAKED a secret value" ;;
	*) pass "(10) the redaction report contains NO secret value (counts + categories only)" ;;
esac
# Positive control: a clean tree scans clean (exit 0).
CLEAN="$WORK/clean"; mkdir -p "$CLEAN"
printf 'just ordinary log output\nno credentials here at all\n' > "$CLEAN/ok.txt"
rd_scan_paths "$CLEAN" >/dev/null 2>&1 && CLNRC=0 || CLNRC=$?
[ "$CLNRC" = 0 ] && pass "(10+) a clean artifact tree scans clean (exit 0)" || fail "(10+) clean tree scan (rc=$CLNRC)"

# ============================================================================
# (11) MULTIPLE OVERLAPPING SECRET VALUES — longest-first literal removal leaves no fragment.
# ============================================================================
rd_secret_reset
LONG='SUPERTOKENVALUEX'
SHORT='TOKENVAL'               # a substring of LONG (overlapping); absent from any placeholder
if ! rd_secret_add "$LONG" >/dev/null 2>&1; then fail "(11) could not register the long token"; fi
if ! rd_secret_add "$SHORT" >/dev/null 2>&1; then fail "(11) could not register the short token"; fi
RED=$(printf 'a %s b %s c\n' "$LONG" "$SHORT" | rd_redact_stream)
case "$RED" in
	*"$LONG"*) fail "(11) the longer overlapping secret leaked" ;;
	*TOKENVAL*) fail "(11) a secret fragment leaked (overlap not handled longest-first)" ;;
	*) pass "(11) multiple overlapping secret values are fully redacted (longest-first, no fragment)" ;;
esac

# ============================================================================
# (12) EXTREMELY LONG UNTRUSTED DIAGNOSTIC LINE — bounded, and an early secret still removed.
# ============================================================================
rd_secret_reset
FILLER=$(awk 'BEGIN{s="";for(i=0;i<12000;i++)s=s"A";print s}')
LONGLINE=$(printf 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 %s' "$FILLER")
RED=$(printf '%s\n' "$LONGLINE" | rd_redact_stream)
case "$RED" in *ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*) fail "(12) early token in a long line leaked" ;; *) : ;; esac
if [ "${#RED}" -le 8300 ]; then
	pass "(12) an extremely long untrusted line is bounded (<= RD_MAX_LINE + marker)"
else
	fail "(12) long line was NOT bounded (len=${#RED})"
fi
case "$RED" in *"[TRUNCATED]"*) pass "(12+) the bounded line carries the [TRUNCATED] marker" ;; *) fail "(12+) truncation marker absent" ;; esac

# ============================================================================
# (FI) FAILURE-INJECTION — the sensitive-value registry refuses under-min / over-size values and
# records the cap honestly; a benign line passes through UNCHANGED (no over-redaction).
# ============================================================================
rd_secret_reset
rd_secret_add "ab" >/dev/null 2>&1 && TOOSHORT_RC=0 || TOOSHORT_RC=$?
[ "$TOOSHORT_RC" != 0 ] && [ "$RD__SECRETS_CAPPED" = 1 ] \
	&& pass "(FI) an under-minimum secret value is REFUSED and recorded as capped" \
	|| fail "(FI) under-min refusal (rc=$TOOSHORT_RC capped=$RD__SECRETS_CAPPED)"
rd_secret_reset
BENIGN='all systems nominal, build 42 ok'
RED=$(printf '%s\n' "$BENIGN" | rd_redact_stream)
[ "$RED" = "$BENIGN" ] && pass "(FI+) a benign line passes through unchanged (no over-redaction)" || fail "(FI+) benign line altered: '$RED'"

# ============================================================================
if [ "$FAILS" -ne 0 ]; then
	printf '\n%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\nAll redaction-security assertions passed.\n'
exit 0
