# Entrada da API e do site em UAT (Camada 02 / API-01): ALB → web-service
# blue-green (API e frontend), com papéis e smoke do modules/api-deploy.
# Duas chaves: `provision_enabled` (o resto do ambiente) e `api_enabled`. Mesmo
# com as duas ligadas, nenhuma task sobe: o web-service nasce com
# desired_count 0, e este root não expõe a contagem de propósito — ligar é uma
# mudança revisada à parte, depois do ensaio.

variable "api_enabled" {
  type    = bool
  default = false
}
variable "api_certificate_arn" {
  description = "Certificado ACM emitido para os hosts abaixo. Fica explícito: o certificate_arn do output edge só serve depois de ISSUED, e listener com certificado pendente falha."
  type        = string
  default     = null
}
variable "api_host_names" {
  description = "Host(s) da API sem reescrita de caminho (API-01.1), ex.: api.uat.<domínio>."
  type        = list(string)
  default     = []
}
variable "web_host_names" {
  description = "Host(s) do site."
  type        = list(string)
  default     = []
}
variable "api_image" {
  description = "chico-api por digest (sa-east-1), publicado pelo release do backend."
  type        = string
  default     = null
}
variable "frontend_image" {
  description = "chico-frontend por digest (sa-east-1)."
  type        = string
  default     = null
}
variable "api_secret_arns" {
  description = "Segredos que as task definitions da API e do frontend referenciam."
  type        = list(string)
  default     = []
}
variable "api_secrets" {
  description = "Por serviço: { api = [{ name, valueFrom }], frontend = [...] }."
  type        = map(list(object({ name = string, valueFrom = string })))
  default     = {}
}
variable "api_environment" {
  description = "Configuração pública por serviço: { api = [{ name, value }], frontend = [...] }; nunca credencial."
  type        = map(list(object({ name = string, value = string })))
  default     = {}
}
variable "api_logs_key_arn" {
  description = "CMK dos log groups /chico/uat/api, /frontend e da Lambda de smoke."
  type        = string
  default     = null
}
variable "api_alarm_topic_arns" {
  description = "Tópicos SNS do canal de alerta (MON-01) para os alarmes do ALB."
  type        = list(string)
  default     = []
}

locals {
  api_on           = var.provision_enabled && var.api_enabled
  api_logs_key_arn = var.api_logs_key_arn != null ? var.api_logs_key_arn : local.uat_logs_key_arn
  web_services = {
    api      = { image = var.api_image, security_group = "api" }
    frontend = { image = var.frontend_image, security_group = "frontend" }
  }
}

resource "aws_ecs_cluster" "web" {
  count = local.api_on ? 1 : 0
  name  = "chico-uat-web"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  depends_on = [module.funding]
}

resource "aws_ecs_cluster_capacity_providers" "web" {
  count              = local.api_on ? 1 : 0
  cluster_name       = aws_ecs_cluster.web[0].name
  capacity_providers = ["FARGATE"]
}

module "alb" {
  count                 = local.api_on ? 1 : 0
  source                = "../../modules/alb"
  env                   = "uat"
  vpc_id                = module.network[0].vpc_id
  public_subnet_ids     = module.network[0].public_subnet_ids
  alb_security_group_id = module.network[0].security_group_ids["alb"]
  certificate_arn       = var.api_certificate_arn
  api_host_names        = var.api_host_names
  web_host_names        = var.web_host_names
  alarm_topic_arns      = concat(var.api_alarm_topic_arns, local.uat_alarm_topics)
  depends_on            = [module.funding]
}

module "api_deploy" {
  count           = local.api_on ? 1 : 0
  source          = "../../modules/api-deploy"
  env             = "uat"
  account_id      = var.account_id
  smoke_urls      = concat([for host in var.api_host_names : "https://${host}/health/ready/release"], [for host in var.web_host_names : "https://${host}/"])
  test_header     = module.alb[0].test_header
  secret_arns     = var.api_secret_arns
  secrets_key_arn = local.uat_secrets_key_arn
  logs_key_arn    = local.api_logs_key_arn
  depends_on      = [module.funding]
}

module "web" {
  for_each                = local.api_on ? local.web_services : {}
  source                  = "../../modules/web-service"
  env                     = "uat"
  service                 = each.key
  image                   = each.value.image
  cluster_arn             = aws_ecs_cluster.web[0].arn
  execution_role_arn      = module.api_deploy[0].execution_role_arn
  task_role_arn           = module.api_deploy[0].task_role_arns[each.key]
  public_subnet_ids       = module.network[0].public_subnet_ids
  security_group_id       = module.network[0].security_group_ids[each.value.security_group]
  blue_target_group_arn   = module.alb[0].target_group_arns[each.key]["blue"]
  green_target_group_arn  = module.alb[0].target_group_arns[each.key]["green"]
  production_rule_arn     = module.alb[0].production_rule_arns[each.key]
  test_rule_arn           = module.alb[0].test_rule_arns[each.key]
  alb_management_role_arn = module.api_deploy[0].alb_management_role_arn
  smoke_hook_arn          = module.api_deploy[0].smoke_hook_arn
  hook_execution_role_arn = module.api_deploy[0].hook_execution_role_arn
  logs_key_arn            = local.api_logs_key_arn
  alarm_names             = module.alb[0].alarm_names[each.key]
  secrets                 = lookup(var.api_secrets, each.key, [])
  environment             = lookup(var.api_environment, each.key, [])
  # Os ARNs dos papéis e da Lambda são montados pelo nome no api-deploy: sem
  # isto o Terraform não sabe que o serviço espera os dois existirem.
  depends_on = [module.funding, module.api_deploy, aws_ecs_cluster_capacity_providers.web]
}

output "api_alb_dns_name" { value = try(module.alb[0].alb_dns_name, null) }
