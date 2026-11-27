# Entrada da API e do site do ambiente (Camada 02 / API-01): ALB → web-service
# blue-green (API e frontend), com papéis e smoke do modules/api-deploy.
# Duas chaves: `enabled` (o `provision_enabled` do root) e `api_enabled`. Mesmo
# com as duas ligadas, nenhuma task sobe: o web-service nasce com
# desired_count 0. Ligar é `api_desired_counts` (run-switches.tf), depois da
# migration (migrate.tf).

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
  description = "Vazio = derivado de api_secrets (secrets.tf). Preencher só para fixar a lista à mão."
  type        = list(string)
  default     = []
}
variable "api_secrets" {
  description = "Por serviço: { api = [{ name, valueFrom }], frontend = [...] }; valueFrom é ARN ou nome de secret_names (ex.: api/SECRET_KEY)."
  type        = map(list(object({ name = string, valueFrom = string })))
  default     = {}
}
variable "api_environment" {
  description = "Configuração pública por serviço: { api = [{ name, value }], frontend = [...] }; nunca credencial."
  type        = map(list(object({ name = string, value = string })))
  default     = {}
}
variable "api_logs_key_arn" {
  description = "CMK dos log groups /chico/<env>/api, /frontend e da Lambda de smoke."
  type        = string
  default     = null
}
variable "api_alarm_topic_arns" {
  description = "Tópicos SNS do canal de alerta (MON-01) para os alarmes do ALB."
  type        = list(string)
  default     = []
}

locals {
  api_on           = var.enabled && var.api_enabled
  api_logs_key_arn = var.api_logs_key_arn != null ? var.api_logs_key_arn : local.env_logs_key_arn
  web_services = {
    api      = { image = var.api_image, security_group = "api" }
    frontend = { image = var.frontend_image, security_group = "frontend" }
  }
}

resource "aws_ecs_cluster" "web" {
  count = local.api_on ? 1 : 0
  name  = "chico-${var.env}-web"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "web" {
  count              = local.api_on ? 1 : 0
  cluster_name       = aws_ecs_cluster.web[0].name
  capacity_providers = ["FARGATE"]
}

module "alb" {
  count                 = local.api_on ? 1 : 0
  source                = "../alb"
  env                   = var.env
  vpc_id                = var.vpc_id
  public_subnet_ids     = var.public_subnet_ids
  alb_security_group_id = var.security_group_ids["alb"]
  certificate_arn       = var.api_certificate_arn
  api_host_names        = var.api_host_names
  web_host_names        = var.web_host_names
  alarm_topic_arns      = concat(var.api_alarm_topic_arns, local.env_alarm_topics)
}

module "api_deploy" {
  count           = local.api_on ? 1 : 0
  source          = "../api-deploy"
  env             = var.env
  account_id      = var.account_id
  test_header     = module.alb[0].test_header
  secret_arns     = local.api_secret_arns
  secrets_key_arn = local.env_secrets_key_arn
  logs_key_arn    = local.api_logs_key_arn
  # Pelo site também: /api/health/ready/release prova a rota com reescrita.
  smoke_urls = concat(
    [for host in var.api_host_names : "https://${host}/health/ready/release"],
    [for host in var.web_host_names : "https://${host}/api/health/ready/release"],
    [for host in var.web_host_names : "https://${host}/"],
  )
}

module "web" {
  for_each                = local.api_on ? local.web_services : {}
  source                  = "../web-service"
  env                     = var.env
  service                 = each.key
  image                   = each.value.image
  cluster_arn             = aws_ecs_cluster.web[0].arn
  execution_role_arn      = module.api_deploy[0].execution_role_arn
  task_role_arn           = module.api_deploy[0].task_role_arns[each.key]
  public_subnet_ids       = var.public_subnet_ids
  security_group_id       = var.security_group_ids[each.value.security_group]
  load_balancers          = module.alb[0].load_balancers[each.key]
  alb_management_role_arn = module.api_deploy[0].alb_management_role_arn
  smoke_hook_arn          = module.api_deploy[0].smoke_hook_arn
  hook_execution_role_arn = module.api_deploy[0].hook_execution_role_arn
  logs_key_arn            = local.api_logs_key_arn
  alarm_names             = module.alb[0].alarm_names[each.key]
  secrets                 = lookup(local.api_secrets_resolved, each.key, [])
  environment             = lookup(var.api_environment, each.key, [])
  desired_count           = lookup(var.api_desired_counts, each.key, 0)
  # Os ARNs dos papéis e da Lambda são montados pelo nome no api-deploy: sem
  # isto o Terraform não sabe que o serviço espera os dois existirem.
  depends_on = [module.api_deploy, aws_ecs_cluster_capacity_providers.web]
}

output "api_alb_dns_name" { value = try(module.alb[0].alb_dns_name, null) }
