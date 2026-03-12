# ─────────────────────────────────────────────────────────────────
# ETRM Sandbox — Terraform config for LocalStack (fake AWS)
# Run: terraform init && terraform apply -auto-approve
# Verify: aws --endpoint-url=http://localhost:4566 s3 ls
# ─────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# LocalStack provider — all requests go to localhost:4566
provider "aws" {
  region                      = var.aws_region
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3  = var.localstack_endpoint
    ec2 = var.localstack_endpoint
    iam = var.localstack_endpoint
  }
}

# ── S3 Buckets ────────────────────────────────────────────────────
# In production: stores trade payloads, curve files, audit logs
resource "aws_s3_bucket" "payloads" {
  bucket = "etrm-payloads"
  tags = {
    Environment = "sandbox"
    Purpose     = "Trade payload archive"
  }
}

resource "aws_s3_bucket" "curves" {
  bucket = "etrm-curves"
  tags = {
    Environment = "sandbox"
    Purpose     = "MTM curve snapshots"
  }
}

resource "aws_s3_bucket" "audit" {
  bucket = "etrm-audit"
  tags = {
    Environment = "sandbox"
    Purpose     = "Audit trail logs"
  }
}

# ── S3 Bucket Versioning ──────────────────────────────────────────
# Audit bucket should keep all versions (compliance requirement)
resource "aws_s3_bucket_versioning" "audit_versioning" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration {
    status = "Enabled"
  }
}

# ── S3 Lifecycle Rules ────────────────────────────────────────────
# Move old payloads to cheaper storage after 90 days
resource "aws_s3_bucket_lifecycle_configuration" "payloads_lifecycle" {
  bucket = aws_s3_bucket.payloads.id

  rule {
    id     = "archive-old-payloads"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}
