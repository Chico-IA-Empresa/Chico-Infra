variable "logs_key_arn" {
  type    = string
  default = null
  validation {
    condition     = var.logs_key_arn == null ? true : can(regex("^arn:aws:kms:sa-east-1:${var.account_id}:key/[a-zA-Z0-9-]+$", var.logs_key_arn))
    error_message = "CMK de logs Dev revisada na mesma conta/região."
  }
}
variable "alarm_topic_arn" {
  type    = string
  default = null
  validation {
    condition     = var.alarm_topic_arn == null ? true : can(regex("^arn:aws:sns:sa-east-1:${var.account_id}:chico-dev-[a-z0-9-]+$", var.alarm_topic_arn))
    error_message = "Destino SNS exclusivo Dev revisado."
  }
}
locals { log_names = toset(["bootstrap", "ssm", "proxy", "backup"]) }
resource "aws_cloudwatch_log_group" "dev" {
  for_each          = local.host_enabled ? local.log_names : toset([])
  name              = "/chico/dev/${each.key}"
  retention_in_days = 30
  kms_key_id        = var.logs_key_arn
  lifecycle {
    precondition {
      condition     = var.logs_key_arn != null && var.alarm_topic_arn != null
      error_message = "CMK e tópico Dev revisados/cotados necessários."
    }
  }
  depends_on = [module.funding]
}
resource "aws_iam_role_policy" "telemetry" {
  count = local.host_enabled ? 1 : 0
  role  = aws_iam_role.runtime[0].id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"], Resource = [for g in aws_cloudwatch_log_group.dev : "${g.arn}:*"] },
    { Effect = "Allow", Action = ["cloudwatch:PutMetricData"], Resource = "*", Condition = { StringEquals = { "cloudwatch:namespace" = "Chico/Dev" } } }
  ] })
}
resource "aws_cloudwatch_metric_alarm" "status" {
  count               = local.host_enabled ? 1 : 0
  alarm_name          = "chico-dev-host-status"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  evaluation_periods  = 2
  period              = 300
  statistic           = "Maximum"
  dimensions          = { InstanceId = module.dev_box[0].instance_id }
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}
resource "aws_cloudwatch_metric_alarm" "runtime" {
  for_each            = local.host_enabled ? { MemoryUsedPercent = 85, DiskUsedPercent = 80, BackupAgeHours = 26 } : {}
  alarm_name          = "chico-dev-${each.key}"
  namespace           = "Chico/Dev"
  metric_name         = each.key
  comparison_operator = "GreaterThanThreshold"
  threshold           = each.value
  evaluation_periods  = 2
  period              = 300
  statistic           = "Maximum"
  dimensions          = { InstanceId = module.dev_box[0].instance_id }
  treat_missing_data  = "breaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}
resource "aws_cloudwatch_metric_alarm" "cpu" {
  count               = local.host_enabled ? 1 : 0
  alarm_name          = "chico-dev-cpu"
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  evaluation_periods  = 3
  period              = 300
  statistic           = "Average"
  dimensions          = { InstanceId = module.dev_box[0].instance_id }
  treat_missing_data  = "missing"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}
output "observability" {
  value = { log_groups = { for k, g in aws_cloudwatch_log_group.dev : k => g.name }, namespace = "Chico/Dev", thresholds = "provisional; baseline review required before activation" }
}
