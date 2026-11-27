# O modules/configuration fica no root; aqui ele entra como o mapa que devolve
# (nome revisado → ARN), em config_secret_arns.
mock_provider "aws" {
  mock_data "aws_ami" { defaults = { architecture = "arm64", state = "available", name = "al2023-ami-ecs-hvm-2023.0.20251101-kernel-6.1-arm64" } }
}
variables {
  env                = "uat"
  account_id         = "123456789012"
  vpc_id             = "vpc-0123456789abcdef0"
  public_subnet_ids  = ["subnet-0aaaaaaaaaaaaaaaa", "subnet-0bbbbbbbbbbbbbbbb"]
  security_group_ids = { alb = "sg-0000000000000000a", api = "sg-0000000000000000b", frontend = "sg-0000000000000000c", workers = "sg-0000000000000000d", jobs = "sg-0000000000000000e" }
  enabled            = true
  workers_enabled    = true
  workers_image      = "123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-workers@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  workers_ami_id     = "ami-0123456789abcdef0"
  config_secret_arns = { "workers/DATABASE_URL" = "arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/DATABASE_URL-AbCdEf" }
  secrets_key_arn    = "arn:aws:kms:sa-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
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
    condition     = local.workers_secret_arns == tolist(["arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/workers/OTHER-QwErTy"])
    error_message = "workers_secret_arns preenchida vence a derivação."
  }
}
