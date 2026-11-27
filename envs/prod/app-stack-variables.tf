# Variáveis da pilha de aplicação (modules/app-stack). ESTE ARQUIVO É IDÊNTICO
# em envs/uat e envs/prod (tests/app-stack-roots.test.mjs reprova divergência):
# os dois ambientes têm a mesma superfície e só mudam os valores. Validações
# vivem no módulo, para valerem nos dois sem cópia.

# --- foundation.tf
variable "foundation_enabled" {
  description = "Cria as CMKs e o tópico de alerta do ambiente."
  type        = bool
  default     = false
}
variable "alert_emails" {
  description = "Assinaturas por e-mail do tópico do ambiente; cada destinatário confirma. O canal definitivo (MON-01) é do Felipe."
  type        = set(string)
  default     = []
}

# --- api.tf
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

# --- edge.tf
variable "edge_domain_names" {
  description = "Nomes do certificado (ex.: api-uat.chicoia.com.br). Vazio mantém o certificado desligado."
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
  description = "Null usa a CMK de logs do ambiente (foundation.tf) quando ela existe."
  type        = string
  default     = null
}
variable "edge_alb_arn" {
  description = "ARN do ALB do ambiente. Null usa o ALB do api.tf quando ele existe; a associação continua exigindo edge_association_approved."
  type        = string
  default     = null
}
variable "edge_association_approved" {
  type    = bool
  default = false
}

# --- workers.tf
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

# --- run-switches.tf
variable "api_desired_counts" {
  description = "Tasks por serviço web: { api = 1, frontend = 1 }. Ausente = 0. Rodar a migration (output migrate_run_task) antes de subir a API."
  type        = map(number)
  default     = {}
}
variable "workers_service_desired_counts" {
  description = "Serviços contínuos dos workers: { odds-bsd = 1, odds-surebetting = 1, telegram-update = 1 }. Ausente = 0."
  type        = map(number)
  default     = {}
}
variable "workers_schedules_enabled" {
  description = "Liga os onze schedules dos jobs. Exige workers_application_proofs_approved."
  type        = bool
  default     = false
}
variable "workers_application_proofs_approved" {
  description = "Declaração de que one-shot/trava/saída/heartbeat foram provados neste ambiente (precondition do modules/schedules)."
  type        = bool
  default     = false
}

# --- variables.tf
variable "workers_cutover_approved" {
  description = "Só Prod: libera serviço contínuo acima de 0 (precondition do modules/workers). Ignorado em UAT."
  type        = bool
  default     = false
}
