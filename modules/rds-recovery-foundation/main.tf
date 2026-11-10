variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Explicit target account required."
  }
}
variable "create_key" {
  type    = bool
  default = false
}
variable "external_key_arn" {
  type    = string
  default = null
}
variable "storage_enabled" {
  type    = bool
  default = false
}
variable "bucket_name" {
  type    = string
  default = null
  validation {
    condition     = !var.storage_enabled || try(var.bucket_name == "chico-prod-recovery-${var.account_id}-sa-east-1", false)
    error_message = "Use the dedicated Prod recovery bucket, never the legacy or Dev bucket."
  }
}
locals {
  key_arn = var.create_key ? aws_kms_key.data[0].arn : var.external_key_arn
  log_groups = [
    "arn:aws:logs:sa-east-1:${var.account_id}:log-group:/aws/rds/instance/chico-prod/postgresql",
    "arn:aws:logs:sa-east-1:${var.account_id}:log-group:/aws/rds/instance/chico-prod-recovery-proof/postgresql",
    "arn:aws:logs:sa-east-1:${var.account_id}:log-group:/chico/prod/rds-importer",
  ]
}
resource "aws_kms_key" "data" {
  count                   = var.create_key ? 1 : 0
  description             = "Chico Prod RDS and private recovery artifacts"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountIAMDelegation"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "EncryptOnlyProdDatabaseAndImporterLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.sa-east-1.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
        Condition = { ArnEquals = { "kms:EncryptionContext:aws:logs:arn" = local.log_groups } }
      },
    ]
  })
  lifecycle { prevent_destroy = true }
}
resource "aws_kms_alias" "data" {
  count         = var.create_key ? 1 : 0
  name          = "alias/chico/prod/data"
  target_key_id = aws_kms_key.data[0].key_id
}
resource "aws_s3_bucket" "artifacts" {
  count         = var.storage_enabled ? 1 : 0
  bucket        = var.bucket_name
  force_destroy = false
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = try(startswith(local.key_arn, "arn:aws:kms:sa-east-1:${var.account_id}:key/"), false)
      error_message = "Prod artifacts require an explicit CMK in the target account and region."
    }
  }
}
resource "aws_s3_bucket_public_access_block" "artifacts" {
  count                   = var.storage_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
module "access_logs" {
  count             = var.storage_enabled ? 1 : 0
  source            = "../access-log-sink"
  bucket_name       = "chico-prod-recovery-access-${var.account_id}-sa-east-1"
  source_bucket_arn = aws_s3_bucket.artifacts[0].arn
  account_id        = var.account_id
  delivery_prefix   = "prod/recovery-access/"
  retention_days    = 30
}
resource "aws_s3_bucket_logging" "artifacts" {
  count         = var.storage_enabled ? 1 : 0
  bucket        = aws_s3_bucket.artifacts[0].id
  target_bucket = module.access_logs[0].bucket_name
  target_prefix = "prod/recovery-access/"
}
resource "aws_s3_bucket_ownership_controls" "artifacts" {
  count  = var.storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_versioning" "artifacts" {
  count  = var.storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  count  = var.storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = local.key_arn
    }
  }
}
resource "aws_s3_bucket_policy" "artifacts" {
  count  = var.storage_enabled ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.artifacts[0].arn, "${aws_s3_bucket.artifacts[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyExplicitNonKmsEncryption"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.artifacts[0].arn}/*"
        Condition = {
          Null            = { "s3:x-amz-server-side-encryption" = "false" }
          StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
        }
      },
      {
        Sid       = "DenyExplicitForeignKmsKey"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.artifacts[0].arn}/*"
        Condition = {
          Null            = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = "false" }
          StringNotEquals = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = local.key_arn }
        }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.artifacts]
}
output "key_arn" { value = local.key_arn }
output "bucket_name" { value = try(aws_s3_bucket.artifacts[0].id, null) }
