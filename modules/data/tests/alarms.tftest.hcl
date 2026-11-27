mock_provider "aws" {}
variables {
  env                    = "uat"
  account_id             = "123456789012"
  subnet_ids             = ["subnet-test1", "subnet-test2"]
  rds_sg_id              = "sg-rds"
  cache_sg_id            = "sg-cache"
  availability_zone      = "sa-east-1a"
  postgres_version       = "16.1"
  valkey_version         = "7.2"
  data_key_arn           = "arn:aws:kms:sa-east-1:123456789012:key/test-only"
  cache_user_group_ids   = ["test-only"]
  sanitized_snapshot_arn = "arn:aws:rds:sa-east-1:123456789012:snapshot:uat-sanitized-test-only"
  alarm_topic_arns       = ["arn:aws:sns:sa-east-1:123456789012:chico-uat-operations"]
}
run "every_alarm_notifies_the_environment_topic" {
  command = plan
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds) == 7 && length(aws_cloudwatch_metric_alarm.cache) == 3
    error_message = "Sete alarmes do Postgres e três do Valkey."
  }
  assert {
    condition = alltrue([for alarm in concat(values(aws_cloudwatch_metric_alarm.rds), values(aws_cloudwatch_metric_alarm.cache)) :
    startswith(alarm.alarm_name, "chico-uat-") && alarm.alarm_actions == toset(["arn:aws:sns:sa-east-1:123456789012:chico-uat-operations"]) && alarm.ok_actions == alarm.alarm_actions])
    error_message = "Todo alarme usa o prefixo chico-<env>- (o que o tópico aceita) e avisa na entrada e na saída."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.rds["connections-high"].threshold == 150 && aws_cloudwatch_metric_alarm.rds["freeable-memory-low"].threshold == 2 * 1024 * 1024 * 1024 / 10
    error_message = "UAT (t4g.small): conexões em ~75% de 200 e memória em 10% de 2 GiB."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.rds["free-storage-low"].treat_missing_data == "breaching" && aws_cloudwatch_metric_alarm.cache["evictions"].dimensions["CacheClusterId"] == "chico-uat-001"
    error_message = "Espaço livre sem métrica é tratado como problema; o cache é medido no nó único do replication group."
  }
}
run "prod_thresholds_follow_the_larger_class" {
  command = plan
  variables {
    env                       = "prod"
    final_snapshot_identifier = "test-only-final"
  }
  assert {
    condition     = aws_db_instance.this[0].instance_class == "db.t4g.medium" && aws_cloudwatch_metric_alarm.rds["connections-high"].threshold == 307 && aws_cloudwatch_metric_alarm.rds["freeable-memory-low"].threshold == 4 * 1024 * 1024 * 1024 / 10
    error_message = "Prod (t4g.medium): conexões em ~75% de 410 e memória em 10% de 4 GiB."
  }
  assert {
    condition     = alltrue([for alarm in values(aws_cloudwatch_metric_alarm.rds) : startswith(alarm.alarm_name, "chico-prod-rds-")])
    error_message = "Em Prod, alarmes no namespace de Prod."
  }
}
run "explicit_connection_threshold_wins" {
  command = plan
  variables { connections_alarm_threshold = 120 }
  assert {
    condition     = aws_cloudwatch_metric_alarm.rds["connections-high"].threshold == 120
    error_message = "connections_alarm_threshold preenchido vence o padrão da classe."
  }
}
run "alarms_follow_each_service_switch" {
  command = plan
  variables {
    cache_enabled        = false
    cache_user_group_ids = []
    valkey_version       = null
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds) == 7 && length(aws_cloudwatch_metric_alarm.cache) == 0
    error_message = "Sem cache, nenhum alarme de cache."
  }
}
run "no_topic_still_creates_silent_alarms" {
  command = plan
  variables { alarm_topic_arns = [] }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.rds) == 7 && alltrue([for alarm in values(aws_cloudwatch_metric_alarm.rds) : length(alarm.alarm_actions) == 0])
    error_message = "Sem tópico, os alarmes existem sem ação."
  }
}
