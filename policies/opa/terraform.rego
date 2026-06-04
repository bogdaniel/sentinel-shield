# Sentinel Shield — Terraform OPA policy (Conftest against `terraform show -json`
# plan output, or HCL via the conftest hcl2 parser).
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

# --- 0.0.0.0/0 ingress on SSH (22) / RDP (3389) ---
deny contains msg if {
	some r in resources
	r.type == "aws_security_group_rule"
	after := r.change.after
	after.type == "ingress"
	some cidr in after.cidr_blocks
	cidr == "0.0.0.0/0"
	after.from_port <= 22
	after.to_port >= 22
	msg := sprintf("security group rule '%s' exposes SSH to 0.0.0.0/0", [r.address])
}

# --- unrestricted ingress (any port from anywhere) ---
deny contains msg if {
	some r in resources
	r.type == "aws_security_group_rule"
	after := r.change.after
	after.type == "ingress"
	some cidr in after.cidr_blocks
	cidr == "0.0.0.0/0"
	after.from_port == 0
	after.to_port == 0
	msg := sprintf("security group rule '%s' allows unrestricted ingress from 0.0.0.0/0", [r.address])
}

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
