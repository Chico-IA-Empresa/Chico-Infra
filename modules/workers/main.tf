variable "env" {
  type = string
  validation {
    condition     = contains(["uat", "prod"], var.env)
    error_message = "Dev roda os workers no Compose do host chico-dev, não no ECS."
  }
}
variable "image" {
  description = "chico-workers por digest; a mesma imagem para os serviços contínuos e os jobs."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.sa-east-1\\.amazonaws\\.com/chico-workers@sha256:[a-f0-9]{64}$", var.image))
    error_message = "Imagem chico-workers do ECR sa-east-1 por digest obrigatório."
  }
}
variable "ami_id" {
  description = "AMI ECS-optimized Amazon Linux 2023 ARM64 verificada em sa-east-1; nunca adivinhar."
  type        = string
}
variable "instance_type" {
  type    = string
  default = "t4g.small"
  validation {
    condition     = contains(["t4g.small", "t4g.medium"], var.instance_type)
    error_message = "Host ARM64 revisado: t4g.small (baseline) ou t4g.medium (depois de medir)."
  }
}
variable "max_hosts" {
  description = "Teto do ASG: um host de trabalho mais um de substituição; cabe na quota de vCPU."
  type        = number
  default     = 2
  validation {
    condition     = var.max_hosts >= 1 && var.max_hosts <= 3 && floor(var.max_hosts) == var.max_hosts
    error_message = "Entre 1 e 3 hosts; acima disso, revisar quota e custo antes."
  }
}
variable "host_subnet_id" {
  description = "Subnet privada da MESMA AZ do RDS; os workers não ficam atrás de ALB."
  type        = string
}
variable "host_security_group_id" { type = string }
variable "instance_profile_arn" { type = string }
variable "execution_role_arn" { type = string }
variable "task_role_arns" {
  description = "Papel de task POR consumidor (serviço ou job): permissões e segredos separados."
  type        = map(string)
}
variable "secrets" {
  description = "Por consumidor: { consumidor = [{ name, valueFrom }] }, de Secrets Manager/SSM."
  type        = map(list(object({ name = string, valueFrom = string })))
  default     = {}
}
variable "environment" {
  description = "Configuração pública comum a todos os consumidores; nunca credencial."
  type        = list(object({ name = string, value = string }))
  default     = []
}
variable "logs_key_arn" { type = string }
variable "service_desired_counts" {
  description = "0 parado. Cada serviço tem trava de líder: uma réplica trabalha, as outras esperam."
  type        = map(number)
  default     = { odds-bsd = 0, odds-surebetting = 0, telegram-update = 0 }
  validation {
    condition     = alltrue([for count in values(var.service_desired_counts) : contains([0, 1], count)])
    error_message = "0 ou 1 por serviço; réplica extra só existe durante o deploy (100/200)."
  }
}
variable "cutover_approved" {
  description = "Prod só liga consumidor depois do AWS-035 e da autorização específica do corte."
  type        = bool
  default     = false
}

locals {
  name = "chico-${var.env}-workers"

  # Contínuos (ECS EC2, bridge): trava de líder + standby saudável (AWS-019),
  # SIGTERM termina a iteração e solta a trava. Reserva de memória (soft) para
  # caber duas cópias de cada no host durante o deploy 100/200.
  services = {
    odds-bsd         = { command = ["python", "./workers/worker_odds_bsd.py"], memory_reservation = 256 }
    odds-surebetting = { command = ["python", "./workers/worker_odds_surebetting.py"], memory_reservation = 256 }
    telegram-update  = { command = ["python", "./workers/telegram_update_worker.py"], memory_reservation = 192 }
  }

  # Jobs (Fargate ARM, disparados pelo modules/schedules): contrato one-shot
  # (AWS-018/020/022/023). O prazo fica abaixo da cadência de cada um, para um
  # disparo nunca encostar no próximo; parar no prazo sai com 3 e retoma depois.
  jobs = {
    post-match-stats   = { command = ["python", "./workers/sofascore_post_match_statistics_worker.py", "--max-runtime-seconds", "780"], cpu = 256, memory = 512 }
    lineups            = { command = ["python", "./workers/sofascore_lineups_worker.py", "--max-runtime-seconds", "1080"], cpu = 256, memory = 512 }
    match-list         = { command = ["python", "./workers/sofascore_match_list_worker.py", "--max-runtime-seconds", "1500"], cpu = 256, memory = 512 }
    standings          = { command = ["python", "./workers/sofascore_standings_worker.py", "--max-runtime-seconds", "3600"], cpu = 256, memory = 512 }
    team-stats         = { command = ["python", "./workers/sofascore_team_statistics_worker.py", "--max-runtime-seconds", "3600"], cpu = 256, memory = 512 }
    round-matches      = { command = ["python", "./workers/sofascore_round_matches_worker.py", "--max-runtime-seconds", "3600"], cpu = 256, memory = 512 }
    match-analysis     = { command = ["python", "./workers/worker_match_analysis.py", "--run-once", "--max-runtime-seconds", "3600"], cpu = 512, memory = 1024 }
    league-reports     = { command = ["python", "./workers/worker_league_reports.py", "--run-once", "--max-runtime-seconds", "3600"], cpu = 512, memory = 1024 }
    odds-history-purge = { command = ["python", "./workers/worker_odds_history_purge.py", "--max-runtime-seconds", "900"], cpu = 256, memory = 512 }
    account-deletions  = { command = ["python", "./scripts/process_account_deletions.py", "--max-runtime-seconds", "600"], cpu = 256, memory = 512 }
    data-freshness     = { command = ["python", "./workers/worker_data_freshness.py", "--max-runtime-seconds", "120"], cpu = 256, memory = 512 }
  }

  consumers = concat(keys(local.services), keys(local.jobs))

  log_options = {
    "awslogs-group"  = aws_cloudwatch_log_group.this.name
    "awslogs-region" = "sa-east-1"
    mode             = "non-blocking"
    max-buffer-size  = "10m"
  }

  host_user_data = join("\n", [
    "#!/bin/bash",
    "cat >> /etc/ecs/ecs.config <<'EOF'",
    "ECS_CLUSTER=${local.name}",
    "ECS_CONTAINER_STOP_TIMEOUT=120s",
    "ECS_ENABLE_SPOT_INSTANCE_DRAINING=false",
    "EOF",
  ])
}

