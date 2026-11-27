# Alarmes do banco e do cache (P-04 da análise de lacunas de Prod/UAT). Nomes
# chico-<env>-rds-* e chico-<env>-cache-*: é o prefixo que o tópico
# chico-<env>-operations e a CMK de alertas aceitam de alarme do CloudWatch
# (modules/app-stack/foundation.tf). Sem tópico, os alarmes existem e aparecem
# no console, mas não notificam ninguém.
#
# Limiares são ponto de partida para a classe Single-AZ aprovada, não medição:
# revisar com o tráfego real dos apps (pg_stat_statements e Database Insights).

variable "alarm_topic_arns" {
  description = "Tópicos SNS do canal de alerta (MON-01). Vazio = alarmes sem notificação."
  type        = list(string)
  default     = []
}
variable "connections_alarm_threshold" {
  description = "Conexões abertas que disparam o alarme. Null = ~75% do max_connections padrão da classe (t4g.medium ≈ 410, t4g.small ≈ 200); conferir com SHOW max_connections e o orçamento de conexões (duas cores, onze jobs, LISTEN, migração)."
  type        = number
  default     = null
  validation {
    condition     = var.connections_alarm_threshold == null || try(var.connections_alarm_threshold > 0, false)
    error_message = "Limiar de conexões deve ser positivo."
  }
}
variable "free_storage_alarm_gib" {
  description = "Espaço livre mínimo. O storage autoscaling cresce sozinho com menos de 10% livre; este alarme pega quando ele não acompanha ou bateu no teto (max_allocated_storage_gib)."
  type        = number
  default     = 4
  validation {
    condition     = var.free_storage_alarm_gib > 0
    error_message = "Limiar de espaço livre deve ser positivo."
  }
}

locals {
  gib            = 1024 * 1024 * 1024
  instance_class = var.env == "prod" ? "db.t4g.medium" : "db.t4g.small"
  # Memória da classe e max_connections padrão do RDS (LEAST(DBInstanceClassMemory/9531392, 5000)).
  class_memory_gib = { "db.t4g.medium" = 4, "db.t4g.small" = 2 }[local.instance_class]
  class_max_conns  = { "db.t4g.medium" = 410, "db.t4g.small" = 200 }[local.instance_class]

  rds_alarms = {
    cpu-high = {
      description = "CPU do Postgres acima de 80% por 15 min."
      metric      = "CPUUtilization", statistic = "Average", period = 300, periods = 3
      operator    = "GreaterThanThreshold", threshold = 80, missing = "missing"
    }
    cpu-credits-low = {
      description = "Créditos de CPU da t4g quase no fim: o burst vira cobrança de surplus ou CPU limitada."
      metric      = "CPUCreditBalance", statistic = "Minimum", period = 300, periods = 3
      operator    = "LessThanThreshold", threshold = 30, missing = "missing"
    }
    free-storage-low = {
      description = "Espaço livre abaixo de ${var.free_storage_alarm_gib} GiB: autoscaling de storage não acompanhou ou chegou ao teto."
      metric      = "FreeStorageSpace", statistic = "Minimum", period = 300, periods = 2
      operator    = "LessThanThreshold", threshold = var.free_storage_alarm_gib * local.gib, missing = "breaching"
    }
    freeable-memory-low = {
      description = "Memória livre abaixo de 10% da classe: cache do Postgres espremido, risco de swap."
      metric      = "FreeableMemory", statistic = "Minimum", period = 300, periods = 3
      operator    = "LessThanThreshold", threshold = local.class_memory_gib * local.gib / 10, missing = "missing"
    }
    connections-high = {
      description = "Conexões abertas perto do max_connections da classe."
      metric      = "DatabaseConnections", statistic = "Maximum", period = 300, periods = 2
      operator    = "GreaterThanThreshold", threshold = coalesce(var.connections_alarm_threshold, floor(local.class_max_conns * 0.75)), missing = "missing"
    }
    read-latency-high = {
      description = "Latência média de leitura do disco acima de 25 ms por 15 min."
      metric      = "ReadLatency", statistic = "Average", period = 300, periods = 3
      operator    = "GreaterThanThreshold", threshold = 0.025, missing = "notBreaching"
    }
    write-latency-high = {
      description = "Latência média de escrita do disco acima de 25 ms por 15 min."
      metric      = "WriteLatency", statistic = "Average", period = 300, periods = 3
      operator    = "GreaterThanThreshold", threshold = 0.025, missing = "notBreaching"
    }
  }

  # Réplica única: o nó do replication group é sempre <id>-001.
  cache_alarms = {
    memory-high = {
      description = "Memória do Valkey acima de 80%: próximo do maxmemory, evictions a seguir."
      metric      = "DatabaseMemoryUsagePercentage", statistic = "Maximum", period = 300, periods = 3
      operator    = "GreaterThanThreshold", threshold = 80, missing = "missing"
    }
    evictions = {
      description = "Valkey despejando chaves por falta de memória (não por TTL)."
      metric      = "Evictions", statistic = "Sum", period = 300, periods = 3
      operator    = "GreaterThanThreshold", threshold = 0, missing = "notBreaching"
    }
    engine-cpu-high = {
      description = "CPU do engine do Valkey acima de 80% por 15 min."
      metric      = "EngineCPUUtilization", statistic = "Average", period = 300, periods = 3
      operator    = "GreaterThanThreshold", threshold = 80, missing = "missing"
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "rds" {
  for_each            = { for name, alarm in local.rds_alarms : name => alarm if var.rds_enabled }
  alarm_name          = "chico-${var.env}-rds-${each.key}"
  alarm_description   = each.value.description
  namespace           = "AWS/RDS"
  metric_name         = each.value.metric
  dimensions          = { DBInstanceIdentifier = aws_db_instance.this[0].identifier }
  statistic           = each.value.statistic
  period              = each.value.period
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = each.value.operator
  treat_missing_data  = each.value.missing
  alarm_actions       = var.alarm_topic_arns
  ok_actions          = var.alarm_topic_arns
}

resource "aws_cloudwatch_metric_alarm" "cache" {
  for_each            = { for name, alarm in local.cache_alarms : name => alarm if var.cache_enabled }
  alarm_name          = "chico-${var.env}-cache-${each.key}"
  alarm_description   = each.value.description
  namespace           = "AWS/ElastiCache"
  metric_name         = each.value.metric
  dimensions          = { CacheClusterId = "${aws_elasticache_replication_group.this[0].replication_group_id}-001" }
  statistic           = each.value.statistic
  period              = each.value.period
  evaluation_periods  = each.value.periods
  threshold           = each.value.threshold
  comparison_operator = each.value.operator
  treat_missing_data  = each.value.missing
  alarm_actions       = var.alarm_topic_arns
  ok_actions          = var.alarm_topic_arns
}

output "alarm_names" {
  value = sort(concat([for alarm in aws_cloudwatch_metric_alarm.rds : alarm.alarm_name], [for alarm in aws_cloudwatch_metric_alarm.cache : alarm.alarm_name]))
}
