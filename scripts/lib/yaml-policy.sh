#!/bin/sh
# Sentinel Shield — canonical YAML policy frontend (POSIX sh library).
#
# ONE parser. ONE interpretation. See docs/yaml-policy-contract.md for the full
# contract (supported subset, rejected constructs, duplicate model, key model).
#
# WHY THIS EXISTS (#259 / #260 / #264)
#
# The engine used to carry FIVE independent YAML readers, each "mikefarah yq v4 if
# installed, else a hand-written awk flatten". Those two backends did not agree:
#
#   * the awk fallbacks stripped `#` comments BEFORE interpreting quotes, so
#     `name: "a # b"` lost half its value without yq and kept it with yq;
#   * the fallbacks never removed surrounding quotes for profile scalars, so
#     `mode: "strict"` resolved to `strict` with yq and to `"strict"` (an invalid
#     mode) without it;
#   * duplicate keys collapsed LAST-wins under yq and under the override loader's
#     `jq reduce`, but FIRST-wins under every `get_scalar`-style flatten reader;
#   * `if (ci == 0) next` silently discarded any line without a colon.
#
# A file could therefore resolve to different SECURITY POLICY depending only on
# whether `yq` happened to be on PATH. Installing a convenience binary changed
# governance with no policy diff.
#
# ARCHITECTURE C — deterministic normalization frontend.
#   This library is the single semantic authority. It tokenizes the input itself,
#   detects duplicates DURING tokenization (before any object exists to collapse
#   them into), and emits one canonical JSON document. `yq` is never consulted for
#   meaning; tests may use it only as an independent oracle. There is no second
#   interpreter to drift from.
#
# Phases (kept separate on purpose — this batch owns syntax + duplicate integrity
# ONLY; profile inheritance, override semantics and gate enforcement live above):
#   read bytes -> lexical validation -> tokenization -> duplicate detection
#   -> subset validation -> canonical representation
#
# Source this file; do not execute it (it also runs as a small CLI for testing):
#   . "$SCRIPT_DIR/lib/sentinel-shield-common.sh"   # first
#   . "$SCRIPT_DIR/lib/yaml-policy.sh"
#   yp_normalize <file>            # -> canonical JSON on stdout
#   yp_validate  <file>            # -> exit 0/3, no stdout
#   yp_envelope  <file>            # -> {parser_contract,input_sha256,normalized}
#
# stdout = machine-readable JSON only. All diagnostics go to stderr.
# Exit: 0 ok; 2 invalid invocation / missing jq / unreadable file;
#       3 the input violates the canonical YAML policy contract.
#
# Errors are ONE machine-readable stderr line, and never echo file content:
#   sentinel-shield-yaml: YAML_DUPLICATE_KEY key=gates.fail_on.secrets first=12:5 second=28:5
#
# `set -eu` ONLY when executed directly (dual-use file: sourced as a lib AND run as
# a CLI). Sourced, it must not mutate the caller's shell options.
case "$0" in *yaml-policy.sh) set -eu ;; esac

# Include guard (safe to source more than once).
if [ "${__SENTINEL_SHIELD_YP_LOADED:-}" = "1" ]; then
	return 0 2>/dev/null || true
fi
__SENTINEL_SHIELD_YP_LOADED=1

# Source the shared library if the caller has not already done so. When run as a
# CLI, $0 points at this file (scripts/lib/); when sourced by a scripts/ wrapper,
# $0 points at that wrapper (scripts/), so check both shapes.
# ponytail: $0-based lookup is the only locator POSIX sh has when sourced.
if [ "${__SENTINEL_SHIELD_COMMON_LOADED:-}" != "1" ]; then
	_yp_d=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
	if [ -f "$_yp_d/sentinel-shield-common.sh" ]; then
		. "$_yp_d/sentinel-shield-common.sh"
	elif [ -f "$_yp_d/lib/sentinel-shield-common.sh" ]; then
		. "$_yp_d/lib/sentinel-shield-common.sh"
	else
		printf '%s\n' "[sentinel-shield][error] yaml-policy: cannot locate sentinel-shield-common.sh; source it first." >&2
		exit 2
	fi
