# Workers e jobs do ambiente (Camada 04): papéis → cluster/serviços/jobs → schedules.
# Duas chaves: `enabled` (o `provision_enabled` do root) e `workers_enabled`
# (este bloco). Mesmo com as duas ligadas, NADA roda: os três serviços nascem
# com desired_count 0 e os onze schedules DISABLED. Ligar é um apply revisado
# com as chaves de run-switches.tf (workers_service_desired_counts,
# workers_schedules_enabled + workers_application_proofs_approved), depois do
# ensaio da fase 3.

variable "workers_enabled" {
  type    = bool
  default = false
}
variable "workers_image" {
  description = "chico-workers por digest (sa-east-1). Publicado pelo release do backend (AWS-016)."
  type        = string
  default     = null
}
variable "workers_ami_id" {
  description = "AMI ECS-optimized Amazon Linux 2023 ARM64 verificada em sa-east-1."
  type        = string
  default     = null
}
variable "workers_secret_arns" {
  description = "Vazio = derivado de workers_secrets (secrets.tf). Preencher só para fixar a lista à mão."
  type        = list(string)
  default     = []
}
variable "workers_secrets" {
  description = "Por consumidor: { consumidor = [{ name, valueFrom }] }; valueFrom é ARN ou nome de secret_names (ex.: workers/DATABASE_URL)."
  type        = map(list(object({ name = string, valueFrom = string })))
  default     = {}
}
variable "workers_environment" {
  description = "Configuração pública comum aos consumidores (ex.: ENVIRONMENT, flags de fonte de odds); nunca credencial."
  type        = list(object({ name = string, value = string }))
  default     = []
}
variable "workers_logs_key_arn" {
  description = "Chave KMS do log group /chico/<env>/workers."
  type        = string
  default     = null
}
variable "workers_alarm_topic_arns" {
  description = "Tópicos SNS do canal de alerta (MON-01) para falha de task, JOB_RESULT e DLQ."
  type        = list(string)
  default     = []
}

locals {
  workers_on = var.enabled && var.workers_enabled
}

module "workers_iam" {
  count           = local.workers_on ? 1 : 0
  source          = "../workers-iam"
  env             = var.env
  account_id      = var.account_id
  secret_arns     = local.workers_secret_arns
  secrets_key_arn = local.env_secrets_key_arn
}

module "workers" {
  count                  = local.workers_on ? 1 : 0
  source                 = "../workers"
  env                    = var.env
  image                  = var.workers_image
  ami_id                 = var.workers_ami_id
  host_subnet_id         = var.public_subnet_ids[0]
  host_security_group_id = var.security_group_ids["workers"]
  instance_profile_arn   = module.workers_iam[0].instance_profile_arn
  execution_role_arn     = module.workers_iam[0].execution_role_arn
  task_role_arns         = module.workers_iam[0].task_role_arns
  secrets                = local.workers_secrets_resolved
  environment            = var.workers_environment
  logs_key_arn           = var.workers_logs_key_arn != null ? var.workers_logs_key_arn : local.env_logs_key_arn
  alarm_topic_arns       = concat(var.workers_alarm_topic_arns, local.env_alarm_topics)
  cutover_approved       = var.workers_cutover_approved
  service_desired_counts = merge({ odds-bsd = 0, odds-surebetting = 0, telegram-update = 0 }, var.workers_service_desired_counts)
  # Os ARNs dos papéis são montados pelo nome no workers-iam: sem isto o
  # Terraform não sabe que o launch template e as task definitions esperam
  # os papéis existirem.
  depends_on = [module.workers_iam]
}

module "schedules" {
  count                       = local.workers_on ? 1 : 0
  source                      = "../schedules"
  env                         = var.env
  cluster_arn                 = module.workers[0].cluster_arn
  target_role_arn             = module.workers_iam[0].scheduler_role_arn
  public_subnet_ids           = toset(var.public_subnet_ids)
  jobs_sg_id                  = var.security_group_ids["jobs"]
  task_definition_arns        = module.workers[0].job_task_definition_arns
  alarm_topic_arns            = concat(var.workers_alarm_topic_arns, local.env_alarm_topics)
  enabled                     = var.workers_schedules_enabled
  application_proofs_approved = var.workers_application_proofs_approved
  depends_on                  = [module.workers_iam]
}

output "workers_cluster_arn" { value = try(module.workers[0].cluster_arn, null) }
