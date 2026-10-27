mock_provider "aws" {}
variables {
  env               = "uat"
  cluster_arn       = "arn:aws:ecs:sa-east-1:123456789012:cluster/chico-uat"
  target_role_arn   = "arn:aws:iam::123456789012:role/chico/uat/scheduler"
  public_subnet_ids = ["subnet-test1", "subnet-test2"]
  jobs_sg_id        = "sg-jobs"
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
run "eight_disabled_schedules" {
  command = plan
  assert {
    condition     = length(aws_scheduler_schedule.this) == 8 && alltrue([for schedule in aws_scheduler_schedule.this : schedule.state == "DISABLED"])
    error_message = "Preparação não pode ativar consumidores."
  }
}
run "reject_unproven_activation" {
  command = plan
  variables { enabled = true }
  expect_failures = [aws_scheduler_schedule.this]
}
