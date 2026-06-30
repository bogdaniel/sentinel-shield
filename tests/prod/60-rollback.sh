#!/bin/sh
# tests/prod/60-rollback.sh — package-manager-aware rollback in the bootstrap engine.
#
# Fault-injects a FAILING install per package manager (npm / pnpm / yarn / composer) using
# fake-bin stubs on PATH and asserts the bootstrap engine's transactional rollback:
#   - the snapshotted manifest + the AUTHORITATIVE lockfile are restored byte-for-byte;
#   - node_modules / vendor is reconstructed with the MATCHING immutable command
#     (npm ci | pnpm install --frozen-lockfile | yarn install --immutable |
#      composer install --no-interaction --prefer-dist);
#   - NO package-manager switch occurs (the non-authoritative managers are never invoked);
#   - ambiguous multiple Node lockfiles are REJECTED (exit 2) with no mutation.
# Self-contained, network-free; creates its own mktemp fixtures and cleans up.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
BPT="$ROOT/scripts/bootstrap-profile-tools.sh"

FAILS=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILS=$((FAILS + 1)); }
check() { # desc actual expected
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi
}

# write_node_stub <path> <log> <target> <lockfile>
# A fake Node package manager: logs every invocation; SUCCEEDS the immutable
# reconstruction (ci / frozen-lockfile / immutable); on the add/install-save command it
# MUTATES the manifest+lockfile (to prove byte-for-byte restore) and FAILS (exit 1).
write_node_stub() {
	cat > "$1" <<EOF
#!/bin/sh
echo "\$*" >> "$2"
case "\$*" in
	*" ci" | *frozen-lockfile* | *immutable*) exit 0 ;;
	*)
		printf 'MUTATED-BY-FAILED-INSTALL' > "$3/package.json"
		printf 'MUTATED-BY-FAILED-INSTALL' > "$3/$4"
		echo "fake: forced install failure (\$*)" >&2
		exit 1 ;;
esac
EOF
	chmod +x "$1"
}

# node_rollback_case <pm> <lockfile> <recon_token>
# Drives bootstrap --apply for one Node manager and asserts PM-aware rollback.
node_rollback_case() {
	_pm="$1"; _lock="$2"; _recon="$3"
	_w=$(mktemp -d); _t="$_w/proj"; mkdir -p "$_t/node_modules"
	printf '{"name":"x","version":"1.0.0"}' > "$_t/package.json"
	printf 'original-lockfile-contents\n' > "$_t/$_lock"
	_op=$(cat "$_t/package.json"); _ol=$(cat "$_t/$_lock")
	_fb="$_w/bin"; mkdir -p "$_fb"
	# Stub ALL three managers so a switch would be observable in its log.
	write_node_stub "$_fb/npm"  "$_w/npm.log"  "$_t" "$_lock"
	write_node_stub "$_fb/pnpm" "$_w/pnpm.log" "$_t" "$_lock"
	write_node_stub "$_fb/yarn" "$_w/yarn.log" "$_t" "$_lock"

	_rc=0
	PATH="$_fb:$PATH" sh "$BPT" --profile node --target "$_t" --apply >/dev/null 2>&1 || _rc=$?
	check "$_pm: failed install exits non-zero (rolled back)" "$([ "$_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
	check "$_pm: package.json restored byte-for-byte" "$(cat "$_t/package.json")" "$_op"
	check "$_pm: authoritative lockfile ($_lock) restored byte-for-byte" "$(cat "$_t/$_lock")" "$_ol"

	# The authoritative manager must have been asked to do the failing install AND the
	# matching immutable reconstruction.
	if [ -s "$_w/$_pm.log" ]; then pass "$_pm: authoritative manager was invoked"; else fail "$_pm: authoritative manager was invoked"; fi
	if grep -q "$_recon" "$_w/$_pm.log" 2>/dev/null; then
		pass "$_pm: reconstruction used the MATCHING immutable command ($_recon)"
	else
		fail "$_pm: reconstruction used the MATCHING immutable command ($_recon)"
	fi

	# NO package-manager switch: every OTHER manager's log must be empty.
	for _o in npm pnpm yarn; do
		[ "$_o" = "$_pm" ] && continue
		if [ -s "$_w/$_o.log" ]; then
			fail "$_pm: no switch to $_o (its log must be empty)"
		else
			pass "$_pm: no switch to $_o"
		fi
	done
	rm -rf "$_w"
}

