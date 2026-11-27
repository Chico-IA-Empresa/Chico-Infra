# Migration do banco do ambiente: o mesmo comando do serviço `migrate` da VPS
# (deploy/docker-compose.runtime.yml do Chico-Back), na imagem da API.
# O Terraform só DEFINE a task; rodar é um passo explícito antes de subir a
# API (output migrate_run_task), porque migration não pode rodar sozinha a
# cada apply.
#
# Credencial: api_secrets["migrate"] quando existir (usuário migrator, dono do
# schema); senão herda os segredos da API. Logs no log group da API, prefixo
# `migrate`, para não precisar de outro log group nem de outra permissão.
locals {
  migrate_on = local.api_on && var.api_image != null
  migrate_command = join("; ", [
    "set -e",
    "python scripts/ensure_alembic_baseline.py",
    "alembic upgrade heads",
    "python scripts/verify_schema_authority.py",
  ])
}

resource "aws_ecs_task_definition" "migrate" {
  count                    = local.migrate_on ? 1 : 0
  family                   = "chico-${var.env}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = module.api_deploy[0].execution_role_arn
  task_role_arn            = module.api_deploy[0].task_role_arns["api"]
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([{
    name        = "migrate", image = var.api_image, essential = true,
    command     = ["sh", "-c", local.migrate_command],
    secrets     = lookup(local.api_secrets_resolved, "migrate", lookup(local.api_secrets_resolved, "api", [])),
    environment = lookup(var.api_environment, "api", []),
    logConfiguration = { logDriver = "awslogs", options = {
      "awslogs-group"  = "/chico/${var.env}/api",
      "awslogs-region" = "sa-east-1", "awslogs-stream-prefix" = "migrate"
    } }
  }])
  # O log group /chico/${var.env}/api nasce no web-service da API.
  depends_on = [module.web]
}

output "migrate_run_task" {
  description = "Rodar antes de subir a API (e a cada release com migration); conferir o código de saída 0 no log /chico/<env>/api, prefixo migrate."
  value = local.migrate_on ? join(" ", [
    "aws ecs run-task --cluster chico-${var.env}-web --launch-type FARGATE",
    "--task-definition ${aws_ecs_task_definition.migrate[0].arn}",
    "--network-configuration 'awsvpcConfiguration={subnets=[${join(",", var.public_subnet_ids)}],securityGroups=[${var.security_group_ids["api"]}],assignPublicIp=ENABLED}'",
  ]) : null
}
