mock_provider "aws" {
  mock_data "aws_ami" { defaults = { architecture = "arm64", state = "available", name = "al2023-ami-ecs-hvm-2023.0.20251101-kernel-6.1-arm64" } }
}
variables {
  env                    = "uat"
  image                  = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-workers@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ami_id                 = "ami-0123456789abcdef0"
  host_subnet_id         = "subnet-same-az-as-rds"
  host_security_group_id = "sg-workers"
  instance_profile_arn   = "arn:aws:iam::123456789012:instance-profile/chico/uat/workers-host"
  execution_role_arn     = "arn:aws:iam::123456789012:role/chico/uat/workers-execution"
  logs_key_arn           = "arn:aws:kms:sa-east-1:123456789012:key/test-only"
  task_role_arns = {
    odds-bsd           = "arn:aws:iam::123456789012:role/chico/uat/odds-bsd"
    odds-surebetting   = "arn:aws:iam::123456789012:role/chico/uat/odds-surebetting"
    telegram-update    = "arn:aws:iam::123456789012:role/chico/uat/telegram-update"
    post-match-stats   = "arn:aws:iam::123456789012:role/chico/uat/post-match-stats"
    lineups            = "arn:aws:iam::123456789012:role/chico/uat/lineups"
    match-list         = "arn:aws:iam::123456789012:role/chico/uat/match-list"
    standings          = "arn:aws:iam::123456789012:role/chico/uat/standings"
    team-stats         = "arn:aws:iam::123456789012:role/chico/uat/team-stats"
    round-matches      = "arn:aws:iam::123456789012:role/chico/uat/round-matches"
    match-analysis     = "arn:aws:iam::123456789012:role/chico/uat/match-analysis"
    league-reports     = "arn:aws:iam::123456789012:role/chico/uat/league-reports"
    odds-history-purge = "arn:aws:iam::123456789012:role/chico/uat/odds-history-purge"
    account-deletions  = "arn:aws:iam::123456789012:role/chico/uat/account-deletions"
    data-freshness     = "arn:aws:iam::123456789012:role/chico/uat/data-freshness"
  }
}
run "continuous_services_stopped_with_leader_handover" {
  command = plan
  assert {
    condition     = length(aws_ecs_service.service) == 3 && alltrue([for service in aws_ecs_service.service : service.desired_count == 0])
    error_message = "Três contínuos, parados por padrão; ligar é decisão do ambiente."
  }
  assert {
    condition     = alltrue([for service in aws_ecs_service.service : service.deployment_minimum_healthy_percent == 100 && service.deployment_maximum_percent == 200 && service.deployment_circuit_breaker[0].rollback])
    error_message = "Deploy 100/200: a réplica nova sobe como standby enquanto a antiga segura a trava; circuit breaker com rollback."
  }
  assert {
    condition     = alltrue([for definition in aws_ecs_task_definition.service : definition.network_mode == "bridge" && contains(definition.requires_compatibilities, "EC2") && definition.runtime_platform[0].cpu_architecture == "ARM64"])
    error_message = "Contínuos em ECS EC2 ARM64, modo bridge."
  }
  assert {
    condition     = alltrue([for definition in aws_ecs_task_definition.service : jsondecode(definition.container_definitions)[0].healthCheck.command == ["CMD", "python", "-m", "workers.leader", "--health"] && jsondecode(definition.container_definitions)[0].stopTimeout == 120])
    error_message = "Health check do líder/standby e stopTimeout de 120 s (vigia do SIGTERM em 110 s)."
  }
}
run "host_is_arm64_imdsv2_encrypted_in_one_az" {
  command = plan
  assert {
    condition     = aws_launch_template.host.metadata_options[0].http_tokens == "required" && aws_launch_template.host.metadata_options[0].http_put_response_hop_limit == 1
    error_message = "IMDSv2 com hop limit 1: containers em bridge não alcançam o IMDS do host."
  }
  assert {
    condition     = aws_launch_template.host.block_device_mappings[0].ebs[0].encrypted == "true" && aws_launch_template.host.credit_specification[0].cpu_credits == "standard"
    error_message = "EBS cifrado e sem CPU Unlimited não aprovado."
  }
  assert {
    condition     = aws_autoscaling_group.host.min_size == 0 && aws_autoscaling_group.host.max_size == 2 && length(aws_autoscaling_group.host.vpc_zone_identifier) == 1
    error_message = "ASG começa vazio, teto revisado e uma subnet só (mesma AZ do RDS)."
  }
  assert {
    condition     = strcontains(local.host_user_data, "ECS_CLUSTER=chico-uat-workers") && strcontains(local.host_user_data, "ECS_CONTAINER_STOP_TIMEOUT=120s")
    error_message = "Host registra no cluster certo e respeita o stopTimeout dos contínuos."
  }
}
run "eleven_jobs_match_the_schedule_contract" {
  command = plan
  assert {
    condition     = length(aws_ecs_task_definition.job) == 11 && alltrue([for definition in aws_ecs_task_definition.job : contains(definition.requires_compatibilities, "FARGATE") && definition.runtime_platform[0].cpu_architecture == "ARM64"])
    error_message = "Os onze jobs do modules/schedules, em Fargate ARM64."
  }
  assert {
    condition     = alltrue([for job, definition in aws_ecs_task_definition.job : can(regex("^chico-(uat|prod)-[a-z0-9-]+$", definition.family)) && definition.family == "chico-uat-${job}"])
    error_message = "Família chico-<env>-<job>, a que o modules/schedules valida."
  }
  assert {
    condition     = alltrue([for definition in aws_ecs_task_definition.job : contains(jsondecode(definition.container_definitions)[0].command, "--max-runtime-seconds")])
    error_message = "Todo job tem prazo: para no checkpoint com exit 3 em vez de encostar no próximo disparo."
  }
  assert {
    condition     = contains(jsondecode(aws_ecs_task_definition.job["league-reports"].container_definitions)[0].command, "--run-once") && contains(jsondecode(aws_ecs_task_definition.job["match-analysis"].container_definitions)[0].command, "--run-once")
    error_message = "Os dois jobs de LLM sem --run-once ficariam em laço dentro da task."
  }
}
run "reject_mutable_tag" {
  command = plan
  variables { image = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-workers:latest" }
  expect_failures = [var.image]
}
run "reject_prod_consumer_before_cutover" {
  command = plan
  variables {
    env                    = "prod"
    service_desired_counts = { odds-bsd = 1, odds-surebetting = 0, telegram-update = 0 }
  }
  expect_failures = [aws_ecs_service.service]
}
run "reject_shared_task_role" {
  command = plan
  variables {
    task_role_arns = {
      odds-bsd = "arn:aws:iam::123456789012:role/chico/uat/odds-bsd"
    }
  }
  expect_failures = [aws_ecs_task_definition.service, aws_ecs_task_definition.job]
}
run "reject_secret_for_unknown_consumer" {
  command = plan
  variables {
    secrets = { odds-bsd-ws = [{ name = "BSD_API_TOKEN", valueFrom = "arn:aws:secretsmanager:sa-east-1:123456789012:secret:test-only" }] }
  }
  expect_failures = [aws_ecs_cluster.this]
}
run "reject_wrong_ami" {
  command = plan
  override_data {
    target = data.aws_ami.host
    values = { architecture = "x86_64", state = "available", name = "al2023-ami-ecs-hvm-2023.0-x86_64" }
  }
  expect_failures = [aws_launch_template.host]
}
run "job_failures_reach_the_alarms" {
  command = plan
  assert {
    condition     = length(aws_cloudwatch_log_metric_filter.signal) == 3 && strcontains(aws_cloudwatch_log_metric_filter.signal["job-error"].pattern, "JOB_RESULT") && strcontains(aws_cloudwatch_log_metric_filter.signal["job-error"].pattern, "\"status\": \"error\"")
    error_message = "Filtro casa a linha JOB_RESULT com status error, como o Chico-Back imprime."
  }
  assert {
    condition     = strcontains(aws_cloudwatch_log_metric_filter.signal["config-error"].pattern, "LEADER_EVENT") && strcontains(aws_cloudwatch_log_metric_filter.signal["config-error"].pattern, "config_error")
    error_message = "Worker contínuo que recusa subir (AWS-021) também alarma."
  }
  assert {
    condition     = aws_cloudwatch_metric_alarm.signal["job-error"].threshold == 1 && aws_cloudwatch_metric_alarm.signal["job-error"].period == 300 && aws_cloudwatch_metric_alarm.signal["job-partial"].threshold == 6 && aws_cloudwatch_metric_alarm.signal["job-partial"].period == 3600
    error_message = "Um erro já alarma; parcial só quando se repete (W6)."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_event_rule.task_failed.event_pattern).detail.lastStatus == ["STOPPED"] && strcontains(jsondecode(aws_cloudwatch_event_rule.task_failed.event_pattern).detail.clusterArn[0].wildcard, ":cluster/chico-uat-workers")
    error_message = "Regra olha só tasks paradas do cluster dos workers deste ambiente."
  }
  assert {
    condition     = length(jsondecode(aws_cloudwatch_event_rule.task_failed.event_pattern).detail["$or"]) == 2 && jsondecode(aws_cloudwatch_event_rule.task_failed.event_pattern).detail["$or"][0].containers.exitCode[0]["anything-but"] == 0
    error_message = "Exit diferente de 0 ou falha ao subir; exit 0 (SIGTERM de deploy) não alarma."
  }
  assert {
    condition     = length(aws_cloudwatch_event_target.task_failed) == 0
    error_message = "Sem tópico configurado, a regra existe mas não tem destino."
  }
}
run "alerts_go_to_the_topic" {
  command = plan
  variables { alarm_topic_arns = ["arn:aws:sns:sa-east-1:123456789012:chico-uat-alerts"] }
  assert {
    condition     = length(aws_cloudwatch_event_target.task_failed) == 1 && alltrue([for alarm in aws_cloudwatch_metric_alarm.signal : contains(alarm.alarm_actions, "arn:aws:sns:sa-east-1:123456789012:chico-uat-alerts")])
    error_message = "Regra e alarmes publicam no canal configurado."
  }
}
run "reject_zero_partial_threshold" {
  command = plan
  variables { partial_alarm_threshold = 0 }
  expect_failures = [var.partial_alarm_threshold]
}