node_rollback_case npm  package-lock.json " ci"
node_rollback_case pnpm pnpm-lock.yaml    "install --frozen-lockfile"
node_rollback_case yarn yarn.lock         "install --immutable"

# --- composer ----------------------------------------------------------------
# Fake composer: validate ok; require MUTATES composer.json+lock then FAILS; the
# reconstruction command (install --no-interaction --prefer-dist) succeeds.
composer_rollback_case() {
	_w=$(mktemp -d); _t="$_w/proj"; mkdir -p "$_t/vendor"
	printf '{"name":"app/app","require":{}}' > "$_t/composer.json"
	printf '{"_":"original-lock"}' > "$_t/composer.lock"
	_ocj=$(cat "$_t/composer.json"); _ocl=$(cat "$_t/composer.lock")
	_fb="$_w/bin"; mkdir -p "$_fb"
	cat > "$_fb/composer" <<EOF
#!/bin/sh
echo "\$*" >> "$_w/composer.log"
case "\$*" in
	*validate*) exit 0 ;;
	*"install --no-interaction --prefer-dist"*) exit 0 ;;
	*require*)
		printf 'MUTATED' > "$_t/composer.json"
		printf 'MUTATED' > "$_t/composer.lock"
		echo "fake composer: forced require failure" >&2
		exit 1 ;;
	*) exit 0 ;;
esac
EOF
	chmod +x "$_fb/composer"
	# Stub the Node managers too, to prove composer rollback never switches to one.
	write_node_stub "$_fb/npm"  "$_w/npm.log"  "$_t" "composer.lock"
	write_node_stub "$_fb/pnpm" "$_w/pnpm.log" "$_t" "composer.lock"
	write_node_stub "$_fb/yarn" "$_w/yarn.log" "$_t" "composer.lock"

	_rc=0
	PATH="$_fb:$PATH" sh "$BPT" --profile laravel --target "$_t" --apply >/dev/null 2>&1 || _rc=$?
	check "composer: failed require exits non-zero (rolled back)" "$([ "$_rc" -ne 0 ] && echo nonzero || echo zero)" "nonzero"
	check "composer: composer.json restored byte-for-byte" "$(cat "$_t/composer.json")" "$_ocj"
	check "composer: composer.lock restored byte-for-byte" "$(cat "$_t/composer.lock")" "$_ocl"
	if grep -q 'install --no-interaction --prefer-dist' "$_w/composer.log" 2>/dev/null; then
		pass "composer: reconstruction used 'composer install --no-interaction --prefer-dist'"
	else
		fail "composer: reconstruction used 'composer install --no-interaction --prefer-dist'"
	fi
	# No switch to a Node manager during composer rollback.
	for _o in npm pnpm yarn; do
		if [ -s "$_w/$_o.log" ]; then
			fail "composer: no switch to $_o (its log must be empty)"
		else
			pass "composer: no switch to $_o"
		fi
	done
	rm -rf "$_w"
}
composer_rollback_case

# --- ambiguous multiple Node lockfiles are rejected (no guessing, no mutation) -
ambiguous_case() {
	_t=$(mktemp -d)
	printf '{"name":"x"}' > "$_t/package.json"
	printf '{}' > "$_t/package-lock.json"
	printf '' > "$_t/yarn.lock"
	_bp=$(cat "$_t/package.json"); _bl=$(cat "$_t/package-lock.json")
	_rc=0
	sh "$BPT" --profile node --target "$_t" --dry-run >/dev/null 2>&1 || _rc=$?
	check "ambiguous: multiple Node lockfiles rejected (exit 2)" "$_rc" "2"
	check "ambiguous: package.json left unchanged (no mutation)" "$(cat "$_t/package.json")" "$_bp"
	check "ambiguous: package-lock.json left unchanged (no mutation)" "$(cat "$_t/package-lock.json")" "$_bl"
	rm -rf "$_t"
}
ambiguous_case

if [ "$FAILS" -ne 0 ]; then
	printf '\n%d assertion(s) FAILED\n' "$FAILS"
	exit 1
fi
printf '\nAll rollback assertions passed.\n'
exit 0
