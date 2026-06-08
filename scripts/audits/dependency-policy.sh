#!/bin/sh
# Sentinel Shield audit — dependency policy (v0.1.14). FIRST concrete emitter for
# dependency_policy_violations. Conservative + deterministic + offline:
#   - flags an ecosystem manifest present WITHOUT its lockfile (reproducible-build risk).
# Ecosystems: composer, npm, python(pip/poetry/pipenv), go, ruby, rust.
# License/version-allowlist policy is intentionally NOT implemented here (documented as
# future in docs/dependency-policy.md) — doing it badly is worse than not at all.
# Writes reports/raw/dependency-policy.json: {violations:[{ecosystem,manifest,reason}], count}.
# Never fakes: if no manifests exist, count=0 (clean, honestly).
set -eu
OUT="${1:-reports/raw/dependency-policy.json}"
TARGET="${2:-.}"
mkdir -p "$(dirname "$OUT")"
command -v jq >/dev/null 2>&1 || { echo "[sentinel-shield] jq required for dependency-policy" >&2; exit 2; }

VIOL="[]"
add() { # add <ecosystem> <manifest> <reason>
	VIOL=$(printf '%s' "$VIOL" | jq --arg e "$1" --arg m "$2" --arg r "$3" '. + [{ecosystem:$e, manifest:$m, reason:$r}]')
}
# manifest present AND none of its lockfiles present -> violation.
chk() { # chk <ecosystem> <manifest> <lock1> [lock2...]
	_eco=$1; _man=$2; shift 2
	[ -f "$TARGET/$_man" ] || return 0
	for _l in "$@"; do [ -f "$TARGET/$_l" ] && return 0; done
	add "$_eco" "$_man" "manifest present without a lockfile ($*)"
}
chk composer composer.json composer.lock
chk npm package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml
chk python-pip requirements.in requirements.txt
chk python-poetry pyproject.toml poetry.lock
chk python-pipenv Pipfile Pipfile.lock
chk go go.mod go.sum
chk ruby Gemfile Gemfile.lock
chk rust Cargo.toml Cargo.lock

COUNT=$(printf '%s' "$VIOL" | jq 'length')
printf '%s' "$VIOL" | jq --argjson c "$COUNT" '{count:$c, violations:.}' > "$OUT"
echo "[sentinel-shield] dependency-policy: $COUNT violation(s) -> $OUT" >&2
exit 0
