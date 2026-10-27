variable "dev_hostname" {
  description = "Approved Dev hostname only; null keeps DNS untouched."
  type        = string
  default     = null
  validation {
    condition     = var.dev_hostname == null ? true : can(regex("^dev\\.[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.dev_hostname))
    error_message = "Somente hostname dev.DOMINIO aprovado; apex/www/Prod proibidos."
  }
}
variable "dns_zone_id" {
  description = "Existing authoritative Route53 zone; no zone or delegation is created. Null means external DNS."
  type        = string
  default     = null
}
variable "dns_change_approved" {
  type    = bool
  default = false
}
resource "aws_route53_record" "dev" {
  count           = local.host_enabled && var.dns_zone_id != null && var.dns_change_approved ? 1 : 0
  zone_id         = var.dns_zone_id
  name            = var.dev_hostname
  type            = "A"
  ttl             = 300
  records         = [module.dev_box[0].public_ip]
  allow_overwrite = false
  lifecycle {
    precondition {
      condition     = var.dev_hostname != null
      error_message = "Hostname e titularidade aprovados antes do registro. Importar registro existente após revisão."
    }
  }
}
output "dns" {
  value = { hostname = var.dev_hostname, managed_record = length(aws_route53_record.dev) == 1, external_authority = var.dns_zone_id == null }
}
