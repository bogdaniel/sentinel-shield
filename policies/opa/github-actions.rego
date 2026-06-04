# Sentinel Shield — GitHub Actions workflow OPA policy (Conftest).
#
# Usage:
#   conftest test .github/workflows/ci.yml --policy policies/opa/github-actions.rego
#
# Starter rules; tune to your conventions. Input is the parsed workflow YAML.
package sentinel.github_actions

import rego.v1

# --- write-all permissions are forbidden ---
deny contains msg if {
	input.permissions == "write-all"
	msg := "workflow must not use 'permissions: write-all'; set minimal permissions"
}

deny contains msg if {
	some job
	input.jobs[job].permissions == "write-all"
	msg := sprintf("job '%s' must not use 'permissions: write-all'", [job])
}

# --- pull_request_target requires explicit, reviewed approval ---
# Flag when pull_request_target is used together with checking out PR code.
deny contains msg if {
	has_trigger("pull_request_target")
	some job, i
	step := input.jobs[job].steps[i]
	startswith(object.get(step, "uses", ""), "actions/checkout")
	# Checking out a ref in pull_request_target context is the dangerous pattern.
	step.with.ref
	msg := sprintf("job '%s' checks out a ref under pull_request_target; this exposes secrets to untrusted PR code", [job])
}

# --- unpinned third-party actions in sensitive workflows ---
# Third-party (not actions/* or github/*) actions must be pinned to a 40-char SHA.
deny contains msg if {
	some job, i
	uses := input.jobs[job].steps[i].uses
	is_third_party(uses)
	not pinned_to_sha(uses)
	msg := sprintf("job '%s' uses unpinned third-party action '%s'; pin to a commit SHA", [job, uses])
}

# --- secrets interpolated into run: in PR-triggered contexts ---
warn contains msg if {
	has_trigger("pull_request")
	some job, i
	run := input.jobs[job].steps[i].run
	contains(run, "secrets.")
	msg := sprintf("job '%s' references secrets in a run step under pull_request; verify secrets are not exposed to forks", [job])
}

# --- helpers ---
has_trigger(name) if {
	input.on[name]
}

has_trigger(name) if {
	input.on == name
}

has_trigger(name) if {
	some t in input.on
	t == name
}

is_third_party(uses) if {
	not startswith(uses, "actions/")
	not startswith(uses, "github/")
	not startswith(uses, "./")
	contains(uses, "@")
}

pinned_to_sha(uses) if {
	parts := split(uses, "@")
	ref := parts[count(parts) - 1]
	regex.match("^[0-9a-f]{40}$", ref)
}
