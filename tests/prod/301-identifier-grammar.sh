#!/bin/sh
# Sentinel Shield production test — profile, parent, tool and group identifiers
# are validated BEFORE shell-based resolution (#251).
#
# WHY THIS EXISTS
#
# #248 made the profile manifest a validated document. It did not make the
# IDENTIFIERS inside that document safe to resolve, because the corruption
# happens after parsing, in the shell representation:
#
#   * `ep__collect` validated the parent name AFTER testing it against the cycle
#     and dedup sets, so an unvalidated name decided both verdicts.
#   * those sets were space-delimited strings tested with `case " $SET " in
#     *" $x "*`, which is substring matching: it cannot represent a member
#     containing a space and it matches across element boundaries.
#   * `EP_CHAIN` was a space-delimited list of manifest PATHS splatted unquoted
#     into `ep__finish`, so a repository path containing a space became two
#     nonexistent manifests and one containing `*` became whatever the cwd held.
#   * `extends`, tool keys, group keys, override keys, `executable[]`,
#     `fallback_order[]` and `disabled_tools[]` were all iterated with
#     `for x in $(jq ...)` — field splitting followed by pathname expansion.
#   * five entry points open-coded `profiles/$PROFILE/profile.manifest.json`
#     with NO identifier validation at all, so `--profile ../../etc` and
#     `--profile 'a b'` reached the filesystem; a name present in BOTH lookup
#     locations resolved to whichever the loop listed first; and a directory
#     matching only case-insensitively satisfied `[ -f ]` on macOS and not on
#     Linux, so the same repository resolved a different effective profile
#     depending on where it ran.
#   * the dedup and cycle sets were keyed by the name a manifest was RESOLVED
#     under while `.profile` was the name it CLAIMED, and nothing bound the two.
#
# This suite proves, in this order, because each is worthless without the one
# before it:
#
#   1. POSITIVE CONTROLS — the grammar accepts the entire live tree, and every
#      shipped profile still resolves. A grammar that rejects everything is
#      indistinguishable from one that works.
#   2. GRAMMAR — every hostile identifier class is rejected, with the reason.
#   3. RECONSTRUCTED PRE-#251 IDIOMS — the defective shell constructs are
#      rebuilt verbatim here and their WRONG answer is recomputed live, so
#      "this was a real hole" cannot rot into an assertion.
#   4. MUTATION OF A REAL TREE — synthetic profile roots built from shipped
#      manifests are fed to the REAL entry points, before and after.
#   5. NO WORD-SPLIT ITERATION — the resolution path is scanned, and the
#      scanner is itself proven to catch a planted instance.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
LIB="$ROOT/scripts/lib/profile-schema.sh"
EPLIB="$ROOT/scripts/lib/effective-profile.sh"
RES="$ROOT/scripts/resolve-effective-profile.sh"
BUILD="$ROOT/scripts/build-security-summary.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { # check <label> <actual> <expected>
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

command -v jq >/dev/null 2>&1 || { fail "jq is required"; exit 1; }
for _f in "$LIB" "$EPLIB" "$RES" "$BUILD"; do
	[ -f "$_f" ] || { fail "missing required file: $_f"; exit 1; }
done

TMP=$(mktemp -d)
# No `exit` inside the trap: an aborted run must keep its non-zero status.
trap 'rm -rf "$TMP" 2>/dev/null || :' EXIT

# Run a snippet with the identifier library loaded, in a subshell.
lib_sh() { # lib_sh <shell-code> [args...] — args become $1.. inside the code
	_code="$1"; shift
	# shellcheck disable=SC1090
	( set +e; . "$ROOT/scripts/lib/sentinel-shield-common.sh"; . "$LIB"; eval "$_code" )
}

NL='
'
TAB=$(printf '\t')

