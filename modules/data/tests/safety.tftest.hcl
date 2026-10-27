mock_provider "aws" {}
variables {
  env                    = "uat"
  account_id             = "123456789012"
  subnet_ids             = ["subnet-test1", "subnet-test2"]
  rds_sg_id              = "sg-rds"
  cache_sg_id            = "sg-cache"
  availability_zone      = "sa-east-1a"
  postgres_version       = "16.1"
  valkey_version         = "7.2"
  data_key_arn           = "arn:aws:kms:sa-east-1:123456789012:key/test-only"
  cache_user_group_ids   = ["test-only"]
  sanitized_snapshot_arn = "arn:aws:rds:sa-east-1:123456789012:snapshot:uat-sanitized-test-only"
}
run "uat_private_encrypted_disposable" {
  command = plan
  assert {
    condition     = !aws_db_instance.this.publicly_accessible && aws_db_instance.this.storage_encrypted && aws_db_instance.this.skip_final_snapshot && aws_db_instance.this.backup_retention_period == 0
    error_message = "UAT deve ser privado/criptografado e descartável."
  }
  assert {
    condition     = aws_elasticache_replication_group.this.transit_encryption_enabled && aws_elasticache_replication_group.this.at_rest_encryption_enabled && aws_elasticache_replication_group.this.transit_encryption_mode == "required"
    error_message = "TLS e criptografia obrigatórios no cache."
  }
}
run "reject_raw_snapshot" {
  command = plan
  variables { sanitized_snapshot_arn = "arn:aws:rds:sa-east-1:123456789012:snapshot:prod-raw" }
  expect_failures = [aws_db_instance.this]
}
run "prod_protected_baseline" {
  command = plan
  variables {
    env                       = "prod"
    final_snapshot_identifier = "test-only-final"
  }
  assert {
    condition     = aws_db_instance.this.deletion_protection && !aws_db_instance.this.skip_final_snapshot && aws_db_instance.this.backup_retention_period == 14 && aws_db_instance.this.instance_class == "db.t4g.medium" && !aws_db_instance.this.multi_az
    error_message = "Preservar baseline e proteção aprovados AWS-005."
  }
}
