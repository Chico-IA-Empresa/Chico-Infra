variable "audit_bucket_name" { type = string }
variable "audit_access_log_bucket_name" { type = string }
variable "access_log_retention_days" { type = number }
module "audit_access_logs" {
  count             = var.provision_enabled ? 1 : 0
  source            = "../../modules/access-log-sink"
  bucket_name       = var.audit_access_log_bucket_name
  source_bucket_arn = "arn:aws:s3:::${var.audit_bucket_name}"
  account_id        = var.account_id
  retention_days    = var.access_log_retention_days
  depends_on        = [module.funding]
}
variable "audit_kms_key_arn" {
  type    = string
  default = null
}
variable "oidc_provider_arn" { type = string }
variable "state_bucket_arn" { type = string }
variable "oidc_bindings" {
  type    = map(object({ scope = string, repository = string, environment = string, writable_state = bool }))
  default = {}
}
variable "alert_emails" { type = set(string) }
variable "verified_oidc_subjects" {
  type    = map(string)
  default = {}
}
variable "budget_limits" { type = map(number) }
module "audit" {
  count                  = var.provision_enabled ? 1 : 0
  source                 = "../../modules/audit"
  bucket_name            = var.audit_bucket_name
  access_log_bucket_name = module.audit_access_logs[0].bucket_name
  account_id             = var.account_id
  kms_key_arn            = var.audit_kms_key_arn
  depends_on             = [module.funding]
}
module "registry" {
  count      = var.provision_enabled ? 1 : 0
  source     = "../../modules/registry"
  depends_on = [module.funding]
}
module "oidc" {
  count             = var.provision_enabled ? 1 : 0
  source            = "../../modules/oidc"
  provider_arn      = var.oidc_provider_arn
  state_bucket_arn  = var.state_bucket_arn
  bindings          = var.oidc_bindings
  verified_subjects = var.verified_oidc_subjects
  depends_on        = [module.funding]
}
module "budgets" {
  count        = var.provision_enabled ? 1 : 0
  source       = "../../modules/budgets"
  alert_emails = var.alert_emails
  limits       = var.budget_limits
  depends_on   = [module.funding]
}
