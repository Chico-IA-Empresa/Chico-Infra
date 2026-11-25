# Chaves e canal de alerta próprios de UAT, no padrão do envs/shared/foundation.tf.
# São preservados no teardown de UAT (prevent_destroy), como rede, segredos e
# auditoria. Workers e API usam estes recursos quando a variável específica
# vier vazia, e a variável explícita sempre vence.

variable "foundation_enabled" {
  description = "Cria as CMKs e o tópico de alerta de UAT."
  type        = bool
  default     = false
}
variable "alert_emails" {
  description = "Assinaturas por e-mail do tópico de UAT; cada destinatário confirma. O canal definitivo (MON-01) é do Felipe."
  type        = set(string)
  default     = []
}

locals {
  foundation_on     = var.provision_enabled && var.foundation_enabled
  foundation_keys   = local.foundation_on ? toset(["logs", "secrets", "alerts"]) : toset([])
  account_principal = "arn:aws:iam::${var.account_id}:root"
  operations_topic  = "arn:aws:sns:sa-east-1:${var.account_id}:chico-uat-operations"
  task_failed_rule  = "arn:aws:events:sa-east-1:${var.account_id}:rule/chico-uat-workers-task-failed"
  uat_alarms        = "arn:aws:cloudwatch:sa-east-1:${var.account_id}:alarm:chico-uat-*"
  # Log groups que os blocos de UAT criam (modules/workers, web-service, api-deploy).
  uat_log_groups = [for name in ["/chico/uat/workers", "/chico/uat/api", "/chico/uat/frontend", "/aws/lambda/chico-uat-api-smoke"] : "arn:aws:logs:sa-east-1:${var.account_id}:log-group:${name}"]

  key_statements = {
    logs = [
      {
        Sid       = "RegionalLogEncryption", Effect = "Allow", Principal = { Service = "logs.sa-east-1.amazonaws.com" },
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"], Resource = "*",
        Condition = { StringEquals = { "kms:EncryptionContext:aws:logs:arn" = local.uat_log_groups } }
      },
      {
        # DescribeKey não tem contexto de cifra; uso criptográfico continua preso ao ARN exato do log group.
        Sid    = "RegionalLogKeyMetadata", Effect = "Allow", Principal = { Service = "logs.sa-east-1.amazonaws.com" },
        Action = ["kms:DescribeKey"], Resource = "*"
      }
    ]
    secrets = [] # Delegação à conta; uso por papel exige kms:Decrypt explícito (workers-iam, api-deploy).
    alerts = [
      {
        Sid       = "UatAlarmEncryption", Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" },
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"], Resource = "*",
        Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = local.uat_alarms } }
      },
      {
        Sid       = "WorkerTaskFailedEncryption", Effect = "Allow", Principal = { Service = "events.amazonaws.com" },
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"], Resource = "*",
        Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnEquals = { "aws:SourceArn" = local.task_failed_rule } }
      }
    ]
  }
}

resource "aws_kms_key" "uat" {
  for_each                = local.foundation_keys
  description             = "Chico UAT ${each.key}; managed by uat root"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    [{ Sid = "AccountRecoveryAndIAMDelegation", Effect = "Allow", Principal = { AWS = local.account_principal }, Action = "kms:*", Resource = "*" }],
    local.key_statements[each.key],
  ) })
  lifecycle {
    prevent_destroy = true
  }
  depends_on = [module.funding]
}

resource "aws_kms_alias" "uat" {
  for_each      = local.foundation_keys
  name          = "alias/chico/uat/${each.key}"
  target_key_id = aws_kms_key.uat[each.key].key_id
}

resource "aws_sns_topic" "operations" {
  count             = local.foundation_on ? 1 : 0
  name              = "chico-uat-operations"
  kms_master_key_id = aws_kms_key.uat["alerts"].arn
  tags              = { env = "uat" }
  lifecycle {
    prevent_destroy = true
  }
}

# Só os alarmes chico-uat-* (ALB, workers, DLQ dos schedules) e a regra de task
# parada dos workers publicam aqui.
resource "aws_sns_topic_policy" "operations" {
  count = local.foundation_on ? 1 : 0
  arn   = aws_sns_topic.operations[0].arn
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    {
      Sid       = "UatAlarmsOnly", Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = "sns:Publish",
      Resource  = local.operations_topic,
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = local.uat_alarms } }
    },
    {
      Sid       = "WorkerTaskFailedRuleOnly", Effect = "Allow", Principal = { Service = "events.amazonaws.com" }, Action = "sns:Publish",
      Resource  = local.operations_topic,
      Condition = { ArnEquals = { "aws:SourceArn" = local.task_failed_rule } }
    }
  ] })
}

resource "aws_sns_topic_subscription" "operations" {
  for_each   = local.foundation_on ? toset([for index in range(length(var.alert_emails)) : tostring(index)]) : toset([])
  topic_arn  = aws_sns_topic.operations[0].arn
  protocol   = "email"
  endpoint   = sort(tolist(var.alert_emails))[tonumber(each.key)]
  depends_on = [aws_sns_topic_policy.operations]
}

locals {
  # Variável explícita vence; sem ela, o recurso de UAT (quando existe).
  uat_logs_key_arn    = try(aws_kms_key.uat["logs"].arn, null)
  uat_secrets_key_arn = var.secrets_key_arn != null ? var.secrets_key_arn : try(aws_kms_key.uat["secrets"].arn, null)
  uat_alarm_topics    = local.foundation_on ? [aws_sns_topic.operations[0].arn] : []
}

output "foundation" {
  value = local.foundation_on ? {
    kms_key_arns     = { for name, key in aws_kms_key.uat : name => key.arn }
    operations_topic = aws_sns_topic.operations[0].arn
  } : null
}
