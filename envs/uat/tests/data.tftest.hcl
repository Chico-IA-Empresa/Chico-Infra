mock_provider "aws" {
  mock_data "aws_ami" { defaults = { architecture = "arm64", state = "available", name = "al2023-ami-ecs-hvm-2023.0.20251101-kernel-6.1-arm64" } }
}
variables {
  account_id        = "123456789012"
  owner             = "local-fixture"
  cost_center       = "local-fixture"
  az_names          = ["sa-east-1a", "sa-east-1b"]
  provision_enabled = true
  credit_approval   = { account_id = "123456789012", evidence_reference = "test-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
}
run "empty_database_gets_its_own_key" {
  command = plan
  variables {
    rds_enabled      = true
    cache_enabled    = false
    empty_database   = true
    database_name    = "chico"
    postgres_version = "16.6"
  }
  assert {
    condition     = length(aws_kms_key.data) == 1 && aws_kms_alias.data[0].name == "alias/chico/uat/data" && aws_kms_key.data[0].enable_key_rotation
    error_message = "RDS de UAT sem chave explícita ganha alias/chico/uat/data, com rotação."
  }
  assert {
    condition     = strcontains(aws_kms_key.data[0].policy, "/aws/rds/instance/chico-uat/postgresql") && length(module.data) == 1
    error_message = "A chave só cifra o log do Postgres de UAT para o CloudWatch Logs; o banco sobe vazio."
  }
}
run "no_data_key_without_rds" {
  command = plan
  assert {
    condition     = length(aws_kms_key.data) == 0 && length(module.data) == 0
    error_message = "Sem banco, nenhuma chave de dados."
  }
}
run "explicit_key_wins" {
  command = plan
  variables {
    rds_enabled      = true
    cache_enabled    = false
    empty_database   = true
    postgres_version = "16.6"
    data_key_arn     = "arn:aws:kms:sa-east-1:123456789012:key/explicit-test-only"
  }
  assert {
    condition     = length(aws_kms_key.data) == 0
    error_message = "data_key_arn explícito dispensa a chave do root."
  }
}
