variable "enabled" { type = bool }
variable "approval" {
  description = "Review metadata only; financial details are kept in private evidence outside state. Not proof by itself."
  type        = object({ account_id = string, evidence_reference = string, reviewed_on = string, expires_on = string, all_charges_covered = bool, shutdown_reserve_confirmed = bool })
  default     = null
  nullable    = true
}
variable "account_id" { type = string }
resource "terraform_data" "gate" {
  input = var.enabled
  lifecycle {
    precondition {
      condition = !var.enabled || try(
        var.approval.account_id == var.account_id &&
        length(var.approval.evidence_reference) > 0 &&
        var.approval.all_charges_covered && var.approval.shutdown_reserve_confirmed &&
        timecmp("${var.approval.reviewed_on}T00:00:00Z", plantimestamp()) <= 0 &&
        timecmp("${var.approval.expires_on}T00:00:00Z", plantimestamp()) > 0,
      false)
      error_message = "Provisionamento exige revisão privada dos créditos válidos/elegíveis, cobertura integral e reserva. Não preencher sem comprovação real."
    }
  }
}
