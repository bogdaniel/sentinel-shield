#!/bin/sh
# Sentinel Shield prod test — enforcement reports are published as one immutable generation.
#
# Two sequential renames are NOT a transactional pair: a failure, a signal or a crash between
# them leaves a NEW JSON beside an OLD Markdown — precisely the mismatch the pairing claimed to
# prevent. Artifacts are now rendered into a private staging generation, validated against
# recorded digests, finalized, and made visible by ONE atomic pointer switch. A published
# generation is immutable; the previous one survives every failure.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT"
ENFORCE="$ROOT/scripts/enforce-gates.sh"
RESOLVE="$ROOT/scripts/resolve-gates.sh"
FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$3', got '$2')"; fi; }
contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3')" ;; esac; }

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT INT TERM HUP

# A failure-injection copy of scripts/ — the real tree is never edited.
SBIN="$WORK/scripts"
cp -R "$ROOT/scripts" "$SBIN"
inject() {  # inject <name> <sed-expression>
	sed "$2" "$ROOT/scripts/enforce-gates.sh" > "$SBIN/$1"
	if cmp -s "$ROOT/scripts/enforce-gates.sh" "$SBIN/$1"; then return 1; fi
	return 0
}

# newcase <name> — an output dir with gates + a summary, ready to enforce into.
newcase() {
	_d="$WORK/$1"; rm -rf "$_d"; mkdir -p "$_d"
	sh "$RESOLVE" --mode baseline --output-dir "$_d" --format all >/dev/null 2>&1
	jq '.tools = {"tests":{"status":"pass"}}' "$ROOT/templates/security-summary.example.json" > "$_d/s.json"
	printf '%s' "$_d"
}
# run <dir> [engine] — enforce into <dir>; echo the exit code.
run() {
	_d="$1"; _eng="${2:-$ENFORCE}"
	_c=0
	sh "$_eng" --gates-env "$_d/sentinel-shield-gates.env" --summary "$_d/s.json" \
		--output-dir "$_d" --format all >"$_d/log" 2>&1 || _c=$?
	printf '%s' "$_c"
}
gen_of() { jq -r '.generation_id // ""' "$1/enforcement/current.json" 2>/dev/null || printf ''; }
gens_in() { ls -1 "$1/enforcement" 2>/dev/null | grep -v '^current\.json$' | grep -vc '^\.' || printf 0; }

# ---------------------------------------------------------------------------
# 1. The published layout, and the manifest that describes it.
# ---------------------------------------------------------------------------
D=$(newcase happy)
check "a clean run publishes" "$(run "$D")" 0
G=$(gen_of "$D")
check "  a current pointer names a generation" "$([ -n "$G" ] && echo yes || echo no)" "yes"
check "  the generation directory exists" "$([ -d "$D/enforcement/$G" ] && echo yes || echo no)" "yes"
check "  it holds the JSON, the Markdown and a manifest" \
	"$(ls -1 "$D/enforcement/$G" | sort | tr '\n' ' ')" \
	"manifest.json sentinel-shield-enforcement.json sentinel-shield-enforcement.md "
check "  the pointer is a regular file, not a symlink" \
	"$([ -L "$D/enforcement/current.json" ] && echo symlink || echo file)" "file"
M="$D/enforcement/$G/manifest.json"
check "  the manifest names the generation" "$(jq -r '.generation_id' "$M")" "$G"
for _f in created_at target_commit profile mode result validation schema_version; do
	check "  the manifest records $_f" "$(jq -r --arg f "$_f" '(.[$f] // "") | length > 0' "$M")" "true"
done
check "  it lists the expected artifacts" "$(jq -r '.expected_artifacts | length' "$M")" "2"
check "  every artifact has a size and a digest" \
	"$(jq -r '[.artifacts[] | select((.bytes > 0) and (.sha256 | test("^[0-9a-f]{64}$")))] | length' "$M")" "2"
# The digests must be of the bytes actually published.
jq -r '.artifacts[] | "\(.path) \(.sha256)"' "$M" | while read -r _p _d; do
	_a=$( (sha256sum "$D/enforcement/$G/$_p" 2>/dev/null || shasum -a 256 "$D/enforcement/$G/$_p") | cut -d' ' -f1)
	if [ "$_a" = "$_d" ]; then pass "  digest matches for $_p"; else fail "  digest MISMATCH for $_p"; fi
done
check "  the compatibility mirror is byte-identical to the generation" \
	"$(cmp -s "$D/sentinel-shield-enforcement.json" "$D/enforcement/$G/sentinel-shield-enforcement.json" && echo same || echo different)" "same"
