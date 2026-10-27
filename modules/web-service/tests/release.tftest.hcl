mock_provider "aws" {}
variables {
  logs_key_arn            = "arn:aws:kms:sa-east-1:123456789012:key/test-only"
  env                     = "uat"
  service                 = "api"
  image                   = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  cluster_arn             = "arn:aws:ecs:sa-east-1:123456789012:cluster/chico-uat"
  execution_role_arn      = "arn:aws:iam::123456789012:role/chico/uat/api-execution"
  task_role_arn           = "arn:aws:iam::123456789012:role/chico/uat/api"
  public_subnet_ids       = ["subnet-test1", "subnet-test2"]
  security_group_id       = "sg-api"
  blue_target_group_arn   = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/test-blue/1234567890abcdef"
  green_target_group_arn  = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/test-green/1234567890abcdef"
  production_rule_arn     = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/test/1234567890abcdef/1234567890abcdef/1234567890abcdef"
  test_rule_arn           = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/test/1234567890abcdef/1234567890abcdef/abcdef1234567890"
  alb_management_role_arn = "arn:aws:iam::123456789012:role/chico/uat/ecs-alb"
  smoke_hook_arn          = "arn:aws:lambda:sa-east-1:123456789012:function:test-only-smoke"
  hook_execution_role_arn = "arn:aws:iam::123456789012:role/chico/uat/hook"
  alarm_names             = ["test-only-target-health"]
}
run "stopped_with_pretraffic_gate" {
  command = plan
  assert {
    condition     = aws_ecs_service.this.desired_count == 0 && aws_ecs_service.this.deployment_configuration[0].strategy == "BLUE_GREEN" && one(aws_ecs_service.this.deployment_configuration[0].lifecycle_hook).lifecycle_stages == tolist(["POST_TEST_TRAFFIC_SHIFT"]) && aws_ecs_service.this.alarms[0].rollback
    error_message = "Manter parado e configurar smoke antes do tráfego com rollback."
  }
  assert {
    condition     = aws_ecs_task_definition.this.runtime_platform[0].cpu_architecture == "ARM64" && aws_ecs_task_definition.this.network_mode == "awsvpc"
    error_message = "Fargate ARM/awsvpc obrigatório."
  }
}
run "reject_mutable_tag" {
  command = plan
  variables { image = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-api:latest" }
  expect_failures = [var.image]
}
