variable "activate_environment_cost_tag" {
  description = "Opt in only after Cost Explorer lists the real env tag and the shared plan is reviewed."
  type        = bool
  default     = false
}
variable "environment_cost_tag_evidence_reference" {
  description = "Private read-only verification reference; never financial values or credentials."
  type        = string
  default     = null
}
provider "aws" {
  alias               = "billing"
  region              = "us-east-1"
  allowed_account_ids = [var.account_id]
}
resource "aws_ce_cost_allocation_tag" "environment" {
  provider = aws.billing
  count    = var.provision_enabled && var.activate_environment_cost_tag ? 1 : 0
  tag_key  = "env"
  status   = "Active"
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = try(length(trimspace(var.environment_cost_tag_evidence_reference)) > 0, false)
      error_message = "Ativação requer evidência privada de que a etiqueta real env está disponível e plan shared revisado."
    }
  }
  depends_on = [module.funding]
}
