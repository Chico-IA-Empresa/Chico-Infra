# ENT-03 — certificado e WAF da API de UAT. Tudo desligado por padrão;
# cada efeito externo tem sua flag (ver modules/edge/main.tf).
variable "edge_domain_names" {
  description = "Nomes do certificado de UAT (ex.: api-uat.chicoia.com.br). Vazio mantém o certificado desligado."
  type        = list(string)
  default     = []
}
variable "edge_certificate_enabled" {
  type    = bool
  default = false
}
variable "edge_dns_zone_id" {
  description = "Zona Route 53 existente. Null = DNS externo (GoDaddy hoje): os CNAMEs saem no output."
  type        = string
  default     = null
}
variable "edge_dns_change_approved" {
  type    = bool
  default = false
}
variable "edge_waf_enabled" {
  type    = bool
  default = false
}
variable "edge_waf_mode" {
  type    = string
  default = "count"
}
variable "edge_logs_key_arn" {
  type    = string
  default = null
}
variable "edge_alb_arn" {
  description = "ARN do ALB de UAT, criado pela API-01. Null mantém o WAF desassociado."
  type        = string
  default     = null
}
variable "edge_association_approved" {
  type    = bool
  default = false
}

module "edge" {
  count                = var.provision_enabled ? 1 : 0
  source               = "../../modules/edge"
  env                  = "uat"
  domain_names         = var.edge_domain_names
  certificate_enabled  = var.edge_certificate_enabled
  dns_zone_id          = var.edge_dns_zone_id
  dns_change_approved  = var.edge_dns_change_approved
  waf_enabled          = var.edge_waf_enabled
  waf_mode             = var.edge_waf_mode
  logs_key_arn         = var.edge_logs_key_arn
  alb_arn              = var.edge_alb_arn
  association_approved = var.edge_association_approved
  depends_on           = [module.funding]
}

output "edge" {
  value = var.provision_enabled ? {
    certificate_arn                = module.edge[0].certificate_arn
    certificate_validation_records = module.edge[0].certificate_validation_records
    web_acl_arn                    = module.edge[0].web_acl_arn
    state                          = module.edge[0].edge
  } : null
}
