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

# --- unpinned third-party reusable workflows ---
# A job-level `uses:` (`jobs.<id>.uses: owner/repo/.github/workflows/x.yml@main`)
# calls a reusable workflow; third-party ones must also be pinned to a SHA.
deny contains msg if {
	some job
	uses := input.jobs[job].uses
	is_third_party(uses)
	not pinned_to_sha(uses)
	msg := sprintf("job '%s' calls unpinned third-party reusable workflow '%s'; pin to a commit SHA", [job, uses])
}

# --- secrets interpolated into PR-triggered contexts (run: or env:) ---
# pull_request_target runs against the base repo with secrets available, so it is
# the more dangerous trigger and is covered alongside pull_request.
warn contains msg if {
	pr_trigger
	some job, i
	run := input.jobs[job].steps[i].run
	contains(run, "secrets.")
	msg := sprintf("job '%s' references secrets in a run step under a pull_request/pull_request_target trigger; verify secrets are not exposed to forks", [job])
}

warn contains msg if {
	pr_trigger
	some job, i
	some _, ev in input.jobs[job].steps[i].env
	is_string(ev)
	contains(ev, "secrets.")
	msg := sprintf("job '%s' interpolates secrets into a step env: under a pull_request/pull_request_target trigger; verify secrets are not exposed to forks", [job])
}

pr_trigger if has_trigger("pull_request")

pr_trigger if has_trigger("pull_request_target")

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

# No `contains(uses, "@")` requirement: a ref-less `uses: foo/bar` resolves to
# the default branch — the most dangerous unpinned form — and must still be flagged.
is_third_party(uses) if {
	not startswith(uses, "actions/")
	not startswith(uses, "github/")
	not startswith(uses, "./")
	not startswith(uses, "docker://")
}

pinned_to_sha(uses) if {
	parts := split(uses, "@")
	ref := parts[count(parts) - 1]
	regex.match("^[0-9a-f]{40}$", ref)
}
