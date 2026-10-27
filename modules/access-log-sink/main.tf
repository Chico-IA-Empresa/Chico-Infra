variable "bucket_name" {
  type = string
  validation {
    condition     = var.bucket_name != "chico-backup" && can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Nome de sink explícito e reconciliado obrigatório; nunca adotar a origem legada."
  }
}
variable "source_bucket_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:s3:::[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.source_bucket_arn))
    error_message = "ARN exato de bucket de origem obrigatório, sem prefixos/wildcards."
  }
}
variable "account_id" { type = string }
variable "delivery_prefix" {
  description = "Exact destination prefix used by the source bucket logging configuration."
  type        = string
  default     = "access/"
  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9/_-]*/$", var.delivery_prefix)) && !strcontains(var.delivery_prefix, "//") && !strcontains(var.delivery_prefix, "..")
    error_message = "Prefixo relativo explícito sem wildcard, terminado em barra."
  }
}
variable "retention_days" {
  type = number
  validation {
    condition     = var.retention_days >= 1 && floor(var.retention_days) == var.retention_days
    error_message = "Retenção explícita e cotada obrigatória."
  }
}
resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = false
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.source_bucket_arn != "arn:aws:s3:::${var.bucket_name}"
      error_message = "Origem e destino de logs devem ser distintos."
    }
  }
}
resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "AccessLogDelivery", Effect = "Allow", Principal = { Service = "logging.s3.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.this.arn}/${var.delivery_prefix}*", Condition = { StringEquals = { "aws:SourceAccount" = var.account_id, "aws:SourceArn" = var.source_bucket_arn } } },
    { Sid = "RequireTLS", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.this.arn, "${aws_s3_bucket.this.arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ] })
}
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    id     = "access-logs"
    status = "Enabled"
    filter { prefix = var.delivery_prefix }
    expiration { days = var.retention_days }
    noncurrent_version_expiration { noncurrent_days = var.retention_days }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
  rule {
    id     = "expired-markers"
    status = "Enabled"
    filter {}
    expiration { expired_object_delete_marker = true }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
  depends_on = [aws_s3_bucket_versioning.this]
}
# This destination is deliberately not logged into itself: recursive log delivery
# amplifies requests/storage. It accepts only its explicit source and TLS.
output "bucket_name" {
  value = aws_s3_bucket.this.id
  depends_on = [
    aws_s3_bucket_policy.this,
    aws_s3_bucket_ownership_controls.this,
    aws_s3_bucket_public_access_block.this,
    aws_s3_bucket_server_side_encryption_configuration.this
  ]
}