fi

# The versioned contract identifier. BUMP THIS when the accepted language or the
# canonical output changes — consumers pin it so a silent grammar drift is visible.
YP_CONTRACT='sentinel-shield-yaml-subset/v1'

# Path-component separator for the awk -> jq handoff. Both this and the TAB field
# separator are CONTROL bytes that the lexer rejects in input, so neither can appear
# inside a key or a value; the transport is unambiguous by construction, not by
# escaping. This is why a key may safely contain a literal '.'.
YP_SEP=$(printf '\037')

yp__die_cfg() { log_error "yaml-policy: $*"; exit 2; }

# yp__tokenize <file> — the canonical frontend.
#
# stdout: TSV token stream, one record per line
#   K <TAB> path <TAB> type <TAB> value    scalar at path      (type: str|num|bool|null)
#   A <TAB> path <TAB> type <TAB> value    append to sequence at path
# where `path` is its components joined by \037.
# stderr: on rejection, ONE `sentinel-shield-yaml: CODE ...` line; exit 3.
#
# LC_ALL=C is mandatory, not cosmetic: it makes substr()/length() operate on BYTES,
# so reported columns are byte offsets into the original input and the accepted
# language cannot shift with the ambient locale.
yp__tokenize() {
	LC_ALL=C awk -v SEP="$YP_SEP" '
		# --- diagnostics -------------------------------------------------------
		# Errors never include the offending LINE, only its coordinates: policy
		# files sit next to secrets in CI logs.
		# ERRED is not decoration: awk runs END after `exit`, so without the flag a
		# rejection would be followed by a second, misleading END diagnostic.
		function err(code, detail) {
			printf("sentinel-shield-yaml: %s %s\n", code, detail) > "/dev/stderr"
			ERRED = 1
			exit 3
		}
		function at(l, c) { return l ":" c }

		# --- byte helpers ------------------------------------------------------
		function ord(c) { return ORD[c] }

		# utf8_bad(s) — 0 when s is well-formed UTF-8, else the 1-based byte offset
		# of the first invalid byte. jq REPLACES malformed bytes with U+FFFD instead
		# of failing, so without this check a corrupt byte would be silently and
		# lossily rewritten into the canonical output.
		function utf8_bad(s,   i, n, b, b2, need, k) {
			n = length(s); i = 1
			while (i <= n) {
				b = ord(substr(s, i, 1))
				if (b < 128) { i++; continue }
				if (b >= 194 && b <= 223) need = 1
				else if (b >= 224 && b <= 239) need = 2
				else if (b >= 240 && b <= 244) need = 3
				else return i
				if (i + need > n) return i
				for (k = 1; k <= need; k++) {
					b2 = ord(substr(s, i + k, 1))
					if (b2 < 128 || b2 > 191) return i
				}
				b2 = ord(substr(s, i + 1, 1))
				if (b == 224 && b2 < 160) return i          # overlong 3-byte
				if (b == 237 && b2 > 159) return i          # UTF-16 surrogate half
				if (b == 240 && b2 < 144) return i          # overlong 4-byte
				if (b == 244 && b2 > 143) return i          # beyond U+10FFFF
				i += need + 1
			}
			return 0
		}

		# --- scalar scanning ---------------------------------------------------
		# All scanners report through SC_val / SC_end / SC_quoted rather than a
		# return value; awk has no tuples.

		# scan_quoted(s, start, q) — s[start] is the opening quote q.
		function scan_quoted(s, start, q,   i, n, c, e, out) {
			n = length(s); out = ""; i = start + 1
			while (i <= n) {
				c = substr(s, i, 1)
				if (q == "\047") {
					if (c == "\047") {
						if (substr(s, i + 1, 1) == "\047") { out = out "\047"; i += 2; continue }
						SC_val = out; SC_end = i + 1; SC_quoted = 1; return
					}
					out = out c; i++
					continue
				}
				if (c == "\\") {
					e = substr(s, i + 1, 1)
					# Only the two escapes the contract defines. Everything else
					# (\n, \t, \uXXXX, ...) is REJECTED rather than approximated:
					# an escape that expands to a control byte would also break the
					# token transport, and no shipped policy file needs one.
					# \/ is deliberately NOT supported: YAML 1.2 permits it but go-yaml
					# (and therefore yq, the independent oracle) rejects it, and a
					# construct only WE accept is a parity gap pointing the wrong way.
					if (e == "\"") out = out "\""
					else if (e == "\\") out = out "\\"
					else err("YAML_UNSUPPORTED_ESCAPE", "escape=" e " at=" at(NR, i))
					i += 2
					continue
				}
				if (c == "\"") { SC_val = out; SC_end = i + 1; SC_quoted = 1; return }
				out = out c; i++
			}
			err("YAML_UNTERMINATED_QUOTE", "at=" at(NR, start))
		}

		# scan_plain(s, start, stops) — an unquoted scalar ending at end-of-string,
		# at " #" (a comment must be whitespace-preceded), or at any byte in `stops`
		# (flow context). Trailing spaces are trimmed.
		function scan_plain(s, start, stops,   i, n, c, out) {
			n = length(s); out = ""; i = start
			while (i <= n) {
				c = substr(s, i, 1)
				if (stops != "" && index(stops, c) > 0) break
				if (c == "#" && i > start && substr(s, i - 1, 1) == " ") { out = substr(out, 1, length(out) - 1); break }
				out = out c; i++
			}
			sub(/[ ]+$/, "", out)
			SC_val = out; SC_end = i; SC_quoted = 0
		}

		# scan_scalar(s, start, stops) — quoted or plain, rejecting the YAML the
		# contract does not accept BEFORE any value can reach policy resolution.
		function scan_scalar(s, start, stops,   c) {
			c = substr(s, start, 1)
			if (c == "\"" || c == "\047") { scan_quoted(s, start, c); return }
			if (c == "&") err("YAML_UNSUPPORTED_ANCHOR", "at=" at(NR, start))
			if (c == "*") err("YAML_UNSUPPORTED_ALIAS", "at=" at(NR, start))
			if (c == "!") err("YAML_UNSUPPORTED_TAG", "at=" at(NR, start))
			if (c == "|" || c == ">") err("YAML_UNSUPPORTED_BLOCK_SCALAR", "at=" at(NR, start))
			if (c == "[") err("YAML_UNSUPPORTED_FLOW_SEQUENCE", "at=" at(NR, start))
			# Reached only from inside a flow mapping or a sequence entry: a top-level
			# `key: {` is dispatched to flow_map() before this point.
			if (c == "{") err("YAML_UNSUPPORTED_FLOW_NESTING", "at=" at(NR, start))
			scan_plain(s, start, stops)
		}

		# --- key validation ----------------------------------------------------
		# One charset for quoted AND unquoted keys, so `mode:` and `"mode":` are the
		# SAME key rather than two spellings with two behaviours. Non-ASCII keys are
		# rejected outright, which makes NFC/NFD collisions unrepresentable instead
		# of locale-dependent.
		function check_key(k, l, c) {
			if (k == "") err("YAML_EMPTY_KEY", "at=" at(l, c))
			if (k == "<<") err("YAML_UNSUPPORTED_MERGE_KEY", "at=" at(l, c))
			if (k !~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/)
				err("YAML_INVALID_KEY", "key=" redact(k) " at=" at(l, c))
		}
		# redact(k) — keys are structural (never a secret VALUE) and are needed to
		# act on the error, but cap the length so a pathological line cannot dump
		# the file into a log.
		function redact(k) { return (length(k) > 64) ? substr(k, 1, 64) "..." : k }

		# --- paths / duplicate detection ---------------------------------------
		function joinpath(last,   i, p) {
			p = ""
			for (i = 0; i <= last; i++) p = (i == 0) ? stack[i] : p SEP stack[i]
			return p
		}
		function dotted(p) { gsub(SEP, ".", p); return p }

		# register(path, parent, l, c) — THE duplicate gate. This runs while the key
		# is still just a token; once jq/yq/an awk array has assigned it, the losing
		# value is gone and the conflict is unrecoverable.
		function register(path, parent, l, c,   lc) {
			if (path in seen)
				err("YAML_DUPLICATE_KEY", "key=" dotted(path) " first=" seen[path] " second=" at(l, c))
			lc = tolower(path)
			# `!= path` matters: without it an EXACT duplicate would also trip this
			# branch, and the two failure modes (a repeated key vs. two keys that
			# differ only in case) would report the same, wrong code.
			if (lc in seenlc && seenlc[lc] != path)
				err("YAML_AMBIGUOUS_KEY_CASE", "key=" dotted(path) " first=" seen[seenlc[lc]] " second=" at(l, c))
			seen[path] = at(l, c); seenlc[lc] = path; keyreg[path] = 1
			if (parent != "") haschild[parent] = 1
		}

		# --- typing ------------------------------------------------------------
		# Quoted is ALWAYS a string. Unquoted uses a deliberately narrow numeric
		# grammar, and ANY other spelling stays a string rather than being rejected
		# or guessed at:
		#   * yes/no/on/off stay strings — YAML 1.1 booleanising them is the single
		#     most notorious silent config change in the format;
		#   * `007` stays a string — a leading zero means the author was writing an
		#     identifier, and `7` is not what they wrote;
		#   * `1.50` and `1.0` stay strings, and integers over 15 digits stay strings,
		#     because their JSON rendering is NOT stable across jq versions/builds.
		#     Every value that does become a number therefore round-trips byte-for-byte,
		#     which is what makes the canonical form reproducible.
		function is_canon_num(raw,   d) {
			if (raw ~ /^-?(0|[1-9][0-9]*)$/) { d = raw; sub(/^-/, "", d); return (length(d) <= 15) }
			if (raw ~ /^-?(0|[1-9][0-9]*)\.[0-9]*[1-9]$/) { d = raw; gsub(/[-.]/, "", d); return (length(d) <= 15) }
			return 0
		}
		function emit(kind, path, raw, quoted) {
			if (quoted) { out(kind, path, "str", raw); return }
			if (raw == "" || raw == "null") { out(kind, path, "null", ""); return }
			if (raw == "true" || raw == "false") { out(kind, path, "bool", raw); return }
			if (is_canon_num(raw)) { out(kind, path, "num", raw); return }
			out(kind, path, "str", raw)
		}
		function out(kind, path, type, value) { printf("%s\t%s\t%s\t%s\n", kind, path, type, value) }

		# --- inline flow mapping ------------------------------------------------
		# `{ policy: optional }` is the DOCUMENTED override spelling
		# (docs/profile-tool-policy.md), so the contract keeps it — but only one
		# level deep, scalars only, and with the same duplicate gate as block form.
		function flow_map(s, start, parent, l,   i, n, c, k, kc, v, vq, path, cnt) {
			n = length(s); i = start + 1; cnt = 0
			while (1) {
				while (i <= n && substr(s, i, 1) == " ") i++
				if (i > n) err("YAML_UNTERMINATED_FLOW", "at=" at(l, start))
				c = substr(s, i, 1)
				if (c == "}") { i++; break }
				if (c == "{" || c == "[") err("YAML_UNSUPPORTED_FLOW_NESTING", "at=" at(l, i))
				kc = i
				if (c == "\"" || c == "\047") { scan_quoted(s, i, c); k = SC_val; i = SC_end }
				else { scan_plain(s, i, ":,{}[]"); k = SC_val; i = SC_end }
				check_key(k, l, kc)
				if (substr(s, i, 1) != ":") err("YAML_MALFORMED_FLOW_ENTRY", "at=" at(l, i))
				i++
				while (i <= n && substr(s, i, 1) == " ") i++
				scan_scalar(s, i, ",}")
				v = SC_val; vq = SC_quoted; i = SC_end
				path = (parent == "") ? k : parent SEP k
				register(path, parent, l, kc)
				emit("K", path, v, vq)
				hasvalue[path] = 1
				cnt++
				while (i <= n && substr(s, i, 1) == " ") i++
				c = substr(s, i, 1)
				if (c == ",") { i++; continue }
				if (c == "}") { i++; break }
				err("YAML_MALFORMED_FLOW_ENTRY", "at=" at(l, i))
			}
			FLOW_END = i
			return cnt
		}

		# ------------------------------------------------------------------------
		BEGIN {
			for (i = 1; i < 256; i++) ORD[sprintf("%c", i)] = i
			# last_open starts TRUE so the first key of the document is allowed at depth 0
			# while a first key at depth 1 still fails the `d > last_depth + 1` check.
			last_depth = -1; last_indent = -2; last_open = 1; last_path = ""
			seq_open = 0; seq_indent = -1; seq_path = ""
			saw_key = 0; ERRED = 0
		}

		{
			line = $0

			# --- lexical validation (bytes) ------------------------------------
			# Rejected control bytes are also the token-stream separators, so this
			# check is what makes the awk -> jq handoff injection-proof.
			if (line ~ /\t/) err("YAML_TAB_INDENTATION", "at=" at(NR, index(line, "\t")))
			# CR is a control byte and would be caught below, but "control character"
			# is a useless diagnosis for the common case: a file saved on Windows.
			if (line ~ /\r$/) err("YAML_CRLF_LINE_ENDING", "at=" at(NR, length(line)))
			if (line ~ /[\001-\010\013-\037\177]/) {
				match(line, /[\001-\010\013-\037\177]/)
				err("YAML_CONTROL_CHARACTER", "at=" at(NR, RSTART))
			}
			bad = utf8_bad(line)
			if (bad) err("YAML_INVALID_UTF8", "at=" at(NR, bad))

			if (line ~ /^[ ]*$/) next
			match(line, /^[ ]*/); indent = RLENGTH
			content = substr(line, indent + 1)
			if (substr(content, 1, 1) == "#") next

			if (content ~ /^---([ ]|$)/ || content ~ /^\.\.\.([ ]|$)/)
				err("YAML_UNSUPPORTED_DOCUMENT_MARKER", "at=" at(NR, indent + 1))

			if (indent % 2 != 0) err("YAML_BAD_INDENTATION", "at=" at(NR, indent + 1))
			d = indent / 2

			# --- block sequence entry ------------------------------------------
			if (content == "-" || substr(content, 1, 2) == "- ") {
				if (seq_open && indent == seq_indent) {
					# same sequence continues
				} else if (last_open && (indent == last_indent || indent == last_indent + 2)) {
					seq_open = 1; seq_indent = indent; seq_path = last_path
					if (seq_path in hasvalue)
						err("YAML_CONFLICTING_NODE", "key=" dotted(seq_path) " at=" at(NR, indent + 1))
					hasseq[seq_path] = 1
					# No `delete seqitem` here: entries are already keyed by seq_path, so
					# sequences cannot collide, and a whole-array delete is the one awk
					# construct in this file whose portability cannot be checked locally.
				} else {
					err("YAML_UNEXPECTED_SEQUENCE", "at=" at(NR, indent + 1))
				}
				if (content == "-") err("YAML_EMPTY_SEQUENCE_ITEM", "at=" at(NR, indent + 1))
				vs = indent + 3
				while (substr(line, vs, 1) == " ") vs++
				if (substr(line, vs, 1) == "#" || vs > length(line))
					err("YAML_EMPTY_SEQUENCE_ITEM", "at=" at(NR, indent + 1))
				scan_scalar(line, vs, "")
				iv = SC_val; iq = SC_quoted; ie = SC_end
				rest = substr(line, ie)
				if (rest !~ /^[ ]*$/ && rest !~ /^[ ]*#/) err("YAML_TRAILING_CONTENT", "at=" at(NR, ie))
				# `- key: value`: a sequence of MAPPINGS is not in the subset. The plain
				# scanner would happily swallow it as the string "key: value", which is
				# how a nested list entry becomes a value nobody reviews.
				if (!iq && iv ~ /: /) err("YAML_UNSUPPORTED_SEQUENCE_ITEM", "at=" at(NR, vs))
				if ((seq_path SEP iv) in seqitem)
					err("YAML_DUPLICATE_LIST_ITEM", "key=" dotted(seq_path) " first=" seqitem[seq_path SEP iv] " second=" at(NR, vs))
				seqitem[seq_path SEP iv] = at(NR, vs)
				emit("A", seq_path, iv, iq)
				last_open = 0
				next
			}

			# --- block mapping key ---------------------------------------------
			seq_open = 0; seq_indent = -1
			if (d > last_depth + 1) err("YAML_BAD_INDENTATION", "at=" at(NR, indent + 1))
			if (d == last_depth + 1 && !last_open) err("YAML_BAD_INDENTATION", "at=" at(NR, indent + 1))

			kc = indent + 1
			c0 = substr(content, 1, 1)
			if (c0 == "\"" || c0 == "\047") { scan_quoted(line, kc, c0); key = SC_val; ke = SC_end }
			else {
				ci = index(content, ":")
				if (ci == 0) err("YAML_MALFORMED_LINE", "at=" at(NR, kc))
				key = substr(content, 1, ci - 1)
				sub(/[ ]+$/, "", key)
				ke = kc + ci - 1
			}
			check_key(key, NR, kc)
			# `key : value` — the plain branch already absorbs the gap into the key and
			# trims it, so without this the QUOTED branch would reject a spelling the
			# unquoted one accepts. Two spellings of one key must not have two fates.
			while (substr(line, ke, 1) == " ") ke++
			if (substr(line, ke, 1) != ":") err("YAML_MALFORMED_LINE", "at=" at(NR, ke))

			vs = ke + 1
			if (substr(line, vs, 1) != "" && substr(line, vs, 1) != " ")
				err("YAML_MALFORMED_LINE", "at=" at(NR, vs))
			while (substr(line, vs, 1) == " ") vs++

			for (k = d; k <= 64; k++) stack[k] = ""
			stack[d] = key
			parent = (d == 0) ? "" : joinpath(d - 1)
			path = joinpath(d)
			register(path, parent, NR, kc)
			saw_key = 1
			last_depth = d; last_indent = indent; last_path = path

			tail = substr(line, vs)
			if (tail == "" || tail ~ /^#/) {
				# A block opener (children follow) OR an explicit null. Which one it
				# is cannot be known yet, so it is decided in END.
				last_open = 1
				next
			}
			last_open = 0

			if (substr(tail, 1, 1) == "{") {
				# An EMPTY inline mapping still has to materialise: `phpstan: {}` means
				# "declared with no fields", and dropping it would make the key vanish
				# from the canonical document entirely rather than fail schema validation.
				if (flow_map(line, vs, path, NR) == 0) out("O", path, "null", "")
				rest = substr(line, FLOW_END)
				if (rest !~ /^[ ]*$/ && rest !~ /^[ ]*#/) err("YAML_TRAILING_CONTENT", "at=" at(NR, FLOW_END))
				hasflow[path] = 1
				haschild[path] = 1
				next
			}

			scan_scalar(line, vs, "")
			val = SC_val; vq = SC_quoted; ve = SC_end
			rest = substr(line, ve)
			if (rest !~ /^[ ]*$/ && rest !~ /^[ ]*#/) err("YAML_TRAILING_CONTENT", "at=" at(NR, ve))
			# `a: b: c` — YAML forbids ": " inside a plain scalar; accepting it is how
			# a mistyped nested key becomes a string nobody reviews.
			if (!vq && val ~ /: /) err("YAML_AMBIGUOUS_PLAIN_SCALAR", "at=" at(NR, vs))
			emit("K", path, val, vq)
			hasvalue[path] = 1
		}

		END {
			if (ERRED) exit 3
			if (!saw_key) err("YAML_EMPTY_DOCUMENT", "at=1:1")
			# Every key that never received a scalar, a child mapping or a sequence
			# is an explicit null. Emitting it here (rather than guessing at parse
			# time) is what lets `enabled:` be REPORTED as present-but-empty instead
			# of vanishing into a default.
			for (p in keyreg)
				if (!(p in hasvalue) && !(p in haschild) && !(p in hasseq)) out("K", p, "null", "")
		}
	' "$1"
}

# yp__assemble — TSV token stream on stdin -> canonical JSON on stdout.
# jq does ALL serialization: no hand-built escaping, sorted keys (-S) for a
# deterministic byte-for-byte representation.
yp__assemble() {
	jq -S -Rn --arg sep "$YP_SEP" '
		reduce (inputs | select(length > 0) | split("\t")) as $r
			({};
				($r[1] | split($sep)) as $p
				| (if   $r[2] == "null" then null
				   elif $r[2] == "bool" then ($r[3] == "true")
				   elif $r[2] == "num"  then ($r[3] | tonumber)
				   else $r[3] end) as $v
				| if   $r[0] == "A" then setpath($p; ((getpath($p) // []) + [$v]))
				  elif $r[0] == "O" then setpath($p; {})
				  else setpath($p; $v)
				  end)
	'
}

# yp_normalize <file> — canonical JSON on stdout. 0 ok, 2 config, 3 contract error.
yp_normalize() {
	command_exists jq || yp__die_cfg "jq is required."
	[ -n "${1:-}" ] || yp__die_cfg "yp_normalize: missing file path."
	[ -f "$1" ] || yp__die_cfg "file not found: $1"
	[ -r "$1" ] || yp__die_cfg "file not readable: $1"
	# The token stream is materialised before assembly so a tokenizer rejection
	# (exit 3) is not masked by jq succeeding on a truncated pipe.
	_yp_toks=$(yp__tokenize "$1") || return 3
	printf '%s\n' "$_yp_toks" | yp__assemble || yp__die_cfg "could not assemble canonical JSON for $1"
}

# yp_validate <file> — exit 0 when the file satisfies the contract, 3 when not.
yp_validate() { yp_normalize "$1" >/dev/null; }

# yp_envelope <file> — the canonical document plus its provenance. Kept OUT of
# yp_normalize's output: the public policy JSON must stay schema-compatible, so
# parser metadata travels in this sidecar instead of inside the document.
yp_envelope() {
	_yp_doc=$(yp_normalize "$1") || return $?
	_yp_sha=$(yp__sha256 "$1") || yp__die_cfg "cannot hash $1"
	printf '%s' "$_yp_doc" | jq -S \
		--arg c "$YP_CONTRACT" --arg s "sha256:$_yp_sha" \
		'{ parser_contract: $c, input_sha256: $s, normalized: . }'
}

yp__sha256() {
	if command_exists sha256sum; then sha256sum "$1" | cut -d' ' -f1
	elif command_exists shasum; then shasum -a 256 "$1" | cut -d' ' -f1
	else yp__die_cfg "no sha256sum/shasum available."
	fi
}

# --- CLI entrypoint (only when executed directly, not when sourced) ----------
yp__usage() {
	cat <<'EOF'
usage: yaml-policy.sh <command> <file.yaml>
  normalize <file>   Print the canonical JSON representation.
  validate  <file>   Exit 0 if the file satisfies the contract, 3 if not.
  envelope  <file>   Print {parser_contract,input_sha256,normalized}.
  contract           Print the contract identifier.
EOF
}

case "$0" in
	*yaml-policy.sh)
		_cmd="${1:-}"
		case "$_cmd" in
			normalize) [ -n "${2:-}" ] || yp__die_cfg "usage: yaml-policy.sh normalize <file>"; yp_normalize "$2" || exit $? ;;
			validate) [ -n "${2:-}" ] || yp__die_cfg "usage: yaml-policy.sh validate <file>"; yp_validate "$2" || exit $? ;;
			envelope) [ -n "${2:-}" ] || yp__die_cfg "usage: yaml-policy.sh envelope <file>"; yp_envelope "$2" || exit $? ;;
			contract) printf '%s\n' "$YP_CONTRACT" ;;
			-h | --help | "") yp__usage ;;
			*) yp__die_cfg "unknown command '$_cmd' (try -h)" ;;
		esac
		;;
esac
