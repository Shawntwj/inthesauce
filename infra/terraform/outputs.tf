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
