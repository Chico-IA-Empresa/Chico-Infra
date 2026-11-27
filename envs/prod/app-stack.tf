# Pilha de aplicação do ambiente (modules/app-stack). ESTE ARQUIVO É IDÊNTICO
# em envs/uat e envs/prod (tests/app-stack-roots.test.mjs); o ambiente vem de
# local.app_env, definido no main.tf de cada root.

module "app_stack" {
  source = "../../modules/app-stack"

  env                = local.app_env
  enabled            = var.provision_enabled
  account_id         = var.account_id
  vpc_id             = try(module.network[0].vpc_id, null)
  public_subnet_ids  = try(module.network[0].public_subnet_ids, [])
  security_group_ids = try(module.network[0].security_group_ids, {})
  config_secret_arns = try(module.configuration[0].secret_arns, {})
  secrets_key_arn    = var.secrets_key_arn

  foundation_enabled                  = var.foundation_enabled
  alert_emails                        = var.alert_emails
  api_enabled                         = var.api_enabled
  api_certificate_arn                 = var.api_certificate_arn
  api_host_names                      = var.api_host_names
  web_host_names                      = var.web_host_names
  api_image                           = var.api_image
  frontend_image                      = var.frontend_image
  api_secret_arns                     = var.api_secret_arns
  api_secrets                         = var.api_secrets
  api_environment                     = var.api_environment
  api_logs_key_arn                    = var.api_logs_key_arn
  api_alarm_topic_arns                = var.api_alarm_topic_arns
  edge_domain_names                   = var.edge_domain_names
  edge_certificate_enabled            = var.edge_certificate_enabled
  edge_dns_zone_id                    = var.edge_dns_zone_id
  edge_dns_change_approved            = var.edge_dns_change_approved
  edge_waf_enabled                    = var.edge_waf_enabled
  edge_waf_mode                       = var.edge_waf_mode
  edge_logs_key_arn                   = var.edge_logs_key_arn
  edge_alb_arn                        = var.edge_alb_arn
  edge_association_approved           = var.edge_association_approved
  workers_enabled                     = var.workers_enabled
  workers_image                       = var.workers_image
  workers_ami_id                      = var.workers_ami_id
  workers_secret_arns                 = var.workers_secret_arns
  workers_secrets                     = var.workers_secrets
  workers_environment                 = var.workers_environment
  workers_logs_key_arn                = var.workers_logs_key_arn
  workers_alarm_topic_arns            = var.workers_alarm_topic_arns
  api_desired_counts                  = var.api_desired_counts
  workers_service_desired_counts      = var.workers_service_desired_counts
  workers_schedules_enabled           = var.workers_schedules_enabled
  workers_application_proofs_approved = var.workers_application_proofs_approved
  workers_cutover_approved            = var.workers_cutover_approved

  # Nada da pilha é planejado antes do gate financeiro do root.
  depends_on = [module.funding]
}

output "api_alb_dns_name" { value = module.app_stack.api_alb_dns_name }
output "edge" { value = module.app_stack.edge }
output "foundation" { value = module.app_stack.foundation }
output "migrate_run_task" {
  description = "Rodar antes de subir a API (e a cada release com migration); conferir o código de saída 0 no log /chico/<env>/api, prefixo migrate."
  value       = module.app_stack.migrate_run_task
}
output "workers_cluster_arn" { value = module.app_stack.workers_cluster_arn }
