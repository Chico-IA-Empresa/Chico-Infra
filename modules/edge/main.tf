# Borda pública da API (ENT-03): certificado ACM e WAF regional do ALB.
#
# Tudo nasce desligado. Cada efeito externo tem sua própria chave:
# - certificate_enabled: pede o certificado. Com DNS externo (GoDaddy hoje),
#   o módulo NÃO espera a validação; devolve os CNAMEs em
#   `certificate_validation_records` para alguém publicar no provedor.
# - dns_zone_id + dns_change_approved: publica os CNAMEs de validação numa
#   zona Route 53 existente e espera o certificado ficar ISSUED.
# - waf_enabled: cria a web ACL e os logs. waf_mode começa em "count".
# - alb_arn + association_approved: associa a web ACL ao ALB (tráfego real).
#
# O ALB e o listener HTTPS são da API-01 (módulo do ALB, ainda inexistente);
# este módulo só recebe o ARN quando ele existir.

variable "env" {
  type = string
  validation {
    condition     = contains(["uat", "prod"], var.env)
    error_message = "Borda pública existe só em UAT e Prod."
  }
}

variable "domain_names" {
  description = "Nomes do certificado; o primeiro é o principal. Vazio mantém o certificado desligado."
  type        = list(string)
  default     = []
  validation {
    condition = length(var.domain_names) == length(distinct(var.domain_names)) && alltrue([
      for d in var.domain_names : can(regex("^(\\*\\.)?[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", d))
    ])
    error_message = "Nomes DNS em minúsculas, sem repetição."
  }
}

variable "certificate_enabled" {
  type    = bool
  default = false
}

variable "dns_zone_id" {
  description = "Zona Route 53 autoritativa existente. Null = DNS externo: os registros de validação saem como output."
  type        = string
  default     = null
}

variable "dns_change_approved" {
  type    = bool
  default = false
}

variable "waf_enabled" {
  type    = bool
  default = false
}

variable "waf_mode" {
  description = "count durante o ensaio (mínimo 48 h); block só depois de revisar falsos positivos."
  type        = string
  default     = "count"
  validation {
    condition     = contains(["count", "block"], var.waf_mode)
    error_message = "waf_mode deve ser count ou block."
  }
}

variable "rate_limit_auth" {
  description = "Requisições por IP em 5 min nas rotas de autenticação (/auth/ e /apps/*/v1/auth/)."
  type        = number
  default     = 300
  validation {
    condition     = var.rate_limit_auth >= 10 && var.rate_limit_auth <= 20000
    error_message = "Limite de autenticação entre 10 e 20000 por 5 min."
  }
}

variable "rate_limit_global" {
  description = "Requisições por IP em 5 min em qualquer rota."
  type        = number
  default     = 2000
  validation {
    condition     = var.rate_limit_global >= 100 && var.rate_limit_global <= 2000000000
    error_message = "Limite global mínimo de 100 por 5 min."
  }
}

variable "count_only_common_rules" {
  description = "Regras do CommonRuleSet que ficam em count mesmo em block (uploads de bilhete, avatar e comprovante passam de 8 KB)."
  type        = set(string)
  default     = ["SizeRestrictions_BODY"]
}

variable "logs_key_arn" {
  description = "Chave KMS do log group do WAF. Null usa a criptografia padrão do CloudWatch Logs."
  type        = string
  default     = null
}

variable "log_retention_days" {
  type    = number
  default = 180
}

variable "alb_arn" {
  description = "ARN do ALB (API-01). Null mantém a web ACL desassociada."
  type        = string
  default     = null
}

variable "association_approved" {
  type    = bool
  default = false
}

locals {
  certificate_on = var.certificate_enabled && length(var.domain_names) > 0
  dns_managed    = local.certificate_on && var.dns_zone_id != null && var.dns_change_approved
  block          = var.waf_mode == "block"
  name           = "chico-${var.env}-api"
  managed_groups = {
    aws-common        = { priority = 10, name = "AWSManagedRulesCommonRuleSet" }
    aws-bad-inputs    = { priority = 20, name = "AWSManagedRulesKnownBadInputsRuleSet" }
    aws-ip-reputation = { priority = 30, name = "AWSManagedRulesAmazonIpReputationList" }
  }
}

