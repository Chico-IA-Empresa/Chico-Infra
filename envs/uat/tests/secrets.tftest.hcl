mock_provider "aws" {
  override_during = plan
  mock_data "aws_ami" { defaults = { architecture = "arm64", state = "available", name = "al2023-ami-ecs-hvm-2023.0.20251101-kernel-6.1-arm64" } }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/DATABASE_URL-AbCdEf" }
  }
}
variables {
  account_id        = "123456789012"
  owner             = "local-fixture"
  cost_center       = "local-fixture"
  az_names          = ["sa-east-1a", "sa-east-1b"]
  provision_enabled = true
  workers_enabled   = true
  credit_approval   = { account_id = "123456789012", evidence_reference = "test-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
  workers_image     = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-workers@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  workers_ami_id    = "ami-0123456789abcdef0"
  secret_names      = ["workers/DATABASE_URL"]
}

run "no_references_no_secret_grant" {
  command = plan
  assert {
    condition     = length(local.workers_secret_arns) == 0 && length(local.api_secret_arns) == 0
    error_message = "Sem referência, nenhum papel lê segredo."
  }
}

run "names_resolve_to_configuration_arns" {
  command = plan
  variables {
    workers_secrets = {
      odds-bsd       = [{ name = "DATABASE_URL", valueFrom = "workers/DATABASE_URL" }]
      data-freshness = [{ name = "RAPIDAPI_KEY", valueFrom = "arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/RAPIDAPI-XyZ123:key::" }]
    }
  }
  assert {
    condition     = local.workers_secrets_resolved["odds-bsd"][0].valueFrom == "arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/DATABASE_URL-AbCdEf"
    error_message = "Nome de secret_names vira o ARN do module.configuration."
  }
  assert {
    condition     = local.workers_secrets_resolved["data-freshness"][0].valueFrom == "arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/RAPIDAPI-XyZ123:key::"
    error_message = "ARN explícito (com chave JSON) passa intacto para a task definition."
  }
  assert {
    condition = toset(local.workers_secret_arns) == toset([
      "arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/DATABASE_URL-AbCdEf",
      "arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/RAPIDAPI-XyZ123",
    ]) && length(local.api_secret_arns) == 0
    error_message = "O papel dos workers lê exatamente os segredos referenciados, sem sufixo de chave; a API não herda nada."
  }
}

run "explicit_list_wins" {
  command = plan
  variables {
    workers_secrets     = { odds-bsd = [{ name = "DATABASE_URL", valueFrom = "workers/DATABASE_URL" }] }
    workers_secret_arns = ["arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/OTHER-QwErTy"]
  }
  assert {
    condition     = local.workers_secret_arns == ["arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/OTHER-QwErTy"]
    error_message = "workers_secret_arns preenchida vence a derivação."
  }
}
