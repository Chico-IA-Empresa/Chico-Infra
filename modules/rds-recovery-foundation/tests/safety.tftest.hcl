mock_provider "aws" {
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::chico-prod-recovery-123456789012-sa-east-1" }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:sa-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
      key_id = "11111111-1111-1111-1111-111111111111"
    }
  }
}
variables { account_id = "123456789012" }
run "defaults_have_no_resources" {
  command = plan
  assert {
    condition     = length(aws_kms_key.data) == 0 && length(aws_s3_bucket.artifacts) == 0
    error_message = "Foundation must remain off by default."
  }
}
run "private_durable_prod_artifacts" {
  command = plan
  variables {
    create_key      = true
    storage_enabled = true
    bucket_name     = "chico-prod-recovery-123456789012-sa-east-1"
  }
  assert {
    condition     = aws_kms_key.data[0].enable_key_rotation && aws_kms_key.data[0].deletion_window_in_days == 30 && !aws_s3_bucket.artifacts[0].force_destroy
    error_message = "Preserve key rotation and durable artifacts."
  }
  assert {
    condition = (aws_s3_bucket_public_access_block.artifacts[0].block_public_acls &&
      aws_s3_bucket_public_access_block.artifacts[0].block_public_policy &&
      aws_s3_bucket_public_access_block.artifacts[0].ignore_public_acls &&
      aws_s3_bucket_public_access_block.artifacts[0].restrict_public_buckets &&
      aws_s3_bucket_versioning.artifacts[0].versioning_configuration[0].status == "Enabled")
    error_message = "Artifacts must stay private and versioned."
  }
  assert {
    condition     = length(jsondecode(aws_kms_key.data[0].policy).Statement[1].Condition.ArnEquals["kms:EncryptionContext:aws:logs:arn"]) == 3
    error_message = "Log encryption must reference only target, proof and importer log groups."
  }
}
run "reject_dev_or_legacy_bucket" {
  command = plan
  variables {
    storage_enabled = true
    bucket_name     = "chico-backup"
    external_key_arn = "arn:aws:kms:sa-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
  }
  expect_failures = [var.bucket_name]
}
run "require_key_for_artifact_store" {
  command = plan
  variables {
    storage_enabled = true
    bucket_name     = "chico-prod-recovery-123456789012-sa-east-1"
  }
  expect_failures = [aws_s3_bucket.artifacts]
}