check "  no staging directory is left behind" \
	"$(find "$D/enforcement" -maxdepth 1 -name '.staging.*' | wc -l | tr -d ' ')" "0"
check "  no publish lock is left behind" \
	"$([ -e "$D/enforcement/.publish.lock" ] && echo held || echo released)" "released"

# A second run publishes a NEW generation and leaves the first one untouched.
_g1="$G"; _d1=$(cat "$D/enforcement/$G/sentinel-shield-enforcement.json")
check "a second run publishes" "$(run "$D")" 0
_g2=$(gen_of "$D")
if [ "$_g1" != "$_g2" ]; then pass "  it is a NEW generation"; else fail "  the generation id did not change"; fi
check "  the previous generation is still readable" "$([ -f "$D/enforcement/$_g1/manifest.json" ] && echo yes || echo no)" "yes"
check "  and was not mutated" "$(cat "$D/enforcement/$_g1/sentinel-shield-enforcement.json")" "$_d1"

# ---------------------------------------------------------------------------
# 2. Failure injection: the previous generation always survives.
# ---------------------------------------------------------------------------
# base <name> — a case with ONE good published generation, recorded for comparison.
base() {
	_b=$(newcase "$1"); run "$_b" >/dev/null
	printf '%s' "$_b"
}
survives() {  # survives <dir> <good-generation> <label>
	_bd="$1"; _bg="$2"; _lbl="$3"
	check "  $_lbl: the pointer still names the last valid generation" "$(gen_of "$_bd")" "$_bg"
	check "  $_lbl: that generation is intact" "$([ -f "$_bd/enforcement/$_bg/manifest.json" ] && echo yes || echo no)" "yes"
	check "  $_lbl: no staging directory survives" \
		"$(find "$_bd/enforcement" -maxdepth 1 -name '.staging.*' | wc -l | tr -d ' ')" "0"
}

# (a) failure after the FIRST artifact is rendered.
if inject e-after-first 's|^gen_manifest$|die_cfg "INJECTED: failed after rendering the first artifact"|'; then
	B=$(base inj-first); BG=$(gen_of "$B")
	check "failure after the first artifact fails the run" "$(run "$B" "$SBIN/e-after-first")" 2
	survives "$B" "$BG" "after-first"
else fail "injection e-after-first did not apply"; fi

# (b) failure after ALL artifacts but before validation.
if inject e-before-val 's|^gen_validate$|die_cfg "INJECTED: failed before validation"|'; then
	B=$(base inj-val); BG=$(gen_of "$B")
	check "failure before validation fails the run" "$(run "$B" "$SBIN/e-before-val")" 2
	survives "$B" "$BG" "before-validation"
else fail "injection e-before-val did not apply"; fi

# (c) failure DURING manifest creation.
if inject e-manifest 's|^\tjq -e . "\$_gm" >/dev/null 2>&1 |\tdie_cfg "INJECTED: manifest creation failed"; jq -e . "$_gm" >/dev/null 2>&1 |'; then
	B=$(base inj-man); BG=$(gen_of "$B")
	check "failure during manifest creation fails the run" "$(run "$B" "$SBIN/e-manifest")" 2
	survives "$B" "$BG" "manifest"
else fail "injection e-manifest did not apply"; fi

# (d) failure immediately BEFORE the pointer switch — the generation directory may exist, but
#     it must not become current, because only the pointer makes a generation authoritative.
if inject e-before-ptr 's|^\t_ptmp=$(mktemp "\$ENFORCEMENT_ROOT/.current.XXXXXX").*|\tdie_cfg "INJECTED: failed immediately before the pointer switch"|'; then
	B=$(base inj-ptr); BG=$(gen_of "$B")
	check "failure before the pointer switch fails the run" "$(run "$B" "$SBIN/e-before-ptr")" 2
	check "  the pointer still names the previous generation" "$(gen_of "$B")" "$BG"
	check "  the previous generation is intact" "$([ -f "$B/enforcement/$BG/manifest.json" ] && echo yes || echo no)" "yes"
else fail "injection e-before-ptr did not apply"; fi

# (e) a MALFORMED artifact never reaches a generation.
# Corrupt the rendered JSON right after it is written, before the manifest is built.
if inject e-bad-json 's|^gen_manifest$|printf "{ broken" > "$GEN_STAGE/sentinel-shield-enforcement.json"; gen_manifest|'; then
	B=$(base inj-bad); BG=$(gen_of "$B")
	_c=$(run "$B" "$SBIN/e-bad-json")
	if [ "$_c" -eq 0 ]; then
		fail "a malformed JSON artifact was published"
	else
		pass "a malformed JSON artifact fails the run"
		survives "$B" "$BG" "malformed-artifact"
	fi
