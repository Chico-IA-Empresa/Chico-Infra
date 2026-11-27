# Pilha de aplicação de um ambiente (UAT ou Prod): CMKs e tópico de alerta,
# entrada da API (ALB, WAF, blue-green), migration, workers e schedules. Os
# dois roots chamam este módulo com o mesmo conjunto de variáveis (o arquivo
# envs/*/app-stack-variables.tf é idêntico nos dois, conferido por
# tests/app-stack-roots.test.mjs); o que muda entre eles é só o valor.
#
# Rede, configuração e dados continuam nos roots: são persistentes, diferem
# entre UAT e Prod (snapshot sanitizado, PITR, recovery) e não seguem o ciclo
# de liga/desliga desta pilha. O gate financeiro (modules/funding) também fica
# no root, que passa `depends_on = [module.funding]` na chamada.

variable "env" {
  type = string
  validation {
    condition     = contains(["uat", "prod"], var.env)
    error_message = "A pilha de aplicação existe só em UAT e Prod."
  }
}
variable "enabled" {
  description = "O provision_enabled do root. Desligado, nada desta pilha é planejado."
  type        = bool
  default     = false
}
variable "account_id" { type = string }

variable "vpc_id" {
  description = "Saída do modules/network do root; null com a rede desligada."
  type        = string
  default     = null
}
variable "public_subnet_ids" {
  type    = list(string)
  default = []
}
variable "security_group_ids" {
  description = "Mapa do modules/network (alb, api, frontend, workers, jobs)."
  type        = map(string)
  default     = {}
}
variable "config_secret_arns" {
  description = "Nome revisado (secret_names) → ARN, saída do modules/configuration do root."
  type        = map(string)
  default     = {}
}
variable "secrets_key_arn" {
  description = "CMK dos segredos. Null usa a CMK de segredos desta pilha (foundation.tf) quando ela existe."
  type        = string
  default     = null
}
variable "workers_cutover_approved" {
  description = "Só Prod: libera serviço contínuo acima de 0 (precondition do modules/workers). Ignorado em UAT."
  type        = bool
  default     = false
}

output "secrets_key_arn" {
  description = "CMK de segredos efetiva: a explícita ou a desta pilha. O modules/configuration do root usa a mesma."
  value       = local.env_secrets_key_arn
}
output "alarm_topic_arns" {
  description = "Tópico de alerta da pilha (vazio sem foundation_enabled). Os alarmes de dados do root (modules/data) publicam nele."
  value       = local.env_alarm_topics
}
