variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Informar ID real da conta destinatária dos créditos."
  }
}
variable "owner" { type = string }
variable "cost_center" { type = string }
variable "provision_enabled" {
  type    = bool
  default = false
}
variable "credit_approval" {
  type    = object({ account_id = string, evidence_reference = string, reviewed_on = string, expires_on = string, all_charges_covered = bool, shutdown_reserve_confirmed = bool })
  default = null
}
