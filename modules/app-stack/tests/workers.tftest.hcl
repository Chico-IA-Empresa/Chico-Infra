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
run "workers_off_by_default" {
  command = plan
  assert {
    condition     = length(module.workers_iam) == 0 && length(module.workers) == 0 && length(module.schedules) == 0 && output.workers_cluster_arn == null
    error_message = "Sem as duas chaves, nenhum recurso de workers é planejado."
  }
}
run "workers_flag_alone_creates_nothing" {
  command = plan
  variables { workers_enabled = true }
  assert {
    condition     = length(module.workers) == 0
    error_message = "workers_enabled sem provision_enabled não cria nada: o ambiente inteiro segue a mesma chave."
  }
}
run "workers_wired_but_nothing_runs" {
  command = plan
  variables {
    enabled         = true
    workers_enabled = true
    workers_image   = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-workers@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    workers_ami_id  = "ami-0123456789abcdef0"
  }
  assert {
    condition     = length(module.workers_iam) == 1 && length(module.workers) == 1 && length(module.schedules) == 1
    error_message = "Com as duas chaves, papéis, cluster e schedules entram juntos."
  }
  assert {
    condition     = length(module.workers_iam[0].task_role_arns) == 14 && module.workers_iam[0].task_role_arns["data-freshness"] == "arn:aws:iam::123456789012:role/chico/uat/chico-uat-data-freshness"
    error_message = "Um papel por consumidor, no formato que o modules/workers recebe."
  }
  assert {
    condition     = join(",", module.workers[0].service_names) == "chico-uat-odds-bsd,chico-uat-odds-surebetting,chico-uat-telegram-update"
    error_message = "Os três contínuos do ambiente."
  }
  assert {
    condition     = length(module.schedules[0].schedule_names) == 11
    error_message = "Onze schedules, ligados às task definitions do modules/workers."
  }
}
run "foundation_and_workers_plan_together" {
  command = plan
  variables {
    provision_enabled  = true
    foundation_enabled = true
    workers_enabled    = true
    credit_approval    = { account_id = "123456789012", evidence_reference = "test-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
    workers_image      = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-workers@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    workers_ami_id     = "ami-0123456789abcdef0"
  }
  assert {
    condition     = length(module.workers[0].task_failed_target_keys) == 1
    error_message = "No primeiro apply o ARN do tópico de UAT ainda não existe; o destino da regra precisa de chave conhecida no plan."
  }
}
run "reject_unknown_worker_service_count" {
  command = plan
  variables { workers_service_desired_counts = { odds-api = 1 } }
  expect_failures = [var.workers_service_desired_counts]
}
run "reject_second_replica_of_a_leader_worker" {
  command = plan
  variables { workers_service_desired_counts = { odds-bsd = 2 } }
  expect_failures = [var.workers_service_desired_counts]
}