# ---------------------------------------------------------------------------
# 1. POSITIVE CONTROLS — non-vacuity
# ---------------------------------------------------------------------------
# 1a. Every identifier in the LIVE tree is canonical. If this ever fails the
#     grammar has drifted away from the product and every rejection below is
#     meaningless.
_live_ids=$(
	for _m in "$ROOT"/profiles/*/profile.manifest.json "$ROOT"/profiles/combinations/*.manifest.json; do
		[ -f "$_m" ] || continue
		jq -r '
			(.profile // empty),
			((.extends // [])[]),
			((.tools // {}) | keys[]),
			((.tools // {}) | to_entries[] | (.value.alternatives // [])[]),
			((.tools // {}) | to_entries[] | (.value.fallback_order // [])[]),
			((.tools // {}) | to_entries[] | (.value.requires // [])[]),
			((.tools // {}) | to_entries[] | (.value.category // empty))' "$_m"
	done | LC_ALL=C sort -u
)
_n_live=$(printf '%s\n' "$_live_ids" | grep -c . || printf '0')
if [ "$_n_live" -ge 60 ]; then
	pass "positive control: $_n_live distinct identifiers harvested from the live tree"
else
	fail "only $_n_live live identifiers harvested — this whole section would be near-vacuous"
fi
_rejected=$(lib_sh '
	while IFS= read -r _i; do
		[ -n "$_i" ] || continue
		ps_valid_id "$_i" || printf "%s\n" "$_i"
	done <<EOF
'"$_live_ids"'
EOF')
if [ -z "$_rejected" ]; then
	pass "positive control: the grammar accepts every identifier the product actually ships"
else
	fail "the grammar rejects shipped identifiers: $(printf '%s' "$_rejected" | tr '\n' ' ')"
fi

# 1b. Every shipped profile still resolves through the hardened resolver.
_resolved=0; _resfail=""
for _p in docker hardened-enterprise laravel node php-library react symfony laravel-react-docker node-react; do
	if sh "$RES" --profile "$_p" --format json >"$TMP/eff-$_p.json" 2>"$TMP/eff-$_p.err"; then
		_resolved=$((_resolved + 1))
	else
		_resfail="$_resfail $_p"
	fi
done
check "positive control: every shipped profile resolves (9)" "$_resolved" 9
[ -z "$_resfail" ] || fail "profiles that failed to resolve:$_resfail"

# 1c. A valid CONTROL that exercises the one-of satisfaction path end to end —
#     the path where `available` used to be a space-joined string.
CTL="$TMP/ctl"; mkdir -p "$CTL/vendor/bin"
printf '#!/bin/sh\n' > "$CTL/vendor/bin/pest"; chmod +x "$CTL/vendor/bin/pest"
if sh "$RES" --profile laravel --target "$CTL" --format json >"$TMP/ctl.json" 2>/dev/null; then
	check "positive control: one-of group is satisfied by the installed member" \
		"$(jq -r '.one_of_groups["php-tests"].selected' "$TMP/ctl.json")" "pest"
	check "positive control: available[] is a JSON array of exactly that member" \
		"$(jq -c '.one_of_groups["php-tests"].available' "$TMP/ctl.json")" '["pest"]'
else
	fail "the control resolution with a target failed — the one-of assertions are uninterpretable"
fi

# ---------------------------------------------------------------------------
# 2. GRAMMAR — every hostile identifier class is rejected, with a reason
# ---------------------------------------------------------------------------
# ps_id_reject_reason is invoked through a positional parameter so the value can
# carry any byte without being re-parsed by the shell.
reason_of() {
	# shellcheck disable=SC1090
	( set +e
	  . "$ROOT/scripts/lib/sentinel-shield-common.sh"
	  . "$LIB"
	  ps_id_reject_reason "$1" 2>/dev/null || true )
}
accepts() {
	# shellcheck disable=SC1090
	( set +e
	  . "$ROOT/scripts/lib/sentinel-shield-common.sh"
	  . "$LIB"
	  if ps_valid_id "$1"; then printf 'yes'; else printf 'no'; fi )
}

# The valid corpus: shapes a real profile legitimately uses.
for _ok in a a1 laravel php-library laravel-react-docker node-react php-tests \
	trivy-fs github-actions-pins x9 9x a-b-c-d 0; do
	check "grammar accepts '$_ok'" "$(accepts "$_ok")" "yes"
done
check "grammar accepts a 64-byte identifier (the limit)" \
	"$(accepts "$(printf 'a%.0s' $(seq 1 64))")" "yes"

# The hostile corpus. Every entry is a class named in the issue.
neg() { # neg <label> <value> <expected-reason>
	_a=$(accepts "$2"); _r=$(reason_of "$2")
	if [ "$_a" = "no" ]; then pass "grammar rejects $1"; else fail "grammar ACCEPTED $1"; fi
	check "  reason for $1" "$_r" "$3"
}
neg "the empty identifier"                ''                    'empty'
neg "a space"                             'php library'         'space'
neg "a tab"                               "php${TAB}library"    'tab'
neg "a newline"                           "php${NL}library"     'newline'
neg "a leading dash (option injection)"   '-rf'                 'leading-dash'
neg "a glob star"                         'php-*'               'glob-metacharacter'
neg "a glob question mark"                'php?'                'glob-metacharacter'
neg "a bracket class"                     'php[ab]'             'glob-metacharacter'
neg "a closing bracket"                   'php]'                'glob-metacharacter'
neg "a path separator"                    'a/b'                 'path-separator'
neg "a parent traversal"                  '../../etc'           'path-separator'
neg "a backslash"                         'a\\b'                'path-separator'
neg "a dot segment"                       'a.b'                 'dot'
neg "a command substitution"              'a$(id)'              'shell-metacharacter'
neg "a backtick"                          'a`id`'               'shell-metacharacter'
neg "a command separator"                 'a;id'                'shell-metacharacter'
neg "a pipe"                              'a|id'                'shell-metacharacter'
neg "an ampersand"                        'a&b'                 'shell-metacharacter'
neg "a double quote"                      'a"b'                 'shell-metacharacter'
neg "a single quote"                      "a'b"                 'shell-metacharacter'
neg "an underscore (emit-name collision)" 'php_style'           'underscore'
neg "an uppercase letter"                 'Laravel'             'uppercase'
neg "an all-caps identifier"              'LARAVEL'             'uppercase'
neg "a BEL control byte"                  "$(printf 'a\007b')"  'control-or-non-ascii'
neg "a SOH control byte"                  "$(printf 'a\001b')"  'control-or-non-ascii'
neg "a Cyrillic confusable (U+0430)"      "$(printf 'l\303\240ravel')" 'control-or-non-ascii'
neg "a Cyrillic 'a' confusable"           "$(printf 'l\320\260ravel')" 'control-or-non-ascii'
neg "a Greek omicron confusable (U+03BF)" "$(printf 'n\317\277de')"    'control-or-non-ascii'
neg "a fullwidth 'a' (U+FF41)"            "$(printf '\357\275\201bc')" 'control-or-non-ascii'
neg "a combining acute (NFD form)"        "$(printf 'a\314\201bc')"    'control-or-non-ascii'
neg "a zero-width space (U+200B)"         "$(printf 'ab\342\200\213c')" 'control-or-non-ascii'
neg "a non-breaking space (U+00A0)"       "$(printf 'ab\302\240c')"    'control-or-non-ascii'
neg "a 65-byte identifier"                "$(printf 'a%.0s' $(seq 1 65))" 'too-long'

# LOCALE INDEPENDENCE. The pre-#251 gate was `case "$x" in *[!a-z0-9-]*)`. A
# bracket RANGE is resolved through the locale's collating sequence, so under
# bash-as-/bin/sh with LANG=en_US.UTF-8 `a-z` collates to include the uppercase
# and accented Latin letters and the gate ACCEPTS `Laravel` and `laravel` with a
# grave accent — while the jq/JSON-Schema side of the same grammar (Oniguruma,
# codepoint ranges) rejects both. The shell gate is the one standing in front of
# the filesystem. Both idioms are recomputed live, in every shell available.
range_gate() { # the pre-#251 idiom, verbatim
	case "$1" in
		'' | -*) printf 'reject'; return ;;
		*[!a-z0-9-]*) printf 'reject' ;;
		*) printf 'accept' ;;
	esac
}
for _sh in sh dash bash; do
	command -v "$_sh" >/dev/null 2>&1 || continue
	_pre=$("$_sh" -c 'case "$1" in *[!a-z0-9-]*) printf reject ;; *) printf accept ;; esac' _ 'Laravel')
	_post=$("$_sh" -c '. "$1/scripts/lib/sentinel-shield-common.sh"; . "$1/scripts/lib/profile-schema.sh"; if ps_valid_id "$2"; then printf accept; else printf reject; fi' _ "$ROOT" 'Laravel' 2>/dev/null)
	if [ "$_pre" = "accept" ]; then
		pass "pre-#251 under $_sh: the ranged gate ACCEPTS 'Laravel' (locale collation)"
	else
		pass "observation: under $_sh the ranged gate already rejected 'Laravel' (locale/shell dependent — that dependence is the defect)"
	fi
	check "post-#251 under $_sh: 'Laravel' is rejected" "$_post" "reject"
	_post2=$("$_sh" -c '. "$1/scripts/lib/sentinel-shield-common.sh"; . "$1/scripts/lib/profile-schema.sh"; if ps_valid_id "$2"; then printf accept; else printf reject; fi' _ "$ROOT" 'php-library' 2>/dev/null)
	check "  control under $_sh: 'php-library' is still accepted" "$_post2" "accept"
done
check "the ranged-gate reconstruction is reachable (it is used above)" "$(range_gate 'php-library')" "accept"

# Hyphen/underscore and case collisions cannot survive the grammar: the folded
# form of every ACCEPTED identifier is the identifier itself, so two distinct
# accepted identifiers can never fold together.
check "hyphen and underscore spellings cannot coexist (the '_' form is rejected)" \
	"$(accepts 'php-style')/$(accepts 'php_style')" "yes/no"
check "case variants cannot coexist (the uppercase form is rejected)" \
	"$(accepts 'laravel')/$(accepts 'Laravel')" "yes/no"
check "folding is the identity on every live identifier" \
	"$(lib_sh 'while IFS= read -r _i; do [ -n "$_i" ] || continue; [ "$(ps_id_fold "$_i")" = "$_i" ] || printf "%s " "$_i"; done <<EOF
'"$_live_ids"'
EOF')" ""
check "no two live identifiers collide after normalization" \
	"$(lib_sh 'ps_id_collisions "$1" || true' "$_live_ids" 2>/dev/null)" ""

# NON-VACUITY OF THE COLLISION DETECTOR. It must actually fire, and it fires on
# the engine's OWN emit-name table, which is a real many-to-one mapping.
# Well-formed TOOL_TABLE rows only: <tool-key>|<report>.json|<collector>.sh|<emit>.
_tool_rows=$(LC_ALL=C awk -F'|' '
	{ k=$1; sub(/^.*=.?/, "", k); e=$4; gsub(/[^A-Za-z0-9_]/, "", e) }
	NF==4 && k ~ /^[a-z0-9-]+$/ && $2 ~ /\.json$/ && $3 ~ /\.sh$/ && e != "" { print k "|" e }' "$BUILD")
_n_emit=$(printf '%s\n' "$_tool_rows" | grep -c . || printf '0')
if [ "$_n_emit" -ge 60 ]; then
	pass "positive control: $_n_emit tool-key -> emit-name rows harvested from the live TOOL_TABLE"
else
	fail "only $_n_emit TOOL_TABLE rows harvested — the collision assertion below is near-vacuous"
fi
# The mapping is demonstrably many-to-one in the shipped table.
_many_to_one=$(printf '%s\n' "$_tool_rows" | LC_ALL=C awk -F'|' '
	{ if ($2 in k && k[$2] != $1) dup[$2]=k[$2] "," $1; k[$2]=$1 }
	END { for (e in dup) print e " <- " dup[e] }' | LC_ALL=C sort)
if printf '%s' "$_many_to_one" | grep -q 'php_style'; then
	pass "non-vacuity: the live emit-name map is many-to-one ($_many_to_one)"
else
	fail "the live emit-name map shows no many-to-one mapping — the collision machinery below is untestable"
fi
# The tool-key namespace and the emit-name namespace overlap after folding —
# which is exactly why `_` is outside the identifier grammar. Feed both to the
# detector and prove it fires.
_emit_col=$(lib_sh 'ps_id_collisions "$1" || true' \
	"$(printf '%s\n' "$_tool_rows" | tr '|' '\n' | LC_ALL=C sort -u)" 2>/dev/null)
if printf '%s' "$_emit_col" | grep -q 'fold=php-style'; then
	pass "non-vacuity: the collision detector fires on the live tool-key/emit-name namespaces"
else
	fail "the collision detector found nothing in a namespace that demonstrably collides: '$_emit_col'"
fi

# ---------------------------------------------------------------------------
# 3. RECONSTRUCTED PRE-#251 IDIOMS — the wrong answer, recomputed live
# ---------------------------------------------------------------------------
# 3a. Space-padded substring membership vs whole-line membership.
#     The old set for `a` and `b` is " a b "; the string "a b" is NOT a member of
#     that set, and the old idiom says it is.
padded_member() { # padded_member <member> <space-padded-set> — the pre-#251 idiom
	case " $2 " in
		*" $1 "*) printf 'yes' ;;
		*) printf 'no' ;;
	esac
}
_old_member=$(padded_member "a b" " a b ")
check "pre-#251: space-padded membership claims 'a b' is a member of {a,b}" "$_old_member" "yes"
check "post-#251: whole-line membership does not" \
	"$(lib_sh 'if ps_set_has "a b" "a
b"; then printf yes; else printf no; fi')" "no"

#     And the converse: a real member is still found.
check "post-#251: a real member is still found (the guard is not always-false)" \
	"$(lib_sh 'if ps_set_has "b" "a
b"; then printf yes; else printf no; fi')" "yes"
check "post-#251: a prefix of a member is NOT a member" \
	"$(lib_sh 'if ps_set_has "pest" "pest-parallel
phpunit"; then printf yes; else printf no; fi')" "no"
check "post-#251: deleting one member leaves the rest intact" \
	"$(lib_sh 'ps_set_del "b" "a
b
c" | tr "\n" ","')" "a,c"

# 3b. Word splitting + glob expansion of a JSON array in command substitution.
#     Reconstructed verbatim, in a directory seeded to make the glob bite.
GLOBDIR="$TMP/globdir"; mkdir -p "$GLOBDIR"
: > "$GLOBDIR/php-library"; : > "$GLOBDIR/php-tests"
printf '["a b","php-*"]' > "$GLOBDIR/arr.json"
_old_words=$( cd "$GLOBDIR" && set +e; _n=0
	# shellcheck disable=SC2046,SC2086
	for _w in $(jq -r '.[]' arr.json); do _n=$((_n + 1)); done; printf '%s' "$_n" )
check "pre-#251: a 2-element JSON array iterates as 4 shell words (split + glob)" "$_old_words" "4"
_new_words=$( cd "$GLOBDIR" && set +e; _n=0
	_l=$(jq -r '.[]' arr.json)
	while IFS= read -r _w; do [ -n "$_w" ] || continue; _n=$((_n + 1)); done <<EOF
$_l
EOF
	printf '%s' "$_n" )
check "post-#251: the same array iterates as exactly 2 entries" "$_new_words" "2"

# 3c. Validation ordering. The pre-#251 ep__collect tested membership BEFORE
#     validating; reconstruct both orders and show only one lets an invalid
#     identifier reach the membership decision.
pre_order_verdict() { # the pre-#251 ep__collect order: membership test, then validate
	if [ "$(padded_member "$1" " $1 ")" = "yes" ]; then printf 'membership-decided'; else printf 'validated-first'; fi
}
_pre_order=$(pre_order_verdict '../../etc')
check "pre-#251: an unvalidated identifier reached the cycle decision" "$_pre_order" "membership-decided"
_post_order=$(lib_sh 'ps_valid_id "../../etc" && printf membership-decided || printf validated-first')
check "post-#251: it is rejected before any membership decision" "$_post_order" "validated-first"

# ---------------------------------------------------------------------------
# 4. MUTATION OF A REAL TREE — the real entry points, before and after
# ---------------------------------------------------------------------------
# synth_root <name> — a synthetic profiles/ root seeded from the shipped tree.
synth_root() {
	_s="$TMP/$1"; mkdir -p "$_s/profiles/combinations"
	cp -R "$ROOT/profiles/php-library" "$_s/profiles/"
	cp -R "$ROOT/profiles/symfony" "$_s/profiles/"
	printf '%s' "$_s"
}

# --- 4a. an `extends` naming an invalid identifier ---------------------------
S=$(synth_root s-extends)
mkdir -p "$S/profiles/child"
jq '.profile = "child" | .extends = ["php library"] | .tools = {} | del(.files)' \
	"$ROOT/profiles/php-library/profile.manifest.json" > "$S/profiles/child/profile.manifest.json"
# The mutation actually applied:
check "mutation applied: child extends a name containing a space" \
	"$(jq -r '.extends[0]' "$S/profiles/child/profile.manifest.json")" "php library"
_rc=0; _err=$(EP_REPO_ROOT="$S" sh "$RES" --profile child --format json 2>&1 >/dev/null) || _rc=$?
check "an extends identifier containing a space is refused (exit 2)" "$_rc" "2"
printf '%s' "$_err" | grep -q 'INVALID_IDENTIFIER\|invalid profile identifier' \
	&& pass "  and the refusal names the identifier rule" \
	|| fail "  refused for an unrelated reason: $(printf '%s' "$_err" | head -1)"
# CONTROL: the same child with a valid parent resolves.
jq '.extends = ["php-library"]' "$S/profiles/child/profile.manifest.json" > "$S/c.tmp" \
	&& mv "$S/c.tmp" "$S/profiles/child/profile.manifest.json"
if EP_REPO_ROOT="$S" sh "$RES" --profile child --format json >/dev/null 2>&1; then
	pass "  control: the same child with a VALID parent resolves"
else
	fail "  control: a valid child no longer resolves — the rejection above proves nothing"
fi

# --- 4b. a profile present in BOTH lookup locations ---------------------------
S=$(synth_root s-dual)
mkdir -p "$S/profiles/dual"
jq '.profile = "dual" | .extends = [] | .tools = {"gitleaks": (.tools.gitleaks // {"policy":"required","execution":{"pr":true}})}' \
	"$ROOT/profiles/php-library/profile.manifest.json" > "$S/profiles/dual/profile.manifest.json"
jq '.profile = "dual" | .extends = [] | .tools = {}' \
	"$ROOT/profiles/php-library/profile.manifest.json" > "$S/profiles/combinations/dual.manifest.json"
check "mutation applied: two different manifests both claim the name 'dual'" \
	"$( [ -f "$S/profiles/dual/profile.manifest.json" ] && [ -f "$S/profiles/combinations/dual.manifest.json" ] && printf both )" "both"
# PRE-#251 lookup, reconstructed verbatim: first-wins, silently.
prefix_lookup() { # the pre-#251 open-coded two-candidate loop, first-wins
	for _c in "$1/profiles/$2/profile.manifest.json" "$1/profiles/combinations/$2.manifest.json"; do
		[ -f "$_c" ] && { printf '%s' "${_c#"$1"/}"; return 0; }
	done
	return 1
}
_pre_pick=$(prefix_lookup "$S" dual || true)
check "pre-#251: the lookup silently picked one of the two" "$_pre_pick" "profiles/dual/profile.manifest.json"
_rc=0; _err=$(EP_REPO_ROOT="$S" sh "$RES" --profile dual --format json 2>&1 >/dev/null) || _rc=$?
check "post-#251: an ambiguous profile name is refused (exit 2)" "$_rc" "2"
printf '%s' "$_err" | grep -q 'ambiguous profile' \
	&& pass "  and the refusal says the name resolves in both locations" \
	|| fail "  refused for an unrelated reason: $(printf '%s' "$_err" | head -1)"
# CONTROL: remove the duplicate and the same name resolves.
rm -f "$S/profiles/combinations/dual.manifest.json"
if EP_REPO_ROOT="$S" sh "$RES" --profile dual --format json >/dev/null 2>&1; then
	pass "  control: with the ambiguity removed, 'dual' resolves"
else
	fail "  control: 'dual' does not resolve even unambiguously"
fi

# --- 4c. a directory that matches only case-insensitively ---------------------
S=$(synth_root s-case)
mkdir -p "$S/profiles/Mixed"
jq '.profile = "mixed" | .extends = [] | .tools = {}' \
	"$ROOT/profiles/php-library/profile.manifest.json" > "$S/profiles/Mixed/profile.manifest.json"
check "mutation applied: the on-disk directory is 'Mixed'" \
	"$(ls -a "$S/profiles" | grep -Fx 'Mixed' || printf missing)" "Mixed"
# Is this filesystem case-insensitive? Recorded either way; the dirent check is
# correct on both, but the DIFFERENTIAL against `[ -f ]` only exists on one.
if [ -f "$S/profiles/mixed/profile.manifest.json" ]; then
	pass "observation: this filesystem is case-INsensitive — pre-#251 [ -f ] matched 'Mixed' for 'mixed'"
else
	pass "observation: this filesystem is case-sensitive — the pre-#251 differential is not reproducible here"
fi
check "post-#251: the dirent check refuses a case-only match on ANY filesystem" \
	"$(lib_sh 'if ps__dirent_exact "$1/profiles" mixed; then printf yes; else printf no; fi' "$S")" "no"
_rc=0; EP_REPO_ROOT="$S" sh "$RES" --profile mixed --format json >/dev/null 2>&1 || _rc=$?
check "post-#251: resolving 'mixed' against a 'Mixed' directory fails closed" "$_rc" "2"
# CONTROL: the exact-case name resolves. (`Mixed` is not a canonical identifier,
# so the control renames the directory rather than asking for the uppercase name.)
mv "$S/profiles/Mixed" "$S/profiles/mixed2" 2>/dev/null || :
jq '.profile = "mixed2"' "$S/profiles/mixed2/profile.manifest.json" > "$S/m.tmp" && mv "$S/m.tmp" "$S/profiles/mixed2/profile.manifest.json"
if EP_REPO_ROOT="$S" sh "$RES" --profile mixed2 --format json >/dev/null 2>&1; then
	pass "  control: an exact-case directory resolves"
else
	fail "  control: an exact-case directory no longer resolves"
fi

# --- 4d. a manifest whose `profile` is not the name it resolves under ---------
#     The dedup and cycle sets are keyed by the RESOLVED name. When the claimed
#     name differs, one manifest is reachable under two keys: it is merged twice
#     and a cycle through it is invisible.
S=$(synth_root s-identity)
mkdir -p "$S/profiles/alias" "$S/profiles/top"
jq '.profile = "php-library" | .extends = [] | .tools = {}' \
	"$ROOT/profiles/php-library/profile.manifest.json" > "$S/profiles/alias/profile.manifest.json"
jq '.profile = "top" | .extends = ["alias","php-library"] | .tools = {}' \
	"$ROOT/profiles/php-library/profile.manifest.json" > "$S/profiles/top/profile.manifest.json"
check "mutation applied: profiles/alias/ declares \"profile\": \"php-library\"" \
	"$(jq -r '.profile' "$S/profiles/alias/profile.manifest.json")" "php-library"
# PRE-#251: `alias` and `php-library` are two distinct dedup keys for what the
# manifests themselves call one profile, so the DAG merges it twice.
prefix_dedup_count() { # the pre-#251 space-padded dedup, keyed by RESOLVED name
	_resolved=""; _n=0
	for _p in "$@"; do
		[ "$(padded_member "$_p" "$_resolved")" = "yes" ] && continue
		_resolved="$_resolved $_p"; _n=$((_n + 1))
	done
	printf '%s' "$_n"
}
_pre_dedup=$(prefix_dedup_count alias php-library)
check "pre-#251: the same declared profile was merged under 2 distinct keys" "$_pre_dedup" "2"
_rc=0; _err=$(EP_REPO_ROOT="$S" sh "$RES" --profile top --format json 2>&1 >/dev/null) || _rc=$?
check "post-#251: a manifest that claims a different name is refused (exit 2)" "$_rc" "2"
printf '%s' "$_err" | grep -q 'profile identity mismatch' \
	&& pass "  and the refusal names the identity mismatch" \
	|| fail "  refused for an unrelated reason: $(printf '%s' "$_err" | head -1)"
# CONTROL: bind the identity and the same DAG resolves.
jq '.profile = "alias"' "$S/profiles/alias/profile.manifest.json" > "$S/a.tmp" && mv "$S/a.tmp" "$S/profiles/alias/profile.manifest.json"
if EP_REPO_ROOT="$S" sh "$RES" --profile top --format json >/dev/null 2>&1; then
	pass "  control: with the identity bound, the same DAG resolves"
else
	fail "  control: the bound DAG no longer resolves"
fi

# --- 4d2. prefix/suffix profile names stay distinct ---------------------------
#     `php` is a prefix of `php-library`, and `library` a suffix. Under the
#     space-padded dedup set those were still distinct WORDS, but the padded
#     idiom is one `case` pattern away from matching a prefix (`*"$p"*`), and the
#     cycle path is built by string concatenation. Prove all three resolve, that
#     none is deduped against another, and that all three appear in the chain.
S=$(synth_root s-prefix)
for _n in php php-library-extra; do
	mkdir -p "$S/profiles/$_n"
	jq --arg n "$_n" '.profile = $n | .extends = [] | .tools = {}' \
		"$ROOT/profiles/php-library/profile.manifest.json" > "$S/profiles/$_n/profile.manifest.json"
done
mkdir -p "$S/profiles/prefix-top"
jq '.profile = "prefix-top" | .extends = ["php","php-library","php-library-extra"] | .tools = {}' \
	"$ROOT/profiles/php-library/profile.manifest.json" > "$S/profiles/prefix-top/profile.manifest.json"
check "mutation applied: three prefix/suffix-related parents are declared" \
	"$(jq -r '.extends | join(",")' "$S/profiles/prefix-top/profile.manifest.json")" \
	"php,php-library,php-library-extra"
if EP_REPO_ROOT="$S" sh "$RES" --profile prefix-top --format json > "$TMP/prefix.json" 2>"$TMP/prefix.err"; then
	pass "prefix/suffix profile names all resolve without deduping against each other"
	check "  and the composed extends list is intact" \
		"$(jq -r '.extends | join(",")' "$TMP/prefix.json")" "php,php-library,php-library-extra"
else
	fail "prefix/suffix profile names failed to resolve: $(head -2 "$TMP/prefix.err" | tr '\n' ' ')"
fi
# A REAL self-cycle through a prefix name is still caught.
jq '.extends = ["php-library"]' "$S/profiles/php-library/profile.manifest.json" > "$S/p.tmp" \
	&& mv "$S/p.tmp" "$S/profiles/php-library/profile.manifest.json"
_rc=0; EP_REPO_ROOT="$S" sh "$RES" --profile prefix-top --format json >/dev/null 2>&1 || _rc=$?
check "  a self-reference through the longer name is still refused (exit 2)" "$_rc" "2"

# --- 4d3. recursion scoping: the profile's OWN manifest reaches the chain ------
#     POSIX sh has no function-local variables and ep__collect RECURSES, so `_p`
#     and `_mf` held the LAST PARENT's values after the `extends` loop. For every
#     profile that declares `extends`, its own manifest was never appended to
#     EP_CHAIN (its own tools, including `required` ones, silently never merged),
#     its name was never popped from EP_VISITING (a later branch reaching it
#     reported a cycle that does not exist), and the last parent was chained and
#     marked resolved twice.
S=$(synth_root s-scope)
jq '.profile="combo" | .extends=["php-library"] | .files=[] |
    .tools={"combo-only":{"policy":"required","execution":{"pr":true},"report":"reports/raw/combo-only.json"}}' \
	"$ROOT/profiles/php-library/profile.manifest.json" > "$S/profiles/combinations/combo.manifest.json"
check "mutation applied: the combination declares its OWN required tool" \
	"$(jq -r '[.tools|keys[]]|join(",")' "$S/profiles/combinations/combo.manifest.json")" "combo-only"
if EP_REPO_ROOT="$S" sh "$RES" --profile combo --format json > "$TMP/combo.json" 2>"$TMP/combo.err"; then
	check "a profile's OWN tools survive its inheritance (named entry point)" \
		"$(jq -r 'if (.tools|has("combo-only")) then "present" else "VANISHED" end' "$TMP/combo.json")" "present"
	check "  and it kept its declared policy" \
		"$(jq -r '.tools["combo-only"].policy' "$TMP/combo.json")" "required"
	check "  while the parent's tools are still merged" \
		"$(jq -r 'if (.tools|has("php-style")) then "present" else "MISSING" end' "$TMP/combo.json")" "present"
else
	fail "the combination profile did not resolve: $(head -2 "$TMP/combo.err" | tr '\n' ' ')"
fi
if EP_REPO_ROOT="$S" sh "$RES" --manifest "$S/profiles/combinations/combo.manifest.json" --format json > "$TMP/combom.json" 2>"$TMP/combom.err"; then
	check "a seed manifest's OWN tools survive its inheritance (--manifest entry point)" \
		"$(jq -r 'if (.tools|has("combo-only")) then "present" else "VANISHED" end' "$TMP/combom.json")" "present"
	check "  and --manifest read extends off the SEED, not off the last parent" \
		"$(jq -c '.extends' "$TMP/combom.json")" '["php-library"]'
else
	fail "the --manifest entry point did not resolve: $(head -2 "$TMP/combom.err" | tr '\n' ' ')"
fi
# The chain itself: every manifest exactly once, the profile's own manifest last.
_chain=$(EP_REPO_ROOT="$S" sh -c '
	. "$1/scripts/lib/sentinel-shield-common.sh"
	. "$1/scripts/lib/profile-schema.sh"
	. "$1/scripts/lib/effective-profile.sh"
	EP_CHAIN=""; EP_VISITING=""; EP_RESOLVED=""; EP_DIAG=""
	ep__collect "$EP_REPO_ROOT" combo ""
	printf "%s\n" "$EP_CHAIN" | sed "s|.*/||"
	printf "VISITING=[%s]\n" "$EP_VISITING"' _ "$ROOT" 2>/dev/null)
check "  the chain is the parent then the profile itself, each once" \
	"$(printf '%s' "$_chain" | grep -v '^VISITING' | tr '\n' ',')" \
	"profile.manifest.json,combo.manifest.json,"
check "  and the visiting stack is empty when collection ends" \
	"$(printf '%s' "$_chain" | grep '^VISITING')" "VISITING=[]"

# --- 4d4. a diamond DAG is not a cycle ---------------------------------------
#     Because the name was never popped from EP_VISITING, a second path to an
#     already-collected profile was reported as an inheritance cycle — with a
#     nonsense path. This is a plain diamond and must resolve.
S=$(synth_root s-diamond)
for _spec in 'leaf:[]' 'mid:["leaf"]' 'other:["mid"]' 'top:["mid","other"]'; do
	_dn=${_spec%%:*}; _de=${_spec#*:}
	mkdir -p "$S/profiles/$_dn"
	jq --arg n "$_dn" --argjson e "$_de" '.profile=$n | .extends=$e | .tools={} | .files=[]' \
		"$ROOT/profiles/php-library/profile.manifest.json" > "$S/profiles/$_dn/profile.manifest.json"
done
check "mutation applied: top extends mid and other, and other extends mid" \
	"$(jq -r '.extends|join(",")' "$S/profiles/top/profile.manifest.json")/$(jq -r '.extends|join(",")' "$S/profiles/other/profile.manifest.json")" \
	"mid,other/mid"
_rc=0; _err=$(EP_REPO_ROOT="$S" sh "$RES" --profile top --format json 2>&1 >/dev/null) || _rc=$?
if [ "$_rc" -eq 0 ]; then
	pass "a diamond inheritance DAG resolves and is NOT reported as a cycle"
else
	fail "a diamond DAG was refused (rc=$_rc): $(printf '%s' "$_err" | head -1)"
fi
# CONTROL: making it a REAL cycle must still be refused.
jq '.extends=["top"]' "$S/profiles/leaf/profile.manifest.json" > "$S/l.tmp" && mv "$S/l.tmp" "$S/profiles/leaf/profile.manifest.json"
_rc=0; EP_REPO_ROOT="$S" sh "$RES" --profile top --format json >/dev/null 2>&1 || _rc=$?
check "  control: turning the diamond into a real cycle is still refused (exit 2)" "$_rc" "2"

# --- 4e. a real cycle is still detected, and its path is still reported -------
FX="$ROOT/tests/fixtures/v2"
if [ -d "$FX/profiles/cycle-a" ]; then
	_rc=0; _err=$(EP_REPO_ROOT="$FX" sh "$RES" --profile cycle-a --format json 2>&1 >/dev/null) || _rc=$?
	check "regression control: a real inheritance cycle is still refused (exit 2)" "$_rc" "2"
	printf '%s' "$_err" | grep -q 'cycle-a -> cycle-b -> cycle-a' \
		&& pass "  and the cycle path is still reported" \
		|| fail "  the cycle path is no longer reported: $(printf '%s' "$_err" | head -1)"
else
	fail "the cycle fixture is missing — cycle detection is unverified"
fi

# --- 4f. an override naming an invalid tool identifier ------------------------
printf '{"tools":{"php-*":{"policy":"disabled"}}}' > "$TMP/ovr-bad.json"
_rc=0; _err=$(sh "$RES" --profile php-library --override "$TMP/ovr-bad.json" --format json 2>&1 >/dev/null) || _rc=$?
if [ "$_rc" -ne 0 ]; then
	pass "an override tool key containing a glob is refused (exit $_rc)"
else
	fail "an override tool key containing a glob was ACCEPTED"
fi

# --- 4g. the CLI entry points refuse an invalid --profile before touching disk -
for _cli in resolve-effective-profile resolve-tool-plan; do
	for _bad in '../../etc' 'php library' '-rf'; do
		_rc=0; sh "$ROOT/scripts/$_cli.sh" --profile "$_bad" --format json >/dev/null 2>&1 || _rc=$?
		if [ "$_rc" = "2" ]; then
			pass "$_cli.sh refuses --profile '$_bad' (exit 2)"
		else
			fail "$_cli.sh returned $_rc for --profile '$_bad' (want 2)"
		fi
	done
done
# CONTROL: a valid --profile still works on both.
for _cli in resolve-effective-profile resolve-tool-plan; do
	if sh "$ROOT/scripts/$_cli.sh" --profile php-library --target "$CTL" --format json >/dev/null 2>&1; then
		pass "  control: $_cli.sh still accepts a valid --profile"
	else
		fail "  control: $_cli.sh no longer accepts a valid --profile"
	fi
done

# --- 4h. emit-name collision in the policy overlay ----------------------------
#     `php-style` (php-library) and `php-cs-fixer` (symfony) are DISTINCT valid
#     identifiers that normalize to the SAME summary key. A profile extending
#     both composes both. Pre-#251 the policy overlay was a last-wins reduce, so
#     one whole row — including its gate_enforced verdict — disappeared.
_pre_lastwins=$(printf '%s\n%s\n' \
	'{"_emit":"php_style","tool":"php-style","gate_enforced":true,"status":"unavailable"}' \
	'{"_emit":"php_style","tool":"php-cs-fixer","gate_enforced":false,"status":"pass"}' \
	| jq -s -r 'reduce .[] as $o ({}; .[$o._emit] = ($o | del(._emit))) | .php_style.tool')
check "pre-#251: last-wins dropped the gate-enforced row" "$_pre_lastwins" "php-cs-fixer"

S=$(synth_root s-emit)
mkdir -p "$S/profiles/bothstyle"
jq -n --slurpfile a "$ROOT/profiles/php-library/profile.manifest.json" \
	 --slurpfile b "$ROOT/profiles/symfony/profile.manifest.json" '
	{ "$schema": ($a[0]["$schema"]), profile: "bothstyle", tool_policy_version: 2,
	  extends: [], files: [],
	  tools: { "php-style": $a[0].tools["php-style"], "php-cs-fixer": $b[0].tools["php-cs-fixer"] } }' \
	> "$S/profiles/bothstyle/profile.manifest.json"
check "mutation applied: one profile declares BOTH colliding tool keys" \
	"$(jq -r '[.tools | keys[]] | sort | join(",")' "$S/profiles/bothstyle/profile.manifest.json")" \
	"php-cs-fixer,php-style"
if EP_REPO_ROOT="$S" sh "$RES" --profile bothstyle --format json > "$TMP/bothstyle.json" 2>"$TMP/bothstyle.err"; then
	pass "  the colliding profile resolves (both identifiers are individually valid)"
	RAWD="$TMP/rawd"; mkdir -p "$RAWD"
	printf '{"status":"findings","violations":3}\n' > "$RAWD/php-style.json"
	printf '{"status":"pass","violations":0}\n'     > "$RAWD/php-cs-fixer.json"
	_rc=0
	EP_REPO_ROOT="$S" sh "$BUILD" --raw-dir "$RAWD" --output "$TMP/emit.json" \
		--profile bothstyle --target "$CTL" >"$TMP/emit.log" 2>&1 || _rc=$?
	if [ "$_rc" -eq 0 ]; then
		pass "  the summary builds with both producers present"
		check "  exactly one policy row survives the registered channel" \
			"$(jq -r '[.tools | keys[] | select(. == "php_style")] | length' "$TMP/emit.json")" "1"
		check "  and both producers are still preserved under the channel" \
			"$(jq -r '[.tools.php_style.producers[].producer] | sort | join(",")' "$TMP/emit.json")" \
			"php-cs-fixer,php-style"
		check "  the channel takes the WORST producer status, not the last one" \
			"$(jq -r '.tools.php_style.status' "$TMP/emit.json")" "findings"
	else
		fail "  the summary build failed (rc=$_rc): $(tail -3 "$TMP/emit.log" | tr '\n' ' ')"
	fi
else
	fail "  the colliding profile does not resolve: $(head -2 "$TMP/bothstyle.err" | tr '\n' ' ')"
fi
if grep -q 'group_by(._emit)' "$BUILD" && grep -q 'normalize to one summary key with no registered merger' "$BUILD"; then
	pass "post-#251: the policy overlay groups by emit name and refuses unregistered collisions"
else
	fail "the policy overlay is no longer collision-aware"
fi

# ---------------------------------------------------------------------------
# 5. NO WORD-SPLIT ITERATION OVER A JSON ARRAY OR KEY LIST
# ---------------------------------------------------------------------------
# The scanner: `for <var> in $( ... jq ... )` anywhere in the ENGINE. The scope is
# every shell script under scripts/ — not a hand-maintained list, so a new
# consumer added later is caught without editing this test. tests/ is excluded on
# purpose: a test harness that deliberately RECONSTRUCTS the defective idiom (as
# section 3 above does) must keep it, and a test is not the engine.
scan_wordsplit() { # scan_wordsplit <root> — print offending "file:line" pairs
	# `grep -n` prefixes "<line>:"; a COMMENT is a line whose first non-blank
	# character after that prefix is `#`.
	grep -rn 'for [_A-Za-z][_A-Za-z0-9]* in \$(' \
		"$1/scripts" 2>/dev/null \
		| grep 'jq ' \
		| grep -v ':[0-9][0-9]*:[[:space:]]*#' \
		| sed "s|^$1/||" || true
}

# 5a. Non-vacuity: the scanner catches a planted instance.
PLANT="$TMP/plant"; mkdir -p "$PLANT/scripts/lib"
printf '#!/bin/sh\nfor _k in $(jq -r "keys[]" x.json); do :; done\n' > "$PLANT/scripts/lib/planted.sh"
_planted=$(scan_wordsplit "$PLANT")
if [ -n "$_planted" ]; then
	pass "non-vacuity: the word-split scanner catches a planted instance"
else
	fail "the word-split scanner does not catch a planted instance — its clean result would mean nothing"
fi

# 5b. The live tree is clean.
_found=$(scan_wordsplit "$ROOT")
if [ -z "$_found" ]; then
	pass "no JSON array or key list anywhere under scripts/ is iterated by word splitting"
else
	fail "word-split iteration over jq output remains:"
	printf '%s\n' "$_found" | while IFS= read -r _l; do [ -n "$_l" ] && printf '        %s\n' "$_l"; done
fi

# 5c. The space-padded membership idiom is gone from every identifier set this
#     issue names. Same scope as 5b: all of scripts/, discovered not listed.
scan_padded() { # scan_padded <root>
	grep -rn 'case " \$EP_NON_SUPPRESSIBLE\|case " \$REQUIRE_TOOLS\|case " \$DISABLED_SET\|case " \$DISABLED_TOOLS\|case " \$ONEOF_MEMBERS\|case " \$PROTECT\|case " \$EP_VISITING\|case " \$EP_RESOLVED' \
		"$1/scripts" 2>/dev/null \
		| grep -v ':[0-9][0-9]*:[[:space:]]*#' \
		| sed "s|^$1/||" || true
}
# Non-vacuity: the padded-set scanner catches a planted instance too.
printf '#!/bin/sh\ncase " $DISABLED_SET " in *" x "*) : ;; esac\n' > "$PLANT/scripts/lib/planted2.sh"
if [ -n "$(scan_padded "$PLANT")" ]; then
	pass "non-vacuity: the padded-set scanner catches a planted instance"
else
	fail "the padded-set scanner does not catch a planted instance"
fi
_padded=$(scan_padded "$ROOT")
if [ -z "$_padded" ]; then
	pass "no identifier set under scripts/ is a space-padded string"
else
	fail "space-padded identifier sets remain:"
	printf '%s\n' "$_padded" | while IFS= read -r _l; do [ -n "$_l" ] && printf '        %s\n' "$_l"; done
fi

# 5d. The manifest chain is carried as positional parameters, not a splatted
#     space-delimited string.
if grep -q 'ep__finish "\$_profile" "\$_topmf" "\$_ovrfile" "\$_target"$' "$EPLIB" \
	&& ! grep -q 'ep__finish .* \$EP_CHAIN' "$EPLIB"; then
	pass "the manifest chain is no longer splatted from a space-delimited string"
else
	fail "the manifest chain is still passed by word splitting"
fi

printf '\n'
if [ "$FAILS" -eq 0 ]; then
	printf 'identifier-grammar: ALL CHECKS PASSED\n'
	exit 0
fi
printf 'identifier-grammar: %s CHECK(S) FAILED\n' "$FAILS"
exit 1
