variable "env" {
  type = string
  validation {
    condition     = contains(["uat", "prod"], var.env)
    error_message = "Dev usa loops Compose, não Scheduler."
  }
}
variable "cluster_arn" { type = string }
variable "target_role_arn" { type = string }
variable "public_subnet_ids" { type = set(string) }
variable "jobs_sg_id" { type = string }
variable "task_definition_arns" {
  type = map(string)
  validation {
    condition     = alltrue([for arn in values(var.task_definition_arns) : can(regex("^arn:aws:ecs:sa-east-1:[0-9]{12}:task-definition/chico-(uat|prod)-[a-z0-9-]+:[0-9]+$", arn))])
    error_message = "Usar ARNs de task definition com revisão explícita em sa-east-1."
  }
}
variable "enabled" {
  type    = bool
  default = false
}
variable "application_proofs_approved" {
  description = "Only true after real one-shot/lock/exit/heartbeat and activation gates. Review flag is not proof by itself."
  type        = bool
  default     = false
}
variable "alarm_topic_arns" {
  description = "SNS topics notified when a schedule invocation lands in the DLQ. Empty keeps the alarm without actions."
  type        = list(string)
  default     = []
}

# Horário civil de Brasília (sem horário de verão desde 2019). Os seis jobs
# SofaScore disputam a MESMA trava (`sofascore:production_worker`, espera de
# 120 s): com rate() todos caíam na mesma marca, passavam o ciclo pulando uns
# aos outros e somavam o pico de conexões. Na hora cheia ficam assim:
#   post-match-stats :00 :15 :30 :45 | lineups :07 :27 :47 | match-list :21 :51
# Os de 12 h e 24 h usam minutos e horas livres desses:
#   standings 03:38/15:38 | team-stats 04:38/16:38 | round-matches 05:03
# Fora da trava SofaScore:
#   match-analysis 05:00/17:00 (LLM, trava própria)
#   league-reports 06:00, o mesmo horário do laço da VPS hoje (decisão W4)
#   odds-history-purge 03:20, menor tráfego (AWS-020)
#   account-deletions de hora em hora no minuto 12 (ENT-02)
#   data-freshness :04 :19 :34 :49 — só leitura, trava própria, fora das
#   marcas SofaScore para não medir no meio de uma escrita (AWS-023)
locals {
  timezone = "America/Sao_Paulo"
  cadence = {
    post-match-stats   = "cron(0/15 * * * ? *)"
    lineups            = "cron(7/20 * * * ? *)"
    match-list         = "cron(21/30 * * * ? *)"
    standings          = "cron(38 3,15 * * ? *)"
    team-stats         = "cron(38 4,16 * * ? *)"
    round-matches      = "cron(3 5 * * ? *)"
    match-analysis     = "cron(0 5,17 * * ? *)"
    league-reports     = "cron(0 6 * * ? *)"
    odds-history-purge = "cron(20 3 * * ? *)"
    account-deletions  = "cron(12 * * * ? *)"
    data-freshness     = "cron(4/15 * * * ? *)"
  }
  # O envio para a DLQ é feito com o papel de execução do Scheduler, então a
  # permissão vai no papel de `target_role_arn` (nome = último segmento do ARN).
  target_role_name = element(split("/", var.target_role_arn), length(split("/", var.target_role_arn)) - 1)
}

resource "aws_scheduler_schedule_group" "this" { name = "chico-${var.env}" }

# Só chega aqui a invocação que o Scheduler não conseguiu entregar depois do
# retry_policy (RunTask recusado por capacidade, permissão ou task definition
# inválida). Falha DENTRO da task (exit != 0) não passa pela DLQ: essa é lida
# pelo JOB_RESULT/heartbeat e pelo evento de task parada do ECS.
resource "aws_sqs_queue" "dlq" {
  name                      = "chico-${var.env}-scheduler-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_iam_role_policy" "dlq_send" {
  name = "chico-${var.env}-scheduler-dlq-send"
  role = local.target_role_name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "sqs:SendMessage"
      Resource = aws_sqs_queue.dlq.arn
    }]
  })
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "chico-${var.env}-scheduler-dlq-not-empty"
  alarm_description   = "Schedule do EventBridge não conseguiu disparar a task do job depois dos retries."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_topic_arns
  ok_actions          = var.alarm_topic_arns
}

resource "aws_scheduler_schedule" "this" {
  for_each                     = local.cadence
  name                         = each.key
  group_name                   = aws_scheduler_schedule_group.this.name
  schedule_expression          = each.value
  schedule_expression_timezone = local.timezone
  state                        = var.enabled ? "ENABLED" : "DISABLED"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = var.cluster_arn
    role_arn = var.target_role_arn
    ecs_parameters {
      task_definition_arn = lookup(var.task_definition_arns, each.key, "")
      task_count          = 1
      launch_type         = "FARGATE"
      platform_version    = "1.4.0"
      network_configuration {
        assign_public_ip = true
        subnets          = var.public_subnet_ids
        security_groups  = [var.jobs_sg_id]
      }
    }
    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 2
    }
    dead_letter_config {
      arn = aws_sqs_queue.dlq.arn
    }
  }
  lifecycle {
    precondition {
      condition     = !var.enabled || var.application_proofs_approved
      error_message = "Ativação depende de one-shot/locks/exit/heartbeat e gate real do ambiente."
    }
    precondition {
      condition     = try(strcontains(var.task_definition_arns[each.key], ":task-definition/chico-${var.env}-"), false)
      error_message = "Task definition de outro ambiente não pode ser schedule deste scope."
    }
  }
}

output "dlq_arn" { value = aws_sqs_queue.dlq.arn }
output "schedule_names" { value = sort(keys(aws_scheduler_schedule.this)) }