data "aws_ami" "host" {
  owners = ["amazon"]
  filter {
    name   = "image-id"
    values = [var.ami_id]
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/chico/${var.env}/workers"
  retention_in_days = 30
  kms_key_id        = var.logs_key_arn
}

resource "aws_ecs_cluster" "this" {
  name = local.name
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  lifecycle {
    precondition {
      condition     = alltrue([for consumer in keys(var.secrets) : contains(local.consumers, consumer)])
      error_message = "Segredo para consumidor que não existe (ex.: um quarto worker live de odds); ver environment-readiness."
    }
  }
}

resource "aws_launch_template" "host" {
  name_prefix   = "${local.name}-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  ebs_optimized = true
  user_data     = base64encode(local.host_user_data)
  iam_instance_profile {
    arn = var.instance_profile_arn
  }
  vpc_security_group_ids = [var.host_security_group_id]
  credit_specification {
    cpu_credits = "standard"
  }
  # hop limit 1: containers em bridge não alcançam o IMDS do host; credencial
  # de task vem do agente do ECS (169.254.170.2), como o metadata v4.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      encrypted             = true
      volume_type           = "gp3"
      volume_size           = 30
      delete_on_termination = true
    }
  }
  monitoring {
    enabled = false
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = local.name, env = var.env, project = "chicoai" }
  }
  lifecycle {
    precondition {
      condition     = data.aws_ami.host.architecture == "arm64" && data.aws_ami.host.state == "available" && startswith(data.aws_ami.host.name, "al2023-ami-ecs-")
      error_message = "AMI ECS-optimized Amazon Linux 2023 ARM64 disponível exigida."
    }
  }
}

resource "aws_autoscaling_group" "host" {
  name_prefix           = "${local.name}-"
  min_size              = 0
  max_size              = var.max_hosts
  vpc_zone_identifier   = [var.host_subnet_id]
  protect_from_scale_in = false
  launch_template {
    id      = aws_launch_template.host.id
    version = aws_launch_template.host.latest_version
  }
  tag {
    key                 = "AmazonECSManaged"
    value               = "true"
    propagate_at_launch = true
  }
  lifecycle {
    # O capacity provider do ECS é dono da capacidade desejada.
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "host" {
  name = local.name
  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.host.arn
    managed_termination_protection = "DISABLED"
    managed_draining               = "ENABLED"
    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", aws_ecs_capacity_provider.host.name]
  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.host.name
    weight            = 1
  }
}

resource "aws_ecs_task_definition" "service" {
  for_each                 = local.services
  family                   = "chico-${var.env}-${each.key}"
  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = lookup(var.task_role_arns, each.key, "")
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([{
    name              = each.key, image = var.image, essential = true, command = each.value.command,
    memoryReservation = each.value.memory_reservation, memory = 512, stopTimeout = 120,
    environment       = var.environment, secrets = lookup(var.secrets, each.key, []),
    healthCheck = {
      command     = ["CMD", "python", "-m", "workers.leader", "--health"]
      interval    = 30
      timeout     = 10
      retries     = 3
      startPeriod = 60
    }
    logConfiguration = { logDriver = "awslogs", options = merge(local.log_options, { "awslogs-stream-prefix" = each.key }) }
  }])
  lifecycle {
    precondition {
      condition     = contains(keys(var.task_role_arns), each.key)
      error_message = "Cada consumidor precisa do próprio papel de task."
    }
  }
}

resource "aws_ecs_service" "service" {
  for_each                           = local.services
  name                               = "chico-${var.env}-${each.key}"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.service[each.key].arn
  desired_count                      = lookup(var.service_desired_counts, each.key, 0)
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.host.name
    weight            = 1
  }
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  depends_on = [aws_ecs_cluster_capacity_providers.this]
  lifecycle {
    precondition {
      condition     = var.env != "prod" || var.cutover_approved || lookup(var.service_desired_counts, each.key, 0) == 0
      error_message = "Prod mantém os consumidores em 0 até o AWS-035 e a autorização do corte."
    }
  }
}

resource "aws_ecs_task_definition" "job" {
  for_each                 = local.jobs
  family                   = "chico-${var.env}-${each.key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = tostring(each.value.cpu)
  memory                   = tostring(each.value.memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = lookup(var.task_role_arns, each.key, "")
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([{
    name             = each.key, image = var.image, essential = true, command = each.value.command,
    stopTimeout      = 120, environment = var.environment, secrets = lookup(var.secrets, each.key, []),
    logConfiguration = { logDriver = "awslogs", options = merge(local.log_options, { "awslogs-stream-prefix" = each.key }) }
  }])
  lifecycle {
    precondition {
      condition     = contains(keys(var.task_role_arns), each.key)
      error_message = "Cada consumidor precisa do próprio papel de task."
    }
  }
}

output "cluster_arn" { value = aws_ecs_cluster.this.arn }
output "job_task_definition_arns" { value = { for job, definition in aws_ecs_task_definition.job : job => definition.arn } }
output "service_names" { value = sort([for service in aws_ecs_service.service : service.name]) }
