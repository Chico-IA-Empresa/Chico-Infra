variable "az_names" { type = list(string) }
variable "secrets_key_arn" {
  type    = string
  default = null
}
variable "secret_names" {
  type    = set(string)
  default = []
}
variable "parameters" {
  type    = map(string)
  default = {}
}
module "network" {
  count      = var.provision_enabled ? 1 : 0
  source     = "../../modules/network"
  env        = "uat"
  az_names   = var.az_names
  depends_on = [module.funding]
}
module "configuration" {
  count           = var.provision_enabled ? 1 : 0
  source          = "../../modules/configuration"
  env             = "uat"
  secret_names    = var.secret_names
  secrets_key_arn = var.secrets_key_arn
  parameters      = var.parameters
  depends_on      = [module.funding]
}