else fail "injection e-bad-json did not apply"; fi

# (f) a MISSING expected artifact is caught by validation.
if inject e-missing 's|^gen_validate$|rm -f "$GEN_STAGE/sentinel-shield-enforcement.md"; gen_validate|'; then
	B=$(base inj-miss); BG=$(gen_of "$B")
	check "a missing expected artifact fails validation" "$(run "$B" "$SBIN/e-missing")" 2
	contains "  naming the artifact" "$(cat "$B/log")" "sentinel-shield-enforcement.md"
	survives "$B" "$BG" "missing-artifact"
else fail "injection e-missing did not apply"; fi

# (g) a DIGEST MISMATCH — an artifact altered after the manifest was written.
if inject e-tamper 's|^gen_validate$|printf "tampered\\n" >> "$GEN_STAGE/sentinel-shield-enforcement.md"; gen_validate|'; then
	B=$(base inj-tamper); BG=$(gen_of "$B")
	check "a digest mismatch fails validation" "$(run "$B" "$SBIN/e-tamper")" 2
	contains "  naming the mismatch" "$(cat "$B/log")" "does not match its manifest digest"
	survives "$B" "$BG" "digest-mismatch"
else fail "injection e-tamper did not apply"; fi

# (h) a STALE artifact copied in from a previous generation is still digest-checked.
if inject e-stale 's|^gen_validate$|cp "$ENFORCEMENT_ROOT"/*/sentinel-shield-enforcement.md "$GEN_STAGE/sentinel-shield-enforcement.md" 2>/dev/null || true; gen_validate|'; then
	B=$(base inj-stale)
	# make the previous generation differ so a copied file is detectably stale
	run "$B" >/dev/null; BG=$(gen_of "$B")
	_c=$(run "$B" "$SBIN/e-stale")
	if [ "$_c" -eq 0 ]; then
		# identical content is not "stale" in any observable way; only a DIFFERENT file is
		_same=$(cmp -s "$B/enforcement/$(gen_of "$B")/sentinel-shield-enforcement.md" "$B/enforcement/$BG/sentinel-shield-enforcement.md" && echo same || echo different)
		check "a copied-in artifact is only accepted when identical" "$_same" "same"
	else
		pass "a stale copied-in artifact is refused by the digest check"
	fi
else fail "injection e-stale did not apply"; fi

# ---------------------------------------------------------------------------
# 3. Concurrency, and hostile paths.
# ---------------------------------------------------------------------------
B=$(base lock); BG=$(gen_of "$B")
mkdir -p "$B/enforcement/.publish.lock"
printf 'pid=999999 host=other user=someone started=then run=42\n' > "$B/enforcement/.publish.lock/owner"
check "a second concurrent publisher is refused" "$(run "$B")" 2
contains "  naming the holder" "$(cat "$B/log")" "pid=999999"
contains "  and how to recover a stale lock" "$(cat "$B/log")" "remove the stale lock directory"
check "  the foreign lock is NOT removed by the refused run" \
	"$([ -d "$B/enforcement/.publish.lock" ] && echo held || echo removed)" "held"
survives "$B" "$BG" "concurrent"
rm -rf "$B/enforcement/.publish.lock"
check "  once the lock clears, publication resumes" "$(run "$B")" 0

# A symlinked current pointer must never be written through.
B=$(base symptr); BG=$(gen_of "$B")
rm -f "$B/enforcement/current.json"
ln -s "$B/outside-pointer.json" "$B/enforcement/current.json"
check "a symlinked current pointer is refused" "$(run "$B")" 2
check "  and nothing was written through it" \
	"$([ -e "$B/outside-pointer.json" ] && echo written || echo clean)" "clean"

# A symlinked generation root is refused.
B=$(newcase symroot); mkdir -p "$B/elsewhere"
ln -s "$B/elsewhere" "$B/enforcement"
check "a symlinked generation root is refused" "$(run "$B")" 2
contains "  naming the symlink" "$(cat "$B/log")" "symlink"

# A non-directory in the generation root's place is refused.
B=$(newcase notdir); printf 'x' > "$B/enforcement"
check "a file where the generation root belongs is refused" "$(run "$B")" 2

# ---------------------------------------------------------------------------
# 4. Pointer integrity, GC, and readers.
# ---------------------------------------------------------------------------
# A corrupt pointer must not be mistaken for a valid generation, and the next run repairs it.
B=$(base corrupt); BG=$(gen_of "$B")
printf 'not json at all' > "$B/enforcement/current.json"
check "  a corrupt pointer does not resolve to a generation" "$(gen_of "$B")" ""
check "the next run republishes over a corrupt pointer" "$(run "$B")" 0
_g=$(gen_of "$B")
check "  the pointer resolves again" "$([ -n "$_g" ] && echo yes || echo no)" "yes"
check "  and the older generation is still on disk" "$([ -d "$B/enforcement/$BG" ] && echo yes || echo no)" "yes"

