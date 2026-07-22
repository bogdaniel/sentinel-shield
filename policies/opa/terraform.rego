# Sentinel Shield — Terraform OPA policy (Conftest against `terraform show -json`
# plan output).
#
# SCOPE: these rules read plan-JSON (`input.resource_changes`) ONLY. Raw HCL parsed with the
# hcl2 parser produces a different shape (top-level `resource` blocks) and matches nothing
# here — always evaluate the plan JSON, not the .tf sources.
#
# Usage (plan JSON):
#   terraform plan -out tfplan && terraform show -json tfplan > plan.json
#   conftest test plan.json --policy policies/opa/terraform.rego
#
# Starter rules covering common high-risk misconfigurations. Tune resource type
# names to your providers (examples use AWS).
package sentinel.terraform

import rego.v1

resources := input.resource_changes

# --- world-open ingress on SSH (22) / RDP (3389) ---
admin_ports := {22: "SSH", 3389: "RDP"}

# Normalize the three ingress shapes into a common rule:
#   - aws_security_group_rule            (standalone rule, cidr_blocks/ipv6_cidr_blocks)
#   - aws_security_group inline `ingress` blocks
#   - aws_vpc_security_group_ingress_rule (current provider idiom, cidr_ipv4/cidr_ipv6)
ingress_rules contains out if {
	some r in resources
	r.type == "aws_security_group_rule"
	after := r.change.after
	after.type == "ingress"
	out := {
		"address": r.address,
		"from_port": object.get(after, "from_port", null),
		"to_port": object.get(after, "to_port", null),
		"protocol": object.get(after, "protocol", null),
		"v4": object.get(after, "cidr_blocks", []),
		"v6": object.get(after, "ipv6_cidr_blocks", []),
	}
}

ingress_rules contains out if {
	some r in resources
	r.type == "aws_security_group"
	some ing in object.get(r.change.after, "ingress", [])
	out := {
		"address": r.address,
		"from_port": object.get(ing, "from_port", null),
		"to_port": object.get(ing, "to_port", null),
		"protocol": object.get(ing, "protocol", null),
		"v4": object.get(ing, "cidr_blocks", []),
		"v6": object.get(ing, "ipv6_cidr_blocks", []),
	}
}

ingress_rules contains out if {
	some r in resources
	r.type == "aws_vpc_security_group_ingress_rule"
	after := r.change.after
	out := {
		"address": r.address,
		"from_port": object.get(after, "from_port", null),
		"to_port": object.get(after, "to_port", null),
		"protocol": object.get(after, "ip_protocol", null),
		"v4": vpc_cidr_list(after, "cidr_ipv4"),
		"v6": vpc_cidr_list(after, "cidr_ipv6"),
	}
}

vpc_cidr_list(after, key) := [c] if { c := after[key]; c != null }

vpc_cidr_list(after, key) := [] if { object.get(after, key, null) == null }

# Open to the world over IPv4 (0.0.0.0/0) or IPv6 (::/0).
world_open(rule) if { some c in rule.v4; c == "0.0.0.0/0" }

world_open(rule) if { some c in rule.v6; c == "::/0" }

deny contains msg if {
	some rule in ingress_rules
	world_open(rule)
	some port, label in admin_ports
	rule.from_port <= port
	rule.to_port >= port
	msg := sprintf("security group rule '%s' exposes %s (%d) to the internet (0.0.0.0/0 or ::/0)", [rule.address, label, port])
}

# --- unrestricted ingress (any port from anywhere) ---
deny contains msg if {
	some rule in ingress_rules
	world_open(rule)
	unrestricted_range(rule)
	msg := sprintf("security group rule '%s' allows unrestricted ingress from the internet (0.0.0.0/0 or ::/0)", [rule.address])
}

unrestricted_range(rule) if { rule.from_port == 0; rule.to_port == 0 }

unrestricted_range(rule) if { rule.from_port == 0; rule.to_port >= 65535 }

unrestricted_range(rule) if { rule.protocol == "-1" }

# --- publicly accessible database ---
deny contains msg if {
	some r in resources
	r.type == "aws_db_instance"
	r.change.after.publicly_accessible == true
	msg := sprintf("RDS instance '%s' must not be publicly accessible", [r.address])
}

# --- public object storage (S3 ACL public) ---
deny contains msg if {
	some r in resources
	r.type == "aws_s3_bucket_acl"
	acl := r.change.after.acl
	acl in {"public-read", "public-read-write"}
	msg := sprintf("S3 bucket ACL '%s' is public (%s); buckets must be private unless explicitly classified public", [r.address, acl])
}

# --- public access block missing on a bucket (advisory) ---
warn contains msg if {
	some r in resources
	r.type == "aws_s3_bucket"
	not has_public_access_block(r.change.after.bucket)
	msg := sprintf("S3 bucket '%s' should have an aws_s3_bucket_public_access_block", [r.address])
}

has_public_access_block(bucket) if {
	some r in resources
	r.type == "aws_s3_bucket_public_access_block"
	r.change.after.bucket == bucket
}
