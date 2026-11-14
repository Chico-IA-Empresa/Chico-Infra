mock_provider "aws" {
  mock_resource "aws_acm_certificate" {
    defaults = {
      arn = "arn:aws:acm:sa-east-1:000000000000:certificate/00000000-0000-0000-0000-000000000000"
      domain_validation_options = [
        {
          domain_name           = "api-uat.example.invalid"
          resource_record_name  = "_x.api-uat.example.invalid."
          resource_record_type  = "CNAME"
          resource_record_value = "_y.acm-validations.aws."
        }
      ]
    }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = {
      arn = "arn:aws:wafv2:sa-east-1:000000000000:regional/webacl/chico-uat-api/00000000-0000-0000-0000-000000000000"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:sa-east-1:000000000000:log-group:aws-waf-logs-chico-uat-api"
    }
  }
}

variables {
  env = "uat"
}

run "default_creates_nothing" {
  command = plan
  assert {
    condition     = length(aws_acm_certificate.this) == 0 && length(aws_wafv2_web_acl.this) == 0 && length(aws_wafv2_web_acl_association.this) == 0 && length(aws_route53_record.validation) == 0
    error_message = "Sem flags, a borda não pode criar nenhum recurso."
  }
}

run "certificate_with_external_dns_never_touches_route53" {
  command = apply
  variables {
    certificate_enabled = true
    domain_names        = ["api-uat.example.invalid"]
  }
  assert {
    condition     = length(aws_acm_certificate.this) == 1 && length(aws_route53_record.validation) == 0 && length(aws_acm_certificate_validation.this) == 0
    error_message = "DNS externo: pede o certificado, não escreve no Route 53 e não espera validação."
  }
  assert {
    condition     = output.certificate_validation_records["api-uat.example.invalid"].type == "CNAME"
    error_message = "Os CNAMEs de validação precisam sair como output para o DNS externo."
  }
}

run "zone_without_approval_stays_external" {
  command = plan
  variables {
    certificate_enabled = true
    domain_names        = ["api-uat.example.invalid"]
    dns_zone_id         = "Z0000000000000"
  }
  assert {
    condition     = length(aws_acm_certificate_validation.this) == 0
    error_message = "Escrever na zona exige dns_change_approved."
  }
}

run "waf_starts_in_count" {
  command = plan
  variables { waf_enabled = true }
  assert {
    condition     = length(aws_wafv2_web_acl.this) == 1 && aws_wafv2_web_acl.this[0].scope == "REGIONAL"
    error_message = "WAF regional deve existir quando ligado."
  }
  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.this[0].rule :
      (length(r.override_action) > 0 ? length(r.override_action[0].count) == 1 && length(r.override_action[0].none) == 0 : length(r.action[0].count) == 1 && length(r.action[0].block) == 0)
    ])
    error_message = "No modo count, nenhuma regra pode bloquear."
  }
  assert {
    condition     = length(aws_wafv2_web_acl_association.this) == 0
    error_message = "Sem ALB e aprovação, a web ACL fica desassociada."
  }
  assert {
    condition     = startswith(aws_cloudwatch_log_group.waf[0].name, "aws-waf-logs-")
    error_message = "O WAF só entrega logs para log groups com prefixo aws-waf-logs-."
  }
  assert {
    condition     = length(aws_wafv2_web_acl_logging_configuration.this[0].redacted_fields) == 2
    error_message = "Authorization e Cookie precisam ser redigidos nos logs."
  }
}

run "block_mode_blocks_but_keeps_upload_exception" {
  command = plan
  variables {
    waf_enabled = true
    waf_mode    = "block"
  }
  assert {
    condition = alltrue([
      for r in aws_wafv2_web_acl.this[0].rule :
      (length(r.override_action) > 0 ? length(r.override_action[0].none) == 1 : length(r.action[0].block) == 1)
    ])
    error_message = "No modo block, grupos gerenciados aplicam a própria ação e as regras de taxa bloqueiam."
  }
  assert {
    condition = anytrue([
      for r in aws_wafv2_web_acl.this[0].rule :
      r.name == "aws-common" && length(r.statement[0].managed_rule_group_statement[0].rule_action_override) == 1
    ])
    error_message = "SizeRestrictions_BODY continua em count para não quebrar uploads."
  }
}

run "association_needs_alb_and_approval" {
  command = plan
  variables {
    waf_enabled = true
    alb_arn     = "arn:aws:elasticloadbalancing:sa-east-1:000000000000:loadbalancer/app/chico-uat-alb/0000000000000000"
  }
  assert {
    condition     = length(aws_wafv2_web_acl_association.this) == 0
    error_message = "ARN do ALB sozinho não associa: exige association_approved."
  }
}

run "association_when_approved" {
  command = plan
  variables {
    waf_enabled          = true
    alb_arn              = "arn:aws:elasticloadbalancing:sa-east-1:000000000000:loadbalancer/app/chico-uat-alb/0000000000000000"
    association_approved = true
  }
  assert {
    condition     = length(aws_wafv2_web_acl_association.this) == 1
    error_message = "Com ALB e aprovação, a associação deve existir."
  }
}

run "reject_dev" {
  command = plan
  variables { env = "dev" }
  expect_failures = [var.env]
}

run "reject_unknown_mode" {
  command = plan
  variables { waf_mode = "challenge" }
  expect_failures = [var.waf_mode]
}

run "reject_bad_domain" {
  command = plan
  variables { domain_names = ["API.Example.com"] }
  expect_failures = [var.domain_names]
}
