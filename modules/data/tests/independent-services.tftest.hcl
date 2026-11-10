mock_provider "aws" {}
variables {
  env                       = "prod"
  account_id                = "123456789012"
  subnet_ids                = ["subnet-aaaa", "subnet-bbbb"]
  rds_sg_id                 = "sg-aaaa"
  cache_sg_id               = "sg-bbbb"
  availability_zone         = "sa-east-1a"
  postgres_version          = "16.15"
  valkey_version            = "8.0"
  cache_user_group_ids      = ["reviewed-test-group"]
  data_key_arn              = "arn:aws:kms:sa-east-1:123456789012:key/11111111-1111-1111-1111-111111111111"
  final_snapshot_identifier = "chico-prod-final-test"
}
run "legacy_combined_defaults" {
  command = plan
  assert {
    condition     = length(aws_db_instance.this) == 1 && length(aws_elasticache_replication_group.this) == 1
    error_message = "Legacy callers must retain both services."
  }
}
run "database_without_cache_prerequisites" {
  command = plan
  variables {
    cache_enabled        = false
    cache_user_group_ids = []
    valkey_version       = null
    cache_sg_id          = null
  }
  assert {
    condition     = length(aws_db_instance.this) == 1 && length(aws_elasticache_replication_group.this) == 0 && length(aws_elasticache_subnet_group.this) == 0
    error_message = "RDS-only must not create cache or require its inputs."
  }
  assert {
    condition     = !aws_db_instance.this[0].publicly_accessible && aws_db_instance.this[0].storage_encrypted && aws_db_instance.this[0].deletion_protection && aws_db_instance.this[0].backup_retention_period == 14 && aws_db_instance.this[0].manage_master_user_password
    error_message = "RDS-only must retain private encrypted managed credentials and recovery controls."
  }
}
run "cache_without_database_prerequisites" {
  command = plan
  variables {
    rds_enabled               = false
    postgres_version          = null
    rds_sg_id                 = null
    final_snapshot_identifier = null
  }
  assert {
    condition     = length(aws_db_instance.this) == 0 && length(aws_db_subnet_group.this) == 0 && length(aws_db_parameter_group.this) == 0 && length(aws_cloudwatch_log_group.postgresql) == 0 && length(aws_elasticache_replication_group.this) == 1
    error_message = "Cache-only must not create database resources."
  }
}
run "cache_still_requires_rbac" {
  command = plan
  variables { cache_user_group_ids = [] }
  expect_failures = [var.cache_user_group_ids]
}
run "database_still_requires_pg16" {
  command = plan
  variables { postgres_version = "17.1" }
  expect_failures = [var.postgres_version]
}

run "reviewed_capacity_and_initial_database" {
  command = plan
  variables {
    cache_enabled             = false
    database_name             = "sofascore"
    allocated_storage_gib     = 120
    max_allocated_storage_gib = 200
  }
  assert {
    condition     = aws_db_instance.this[0].db_name == "sofascore" && aws_db_instance.this[0].allocated_storage == 120
    error_message = "Use the reviewed database name and measured capacity."
  }
}
run "reject_autoscaling_without_headroom" {
  command = plan
  variables {
    allocated_storage_gib     = 200
    max_allocated_storage_gib = 200
  }
  expect_failures = [var.max_allocated_storage_gib]
}
