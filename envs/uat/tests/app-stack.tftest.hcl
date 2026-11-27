# Ligação do root com modules/app-stack. O comportamento de cada bloco
# (foundation, API, workers, segredos) é testado no próprio módulo.
mock_provider "aws" {
  mock_data "aws_ami" { defaults = { architecture = "arm64", state = "available", name = "al2023-ami-ecs-hvm-2023.0.20251101-kernel-6.1-arm64" } }
}
variables {
  account_id  = "123456789012"
  owner       = "local-fixture"
  cost_center = "local-fixture"
  az_names    = ["sa-east-1a", "sa-east-1b"]
}
run "app_stack_off_by_default" {
  command = plan
  assert {
    condition     = output.foundation == null && output.api_alb_dns_name == null && output.edge == null && output.migrate_run_task == null && output.workers_cluster_arn == null
    error_message = "Sem provision_enabled, nada da pilha de aplicação é planejado."
  }
}
run "flags_without_provision_create_nothing" {
  command = plan
  variables {
    foundation_enabled = true
    api_enabled        = true
    workers_enabled    = true
  }
  assert {
    condition     = output.foundation == null && output.workers_cluster_arn == null
    error_message = "As chaves de bloco não ligam nada sem provision_enabled."
  }
}
run "configuration_uses_the_stack_secrets_key" {
  command = plan
  variables {
    provision_enabled  = true
    foundation_enabled = true
    credit_approval    = { account_id = "123456789012", evidence_reference = "test-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
  }
  override_resource {
    target          = module.app_stack.aws_kms_key.this
    override_during = plan
    values          = { arn = "arn:aws:kms:sa-east-1:123456789012:key/stack-key" }
  }
  assert {
    condition     = output.foundation != null && module.app_stack.secrets_key_arn == "arn:aws:kms:sa-east-1:123456789012:key/stack-key"
    error_message = "Sem secrets_key_arn explícita, o modules/configuration do root usa a CMK de segredos da pilha."
  }
}
run "network_reaches_api_and_workers" {
  command = plan
  variables {
    provision_enabled   = true
    api_enabled         = true
    workers_enabled     = true
    credit_approval     = { account_id = "123456789012", evidence_reference = "test-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
    api_certificate_arn = "arn:aws:acm:sa-east-1:123456789012:certificate/test-only"
    api_host_names      = ["api.uat.example.com"]
    web_host_names      = ["uat.example.com"]
    api_image           = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    frontend_image      = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-frontend@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    api_logs_key_arn    = "arn:aws:kms:sa-east-1:123456789012:key/test-only"
    workers_image       = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-workers@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    workers_ami_id      = "ami-0123456789abcdef0"
  }
  # O plano sem erro é a prova: rede (subnets, SGs) e segredos do root chegam
  # ao ALB, ao web-service, à migration, aos workers e aos schedules.
  assert {
    condition     = output.edge != null && output.foundation == null
    error_message = "Com provision_enabled, a borda é planejada; sem foundation_enabled, nenhuma CMK."
  }
}
