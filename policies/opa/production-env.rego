# Sentinel Shield — production environment OPA policy (Conftest).
#
# Validates a production-like environment/config document (parsed .env, JSON, or
# YAML) before deploy. Input is a flat key/value object; adapt the accessors to
# your config shape.
#
# Usage:
#   conftest test prod.env.json --policy policies/opa/production-env.rego
package sentinel.production_env

import rego.v1

# Normalise: treat input as a map of string keys to values.
val(k) := input[k]

is_truthy(v) if { lower(format_int_or_str(v)) == "true" }
is_truthy(v) if { format_int_or_str(v) == "1" }

format_int_or_str(v) := s if { is_string(v); s := v }
format_int_or_str(v) := s if { is_number(v); s := sprintf("%v", [v]) }
format_int_or_str(v) := s if { is_boolean(v); s := sprintf("%v", [v]) }

# --- APP_DEBUG must not be enabled in production ---
deny contains msg if {
	is_truthy(val("APP_DEBUG"))
	msg := "APP_DEBUG must be false in production"
}

# --- NODE_ENV must be 'production' ---
deny contains msg if {
	input.NODE_ENV
	input.NODE_ENV != "production"
	msg := sprintf("NODE_ENV must be 'production', got '%v'", [input.NODE_ENV])
}

# --- Symfony APP_ENV must be 'prod' if present ---
deny contains msg if {
	input.APP_ENV
	not input.APP_ENV in {"prod", "production"}
	msg := sprintf("APP_ENV must be 'prod' in production, got '%v'", [input.APP_ENV])
}

# --- Insecure cookie flags ---
# Bind the value first: `input.KEY` as a bare expression is falsy for boolean
# false, which made the deny fail open in exactly the insecure state.
deny contains msg if {
	v := input.SESSION_SECURE_COOKIE
	not is_truthy(v)
	msg := "SESSION_SECURE_COOKIE must be true in production"
}

deny contains msg if {
	v := input.COOKIE_SECURE
	not is_truthy(v)
	msg := "COOKIE_SECURE must be true in production"
}

# --- Test / placeholder credentials must not reach production ---
test_markers := {"test", "changeme", "password", "secret", "example", "localhost", "dummy"}

deny contains msg if {
	some k
	v := input[k]
	is_string(v)
	some marker in test_markers
	lower(v) == marker
	is_credential_key(k)
	msg := sprintf("config key '%s' contains a test/placeholder value", [k])
}

is_credential_key(k) if { contains(lower(k), "password") }
is_credential_key(k) if { contains(lower(k), "secret") }
is_credential_key(k) if { contains(lower(k), "token") }
is_credential_key(k) if { contains(lower(k), "key") }
