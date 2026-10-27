variable "env" { type = string }
variable "secrets_key_arn" {
  type    = string
  default = null
}
variable "secret_names" {
  description = "Only reviewed service/KEY names. Terraform never accepts secret values."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for n in var.secret_names : can(regex("^(api|workers|frontend|mobile-a|mobile-b)/[A-Z][A-Z0-9_]+$", n)) && !can(regex("(ASAAS|MERCADOPAGO|INTER_|PIX_|PAYOUT|AFFILIATE)", n))])
    error_message = "Nomes service/KEY revisados; segredos financeiros fora do alvo."
  }
}
variable "parameters" {
  type    = map(string)
  default = {}
  validation {
    condition     = alltrue([for n in keys(var.parameters) : can(regex("^(api|workers|frontend)/[A-Z][A-Z0-9_]+$", n)) && !can(regex("(PASSWORD|TOKEN|SECRET|PRIVATE|API_KEY|CREDENTIAL|DSN|DATABASE_URL|REDIS_URL)", n))])
    error_message = "Parâmetros somente de configuração revisada, nunca credenciais."
  }
}
resource "aws_secretsmanager_secret" "this" {
  for_each                = var.secret_names
  name                    = "/chico/${var.env}/${each.key}"
  recovery_window_in_days = 30
  kms_key_id              = var.secrets_key_arn
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = can(regex("^arn:aws:kms:sa-east-1:[0-9]{12}:key/[a-zA-Z0-9-]+$", var.secrets_key_arn))
      error_message = "Contêineres de secrets exigem chave KMS do ambiente revisada."
    }
  }
}
resource "aws_ssm_parameter" "this" {
  for_each = var.parameters
  name     = "/chico/${var.env}/${each.key}"
  type     = "String"
  tier     = "Standard"
  value    = each.value
}
output "secret_arns" { value = { for k, v in aws_secretsmanager_secret.this : k => v.arn } }
