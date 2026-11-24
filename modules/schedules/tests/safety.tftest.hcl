mock_provider "aws" {}
variables {
  env               = "uat"
  cluster_arn       = "arn:aws:ecs:sa-east-1:123456789012:cluster/chico-uat"
  target_role_arn   = "arn:aws:iam::123456789012:role/chico/uat/scheduler"
  public_subnet_ids = ["subnet-test1", "subnet-test2"]
  jobs_sg_id        = "sg-jobs"
  task_definition_arns = {
    match-list         = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-match-list:1"
    lineups            = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-lineups:1"
    post-match-stats   = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-post-match-stats:1"
    standings          = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-standings:1"
    team-stats         = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-team-stats:1"
    round-matches      = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-round-matches:1"
    league-reports     = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-league-reports:1"
    match-analysis     = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-match-analysis:1"
    odds-history-purge = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-odds-history-purge:1"
    account-deletions  = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-account-deletions:1"
  }
}
run "ten_disabled_schedules" {
  command = plan
  assert {
    condition     = length(aws_scheduler_schedule.this) == 10 && alltrue([for schedule in aws_scheduler_schedule.this : schedule.state == "DISABLED"])
    error_message = "Preparação não pode ativar consumidores."
  }
}
run "brt_cron_instead_of_utc_rate" {
  command = plan
  assert {
    condition     = alltrue([for schedule in aws_scheduler_schedule.this : schedule.schedule_expression_timezone == "America/Sao_Paulo" && startswith(schedule.schedule_expression, "cron(")])
    error_message = "Schedules usam cron em horário de Brasília, com minutos escalonados."
  }
  assert {
    condition     = aws_scheduler_schedule.this["league-reports"].schedule_expression == "cron(0 6 * * ? *)"
    error_message = "league-reports roda às 06h BRT, como o laço da VPS (W4)."
  }
}
run "dlq_receives_failed_invocations" {
  command = plan
  assert {
    condition     = alltrue([for schedule in aws_scheduler_schedule.this : length(schedule.target[0].dead_letter_config) == 1])
    error_message = "Todo schedule precisa de DLQ: sem ela, invocação recusada some sem rastro."
  }
  assert {
    condition     = aws_iam_role_policy.dlq_send.role == "scheduler"
    error_message = "A permissão de envio à DLQ vai no papel de execução do Scheduler (nome sem o path)."
  }
  assert {
    condition     = aws_sqs_queue.dlq.sqs_managed_sse_enabled == true
    error_message = "DLQ cifrada em repouso."
  }
}
run "reject_unproven_activation" {
  command = plan
  variables { enabled = true }
  expect_failures = [aws_scheduler_schedule.this]
}
run "reject_job_without_task_definition" {
  command = plan
  variables {
    task_definition_arns = {
      match-list       = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-match-list:1"
      lineups          = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-lineups:1"
      post-match-stats = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-post-match-stats:1"
      standings        = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-standings:1"
      team-stats       = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-team-stats:1"
      round-matches    = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-round-matches:1"
      league-reports   = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-league-reports:1"
      match-analysis   = "arn:aws:ecs:sa-east-1:123456789012:task-definition/chico-uat-match-analysis:1"
    }
  }
  expect_failures = [aws_scheduler_schedule.this]
}
