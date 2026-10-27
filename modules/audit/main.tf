variable "bucket_name" { type = string }
variable "account_id" { type = string }
variable "access_log_bucket_name" { type = string }
resource "aws_s3_bucket_logging" "audit" {
  bucket        = aws_s3_bucket.audit.id
  target_bucket = var.access_log_bucket_name
  target_prefix = "access/audit/"
  lifecycle {
    precondition {
      condition     = var.bucket_name != var.access_log_bucket_name
      error_message = "Auditoria não pode ser destino de seus próprios logs."
    }
  }
}
variable "kms_key_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:kms:sa-east-1:${var.account_id}:key/[a-zA-Z0-9-]+$", var.kms_key_arn))
    error_message = "Chave de auditoria explícita com key policy CloudTrail revisada obrigatória."
  }
}
resource "aws_s3_bucket" "audit" {
  bucket        = var.bucket_name
  force_destroy = false
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
  }
}
locals { trail_arn = "arn:aws:cloudtrail:sa-east-1:${var.account_id}:trail/chico-audit" }
resource "aws_cloudwatch_log_group" "audit" {
  name              = "/chico/shared/audit"
  retention_in_days = 30
  kms_key_id        = var.kms_key_arn
}
resource "aws_iam_role" "delivery" {
  name = "chico-shared-audit-delivery"
  path = "/chico/shared/"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "sts:AssumeRole",
    Condition = { StringEquals = { "aws:SourceAccount" = var.account_id, "aws:SourceArn" = local.trail_arn } }
  }] })
}
resource "aws_iam_role_policy" "delivery" {
  role = aws_iam_role.delivery.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect   = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"],
    Resource = "${aws_cloudwatch_log_group.audit.arn}:log-stream:${var.account_id}_CloudTrail_*"
  }] })
}
resource "aws_sns_topic" "audit" {
  name              = "chico-shared-audit-events"
  kms_master_key_id = var.kms_key_arn
}
resource "aws_sns_topic_policy" "audit" {
  arn = aws_sns_topic.audit.arn
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Sid       = "CloudTrailPublish", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" },
    Action    = "sns:Publish", Resource = aws_sns_topic.audit.arn,
    Condition = { StringEquals = { "aws:SourceAccount" = var.account_id, "aws:SourceArn" = local.trail_arn } }
  }] })
}
resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "AclCheck", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:GetBucketAcl", Resource = aws_s3_bucket.audit.arn,
    Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } } },
    { Sid = "Write", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" }, Action = "s3:PutObject", Resource = "${aws_s3_bucket.audit.arn}/AWSLogs/${var.account_id}/*",
    Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn, "s3:x-amz-acl" = "bucket-owner-full-control" } } },
    { Sid = "Transport", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"],
    Condition = { Bool = { "aws:SecureTransport" = "false" } } }
  ] })
}
resource "aws_cloudtrail" "audit" {
  name                          = "chico-audit"
  s3_bucket_name                = aws_s3_bucket.audit.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  enable_logging                = true
  kms_key_id                    = var.kms_key_arn
  cloud_watch_logs_group_arn    = "${aws_cloudwatch_log_group.audit.arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.delivery.arn
  sns_topic_name                = aws_sns_topic.audit.arn
  depends_on                    = [aws_s3_bucket_policy.audit, aws_iam_role_policy.delivery, aws_sns_topic_policy.audit]
  lifecycle { prevent_destroy = true }
}
output "delivery" {
  value = { log_group = aws_cloudwatch_log_group.audit.name, topic_arn = aws_sns_topic.audit.arn, trail_arn = local.trail_arn }
}
