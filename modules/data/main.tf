variable "env" {
  type = string
  validation {
    condition     = contains(["uat", "prod"], var.env)
    error_message = "Dados gerenciados apenas em UAT/Prod."
  }
}
variable "subnet_ids" { type = list(string) }
variable "rds_sg_id" { type = string }
variable "cache_sg_id" { type = string }
variable "availability_zone" { type = string }
variable "postgres_version" {
  type = string
  validation {
    condition     = can(regex("^16\\.[0-9]+$", var.postgres_version))
    error_message = "Escolher minor 16.x após describe-db-engine-versions em sa-east-1."
  }
}
variable "valkey_version" { type = string }
variable "data_key_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:kms:sa-east-1:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.data_key_arn))
    error_message = "Chave KMS explícita obrigatória, segregando Prod e dados sanitizados."
  }
}
variable "cache_user_group_ids" {
  type = set(string)
  validation {
    condition     = length(var.cache_user_group_ids) > 0
    error_message = "Grupo RBAC revisado obrigatório, com credenciais injetadas fora do state."
  }
}
variable "sanitized_snapshot_arn" {
  type    = string
  default = null
}
variable "account_id" { type = string }
variable "final_snapshot_identifier" {
  type    = string
  default = null
}
resource "aws_db_subnet_group" "this" {
  name       = "chico-${var.env}"
  subnet_ids = var.subnet_ids
}
resource "aws_db_parameter_group" "this" {
  name   = "chico-${var.env}-postgres16"
  family = "postgres16"
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }
  parameter {
    name  = "pg_stat_statements.track"
    value = "all"
  }
  parameter {
    name  = "log_min_duration_statement"
    value = "500"
  }
}
resource "aws_cloudwatch_log_group" "postgresql" {
  name              = "/aws/rds/instance/chico-${var.env}/postgresql"
  retention_in_days = 30
  kms_key_id        = var.data_key_arn
}
resource "aws_db_instance" "this" {
  identifier                            = "chico-${var.env}"
  engine                                = "postgres"
  engine_version                        = var.postgres_version
  instance_class                        = var.env == "prod" ? "db.t4g.medium" : "db.t4g.small"
  allocated_storage                     = 40
  max_allocated_storage                 = 200
  storage_type                          = "gp3"
  storage_encrypted                     = true
  kms_key_id                            = var.data_key_arn
  db_subnet_group_name                  = aws_db_subnet_group.this.name
  vpc_security_group_ids                = [var.rds_sg_id]
  availability_zone                     = var.availability_zone
  publicly_accessible                   = false
  multi_az                              = false
  parameter_group_name                  = aws_db_parameter_group.this.name
  snapshot_identifier                   = var.env == "uat" ? var.sanitized_snapshot_arn : null
  username                              = var.env == "prod" ? "chico_owner" : null
  manage_master_user_password           = true
  master_user_secret_kms_key_id         = var.data_key_arn
  enabled_cloudwatch_logs_exports       = ["postgresql"]
  database_insights_mode                = "standard"
  performance_insights_enabled          = var.env == "prod"
  performance_insights_retention_period = var.env == "prod" ? 7 : null
  performance_insights_kms_key_id       = var.env == "prod" ? var.data_key_arn : null
  depends_on                            = [aws_cloudwatch_log_group.postgresql]
  backup_retention_period               = var.env == "prod" ? 14 : 0
  backup_window                         = "06:00-06:30"
  maintenance_window                    = "sun:07:00-sun:08:00"
  deletion_protection                   = var.env == "prod"
  skip_final_snapshot                   = var.env == "uat"
  final_snapshot_identifier             = var.env == "prod" ? var.final_snapshot_identifier : null
  copy_tags_to_snapshot                 = true
  auto_minor_version_upgrade            = true
  allow_major_version_upgrade           = false
  apply_immediately                     = false
  lifecycle {
    precondition {
      condition     = var.env != "uat" || try(startswith(var.sanitized_snapshot_arn, "arn:aws:rds:sa-east-1:${var.account_id}:snapshot:uat-sanitized-"), false)
      error_message = "UAT restaura somente ARN sanitizado aprovado da conta/região. Prefixo não substitui aprovação/KMS/IAM reais."
    }
    precondition {
      condition     = var.env != "prod" || try(length(var.final_snapshot_identifier) > 0, false)
      error_message = "Snapshot final nomeado obrigatório em Prod."
    }
  }
}
resource "aws_elasticache_subnet_group" "this" {
  name       = "chico-${var.env}"
  subnet_ids = var.subnet_ids
}
resource "aws_elasticache_replication_group" "this" {
  replication_group_id        = "chico-${var.env}"
  description                 = "Cache compartilhado de negocio ${var.env}; dados privados segregados pela aplicacao"
  engine                      = "valkey"
  engine_version              = var.valkey_version
  node_type                   = "cache.t4g.micro"
  num_cache_clusters          = 1
  automatic_failover_enabled  = false
  multi_az_enabled            = false
  subnet_group_name           = aws_elasticache_subnet_group.this.name
  security_group_ids          = [var.cache_sg_id]
  preferred_cache_cluster_azs = [var.availability_zone]
  at_rest_encryption_enabled  = true
  kms_key_id                  = var.data_key_arn
  transit_encryption_enabled  = true
  transit_encryption_mode     = "required"
  user_group_ids              = var.cache_user_group_ids
  port                        = 6379
  apply_immediately           = false
}
output "postgres_address" { value = aws_db_instance.this.address }
output "cache_address" { value = aws_elasticache_replication_group.this.primary_endpoint_address }
