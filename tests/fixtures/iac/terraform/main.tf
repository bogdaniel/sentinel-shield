# Sentinel Shield test fixture — minimal Terraform for Checkov / Terrascan.
# This is intentionally simple, parseable IaC so IaC scanners have something
# to scan. It is NOT a production module and should never be applied.

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "fixture" {
  bucket = "sentinel-shield-fixture-bucket"

  tags = {
    Name      = "sentinel-shield-fixture"
    ManagedBy = "sentinel-shield-tests"
  }
}

resource "aws_s3_bucket_versioning" "fixture" {
  bucket = aws_s3_bucket.fixture.id

  versioning_configuration {
    status = "Enabled"
  }
}
