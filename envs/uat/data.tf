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
module "data" {
  count                     = var.provision_enabled && (local.rds_enabled || local.cache_enabled) ? 1 : 0
  source                    = "../../modules/data"
  rds_enabled               = local.rds_enabled
  cache_enabled             = local.cache_enabled
  database_name             = var.database_name
  allocated_storage_gib     = var.allocated_storage_gib
  max_allocated_storage_gib = var.max_allocated_storage_gib
  env                       = "uat"
  account_id                = var.account_id
  subnet_ids                = module.network[0].data_subnet_ids
  rds_sg_id                 = module.network[0].security_group_ids["rds"]
  cache_sg_id               = module.network[0].security_group_ids["cache"]
  availability_zone         = module.network[0].worker_rds_az
  postgres_version          = var.postgres_version
  valkey_version            = var.valkey_version
  data_key_arn              = var.data_key_arn
  cache_user_group_ids      = var.cache_user_group_ids
  sanitized_snapshot_arn    = var.sanitized_snapshot_arn
  final_snapshot_identifier = var.final_snapshot_identifier
  depends_on                = [module.funding]
}
