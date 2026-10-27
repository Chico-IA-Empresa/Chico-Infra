mock_provider "aws" {
  override_during = plan
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::synthetic-access-log-sink" }
  }
}
variables {
  bucket_name       = "synthetic-access-log-sink"
  source_bucket_arn = "arn:aws:s3:::synthetic-state"
  account_id        = "123456789012"
  retention_days    = 30
}
run "private_source_scoped_delivery" {
  command = plan
  assert {
    condition     = aws_s3_bucket_public_access_block.this.block_public_acls && aws_s3_bucket_public_access_block.this.restrict_public_buckets && aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Enabled"
    error_message = "Destino de logs deve ser privado e versionado."
  }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.this.policy).Statement[0].Condition.StringEquals["aws:SourceArn"] == var.source_bucket_arn && jsondecode(aws_s3_bucket_policy.this.policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == var.account_id
    error_message = "Delivery deve restringir bucket de origem e conta."
  }
}
run "reject_recursive_delivery" {
  command = plan
  variables { source_bucket_arn = "arn:aws:s3:::synthetic-access-log-sink" }
  expect_failures = [aws_s3_bucket.this]
}
run "reject_implicit_retention" {
  command = plan
  variables { retention_days = 0 }
  expect_failures = [var.retention_days]
}
run "dev_backup_prefix_matches_delivery_and_retention" {
  command = plan
  variables { delivery_prefix = "dev/backup-access/" }
  assert {
    condition     = jsondecode(aws_s3_bucket_policy.this.policy).Statement[0].Resource == "arn:aws:s3:::synthetic-access-log-sink/dev/backup-access/*" && one([for r in aws_s3_bucket_lifecycle_configuration.this.rule : r if r.id == "access-logs"]).filter[0].prefix == "dev/backup-access/"
    error_message = "Permissão e lifecycle devem cobrir o prefixo que o Dev realmente entrega."
  }
}
run "reject_wildcard_delivery_prefix" {
  command = plan
  variables { delivery_prefix = "dev/*/" }
  expect_failures = [var.delivery_prefix]
}
run "reject_unresolved_sink_name" {
  command = plan
  variables { bucket_name = null }
  expect_failures = [var.bucket_name]
}
