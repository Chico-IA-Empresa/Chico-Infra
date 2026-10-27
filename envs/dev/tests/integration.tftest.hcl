mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    override_during = plan
    defaults        = { arn = "arn:aws:s3:::chico-dev-synthetic-fixture" }
  }
  mock_data "aws_ami" {
    defaults = { architecture = "arm64", state = "available", name = "al2023-ami-2023.10-kernel-6.1-arm64" }
  }
}
variables {
  account_id  = "123456789012"
  owner       = "local-fixture"
  cost_center = "local-fixture"
  az_names    = ["sa-east-1a"]
}
run "disabled_by_default" {
  command = plan
  assert {
    condition     = length(module.network) == 0 && length(module.dev_box) == 0 && length(aws_iam_role.runtime) == 0 && output.host == null
    error_message = "Flags desligadas não podem criar recursos AWS."
  }
}
run "host_integration" {
  command = plan
  variables {
    provision_enabled              = true
    permissions_boundary_arns      = { runtime = "arn:aws:iam::123456789012:policy/chico/shared/chico-dev-runtime-boundary", flow = "arn:aws:iam::123456789012:policy/chico/shared/chico-dev-flow-boundary" }
    compute_enabled                = true
    credit_approval                = { account_id = "123456789012", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
    ami_id                         = "ami-0123456789abcdef0"
    compose_version                = "v5.6.0"
    backup_bucket_name             = "chico-dev-synthetic-fixture"
    fixture_backup_retention_days  = 7
    database_backup_retention_days = 14
    manage_access_log_sink         = true
    root_volume_size_gib           = 80
    access_log_bucket_name         = "chico-dev-access-synthetic-fixture"
    parameters                     = { "api/FIXTURE_MODE" = "synthetic" }
    logs_key_arn                   = "arn:aws:kms:sa-east-1:123456789012:key/synthetic-fixture"
    alarm_topic_arn                = "arn:aws:sns:sa-east-1:123456789012:chico-dev-synthetic"
    compose_sha256                 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    repository_arns                = ["arn:aws:ecr:sa-east-1:123456789012:repository/chico-api", "arn:aws:ecr:sa-east-1:123456789012:repository/chico-workers", "arn:aws:ecr:sa-east-1:123456789012:repository/chico-frontend"]
  }
  assert {
    condition     = length(module.backup_access_logs) == 1 && output.database_backup.prefix == "dev/database/" && output.database_backup.retention_days == 14 && length(aws_s3_bucket_lifecycle_configuration.backup[0].rule) == 2 && !strcontains(aws_iam_role_policy.backup[0].policy, "chico-backup") && !strcontains(aws_iam_role_policy.backup[0].policy, "s3:DeleteObject")
    error_message = "Backups reais devem ter prefixo/retenção próprios, sem escrita/leitura da origem legada nem exclusão runtime."
  }
  assert {
    condition     = length(module.dev_box) == 1 && length(aws_iam_instance_profile.runtime) == 1 && length(module.network) == 1
    error_message = "Root deve conectar rede, profile gerenciado e host."
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.pull[0].policy, "ecr:PutImage") && !strcontains(aws_iam_role_policy.pull[0].policy, "s3:")
    error_message = "Host não pode publicar imagem nem receber leitura de state."
  }
  assert {
    condition     = !anytrue([for statement in jsondecode(aws_iam_role_policy.ssm_agent[0].policy).Statement : contains(statement.Action, "ssm:GetParameter") || contains(statement.Action, "ssm:GetParameters") || contains(statement.Action, "ssm:GetParametersByPath")]) && jsondecode(aws_iam_role_policy.configuration[0].policy).Statement[0].Resource == ["arn:aws:ssm:sa-east-1:123456789012:parameter/chico/dev/api/FIXTURE_MODE"]
    error_message = "SSM Agent não pode contornar allowlist de configuração Dev com leitura global de parâmetros."
  }
  assert {
    condition     = aws_s3_bucket.backup[0].force_destroy == false && aws_s3_bucket_versioning.backup[0].versioning_configuration[0].status == "Enabled" && aws_s3_bucket_public_access_block.backup[0].block_public_policy && aws_s3_bucket_public_access_block.backup[0].restrict_public_buckets
    error_message = "Backup privado/versionado sem exclusão forçada."
  }
  assert {
    condition     = length(aws_route53_record.dev) == 0 && length(aws_cloudwatch_log_group.dev) == 4 && length(aws_cloudwatch_metric_alarm.runtime) == 3
    error_message = "DNS requer autorização separada; memória/disco/backup devem ter sinais explícitos."
  }
}
run "reject_foreign_log_sink" {
  command = plan
  variables { access_log_bucket_name = "legacy-production-backups" }
  expect_failures = [var.access_log_bucket_name]
}
run "reject_prod_hostname" {
  command = plan
  variables { dev_hostname = "www.example.com" }
  expect_failures = [var.dev_hostname]
}
run "reject_foreign_registry" {
  command = plan
  variables { repository_arns = ["arn:aws:ecr:sa-east-1:999999999999:repository/chico-api"] }
  expect_failures = [var.repository_arns]
}
