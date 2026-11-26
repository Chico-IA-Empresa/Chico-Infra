mock_provider "aws" {
  mock_data "aws_ami" { defaults = { architecture = "arm64", state = "available", name = "al2023-ami-ecs-hvm-2023.0.20251101-kernel-6.1-arm64" } }
}
variables {
  account_id  = "123456789012"
  owner       = "local-fixture"
  cost_center = "local-fixture"
  az_names    = ["sa-east-1a", "sa-east-1b"]
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
    provision_enabled   = true
    api_enabled         = true
    credit_approval     = { account_id = "123456789012", evidence_reference = "test-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
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
    condition     = module.api_deploy[0].smoke_hook_arn == "arn:aws:lambda:sa-east-1:123456789012:function:chico-uat-api-smoke" && length(module.alb[0].alarm_names["api"]) == 4
    error_message = "O web-service recebe o smoke e os alarmes de rollback do ALB."
  }
}
