# Alertas de falha dos workers (INFRA-SCH da Camada 04). A DLQ do
# modules/schedules só recebe disparo que o Scheduler não entregou; uma task
# que SOBE e falha precisa destes sinais para chegar a alguém.

variable "alarm_topic_arns" {
  description = "Tópicos SNS do canal de alerta (MON-01). Vazio mantém regra e alarmes sem destino."
  type        = list(string)
  default     = []
}
variable "partial_alarm_threshold" {
  description = "Execuções parciais por hora, somando todos os jobs, que caracterizam parcial repetido (W6)."
  type        = number
  default     = 6
  validation {
    condition     = var.partial_alarm_threshold >= 1 && floor(var.partial_alarm_threshold) == var.partial_alarm_threshold
    error_message = "Inteiro a partir de 1."
  }
}

locals {
  metric_namespace = "Chico/Workers"

  # Linhas do Chico-Back: `JOB_RESULT {...}` (workers/one_shot.py) e
  # `LEADER_EVENT {...}` (workers/leader.py), com json.dumps padrão (": ").
  # O prefixo de texto impede filtro JSON; o regex casa a frase exata.
  log_signals = {
    job-error    = { pattern = "%JOB_RESULT .*\"status\": \"error\"%", metric = "JobErrors", period = 300, threshold = 1, description = "Job agendado saiu com erro (JOB_RESULT status error): provedor fora, trava perdida, dado velho ou configuração." }
    job-partial  = { pattern = "%JOB_RESULT .*\"status\": \"partial\"%", metric = "JobPartial", period = 3600, threshold = var.partial_alarm_threshold, description = "Execuções parciais repetidas: parte dos itens falha a cada disparo (W6)." }
    config-error = { pattern = "%LEADER_EVENT .*\"event\": \"config_error\"%", metric = "ConfigErrors", period = 300, threshold = 1, description = "Worker contínuo habilitado recusou subir por configuração inválida (WORK-01a)." }
  }
}

resource "aws_cloudwatch_log_metric_filter" "signal" {
  for_each       = local.log_signals
  name           = "${local.name}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.this.name
  pattern        = each.value.pattern
  metric_transformation {
    name          = each.value.metric
    namespace     = local.metric_namespace
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "signal" {
  for_each            = local.log_signals
  alarm_name          = "${local.name}-${each.key}"
  alarm_description   = each.value.description
  namespace           = local.metric_namespace
  metric_name         = each.value.metric
  statistic           = "Sum"
  period              = each.value.period
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_topic_arns
  ok_actions          = var.alarm_topic_arns
}

# Task do cluster que PAROU com algum container saindo diferente de 0, ou que
# nem subiu (imagem que não baixa, segredo inacessível). Contínuos saem com 0
# no SIGTERM do deploy, então troca de versão não alarma; 137 (morto depois
# do stopTimeout) alarma, porque o desligamento gracioso falhou.
resource "aws_cloudwatch_event_rule" "task_failed" {
  name        = "${local.name}-task-failed"
  description = "Task de worker ou job parou com exit diferente de 0 ou falhou ao subir."
  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = {
      clusterArn = [{ wildcard = "*:cluster/${local.name}" }]
      lastStatus = ["STOPPED"]
      "$or" = [
        { containers = { exitCode = [{ anything-but = 0 }] } },
        { stopCode = ["TaskFailedToStart"] },
      ]
    }
  })
}

# O tópico precisa permitir `sns:Publish` para events.amazonaws.com (e a chave
# KMS dele, se houver) — a política é de quem é dono do tópico (MON-01).
#
# A chave é a posição na lista, não o ARN: no primeiro apply de UAT o tópico
# vem do foundation.tf no mesmo plan e o ARN só existe depois do apply, e
# `for_each` não aceita chave desconhecida. O tamanho da lista é conhecido.
resource "aws_cloudwatch_event_target" "task_failed" {
  for_each  = { for index, arn in var.alarm_topic_arns : tostring(index) => arn }
  rule      = aws_cloudwatch_event_rule.task_failed.name
  target_id = "sns-${each.key}"
  arn       = each.value
  input_transformer {
    input_paths = {
      group    = "$.detail.group"
      reason   = "$.detail.stoppedReason"
      stopCode = "$.detail.stopCode"
      task     = "$.detail.taskArn"
    }
    input_template = "\"Worker parou com erro: <group> (stopCode <stopCode>): <reason>. Task <task>. Detalhe na linha JOB_RESULT/LEADER_EVENT do log /chico/${var.env}/workers.\""
  }
}

output "task_failed_target_keys" { value = sort(keys(aws_cloudwatch_event_target.task_failed)) }
output "alarm_names" { value = sort([for alarm in aws_cloudwatch_metric_alarm.signal : alarm.alarm_name]) }
