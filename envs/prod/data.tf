
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
  count                     = var.provision_enabled && var.data_enabled ? 1 : 0
  source                    = "../../modules/data"
  env                       = "prod"
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
