variable "foundation_enabled" {
  description = "Create shared-owned CMKs and operational topic in the reviewed initial shared wave."
  type        = bool
  default     = false
}
locals {
  foundation_enabled   = var.provision_enabled && var.foundation_enabled
  foundation_keys      = local.foundation_enabled ? toset(["audit", "logs", "secrets", "alerts"]) : toset([])
  account_principal    = "arn:aws:iam::${var.account_id}:root"
  audit_trail_arn      = "arn:aws:cloudtrail:sa-east-1:${var.account_id}:trail/chico-audit"
  audit_topic_arn      = "arn:aws:sns:sa-east-1:${var.account_id}:chico-shared-audit-events"
  operations_topic_arn = "arn:aws:sns:sa-east-1:${var.account_id}:chico-dev-operations"
  dev_alarm_arns = [for name in ["host-status", "MemoryUsedPercent", "DiskUsedPercent", "BackupAgeHours", "cpu"] :
    "arn:aws:cloudwatch:sa-east-1:${var.account_id}:alarm:chico-dev-${name}"
  ]
  log_contexts = {
    audit = ["arn:aws:logs:sa-east-1:${var.account_id}:log-group:/chico/shared/audit"]
    logs  = [for name in ["bootstrap", "ssm", "proxy", "backup", "flow"] : "arn:aws:logs:sa-east-1:${var.account_id}:log-group:/chico/dev/${name}"]
  }
  key_statements = {
    audit = [
      {
        Sid       = "TrailEncryption", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" },
        Action    = ["kms:GenerateDataKey*"], Resource = "*",
        Condition = { StringEquals = { "aws:SourceArn" = local.audit_trail_arn }, StringLike = { "kms:EncryptionContext:aws:cloudtrail:arn" = local.audit_trail_arn } }
      },
      {
        Sid    = "TrailKeyMetadata", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" },
        Action = ["kms:DescribeKey"], Resource = "*", Condition = { StringEquals = { "aws:SourceArn" = local.audit_trail_arn } }
      },
      {
        Sid       = "TrailTopicEncryption", Effect = "Allow", Principal = { Service = "cloudtrail.amazonaws.com" },
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"], Resource = "*",
        Condition = { StringEquals = { "aws:SourceAccount" = var.account_id, "aws:SourceArn" = local.audit_trail_arn, "kms:EncryptionContext:aws:sns:topicArn" = local.audit_topic_arn } }
      }
    ]
    logs    = []
    secrets = [] # Account delegation still requires a scoped identity grant, ViaService and SecretARN context.
    alerts = [{
      Sid       = "DevAlarmEncryption", Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" },
      Action    = ["kms:GenerateDataKey*", "kms:Decrypt"], Resource = "*",
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnEquals = { "aws:SourceArn" = local.dev_alarm_arns } }
    }]
  }
  audit_encryption_key_arn = local.foundation_enabled ? aws_kms_key.foundation["audit"].arn : var.audit_kms_key_arn
}
resource "aws_kms_key" "foundation" {
  for_each                = local.foundation_keys
  description             = "Chico ${each.key == "audit" ? "shared audit" : "Dev ${each.key}"}; managed by shared root"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    [{ Sid = "AccountRecoveryAndIAMDelegation", Effect = "Allow", Principal = { AWS = local.account_principal }, Action = "kms:*", Resource = "*" }],
    local.key_statements[each.key],
    contains(keys(local.log_contexts), each.key) ? [{
      Sid       = "RegionalLogEncryption", Effect = "Allow", Principal = { Service = "logs.sa-east-1.amazonaws.com" },
      Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"], Resource = "*",
      Condition = { StringEquals = { "kms:EncryptionContext:aws:logs:arn" = local.log_contexts[each.key] } }
    }] : [],
    contains(keys(local.log_contexts), each.key) ? [{
      # DescribeKey has no encryption context. This service-only statement permits
      # metadata on this key; cryptographic use still requires the exact log ARN.
      Sid    = "RegionalLogKeyMetadata", Effect = "Allow", Principal = { Service = "logs.sa-east-1.amazonaws.com" },
      Action = ["kms:DescribeKey"], Resource = "*"
    }] : []
  ) })
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = var.audit_kms_key_arn == null
      error_message = "Foundation cria a chave audit; reconciliar/importar antes de informar chave externa concorrente."
    }
  }
  depends_on = [module.funding]
}
resource "aws_kms_alias" "foundation" {
  for_each      = local.foundation_keys
  name          = each.key == "audit" ? "alias/chico/shared/audit" : "alias/chico/dev/${each.key}"
  target_key_id = aws_kms_key.foundation[each.key].key_id
}
resource "aws_sns_topic" "dev_operations" {
  count             = local.foundation_enabled ? 1 : 0
  name              = "chico-dev-operations"
  kms_master_key_id = aws_kms_key.foundation["alerts"].arn
  tags              = { env = "dev" }
}
resource "aws_sns_topic_policy" "dev_operations" {
  count = local.foundation_enabled ? 1 : 0
  arn   = aws_sns_topic.dev_operations[0].arn
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Sid       = "DevAlarmsOnly", Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = "sns:Publish",
    Resource  = local.operations_topic_arn,
    Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnEquals = { "aws:SourceArn" = local.dev_alarm_arns } }
  }] })
}
resource "aws_sns_topic_subscription" "dev_operations" {
  for_each   = local.foundation_enabled ? toset([for index in range(length(var.alert_emails)) : tostring(index)]) : toset([])
  topic_arn  = aws_sns_topic.dev_operations[0].arn
  protocol   = "email"
  endpoint   = sort(tolist(var.alert_emails))[tonumber(each.key)]
  depends_on = [aws_sns_topic_policy.dev_operations]
}
output "foundation" {
  value = local.foundation_enabled ? {
    kms_key_arns       = { for name, key in aws_kms_key.foundation : name => key.arn }
    operations_topic   = aws_sns_topic.dev_operations[0].arn
    subscription_count = length(aws_sns_topic_subscription.dev_operations)
  } : null
}
