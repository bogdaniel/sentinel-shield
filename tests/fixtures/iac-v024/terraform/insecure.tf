# Sentinel Shield v0.1.24 IaC fixture (intentionally insecure).
# Representative Terraform with public-read S3 bucket and a wide-open security
# group. Used to exercise IaC scanners (checkov/terrascan/conftest) — NOT for
# deployment. Multiple distinct findings so scanners report >=2 violations.

provider "aws" {
  region = "us-east-1"
}

# FINDING: publicly readable S3 bucket, no encryption, no versioning, no logging.
resource "aws_s3_bucket" "public_data" {
  bucket = "sentinel-shield-fixture-public-bucket"
  acl    = "public-read" # CKV_AWS_20 — public read access
}

resource "aws_s3_bucket_public_access_block" "public_data" {
  bucket                  = aws_s3_bucket.public_data.id
  block_public_acls       = false # disables public-ACL protection
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# FINDING: security group open to the world on SSH (0.0.0.0/0:22).
resource "aws_security_group" "open_ssh" {
  name        = "sentinel-shield-fixture-open-ssh"
  description = "Intentionally insecure SG for IaC scanner fixtures"

  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # CKV_AWS_24 — ingress from 0.0.0.0/0 to port 22
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
