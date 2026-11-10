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
run "classification_does_not_substitute_for_reviewed_sensitive_data_handling" {
  command = plan
  variables {
    provision_enabled = true
    credit_approval   = { account_id = "306915830875", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
    restore_preflight = {
      evidence_reference                        = "synthetic-mock-only"
      source_manifest_sha256                    = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      selected_versions_and_metadata_reviewed   = true
      source_classification_reviewed            = true
      data_handling_reviewed                    = false
      capacity_160gib_48h_approved              = true
      private_cipher_transfer_reviewed          = true
      toolchain_and_pre_restore_checks_reviewed = true
      destination_and_dev_ready                 = true
      no_concurrent_arm_builder                 = true
      business_writers_disabled                 = true
    }
  }
  expect_failures = [terraform_data.readiness]
}

run "dev_readiness_does_not_approve_prod_export" {
  command = plan
  variables {
    provision_enabled       = true
    destination_env         = "prod"
    destination_bucket_name = "chico-prod-recovery-306915830875-sa-east-1"
    destination_key_arn     = "arn:aws:kms:sa-east-1:306915830875:key/11111111-1111-1111-1111-111111111111"
    credit_approval         = { account_id = "306915830875", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
    restore_preflight = {
      evidence_reference                        = "synthetic-mock-only"
      source_manifest_sha256                    = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      selected_versions_and_metadata_reviewed   = true
      source_classification_reviewed            = true
      data_handling_reviewed                    = true
      capacity_160gib_48h_approved              = true
      private_cipher_transfer_reviewed          = true
      toolchain_and_pre_restore_checks_reviewed = true
      destination_and_dev_ready                 = true
      no_concurrent_arm_builder                 = true
      business_writers_disabled                 = true
    }
  }
  expect_failures = [terraform_data.readiness]
}
run "reviewed_prod_export_does_not_require_live_dev_database" {
  command = plan
  variables {
    provision_enabled       = true
    destination_env         = "prod"
    destination_bucket_name = "chico-prod-recovery-306915830875-sa-east-1"
    destination_key_arn     = "arn:aws:kms:sa-east-1:306915830875:key/11111111-1111-1111-1111-111111111111"
    credit_approval         = { account_id = "306915830875", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = "2099-01-01", all_charges_covered = true, shutdown_reserve_confirmed = true }
    restore_preflight = {
      evidence_reference                        = "synthetic-mock-only"
      source_manifest_sha256                    = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      selected_versions_and_metadata_reviewed   = true
      source_classification_reviewed            = true
      data_handling_reviewed                    = true
      capacity_160gib_48h_approved              = true
      private_cipher_transfer_reviewed          = true
      toolchain_and_pre_restore_checks_reviewed = true
      destination_and_dev_ready                 = false
      rds_export_destination_reviewed           = true
      no_concurrent_arm_builder                 = true
      business_writers_disabled                 = true
    }
  }
  assert {
    condition     = output.conversion_destination.environment == "prod" && output.conversion_destination.prefix == "imports/synthetic-only/" && !output.conversion_destination.rds_import_and_validation_proven
    error_message = "Prod conversion is only an export, never proof of SQL import or dependence on a Dev DB."
  }
}

run "lease_cannot_outlive_funding_review" {
  command = plan
  variables {
    provision_enabled       = true
    destination_env         = "prod"
    destination_bucket_name = "chico-prod-recovery-306915830875-sa-east-1"
    destination_key_arn     = "arn:aws:kms:sa-east-1:306915830875:key/11111111-1111-1111-1111-111111111111"
    credit_approval         = { account_id = "306915830875", evidence_reference = "synthetic-mock-only", reviewed_on = "2026-01-01", expires_on = formatdate("YYYY-MM-DD", timeadd(timestamp(), "24h")), all_charges_covered = true, shutdown_reserve_confirmed = true }
    restore_preflight = {
      evidence_reference                        = "synthetic-mock-only"
      source_manifest_sha256                    = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      selected_versions_and_metadata_reviewed   = true
      source_classification_reviewed            = true
      data_handling_reviewed                    = true
      capacity_160gib_48h_approved              = true
      private_cipher_transfer_reviewed          = true
      toolchain_and_pre_restore_checks_reviewed = true
      destination_and_dev_ready                 = false
      rds_export_destination_reviewed           = true
      no_concurrent_arm_builder                 = true
      business_writers_disabled                 = true
    }
  }
  expect_failures = [terraform_data.readiness]
}
