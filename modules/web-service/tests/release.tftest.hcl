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
  alb_management_role_arn = "arn:aws:iam::123456789012:role/chico/uat/ecs-alb"
  smoke_hook_arn          = "arn:aws:lambda:sa-east-1:123456789012:function:test-only-smoke"
  hook_execution_role_arn = "arn:aws:iam::123456789012:role/chico/uat/hook"
  alarm_names             = ["test-only-target-health"]
  load_balancers = [{
    blue_target_group_arn  = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/test-blue/1234567890abcdef"
    green_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/test-green/1234567890abcdef"
    production_rule_arn    = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/test/1234567890abcdef/1234567890abcdef/1234567890abcdef"
    test_rule_arn          = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/test/1234567890abcdef/1234567890abcdef/abcdef1234567890"
  }]
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

run "two_routes_register_both_pairs" {
  command = plan
  variables {
    load_balancers = [
      { blue_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/api-blue/1111111111111111", green_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/api-green/1111111111111111", production_rule_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/test/1111111111111111/1111111111111111/1111111111111111", test_rule_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/test/1111111111111111/1111111111111111/2222222222222222" },
      { blue_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/api-site-blue/3333333333333333", green_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/api-site-green/3333333333333333", production_rule_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/test/1111111111111111/1111111111111111/3333333333333333", test_rule_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/test/1111111111111111/1111111111111111/4444444444444444" },
    ]
  }
  assert {
    condition     = length(aws_ecs_service.this.load_balancer) == 2 && alltrue([for lb in aws_ecs_service.this.load_balancer : length(lb.advanced_configuration) == 1])
    error_message = "Cada rota vira um load_balancer com o próprio par azul/verde e regras."
  }
}

run "reject_route_sharing_a_target_group" {
  command = plan
  variables {
    load_balancers = [
      { blue_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/a/1", green_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/b/1", production_rule_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/t/1/1/1", test_rule_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/t/1/1/2" },
      { blue_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/a/1", green_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/c/1", production_rule_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/t/1/1/3", test_rule_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/t/1/1/4" },
    ]
  }
  expect_failures = [aws_ecs_service.this]
}

run "reject_three_routes" {
  command = plan
  variables {
    load_balancers = [for i in range(3) : { blue_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/b${i}/1", green_target_group_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:targetgroup/g${i}/1", production_rule_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/t/1/1/p${i}", test_rule_arn = "arn:aws:elasticloadbalancing:sa-east-1:123456789012:listener-rule/app/t/1/1/t${i}" }]
  }
  expect_failures = [var.load_balancers]
}
