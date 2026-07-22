# Sentinel Shield — Docker / Compose OPA policy (for use with Conftest).
#
# Usage:
#   conftest test docker-compose.yml --policy policies/opa/docker.rego
#
# SCOPE: these rules read Compose input (`input.services`) ONLY. A Dockerfile parsed with
# `--parser dockerfile` produces a different shape and matches nothing here (it would pass
# vacuously) — use the `ss-docker-*` Semgrep rules in semgrep/app/docker/ for Dockerfiles.
#
# These are starter rules. Tune the package name and inputs to your Conftest setup.
package sentinel.docker

import rego.v1

# --- Compose: privileged containers ---
deny contains msg if {
	some name
	svc := input.services[name]
	svc.privileged == true
	msg := sprintf("service '%s' must not run privileged", [name])
}

# --- Compose: host network ---
deny contains msg if {
	some name
	svc := input.services[name]
	svc.network_mode == "host"
	msg := sprintf("service '%s' must not use host network mode", [name])
}

# --- Compose: root user ---
# `user` may be "root", "0", or a "<uid>:<gid>" form (e.g. "0:0", "root:root",
# "root:0") — all of which run as UID 0. Compare the UID part (before any colon).
deny contains msg if {
	some name
	svc := input.services[name]
	is_root_user(svc.user)
	msg := sprintf("service '%s' must not run as root user", [name])
}

user_str(u) := u if is_string(u)
user_str(u) := sprintf("%v", [u]) if is_number(u)

is_root_user(u) if { split(user_str(u), ":")[0] == "root" }
is_root_user(u) if { split(user_str(u), ":")[0] == "0" }

# --- Compose: latest image tag (or missing tag) ---
deny contains msg if {
	some name
	svc := input.services[name]
	img := svc.image
	endswith(img, ":latest")
	msg := sprintf("service '%s' uses ':latest' image tag; pin a version/digest", [name])
}

# Tag check on the LAST path segment: `registry:5000/app` contains a colon in the
# registry host but still has no tag.
deny contains msg if {
	some name
	svc := input.services[name]
	img := svc.image
	not contains(img, "@sha256:")
	parts := split(img, "/")
	not contains(parts[count(parts) - 1], ":")
	msg := sprintf("service '%s' image '%s' has no version tag; pin a version/digest", [name, img])
}

# --- Compose: missing resource limits ---
deny contains msg if {
	some name
	svc := input.services[name]
	not svc.deploy.resources.limits.memory
	not svc.mem_limit
	msg := sprintf("service '%s' must declare a memory limit", [name])
}

# --- Compose: warn on missing read-only / no-new-privileges (advisory) ---
warn contains msg if {
	some name
	svc := input.services[name]
	not svc.read_only == true
	msg := sprintf("service '%s' should set read_only: true where feasible", [name])
}
