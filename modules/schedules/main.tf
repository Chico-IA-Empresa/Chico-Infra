variable "env" {
  type = string
  validation {
    condition     = contains(["uat", "prod"], var.env)
    error_message = "Dev usa loops Compose, não Scheduler."
  }
}
variable "cluster_arn" { type = string }
variable "target_role_arn" { type = string }
variable "public_subnet_ids" { type = set(string) }
variable "jobs_sg_id" { type = string }
variable "task_definition_arns" {
  type = map(string)
  validation {
    condition     = alltrue([for arn in values(var.task_definition_arns) : can(regex("^arn:aws:ecs:sa-east-1:[0-9]{12}:task-definition/chico-(uat|prod)-[a-z0-9-]+:[0-9]+$", arn))])
    error_message = "Usar ARNs de task definition com revisão explícita em sa-east-1."
  }
}
variable "enabled" {
  type    = bool
  default = false
}
variable "application_proofs_approved" {
  description = "Only true after real one-shot/lock/exit/heartbeat and activation gates. Review flag is not proof by itself."
  type        = bool
  default     = false
}
locals {
  cadence = {
    match-list       = "rate(30 minutes)"
    lineups          = "rate(20 minutes)"
    post-match-stats = "rate(15 minutes)"
    standings        = "rate(12 hours)"
    team-stats       = "rate(12 hours)"
    round-matches    = "rate(1 day)"
    league-reports   = "rate(12 hours)"
    match-analysis   = "rate(12 hours)"
  }
}
resource "aws_scheduler_schedule_group" "this" { name = "chico-${var.env}" }
resource "aws_scheduler_schedule" "this" {
  for_each                     = local.cadence
  name                         = each.key
  group_name                   = aws_scheduler_schedule_group.this.name
  schedule_expression          = each.value
  schedule_expression_timezone = "UTC"
  state                        = var.enabled ? "ENABLED" : "DISABLED"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = var.cluster_arn
    role_arn = var.target_role_arn
    ecs_parameters {
      task_definition_arn = var.task_definition_arns[each.key]
      task_count          = 1
      launch_type         = "FARGATE"
      platform_version    = "1.4.0"
      network_configuration {
        assign_public_ip = true
        subnets          = var.public_subnet_ids
        security_groups  = [var.jobs_sg_id]
      }
    }
    retry_policy {
      maximum_event_age_in_seconds = 300
      maximum_retry_attempts       = 2
    }
  }
  lifecycle {
    precondition {
      condition     = !var.enabled || var.application_proofs_approved
      error_message = "Ativação depende de one-shot/locks/exit/heartbeat e gate real do ambiente."
    }
    precondition {
      condition     = try(strcontains(var.task_definition_arns[each.key], ":task-definition/chico-${var.env}-"), false)
      error_message = "Task definition de outro ambiente não pode ser schedule deste scope."
    }
  }
}
