#!/bin/sh
# Sentinel Shield — canonical effective-profile resolver CLI (v2).
#
# Emits the ONE composed, override-aware effective tool policy for a profile as
# JSON. This is the single source every v2 subsystem consumes; no other script
# may implement its own composition (Significant fix 11). See
# scripts/lib/effective-profile.sh and docs/workflow-execution-model.md.
#
# Usage:
#   resolve-effective-profile.sh --profile <name> [--target <dir>]
#       [--override <path>] [--format json]
#
#   --profile <name>   Profile to resolve (profiles/<name>/ or combinations/).
#   --target <dir>     Consuming project root; enables applicability + one-of
#                      satisfaction detection. Optional.
#   --override <path>  Project tool-policy override (.sentinel-shield/tool-policy.yaml
#                      or .json). Parsed to JSON and schema-validated before use.
#   --format json      Output format (only json today).
#
# Exit codes (shared v2 contract — docs/workflow-execution-model.md#exit-codes):
#   0  effective profile emitted
#   2  invalid invocation / unknown|missing|invalid parent / cycle / invalid
#      policy / invalid override
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/lib/sentinel-shield-common.sh
. "$SCRIPT_DIR/lib/sentinel-shield-common.sh"
# shellcheck source=scripts/lib/effective-profile.sh
. "$SCRIPT_DIR/lib/effective-profile.sh"
# tool-policy-override.sh provides tpo_to_json (YAML/JSON -> validated JSON), if present.
if [ -f "$SCRIPT_DIR/lib/tool-policy-override.sh" ]; then
	# shellcheck source=scripts/lib/tool-policy-override.sh
	. "$SCRIPT_DIR/lib/tool-policy-override.sh"
fi

usage() { printf 'Usage: resolve-effective-profile.sh (--profile <name> | --manifest <path>) [--target <dir>] [--override <path>] [--waivers <path>] [--format json]\n'; }

PROFILE=""; MANIFEST=""; TARGET=""; OVERRIDE=""; WAIVERS=""; FORMAT="json"
while [ $# -gt 0 ]; do
	case "$1" in
		--profile) PROFILE="${2:?--profile requires a value}"; shift 2 ;;
		--manifest) MANIFEST="${2:?--manifest requires a value}"; shift 2 ;;
		--target) TARGET="${2:?--target requires a value}"; shift 2 ;;
		--override) OVERRIDE="${2:?--override requires a value}"; shift 2 ;;
		--waivers) WAIVERS="${2:?--waivers requires a value}"; shift 2 ;;
		--format) FORMAT="${2:?--format requires a value}"; shift 2 ;;
		-h | --help) usage; exit 0 ;;
		*) log_error "unknown argument: $1"; usage >&2; exit 2 ;;
	esac
done

# (B15) --profile and --manifest are mutually exclusive; exactly one is required.
if [ -n "$PROFILE" ] && [ -n "$MANIFEST" ]; then
	log_error "--profile and --manifest are mutually exclusive"; usage >&2; exit 2
fi
[ -n "$PROFILE" ] || [ -n "$MANIFEST" ] || { log_error "one of --profile or --manifest is required"; usage >&2; exit 2; }
case "$FORMAT" in json) ;; *) log_error "--format must be: json"; exit 2 ;; esac
command_exists jq || { log_error "jq is required"; exit 2; }

# Normalize an explicit override to JSON (+ schema-validate) via the canonical
# override validator ONLY. (B14) If that validator is unavailable we MUST NOT
# accept a raw .json override unvalidated — fail closed.
OVR_JSON=""
if [ -n "$OVERRIDE" ]; then
	[ -f "$OVERRIDE" ] || { log_error "override file not found: $OVERRIDE"; exit 2; }
	command -v tpo_load >/dev/null 2>&1 || { log_error "tool-policy override validator (scripts/lib/tool-policy-override.sh: tpo_load) is unavailable; refusing to apply an unvalidated override"; exit 2; }
	OVR_JSON=$(mktemp 2>/dev/null || mktemp -t ssovr)
	# Clean the temp on ANY exit: ep_resolve/ep_resolve_manifest below can exit non-zero
	# internally, which would otherwise leak this file (the success-path rm is never reached).
	trap '[ -n "${OVR_JSON:-}" ] && [ "$OVR_JSON" != "${OVERRIDE:-}" ] && rm -f "$OVR_JSON" 2>/dev/null; true' EXIT INT TERM
	tpo_load "$OVERRIDE" > "$OVR_JSON" || { log_error "invalid tool-policy override: $OVERRIDE"; rm -f "$OVR_JSON"; exit 2; }
fi

if [ -n "$MANIFEST" ]; then
	ep_resolve_manifest "$MANIFEST" "$OVR_JSON" "$TARGET" "$WAIVERS"
else
	ep_resolve "$PROFILE" "$OVR_JSON" "$TARGET" "$WAIVERS"
fi
[ -n "$OVERRIDE" ] && [ "$OVR_JSON" != "$OVERRIDE" ] && rm -f "$OVR_JSON" 2>/dev/null || true
