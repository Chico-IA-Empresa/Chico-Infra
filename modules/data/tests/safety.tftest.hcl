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
    condition     = !aws_db_instance.this[0].publicly_accessible && aws_db_instance.this[0].storage_encrypted && aws_db_instance.this[0].skip_final_snapshot && aws_db_instance.this[0].backup_retention_period == 0
    error_message = "UAT deve ser privado/criptografado e descartável."
  }
  assert {
    condition     = aws_elasticache_replication_group.this[0].transit_encryption_enabled && aws_elasticache_replication_group.this[0].at_rest_encryption_enabled && aws_elasticache_replication_group.this[0].transit_encryption_mode == "required"
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
    condition     = aws_db_instance.this[0].deletion_protection && !aws_db_instance.this[0].skip_final_snapshot && aws_db_instance.this[0].backup_retention_period == 14 && aws_db_instance.this[0].instance_class == "db.t4g.medium" && !aws_db_instance.this[0].multi_az
    error_message = "Preservar baseline e proteção aprovados AWS-005."
  }
  assert {
    condition     = contains([for parameter in aws_db_parameter_group.this[0].parameter : "${parameter.name}=${parameter.value}"], "idle_in_transaction_session_timeout=300000")
    error_message = "Sessão ociosa no meio de transação cai em 5 min, não no default de 24 h do RDS."
  }
}
run "uat_empty_database_starts_without_snapshot" {
  command = plan
  variables {
    uat_empty_database     = true
    sanitized_snapshot_arn = null
  }
  assert {
    condition     = aws_db_instance.this[0].skip_final_snapshot && aws_db_instance.this[0].backup_retention_period == 0
    error_message = "UAT vazio passa a precondition sem snapshot e continua descartável."
  }
}
run "uat_empty_database_refuses_a_snapshot_too" {
  command = plan
  variables { uat_empty_database = true }
  expect_failures = [aws_db_instance.this]
}
run "uat_without_either_is_refused" {
  command = plan
  variables { sanitized_snapshot_arn = null }
  expect_failures = [aws_db_instance.this]
}