# ── Certificado ─────────────────────────────────────────────────────────────

resource "aws_acm_certificate" "this" {
  count                     = local.certificate_on ? 1 : 0
  domain_name               = var.domain_names[0]
  subject_alternative_names = slice(var.domain_names, 1, length(var.domain_names))
  validation_method         = "DNS"
  key_algorithm             = "RSA_2048"
  tags                      = { Name = local.name, task = "ENT-03" }

  options {
    certificate_transparency_logging_preference = "ENABLED"
  }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  validation_records = local.certificate_on ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name  = dvo.resource_record_name
      type  = dvo.resource_record_type
      value = dvo.resource_record_value
    }
  } : {}
}

# Os CNAMEs de validação também renovam o certificado: nunca apagar.
resource "aws_route53_record" "validation" {
  for_each        = local.dns_managed ? local.validation_records : {}
  zone_id         = var.dns_zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.value]
  ttl             = 300
  allow_overwrite = false
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.dns_managed ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]
}

# ── WAF ─────────────────────────────────────────────────────────────────────

resource "aws_wafv2_web_acl" "this" {
  count       = var.waf_enabled ? 1 : 0
  name        = local.name
  description = "Borda da API ${var.env} (ENT-03), modo ${var.waf_mode}"
  scope       = "REGIONAL"
  tags        = { Name = local.name, task = "ENT-03", waf_mode = var.waf_mode }

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.managed_groups
    content {
      name     = rule.key
      priority = rule.value.priority

      override_action {
        dynamic "count" {
          for_each = local.block ? [] : [1]
          content {}
        }
        dynamic "none" {
          for_each = local.block ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value.name

          dynamic "rule_action_override" {
            for_each = rule.key == "aws-common" ? var.count_only_common_rules : []
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-auth"
    priority = 40

    action {
      dynamic "count" {
        for_each = local.block ? [] : [1]
        content {}
      }
      dynamic "block" {
        for_each = local.block ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit_auth
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"

        scope_down_statement {
          or_statement {
            statement {
              byte_match_statement {
                positional_constraint = "STARTS_WITH"
                search_string         = "/auth/"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
            statement {
              byte_match_statement {
                positional_constraint = "CONTAINS"
                search_string         = "/v1/auth/"
                field_to_match {
                  uri_path {}
                }
                text_transformation {
                  priority = 0
                  type     = "LOWERCASE"
                }
              }
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-auth"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-global"
    priority = 50

    action {
      dynamic "count" {
        for_each = local.block ? [] : [1]
        content {}
      }
      dynamic "block" {
        for_each = local.block ? [1] : []
        content {}
      }
    }

    statement {
      rate_based_statement {
        limit                 = var.rate_limit_global
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-global"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }
}

# O nome do log group PRECISA começar com aws-waf-logs-.
resource "aws_cloudwatch_log_group" "waf" {
  count             = var.waf_enabled ? 1 : 0
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.logs_key_arn
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count                   = var.waf_enabled ? 1 : 0
  resource_arn            = aws_wafv2_web_acl.this[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  count        = var.waf_enabled && var.alb_arn != null && var.association_approved ? 1 : 0
  resource_arn = var.alb_arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}

# ── Saídas ──────────────────────────────────────────────────────────────────

output "certificate_arn" {
  description = "Use no listener HTTPS só depois de ISSUED."
  value       = local.certificate_on ? aws_acm_certificate.this[0].arn : null
}

output "certificate_validation_records" {
  description = "CNAMEs para publicar no DNS externo quando dns_zone_id é null. Nunca apagar: renovam o certificado."
  value       = local.certificate_on && !local.dns_managed ? local.validation_records : {}
}

output "web_acl_arn" {
  value = var.waf_enabled ? aws_wafv2_web_acl.this[0].arn : null
}

output "edge" {
  value = {
    certificate    = local.certificate_on
    dns_managed    = local.dns_managed
    waf            = var.waf_enabled
    waf_mode       = var.waf_mode
    waf_associated = length(aws_wafv2_web_acl_association.this) == 1
    waf_log_group  = var.waf_enabled ? aws_cloudwatch_log_group.waf[0].name : null
  }
}
