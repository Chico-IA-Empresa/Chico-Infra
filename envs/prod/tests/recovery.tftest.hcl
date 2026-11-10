mock_provider "aws" {
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:sa-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
      key_id = "11111111-1111-1111-1111-111111111111"
    }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      address            = "synthetic-db.internal.test"
      master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:sa-east-1:123456789012:secret:rds!synthetic-abcdef", secret_status = "active", kms_key_id = "synthetic-key" }]
    }
  }
}
variables {
  account_id  = "123456789012"
  owner       = "synthetic-test-owner"
  cost_center = "synthetic-test"
  az_names    = ["sa-east-1a", "sa-east-1b"]
  credit_approval = {
    account_id                 = "123456789012"
    evidence_reference         = "synthetic-test-only-never-apply"
    reviewed_on                = formatdate("YYYY-MM-DD", timeadd(timestamp(), "-24h"))
    expires_on                 = formatdate("YYYY-MM-DD", timeadd(timestamp(), "48h"))
    all_charges_covered        = true
    shutdown_reserve_confirmed = true
  }
}
run "all_resources_default_off" {
  command = plan
  assert {
    condition     = length(module.data) == 0 && length(module.recovery_foundation) == 0 && length(module.rds_importer) == 0 && length(aws_db_instance.recovery_proof) == 0
    error_message = "Defaults must not create a database, key, store, importer or proof instance."
  }
}
run "database_only_with_managed_prod_key" {
  command = plan
  variables {
    provision_enabled         = true
    rds_enabled               = true
    cache_enabled             = false
    managed_data_key_enabled  = true
    postgres_version          = "16.15"
    database_name             = "sofascore"
    allocated_storage_gib     = 120
    final_snapshot_identifier = "synthetic-prod-final"
  }
  assert {
    condition     = module.data[0].cache_address == null && length(module.data) == 1 && length(module.rds_importer) == 0 && length(aws_db_instance.recovery_proof) == 0
    error_message = "Target creation must be independent of Valkey, importer and proof resources."
  }
}
run "restore_independent_named_instance" {
  command = plan
  variables {
    provision_enabled         = true
    rds_enabled               = true
    cache_enabled             = false
    managed_data_key_enabled  = true
    postgres_version          = "16.15"
    final_snapshot_identifier = "synthetic-prod-final"
    recovery_proof_enabled    = true
    validated_snapshot_arn    = "arn:aws:rds:sa-east-1:123456789012:snapshot:chico-prod-validated-synthetic"
  }
  assert {
    condition     = aws_db_instance.recovery_proof[0].identifier == "chico-prod-recovery-proof" && aws_db_instance.recovery_proof[0].snapshot_identifier == var.validated_snapshot_arn && !aws_db_instance.recovery_proof[0].publicly_accessible && aws_db_instance.recovery_proof[0].manage_master_user_password && aws_db_instance.recovery_proof[0].deletion_protection
    error_message = "Proof must restore the validated snapshot to a distinct protected private instance."
  }
}
run "reject_unvalidated_snapshot_source" {
  command = plan
  variables {
    recovery_proof_enabled = true
    validated_snapshot_arn = "arn:aws:rds:sa-east-1:123456789012:snapshot:unknown-source"
  }
  expect_failures = [var.validated_snapshot_arn]
}
