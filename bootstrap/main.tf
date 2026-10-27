variable "state_bucket_name" { type = string }
variable "state_access_log_bucket_name" { type = string }
variable "access_log_retention_days" { type = number }
module "access_logs" {
  count             = var.provision_enabled ? 1 : 0
  source            = "../modules/access-log-sink"
  bucket_name       = var.state_access_log_bucket_name
  source_bucket_arn = "arn:aws:s3:::${var.state_bucket_name}"
  account_id        = var.account_id
  retention_days    = var.access_log_retention_days
  depends_on        = [module.funding]
}
module "state" {
  count                  = var.provision_enabled ? 1 : 0
  source                 = "../modules/state"
  bucket_name            = var.state_bucket_name
  access_log_bucket_name = module.access_logs[0].bucket_name
  depends_on             = [module.funding]
}
