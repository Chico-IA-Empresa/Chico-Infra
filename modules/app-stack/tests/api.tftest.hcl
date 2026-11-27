mock_provider "aws" {
  mock_data "aws_ami" { defaults = { architecture = "arm64", state = "available", name = "al2023-ami-ecs-hvm-2023.0.20251101-kernel-6.1-arm64" } }
}
variables {
  env                = "uat"
  account_id         = "123456789012"
  vpc_id             = "vpc-0123456789abcdef0"
  public_subnet_ids  = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
  security_group_ids = { alb = "sg-0000000000000000a", api = "sg-0000000000000000b", frontend = "sg-0000000000000000c", workers = "sg-0000000000000000d", jobs = "sg-0000000000000000e" }
}
run "api_off_by_default" {
  command = plan
  assert {
    condition     = length(module.alb) == 0 && length(module.api_deploy) == 0 && length(module.web) == 0 && length(aws_ecs_cluster.web) == 0 && output.api_alb_dns_name == null
    error_message = "Sem as duas chaves, nada da entrada da API é planejado."
  }
}
run "api_flag_alone_creates_nothing" {
  command = plan
  variables { api_enabled = true }
  assert {
    condition     = length(module.web) == 0 && length(module.alb) == 0
    error_message = "api_enabled sem provision_enabled não cria nada."
  }
}
run "api_and_frontend_wired_behind_the_alb" {
  command = plan
  variables {
    enabled             = true
    api_enabled         = true
    api_certificate_arn = "arn:aws:acm:sa-east-1:123456789012:certificate/test-only"
    api_host_names      = ["api.uat.example.com"]
    web_host_names      = ["uat.example.com"]
    api_image           = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    frontend_image      = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-frontend@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    api_logs_key_arn    = "arn:aws:kms:sa-east-1:123456789012:key/test-only"
  }
  assert {
    condition     = length(module.alb) == 1 && length(module.api_deploy) == 1 && length(module.web) == 2 && aws_ecs_cluster.web[0].name == "chico-uat-web"
    error_message = "ALB, papéis/smoke, cluster e os dois web-service entram juntos."
  }
  assert {
    condition     = module.api_deploy[0].smoke_hook_arn == "arn:aws:lambda:sa-east-1:123456789012:function:chico-uat-api-smoke" && length(module.alb[0].alarm_names["api"]) == 8 && length(module.alb[0].load_balancers["api"]) == 2
    error_message = "O web-service recebe o smoke e os alarmes de rollback do ALB."
  }
  assert {
    condition = (
      length(aws_ecs_task_definition.migrate) == 1 &&
      aws_ecs_task_definition.migrate[0].runtime_platform[0].cpu_architecture == "ARM64" &&
      strcontains(aws_ecs_task_definition.migrate[0].container_definitions, "alembic upgrade heads") &&
      strcontains(aws_ecs_task_definition.migrate[0].container_definitions, "verify_schema_authority.py")
    )
    error_message = "A migration é a mesma da VPS (baseline, upgrade heads, verificação), na imagem ARM da API."
  }
}
run "reject_unknown_web_service_count" {
  command = plan
  variables { api_desired_counts = { worker = 1 } }
  expect_failures = [var.api_desired_counts]
}
run "reject_more_than_two_api_tasks" {
  command = plan
  variables { api_desired_counts = { api = 3 } }
  expect_failures = [var.api_desired_counts]
}
