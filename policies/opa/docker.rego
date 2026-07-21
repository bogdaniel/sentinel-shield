# Sentinel Shield — Docker / Compose OPA policy (for use with Conftest).
#
# Usage:
#   conftest test docker-compose.yml --policy policies/opa/docker.rego
#   conftest test Dockerfile --parser dockerfile --policy policies/opa/docker.rego
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
deny contains msg if {
	some name
	svc := input.services[name]
	svc.user == "root"
	msg := sprintf("service '%s' must not run as root user", [name])
}

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
