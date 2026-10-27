variable "access_log_bucket_name" {
  description = "Existing reviewed Dev log sink, same account/region, SSE-S3, no Object Lock/default retention or Requester Pays. Destination policy remains with its owner."
  type        = string
  default     = null
  validation {
    condition     = var.access_log_bucket_name == null ? true : can(regex("^chico-dev-access-[a-z0-9-]{3,45}$", var.access_log_bucket_name))
    error_message = "Destino de acesso exclusivo Dev revisado obrigatório; não reutilizar legado/state."
  }
}
resource "aws_s3_bucket_logging" "backup" {
  count         = local.host_enabled ? 1 : 0
  bucket        = aws_s3_bucket.backup[0].id
  target_bucket = var.access_log_bucket_name
  target_prefix = "dev/backup-access/"
  lifecycle {
    precondition {
      condition     = var.access_log_bucket_name != null && var.access_log_bucket_name != var.backup_bucket_name
      error_message = "Destino de logs existente revisado, distinto da origem para evitar loop, é obrigatório."
    }
  }
}
output "access_log_delivery_review" {
  description = "Proposed statement for destination owner review. Output does not create destination or edit its policy."
  value = local.host_enabled && var.access_log_bucket_name != null ? {
    bucket = var.access_log_bucket_name
    statement = {
      Sid       = "ChicoDevBackupAccessLogs"
      Effect    = "Allow"
      Principal = { Service = "logging.s3.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "arn:aws:s3:::${var.access_log_bucket_name}/dev/backup-access/*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnEquals    = { "aws:SourceArn" = aws_s3_bucket.backup[0].arn }
      }
    }
  } : null
}
