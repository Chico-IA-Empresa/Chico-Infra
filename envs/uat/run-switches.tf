# Chaves para LIGAR a UAT, todas em zero por padrão. Antes ficavam fora do
# root de propósito; agora existem para o ensaio, mas só mudam com um apply
# revisado. Subir pelo console não serve: o próximo apply volta ao valor daqui.
variable "api_desired_counts" {
  description = "Tasks por serviço web: { api = 1, frontend = 1 }. Ausente = 0. Rodar a migration (output migrate_run_task) antes de subir a API."
  type        = map(number)
  default     = {}
  validation {
    condition     = alltrue([for name, count in var.api_desired_counts : contains(["api", "frontend"], name) && count >= 0 && count <= 2 && floor(count) == count])
    error_message = "Só api/frontend, de 0 a 2 tasks."
  }
}
variable "workers_service_desired_counts" {
  description = "Serviços contínuos dos workers: { odds-bsd = 1, odds-surebetting = 1, telegram-update = 1 }. Ausente = 0."
  type        = map(number)
  default     = {}
  validation {
    condition     = alltrue([for name, count in var.workers_service_desired_counts : contains(["odds-bsd", "odds-surebetting", "telegram-update"], name) && contains([0, 1], count)])
    error_message = "Só odds-bsd/odds-surebetting/telegram-update, 0 ou 1 (trava de líder)."
  }
}
variable "workers_schedules_enabled" {
  description = "Liga os onze schedules dos jobs. Exige workers_application_proofs_approved."
  type        = bool
  default     = false
}
variable "workers_application_proofs_approved" {
  description = "Declaração de que one-shot/trava/saída/heartbeat foram provados nesta UAT (precondition do modules/schedules)."
  type        = bool
  default     = false
}
