variable "review_bucket_name" {
  description = "Unique private saved-plan bucket, reconciled before enabling review storage."
  type        = string
  default     = null
  validation {
    condition     = var.review_bucket_name == null ? true : can(regex("^chico-infra-review-[a-z0-9-]{3,45}$", var.review_bucket_name))
    error_message = "Bucket privado exclusivo de planos com prefixo chico-infra-review-."
  }
}
variable "review_access_log_bucket_name" {
  type    = string
  default = null
}
locals { review_storage_enabled = var.provision_enabled && var.review_bucket_name != null }
module "review_access_logs" {
  count             = local.review_storage_enabled ? 1 : 0
  source            = "../../modules/access-log-sink"
  bucket_name       = var.review_access_log_bucket_name
  source_bucket_arn = "arn:aws:s3:::${var.review_bucket_name}"
  account_id        = var.account_id
  retention_days    = 30
  delivery_prefix   = "access/review/"
  depends_on        = [module.funding]
}
resource "aws_s3_bucket" "review" {
  count         = local.review_storage_enabled ? 1 : 0
  bucket        = var.review_bucket_name
  force_destroy = false
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.review_access_log_bucket_name != null && var.review_access_log_bucket_name != var.review_bucket_name
      error_message = "Destino dedicado de access logs obrigatório para planos privados."
    }
  }
  depends_on = [module.funding]
}
resource "aws_s3_bucket_public_access_block" "review" {
  count                   = local.review_storage_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.review[0].id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "review" {
  count  = local.review_storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.review[0].id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_versioning" "review" {
  count  = local.review_storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.review[0].id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "review" {
  count  = local.review_storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.review[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_policy" "review" {
  count  = local.review_storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.review[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Sid      = "RequireTLS", Effect = "Deny", Principal = "*", Action = "s3:*",
    Resource = [aws_s3_bucket.review[0].arn, "${aws_s3_bucket.review[0].arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } }
  }] })
}
resource "aws_s3_bucket_logging" "review" {
  count         = local.review_storage_enabled ? 1 : 0
  bucket        = aws_s3_bucket.review[0].id
  target_bucket = module.review_access_logs[0].bucket_name
  target_prefix = "access/review/"
}
resource "aws_s3_bucket_lifecycle_configuration" "review" {
  count  = local.review_storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.review[0].id
  rule {
    id     = "review-bundles"
    status = "Enabled"
    filter { prefix = "dev/" }
    expiration { days = 7 }
    noncurrent_version_expiration { noncurrent_days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
  rule {
    id     = "abandoned-multipart-and-markers"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
    expiration { expired_object_delete_marker = true }
  }
  depends_on = [aws_s3_bucket_versioning.review]
}
output "review_storage" {
  value = local.review_storage_enabled ? {
    bucket = aws_s3_bucket.review[0].id, access_log_bucket = module.review_access_logs[0].bucket_name,
    prefix = "dev/", retention_days = 7, noncurrent_retention_days = 7
  } : null
  depends_on = [aws_s3_bucket_public_access_block.review, aws_s3_bucket_server_side_encryption_configuration.review, aws_s3_bucket_policy.review, aws_s3_bucket_versioning.review]
}
