output "s3_buckets" {
  description = "Created S3 bucket names"
  value = {
    payloads = aws_s3_bucket.payloads.bucket
    curves   = aws_s3_bucket.curves.bucket
    audit    = aws_s3_bucket.audit.bucket
  }
}

output "audit_versioning_status" {
  description = "Audit bucket versioning status"
  value       = aws_s3_bucket_versioning.audit_versioning.versioning_configuration[0].status
}

# ── VPC Outputs ──────────────────────────────────────────────────
output "vpc_id" {
  description = "ETRM VPC ID"
  value       = aws_vpc.etrm.id
}

output "subnets" {
  description = "Subnet IDs by tier"
  value = {
    public = aws_subnet.public.id
    app    = aws_subnet.app.id
    data   = aws_subnet.data.id
  }
}

output "subnet_cidrs" {
  description = "Subnet CIDR blocks by tier"
  value = {
    public = aws_subnet.public.cidr_block
    app    = aws_subnet.app.cidr_block
    data   = aws_subnet.data.cidr_block
  }
}

output "security_groups" {
  description = "Security group IDs by tier"
  value = {
    app_tier  = aws_security_group.app_tier.id
    data_tier = aws_security_group.data_tier.id
  }
}
