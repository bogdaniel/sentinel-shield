#!/bin/sh
# Sentinel Shield — normalized FINDING IDENTITY for finding-scoped accepted risks.
#
# Accepted-risk governance says finding-scoped suppression is the safe default and broad
# `scope: gate` suppression is discouraged — but finding scope was only ever implemented for
# `unsafe_docker`. For every other suppressible gate an adopter accepting ONE medium
# vulnerability had to suppress the WHOLE gate, which then also covered every unrelated
# medium finding that appeared later. The schema reserved `components` and `fingerprints`
# without enforcing them, so the product implied a capability it did not have.
#
# This emits ONE canonical identity per finding, from the raw scanner reports, so a record can
# name a single vulnerability:
#
#   { source, rule_id, component, version, file, severity, fingerprint }
#
# FINGERPRINT (algorithm version 1) is a readable, canonical string — deliberately not a hash,
# so an auditor can read a record and see exactly what it accepts:
#
#   ss-fp/1|<source>|<rule_id>|<component>|<version>|<file>
#
# It is built ONLY from stable identity fields. It never uses array order, display text,
# titles, descriptions, or line numbers, so re-running a scanner reproduces it. The VERSION is
# part of the identity on purpose: a package upgrade produces a different fingerprint, so an
# acceptance does not silently carry over to a version nobody reviewed. Accepting across
# versions is what `components` (+ optional rule id) is for.
#
# Exit: 0 emitted (possibly an empty array); 2 invalid invocation; 3 required tool missing.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"

usage() {
	cat <<'EOF'
Usage: normalize-findings.sh --gate medium_vulnerabilities [--raw-dir reports/raw] [--severity medium]

Emits a JSON array of normalized findings on stdout:
  { source, rule_id, component, version, file, severity, fingerprint }

Sources read (each optional; an unreadable source is simply absent from the output, and the
caller treats the shortfall against the summary count as UNACCEPTED — never as clean):
  grype.json  osv-scanner.json  trivy-fs.json  composer-audit.json  npm-audit.json
  dependency-check.json
EOF
}

GATE="medium_vulnerabilities"
RAW_DIR="reports/raw"
SEVERITY="medium"
while [ $# -gt 0 ]; do
	case "$1" in
		--gate) GATE="${2:?--gate requires a value}"; shift 2 ;;
		--raw-dir) RAW_DIR="${2:?--raw-dir requires a value}"; shift 2 ;;
		--severity) SEVERITY="${2:?--severity requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done
case "$GATE" in
	medium_vulnerabilities) ;;
	*) log_error "unsupported gate '$GATE' (finding identity is defined for: medium_vulnerabilities)"; exit 2 ;;
esac
case "$SEVERITY" in
	critical | high | medium | low) ;;
	*) log_error "--severity must be critical|high|medium|low"; exit 2 ;;
esac
command_exists jq || { log_error "jq is required"; exit 3; }

# src <name> — the raw report path when it exists AND parses, else /dev/null. An unreadable
# source contributes nothing; it is never guessed at and never treated as empty-and-clean.
src() {
	_f="$RAW_DIR/$1"
	if [ -f "$_f" ] && jq -e . "$_f" >/dev/null 2>&1; then printf '%s' "$_f"; else printf '/dev/null'; fi
}

jq -n \
	--slurpfile grype "$(src grype.json)" \
	--slurpfile osv "$(src osv-scanner.json)" \
	--slurpfile trivy "$(src trivy-fs.json)" \
	--slurpfile composer "$(src composer-audit.json)" \
	--slurpfile npm "$(src npm-audit.json)" \
	--slurpfile depcheck "$(src dependency-check.json)" \
	--arg want "$SEVERITY" '
	def norm: (. // "") | tostring | sub("^\\./"; "");
	def sev: (. // "") | ascii_downcase
		| if . == "moderate" then "medium" elif . == "" then "medium" else . end;
	def fp($s; $r; $c; $v; $f):
		"ss-fp/1|" + $s + "|" + ($r|norm) + "|" + ($c|norm) + "|" + ($v|norm) + "|" + ($f|norm);
	def mk($s; $r; $c; $v; $f; $sv):
		{ source: $s, rule_id: ($r|norm), component: ($c|norm), version: ($v|norm),
		  file: ($f|norm), severity: $sv, fingerprint: fp($s; $r; $c; $v; $f) };

	# --- grype: native matches[] -------------------------------------------------------
	( [ ($grype[0] // {} | if type == "object" and (.matches | type) == "array" then .matches[] else empty end)
		| select((.vulnerability.severity | sev) == $want)
		| mk("grype";
			(.vulnerability.id // "");
			(.artifact.name // "");
			(.artifact.version // "");
			((.artifact.locations // [])[0].path // "");
			$want) ] ) as $g

	# --- osv-scanner: results[].packages[].vulnerabilities[] ---------------------------
	| ( [ ($osv[0] // {} | if type == "object" and (.results | type) == "array" then .results[] else empty end)
		| (.source.path // "") as $path
		| (.packages // [])[]
		| (.package.name // "") as $pkg
		| (.package.version // "") as $pver
		| (.vulnerabilities // [])[]
		| select(((.database_specific.severity // "") | sev) == $want)
		| mk("osv-scanner"; (.id // ""); $pkg; $pver; $path; $want) ] ) as $o

	# --- trivy filesystem: Results[].Vulnerabilities[] ---------------------------------
	| ( [ ($trivy[0] // {} | if type == "object" and (.Results | type) == "array" then .Results[] else empty end)
		| (.Target // "") as $tgt
		| (.Vulnerabilities // [])[]
		| select((.Severity | sev) == $want)
		| mk("trivy-fs"; (.VulnerabilityID // ""); (.PkgName // ""); (.InstalledVersion // ""); $tgt; $want) ] ) as $t

	# --- composer audit: advisories keyed by package -----------------------------------
	| ( [ ($composer[0] // {} | if type == "object" and (.advisories | type) == "object" then (.advisories | to_entries[]) else empty end)
		| .key as $pkg
		| (.value | if type == "array" then .[] else . end)
		| select(((.severity // "") | sev) == $want)
		| mk("composer-audit";
			(.cve // .advisoryId // .title // "");
			$pkg;
			(.affectedVersions // "");
			"composer.lock"; $want) ] ) as $c

	# --- npm audit (v7+): vulnerabilities keyed by package -----------------------------
	| ( [ ($npm[0] // {} | if type == "object" and (.vulnerabilities | type) == "object" then (.vulnerabilities | to_entries[]) else empty end)
		| .key as $pkg
		| .value
		| select(((.severity // "") | sev) == $want)
		| . as $v
		| ( [ (.via // [])[] | if type == "object" then (.source // .url // .title // "") else . end ] ) as $ids
		| mk("npm-audit";
			(($ids | map(tostring) | sort | join(",")) // "");
			$pkg;
			(($v.range // "") | tostring);
			"package-lock.json"; $want) ] ) as $n

	# --- OWASP Dependency-Check: dependencies[].vulnerabilities[] ----------------------
	| ( [ ($depcheck[0] // {} | if type == "object" and (.dependencies | type) == "array" then .dependencies[] else empty end)
		| (.fileName // "") as $fn
		| (.filePath // "") as $fp
		| (.vulnerabilities // [])[]
		| select(((.severity // "") | sev) == $want)
		| mk("dependency-check"; (.name // ""); $fn; ""; (if $fp == "" then $fn else $fp end); $want) ] ) as $d

	| ($g + $o + $t + $c + $n + $d)
	# Deterministic order so two runs over the same evidence produce byte-identical output.
	| sort_by(.fingerprint)
'
