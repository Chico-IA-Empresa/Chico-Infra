# Workers e jobs em UAT (Camada 04): papéis → cluster/serviços/jobs → schedules.
# Duas chaves: `provision_enabled` (o resto do ambiente) e `workers_enabled`
# (este bloco). Mesmo com as duas ligadas, NADA roda: os três serviços nascem
# com desired_count 0 e os onze schedules DISABLED. Ligar consumidor é uma
# mudança revisada à parte (service_desired_counts no modules/workers;
# enabled + application_proofs_approved no modules/schedules), depois do
# ensaio da fase 3; este root não expõe essas chaves de propósito.

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
  description = "Chave KMS do log group /chico/uat/workers."
  type        = string
  default     = null
}
variable "workers_alarm_topic_arns" {
  description = "Tópicos SNS do canal de alerta (MON-01) para falha de task, JOB_RESULT e DLQ."
  type        = list(string)
  default     = []
}

locals {
  workers_on = var.provision_enabled && var.workers_enabled
}

module "workers_iam" {
  count           = local.workers_on ? 1 : 0
  source          = "../../modules/workers-iam"
  env             = "uat"
  account_id      = var.account_id
  secret_arns     = local.workers_secret_arns
  secrets_key_arn = local.uat_secrets_key_arn
  depends_on      = [module.funding]
}

module "workers" {
  count                  = local.workers_on ? 1 : 0
  source                 = "../../modules/workers"
  env                    = "uat"
  image                  = var.workers_image
  ami_id                 = var.workers_ami_id
  host_subnet_id         = module.network[0].public_subnet_ids[0]
  host_security_group_id = module.network[0].security_group_ids["workers"]
  instance_profile_arn   = module.workers_iam[0].instance_profile_arn
  execution_role_arn     = module.workers_iam[0].execution_role_arn
  task_role_arns         = module.workers_iam[0].task_role_arns
  secrets                = local.workers_secrets_resolved
  environment            = var.workers_environment
  logs_key_arn           = var.workers_logs_key_arn != null ? var.workers_logs_key_arn : local.uat_logs_key_arn
  alarm_topic_arns       = concat(var.workers_alarm_topic_arns, local.uat_alarm_topics)
  # Os ARNs dos papéis são montados pelo nome no workers-iam: sem isto o
  # Terraform não sabe que o launch template e as task definitions esperam
  # os papéis existirem.
  depends_on = [module.funding, module.workers_iam]
}

module "schedules" {
  count                = local.workers_on ? 1 : 0
  source               = "../../modules/schedules"
  env                  = "uat"
  cluster_arn          = module.workers[0].cluster_arn
  target_role_arn      = module.workers_iam[0].scheduler_role_arn
  public_subnet_ids    = toset(module.network[0].public_subnet_ids)
  jobs_sg_id           = module.network[0].security_group_ids["jobs"]
  task_definition_arns = module.workers[0].job_task_definition_arns
  alarm_topic_arns     = concat(var.workers_alarm_topic_arns, local.uat_alarm_topics)
  depends_on           = [module.funding, module.workers_iam]
}

output "workers_cluster_arn" { value = try(module.workers[0].cluster_arn, null) }
