variable "backup_bucket_name" {
  type    = string
  default = null
  validation {
    condition     = var.backup_bucket_name == null ? true : can(regex("^chico-dev-[a-z0-9-]{3,50}$", var.backup_bucket_name))
    error_message = "Bucket exclusivo Dev com prefixo chico-dev- e nome único revisado."
  }
}
variable "fixture_backup_retention_days" {
  description = "Explicit priced retention for synthetic fixtures only, independent of Prod."
  type        = number
  default     = null
  validation {
    condition     = var.fixture_backup_retention_days == null ? true : var.fixture_backup_retention_days >= 1 && floor(var.fixture_backup_retention_days) == var.fixture_backup_retention_days
    error_message = "Retenção inteira positiva cotada/revisada obrigatória."
  }
}
variable "database_backup_retention_days" {
  description = "Real restored database retention; independent of fixtures and legacy source. Phase 1 approved 14 days."
  type        = number
  default     = null
  validation {
    condition     = var.database_backup_retention_days == null ? true : var.database_backup_retention_days == 14
    error_message = "Retenção real aprovada nesta fase: 14 dias; outra política exige revisão."
  }
}
resource "aws_s3_bucket" "backup" {
  count         = local.host_enabled ? 1 : 0
  bucket        = var.backup_bucket_name
  force_destroy = false
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.backup_bucket_name != null && var.fixture_backup_retention_days != null
      error_message = "Nome e retenção explícitos do bucket Dev cotado obrigatórios; não reutilizar legado."
    }
  }
  depends_on = [module.funding]
}
resource "aws_s3_bucket_public_access_block" "backup" {
  count                   = local.host_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.backup[0].id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "backup" {
  count  = local.host_enabled ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_versioning" "backup" {
  count  = local.host_enabled ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  count  = local.host_enabled ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_policy" "backup" {
  count  = local.host_enabled ? 1 : 0
  bucket = aws_s3_bucket.backup[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Sid = "RequireTLS", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.backup[0].arn, "${aws_s3_bucket.backup[0].arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } }] })
}
resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  count      = local.host_enabled ? 1 : 0
  bucket     = aws_s3_bucket.backup[0].id
  depends_on = [aws_s3_bucket_versioning.backup]
  rule {
    id     = "dev-fixtures"
    status = "Enabled"
    filter { prefix = "dev/fixtures/" }
    expiration { days = var.fixture_backup_retention_days }
    noncurrent_version_expiration { noncurrent_days = var.fixture_backup_retention_days }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
  dynamic "rule" {
    for_each = var.database_backup_retention_days == null ? [] : [var.database_backup_retention_days]
    content {
      id     = "dev-database"
      status = "Enabled"
      filter { prefix = "dev/database/" }
      expiration { days = rule.value }
      noncurrent_version_expiration { noncurrent_days = rule.value }
      abort_incomplete_multipart_upload { days_after_initiation = 1 }
    }
  }
}
locals { backup_prefixes = var.database_backup_retention_days == null ? ["dev/fixtures/*"] : ["dev/fixtures/*", "dev/database/*"] }
resource "aws_iam_role_policy" "backup" {
  count = local.host_enabled ? 1 : 0
  role  = aws_iam_role.runtime[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.backup[0].arn, Condition = { StringLike = { "s3:prefix" = local.backup_prefixes } } },
    { Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:GetObjectVersion", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource = [for prefix in local.backup_prefixes : "${aws_s3_bucket.backup[0].arn}/${prefix}"] }
  ] })
}
output "backup" {
  value = local.host_enabled ? { bucket = aws_s3_bucket.backup[0].id, prefix = "dev/fixtures/", retention_days = var.fixture_backup_retention_days, retained_after_shutdown = true } : null
}
output "database_backup" {
  value = local.host_enabled && var.database_backup_retention_days != null ? { bucket = aws_s3_bucket.backup[0].id, prefix = "dev/database/", retention_days = var.database_backup_retention_days, source_access = "none; separate temporary restore identity required" } : null
}
