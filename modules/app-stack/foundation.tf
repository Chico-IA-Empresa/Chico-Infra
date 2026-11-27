# Chaves e canal de alerta próprios do ambiente, no padrão do envs/shared/foundation.tf.
# São preservados no teardown de UAT (prevent_destroy), como rede, segredos e
# auditoria. Workers e API usam estes recursos quando a variável específica
# vier vazia, e a variável explícita sempre vence.

variable "foundation_enabled" {
  description = "Cria as CMKs e o tópico de alerta do ambiente."
  type        = bool
  default     = false
}
variable "alert_emails" {
  description = "Assinaturas por e-mail do tópico do ambiente; cada destinatário confirma. O canal definitivo (MON-01) é do Felipe."
  type        = set(string)
  default     = []
}

locals {
  foundation_on     = var.enabled && var.foundation_enabled
  foundation_keys   = local.foundation_on ? toset(["logs", "secrets", "alerts"]) : toset([])
  account_principal = "arn:aws:iam::${var.account_id}:root"
  operations_topic  = "arn:aws:sns:sa-east-1:${var.account_id}:chico-${var.env}-operations"
  task_failed_rule  = "arn:aws:events:sa-east-1:${var.account_id}:rule/chico-${var.env}-workers-task-failed"
  env_alarms        = "arn:aws:cloudwatch:sa-east-1:${var.account_id}:alarm:chico-${var.env}-*"
  # Log groups que os blocos do ambiente criam (modules/workers, web-service, api-deploy, edge).
  env_log_groups = [for name in ["/chico/${var.env}/workers", "/chico/${var.env}/api", "/chico/${var.env}/frontend", "/aws/lambda/chico-${var.env}-api-smoke", "aws-waf-logs-chico-${var.env}-api"] : "arn:aws:logs:sa-east-1:${var.account_id}:log-group:${name}"]

  key_statements = {
    logs = [
      {
        Sid       = "RegionalLogEncryption", Effect = "Allow", Principal = { Service = "logs.sa-east-1.amazonaws.com" },
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"], Resource = "*",
        Condition = { StringEquals = { "kms:EncryptionContext:aws:logs:arn" = local.env_log_groups } }
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
        Sid       = "${title(var.env)}AlarmEncryption", Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" },
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"], Resource = "*",
        Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = local.env_alarms } }
      },
      {
        Sid       = "WorkerTaskFailedEncryption", Effect = "Allow", Principal = { Service = "events.amazonaws.com" },
        Action    = ["kms:GenerateDataKey*", "kms:Decrypt"], Resource = "*",
        Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnEquals = { "aws:SourceArn" = local.task_failed_rule } }
      }
    ]
  }
}

resource "aws_kms_key" "this" {
  for_each                = local.foundation_keys
  description             = "Chico ${upper(var.env)} ${each.key}; managed by ${var.env} root"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({ Version = "2012-10-17", Statement = concat(
    [{ Sid = "AccountRecoveryAndIAMDelegation", Effect = "Allow", Principal = { AWS = local.account_principal }, Action = "kms:*", Resource = "*" }],
    local.key_statements[each.key],
  ) })
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "this" {
  for_each      = local.foundation_keys
  name          = "alias/chico/${var.env}/${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}

resource "aws_sns_topic" "operations" {
  count             = local.foundation_on ? 1 : 0
  name              = "chico-${var.env}-operations"
  kms_master_key_id = aws_kms_key.this["alerts"].arn
  tags              = { env = var.env }
  lifecycle {
    prevent_destroy = true
  }
}

# Só os alarmes chico-${var.env}-* (ALB, workers, DLQ dos schedules) e a regra de task
# parada dos workers publicam aqui.
resource "aws_sns_topic_policy" "operations" {
  count = local.foundation_on ? 1 : 0
  arn   = aws_sns_topic.operations[0].arn
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    {
      Sid       = "${title(var.env)}AlarmsOnly", Effect = "Allow", Principal = { Service = "cloudwatch.amazonaws.com" }, Action = "sns:Publish",
      Resource  = local.operations_topic,
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = local.env_alarms } }
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
  # Variável explícita vence; sem ela, o recurso do ambiente (quando existe).
  env_logs_key_arn    = try(aws_kms_key.this["logs"].arn, null)
  env_secrets_key_arn = var.secrets_key_arn != null ? var.secrets_key_arn : try(aws_kms_key.this["secrets"].arn, null)
  env_alarm_topics    = local.foundation_on ? [aws_sns_topic.operations[0].arn] : []
}

output "foundation" {
  value = local.foundation_on ? {
    kms_key_arns     = { for name, key in aws_kms_key.this : name => key.arn }
    operations_topic = aws_sns_topic.operations[0].arn
  } : null
}
