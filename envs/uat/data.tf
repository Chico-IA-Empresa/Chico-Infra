variable "database_name" {
  type    = string
  default = null
}
variable "allocated_storage_gib" {
  type    = number
  default = 40
}
variable "max_allocated_storage_gib" {
  type    = number
  default = 200
}
# Null inherits the legacy data_enabled switch, preserving existing callers.
variable "rds_enabled" {
  type    = bool
  default = null
}
variable "cache_enabled" {
  type    = bool
  default = null
}
locals {
  rds_enabled   = coalesce(var.rds_enabled, var.data_enabled)
  cache_enabled = coalesce(var.cache_enabled, var.data_enabled)
}

variable "data_enabled" {
  type    = bool
  default = false
}
variable "postgres_version" {
  type    = string
  default = null
}
variable "valkey_version" {
  type    = string
  default = null
}
variable "data_key_arn" {
  type    = string
  default = null
}
variable "cache_user_group_ids" {
  type    = set(string)
  default = []
}
variable "sanitized_snapshot_arn" {
  type    = string
  default = null
}
variable "final_snapshot_identifier" {
  type    = string
  default = null
}
variable "data_alarm_topic_arns" {
  description = "Tópicos extras para os alarmes de banco e cache; o tópico da pilha (foundation_enabled) entra sempre."
  type        = list(string)
  default     = []
}
variable "connections_alarm_threshold" {
  description = "Null = ~75% do max_connections padrão da classe (modules/data/alarms.tf)."
  type        = number
  default     = null
}
variable "empty_database" {
  description = "Sobe o RDS de UAT vazio (migrations criam o schema), sem snapshot. Alternativa a sanitized_snapshot_arn."
  type        = bool
  default     = false
}

# Chave dos dados de UAT (RDS, segredo do usuário mestre, log do Postgres),
# separada da de Prod e das chaves da foundation. data_key_arn explícito vence.
locals {
  uat_data_key_on  = var.provision_enabled && local.rds_enabled && var.data_key_arn == null
  uat_rds_log_arn  = "arn:aws:logs:sa-east-1:${var.account_id}:log-group:/aws/rds/instance/chico-uat/postgresql"
  uat_data_key_arn = var.data_key_arn != null ? var.data_key_arn : try(aws_kms_key.data[0].arn, null)
}

resource "aws_kms_key" "data" {
  count                   = local.uat_data_key_on ? 1 : 0
  description             = "Chico UAT data (RDS, master secret, Postgres log); managed by uat root"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Sid = "AccountRecoveryAndIAMDelegation", Effect = "Allow", Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }, Action = "kms:*", Resource = "*" },
    {
      Sid       = "PostgresLogEncryption", Effect = "Allow", Principal = { Service = "logs.sa-east-1.amazonaws.com" },
      Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"], Resource = "*",
      Condition = { ArnEquals = { "kms:EncryptionContext:aws:logs:arn" = local.uat_rds_log_arn } }
    }
  ] })
  tags       = { env = "uat" }
  depends_on = [module.funding]
}

resource "aws_kms_alias" "data" {
  count         = local.uat_data_key_on ? 1 : 0
  name          = "alias/chico/uat/data"
  target_key_id = aws_kms_key.data[0].key_id
}

module "data" {
  count                       = var.provision_enabled && (local.rds_enabled || local.cache_enabled) ? 1 : 0
  source                      = "../../modules/data"
  rds_enabled                 = local.rds_enabled
  cache_enabled               = local.cache_enabled
  database_name               = var.database_name
  allocated_storage_gib       = var.allocated_storage_gib
  max_allocated_storage_gib   = var.max_allocated_storage_gib
  env                         = "uat"
  account_id                  = var.account_id
  subnet_ids                  = module.network[0].data_subnet_ids
  rds_sg_id                   = module.network[0].security_group_ids["rds"]
  cache_sg_id                 = module.network[0].security_group_ids["cache"]
  availability_zone           = module.network[0].worker_rds_az
  postgres_version            = var.postgres_version
  valkey_version              = var.valkey_version
  data_key_arn                = local.uat_data_key_arn
  uat_empty_database          = var.empty_database
  cache_user_group_ids        = var.cache_user_group_ids
  sanitized_snapshot_arn      = var.sanitized_snapshot_arn
  final_snapshot_identifier   = var.final_snapshot_identifier
  alarm_topic_arns            = concat(var.data_alarm_topic_arns, module.app_stack.alarm_topic_arns)
  connections_alarm_threshold = var.connections_alarm_threshold
  depends_on                  = [module.funding]
}