# Garbage collection keeps a bounded history and NEVER removes the active generation.
B=$(newcase gc)
_i=0; while [ "$_i" -lt 8 ]; do run "$B" >/dev/null; _i=$((_i + 1)); done
_active=$(gen_of "$B")
check "GC keeps the configured number of generations" "$(gens_in "$B")" "5"
check "  the ACTIVE generation is never collected" "$([ -d "$B/enforcement/$_active" ] && echo yes || echo no)" "yes"
check "  and it still validates" \
	"$(jq -r '.generation_id' "$B/enforcement/$_active/manifest.json")" "$_active"
B=$(newcase gc2)
_i=0; while [ "$_i" -lt 4 ]; do env SENTINEL_SHIELD_REPORT_GENERATIONS=2 sh "$ENFORCE" \
	--gates-env "$B/sentinel-shield-gates.env" --summary "$B/s.json" --output-dir "$B" --format all >/dev/null 2>&1; _i=$((_i + 1)); done
check "the retention count is configurable" "$(gens_in "$B")" "2"
check "  with the active generation still present" "$([ -d "$B/enforcement/$(gen_of "$B")" ] && echo yes || echo no)" "yes"

# A reader that resolves the pointer sees ONE immutable generation, even while another is
# published: the generation it resolved is never mutated.
B=$(base reader); RG=$(gen_of "$B")
_before=$( (sha256sum "$B/enforcement/$RG/sentinel-shield-enforcement.json" 2>/dev/null || shasum -a 256 "$B/enforcement/$RG/sentinel-shield-enforcement.json") | cut -d' ' -f1)
run "$B" >/dev/null
_after=$( (sha256sum "$B/enforcement/$RG/sentinel-shield-enforcement.json" 2>/dev/null || shasum -a 256 "$B/enforcement/$RG/sentinel-shield-enforcement.json") | cut -d' ' -f1)
check "a resolved generation is immutable while a new one is published" "$_after" "$_before"
if [ "$(gen_of "$B")" != "$RG" ]; then pass "  and the pointer has moved on to the new generation"; else fail "  the pointer did not advance"; fi

# ---------------------------------------------------------------------------
# Staging paths are not predictable, and the pointer destination is validated.
# ---------------------------------------------------------------------------
# `$dest.tmp.$$` and `.current.$$.tmp` are derivable from the PID, so anyone able to write in
# the report root can pre-create them as symlinks that `cp`/redirection then writes through —
# outside the root, before any rename happens.
B=$(base symlink-tmp)
_out="$B/outside.txt"; : > "$_out"
# Pre-create every plausible PID-derived staging name as a symlink pointing outside.
_pid=$$
for _p in "$B/enforcement/.current.$_pid.tmp" "$B/sentinel-shield-enforcement.json.tmp.$_pid"; do
	mkdir -p "$(dirname "$_p")" 2>/dev/null || true
	ln -s "$_out" "$_p" 2>/dev/null || true
done
_rc=$(run "$B" "$ENFORCE")
check "publication succeeds despite pre-created PID-named symlinks" "$_rc" 0
if [ -s "$_out" ]; then
	fail "a staging write followed a pre-created symlink and landed outside the report root"
else
	pass "  and nothing was written through them"
fi

# A pointer destination that is a DIRECTORY is not something `mv` replaces.
B=$(base ptr-dir)
rm -f "$B/enforcement/current.json"
mkdir -p "$B/enforcement/current.json"
check "a directory in place of the pointer is refused" "$(run "$B" "$ENFORCE")" 2

# ...nor a FIFO, where `mv` does not do what "switch the pointer" promises.
if command -v mkfifo >/dev/null 2>&1; then
	B=$(base ptr-fifo)
	rm -f "$B/enforcement/current.json"
	mkfifo "$B/enforcement/current.json" 2>/dev/null || true
	if [ -p "$B/enforcement/current.json" ]; then
		check "a FIFO in place of the pointer is refused" "$(run "$B" "$ENFORCE")" 2
	else
		pass "mkfifo unavailable on this filesystem; FIFO pointer case skipped"
	fi
fi


printf '\n'
if [ "$FAILED" -eq 0 ]; then
	printf '299-report-generation-publication: ALL CHECKS PASSED\n'
	exit 0
fi
printf '299-report-generation-publication: FAILURES PRESENT\n'
exit 1
