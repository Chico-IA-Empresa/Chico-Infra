variable "env" { type = string }
variable "service" {
  type = string
  validation {
    condition     = contains(["api", "frontend"], var.service)
    error_message = "API comum ou frontend web retido; binários mobile não são serviços Fargate."
  }
}
variable "image" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.sa-east-1\\.amazonaws\\.com/chico-(api|frontend)@sha256:[a-f0-9]{64}$", var.image))
    error_message = "Imagem ECR sa-east-1 por digest obrigatório."
  }
}
variable "cluster_arn" { type = string }
variable "execution_role_arn" { type = string }
variable "task_role_arn" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }
variable "load_balancers" {
  description = "Uma entrada por rota do ALB (output load_balancers do modules/alb): par azul/verde e regras de produção/teste. O ECS troca as cores de todas no mesmo deploy."
  type = list(object({
    blue_target_group_arn  = string
    green_target_group_arn = string
    production_rule_arn    = string
    test_rule_arn          = string
  }))
  validation {
    condition     = length(var.load_balancers) >= 1 && length(var.load_balancers) * 2 <= 5
    error_message = "De 1 a 2 rotas: cada rota usa 2 target groups e o ECS aceita no máximo 5 por serviço."
  }
}
variable "alb_management_role_arn" { type = string }
variable "smoke_hook_arn" { type = string }
variable "hook_execution_role_arn" { type = string }
variable "logs_key_arn" { type = string }
variable "alarm_names" {
  type = list(string)
  validation {
    condition     = length(var.alarm_names) > 0
    error_message = "Alarmes revisados são obrigatórios antes do bake."
  }
}
variable "desired_count" {
  type    = number
  default = 0
  validation {
    condition     = var.desired_count >= 0 && var.desired_count <= 2 && floor(var.desired_count) == var.desired_count
    error_message = "0 parado; baseline inicial máximo 2, alterar após carga combinada e DB."
  }
}
variable "secrets" {
  type    = list(object({ name = string, valueFrom = string }))
  default = []
}
variable "environment" {
  description = "Apenas configuração pública revisada; credenciais via secrets."
  type        = list(object({ name = string, value = string }))
  default     = []
}
locals { port = var.service == "api" ? 8000 : 3000 }
resource "aws_cloudwatch_log_group" "this" {
  name              = "/chico/${var.env}/${var.service}"
  retention_in_days = 30
  kms_key_id        = var.logs_key_arn
}
resource "aws_ecs_task_definition" "this" {
  family                   = "chico-${var.env}-${var.service}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([{
    name         = var.service, image = var.image, essential = true,
    portMappings = [{ containerPort = local.port, protocol = "tcp" }],
    stopTimeout  = 120, secrets = var.secrets, environment = var.environment,
    logConfiguration = { logDriver = "awslogs", options = {
      "awslogs-group"  = aws_cloudwatch_log_group.this.name,
      "awslogs-region" = "sa-east-1", "awslogs-stream-prefix" = var.service,
      mode             = "non-blocking", "max-buffer-size" = "10m"
    } }
  }])
}
resource "aws_ecs_service" "this" {
  name                              = "chico-${var.env}-${var.service}"
  cluster                           = var.cluster_arn
  task_definition                   = aws_ecs_task_definition.this.arn
  desired_count                     = var.desired_count
  launch_type                       = "FARGATE"
  platform_version                  = "1.4.0"
  health_check_grace_period_seconds = 120
  deployment_controller { type = "ECS" }
  deployment_configuration {
    strategy             = "BLUE_GREEN"
    bake_time_in_minutes = 10
    lifecycle_hook {
      hook_target_arn  = var.smoke_hook_arn
      role_arn         = var.hook_execution_role_arn
      lifecycle_stages = ["POST_TEST_TRAFFIC_SHIFT"]
    }
  }
  alarms {
    alarm_names = var.alarm_names
    enable      = true
    rollback    = true
  }
  network_configuration {
    subnets          = var.public_subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = true
  }
  dynamic "load_balancer" {
    for_each = var.load_balancers
    content {
      container_name   = var.service
      container_port   = local.port
      target_group_arn = load_balancer.value.blue_target_group_arn
      advanced_configuration {
        alternate_target_group_arn = load_balancer.value.green_target_group_arn
        production_listener_rule   = load_balancer.value.production_rule_arn
        test_listener_rule         = load_balancer.value.test_rule_arn
        role_arn                   = var.alb_management_role_arn
      }
    }
  }
  lifecycle {
    precondition {
      condition = alltrue([for lb in var.load_balancers : lb.blue_target_group_arn != lb.green_target_group_arn && lb.production_rule_arn != lb.test_rule_arn]) && (
        length(distinct(flatten([for lb in var.load_balancers : [lb.blue_target_group_arn, lb.green_target_group_arn]]))) == 2 * length(var.load_balancers)
      )
      error_message = "Grupos azul/verde e regras de produção/teste devem ser distintos, e nenhuma rota pode repetir target group de outra."
    }
  }
}
