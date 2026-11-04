mock_provider "aws" {
  override_during = plan
  mock_data "aws_ami" {
    defaults = { architecture = "x86_64", state = "available", name = "al2023-ami-synthetic-only", product_codes = [] }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.10.0.0/16", tags = { project = "chicoai", env = "dev" } }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-synthetic" }
  }
}
variables {
  account_id              = "306915830875"
  owner                   = "synthetic-only"
  cost_center             = "synthetic-only"
  ami_id                  = "ami-synthetic"
  vpc_id                  = "vpc-synthetic"
  subnet_id               = "subnet-synthetic"
  destination_bucket_name = "chico-dev-synthetic-backup"
  import_id               = "synthetic-only"
  source_manifest_sha256  = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  source_list_prefixes    = ["pgbackrest/sofascore-postgres/backup/main/backup.info"]
  not_before_utc          = timeadd(timestamp(), "-1h")
  expires_at_utc          = timeadd(timestamp(), "46h")
  source_version_policy_documents = [jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Action = ["s3:GetObjectVersion"], Resource = "arn:aws:s3:::chico-backup/pgbackrest/sofascore-postgres/backup/main/backup.info",
    Condition = { StringEquals = { "s3:VersionId" = "synthetic-version-only" } }
  }] })]
}
run "disabled_root_has_no_aws_children" {
  command = plan
  assert {
    condition     = length(module.access) == 0 && length(module.host) == 0 && terraform_data.readiness.input == false
    error_message = "Staging não pode ser ativado pela presença da root ou por inputs de fixture."
  }
}
run "enabled_root_requires_private_preflight_besides_funding" {
  command = plan
  variables {
    provision_enabled = true
    credit_approval   = { account_id = "306915830875", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
  }
  expect_failures = [terraform_data.readiness]
}
