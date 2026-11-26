variable "env" {
  type = string
  validation {
    condition     = contains(["uat", "prod"], var.env)
    error_message = "ALB da API só em UAT e Prod; Dev usa o proxy do host chico-dev."
  }
}
variable "vpc_id" { type = string }
variable "public_subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "ALB exige subnets em pelo menos duas AZs."
  }
}
variable "alb_security_group_id" {
  description = "SG `alb` do modules/network: 80/443 de fora, saída só para api:8000 e frontend:3000."
  type        = string
}
variable "certificate_arn" {
  description = "Certificado ACM emitido (modules/edge, ENT-03)."
  type        = string
}
variable "api_host_names" {
  description = "Hosts da API sem reescrita de caminho (API-01.1: api.<domínio>)."
  type        = list(string)
  validation {
    condition     = length(var.api_host_names) > 0
    error_message = "Informar ao menos um host da API."
  }
}
variable "web_host_names" {
  description = "Hosts do site (frontend). No máximo 2: a regra de /api soma 2 caminhos e o header de teste, e o ALB aceita 5 valores por regra."
  type        = list(string)
  validation {
    condition     = length(var.web_host_names) > 0 && length(var.web_host_names) <= 2
    error_message = "Informar um ou dois hosts do site."
  }
}
variable "frontend_health_path" {
  type    = string
  default = "/"
}
variable "idle_timeout_seconds" {
  description = "Acima do ping de 20 s do /ws/odds e do heartbeat de 15 s do SSE (API-01), com folga."
  type        = number
  default     = 120
}
variable "access_logs_bucket" {
  description = "Bucket de access logs do ALB (política para o ELB de sa-east-1). Nulo desliga."
  type        = string
  default     = null
}
variable "alarm_topic_arns" {
  type    = list(string)
  default = []
}
variable "target_5xx_threshold" {
  description = "Respostas 5xx do target em 5 min que reprovam a versão (rollback do blue-green)."
  type        = number
  default     = 10
}

locals {
  name = "chico-${var.env}"

  # Blue-green nativo do ECS: cada ROTA tem dois target groups e duas regras no
  # listener HTTPS. A de produção recebe o tráfego real; a de teste, só quem
  # manda o header de teste (o smoke da Lambda). O ECS troca os pesos entre os
  # target groups das regras de cada rota durante o deploy; um serviço com duas
  # rotas registra as tasks nos dois pares (ECS aceita até 5 target groups).
  #
  # Contrato AWS-003 (o mesmo do nginx da VPS), avaliado nesta ordem:
  #   host da API                 → api, sem reescrita (API-01.1, apps mobile)
  #   site /api/contact           → frontend (rota do próprio Next)
  #   site /api/* e /ws/*         → api, sem o prefixo /api (/api/ws/odds → /ws/odds)
  #   site, qualquer outro caminho → frontend
  # A ordem por prioridade é rota mais específica primeiro, e dentro da rota a
  # pista de teste antes da de produção.
  routes = {
    api      = { service = "api", port = 8000, health = "/health/ready", hosts = var.api_host_names, paths = [], rewrite = false, priority = 10 }
    contact  = { service = "frontend", port = 3000, health = var.frontend_health_path, hosts = var.web_host_names, paths = ["/api/contact"], rewrite = false, priority = 30 }
    api-site = { service = "api", port = 8000, health = "/health/ready", hosts = var.web_host_names, paths = ["/api/*", "/ws/*"], rewrite = true, priority = 50 }
    frontend = { service = "frontend", port = 3000, health = var.frontend_health_path, hosts = var.web_host_names, paths = [], rewrite = false, priority = 70 }
  }
  # Sempre casa: /api/x vira /x e /ws/x fica como está.
  site_rewrite = { regex = "^(/api)?(/.*)$", replace = "$2" }
  colors       = ["blue", "green"]
  target_groups = merge([
    for route, cfg in local.routes : {
      for color in local.colors : "${route}-${color}" => merge(cfg, { route = route, color = color })
    }
  ]...)
  service_routes = { for service in distinct([for cfg in values(local.routes) : cfg.service]) : service => sort([for route, cfg in local.routes : route if cfg.service == service]) }
  test_header = "x-chico-deploy-test"
}

resource "aws_lb" "this" {
  name                       = local.name
  load_balancer_type         = "application"
  internal                   = false
  security_groups            = [var.alb_security_group_id]
  subnets                    = var.public_subnet_ids
  idle_timeout               = var.idle_timeout_seconds
  drop_invalid_header_fields = true
  enable_deletion_protection = var.env == "prod"
  dynamic "access_logs" {
    for_each = var.access_logs_bucket == null ? [] : [var.access_logs_bucket]
    content {
      bucket  = access_logs.value
      prefix  = "alb/${var.env}"
      enabled = true
    }
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn
  # Host desconhecido não chega a serviço nenhum.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_target_group" "this" {
  for_each             = local.target_groups
  name                 = "${local.name}-${each.key}"
  port                 = each.value.port
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = 30
  health_check {
    path                = each.value.health
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Regra de teste antes da de produção: o mesmo host COM o header vai para o
# target group de teste durante o deploy. `action` fica fora do Terraform depois
# de criada, porque é o ECS que troca os pesos azul/verde; sem o ignore, o
# próximo apply desfaria a troca no meio de um deploy.
resource "aws_lb_listener_rule" "test" {
  for_each     = local.routes
  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["${each.key}-blue"].arn
  }
  condition {
    host_header {
      values = each.value.hosts
    }
  }
  dynamic "condition" {
    for_each = length(each.value.paths) > 0 ? [each.value.paths] : []
    content {
      path_pattern {
        values = condition.value
      }
    }
  }
  dynamic "transform" {
    for_each = each.value.rewrite ? [local.site_rewrite] : []
    content {
      type = "url-rewrite"
      url_rewrite_config {
        rewrite {
          regex   = transform.value.regex
          replace = transform.value.replace
        }
      }
    }
  }
  condition {
    http_header {
      http_header_name = local.test_header
      values           = ["1"]
    }
  }
  lifecycle {
    ignore_changes = [action]
  }
}

resource "aws_lb_listener_rule" "production" {
  for_each     = local.routes
  listener_arn = aws_lb_listener.https.arn
  priority     = each.value.priority + 10
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this["${each.key}-blue"].arn
  }
  condition {
    host_header {
      values = each.value.hosts
    }
  }
  dynamic "condition" {
    for_each = length(each.value.paths) > 0 ? [each.value.paths] : []
    content {
      path_pattern {
        values = condition.value
      }
    }
  }
  dynamic "transform" {
    for_each = each.value.rewrite ? [local.site_rewrite] : []
    content {
      type = "url-rewrite"
      url_rewrite_config {
        rewrite {
          regex   = transform.value.regex
          replace = transform.value.replace
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [action]
  }
}

# Alarmes por target group (as duas cores): é por eles que o blue-green do
# modules/web-service faz rollback, e a cor nova muda a cada deploy.
resource "aws_cloudwatch_metric_alarm" "unhealthy" {
  for_each            = local.target_groups
  alarm_name          = "${local.name}-${each.key}-unhealthy-hosts"
  alarm_description   = "Target ${each.key} com task reprovando o health check."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix, TargetGroup = aws_lb_target_group.this[each.key].arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_topic_arns
  ok_actions          = var.alarm_topic_arns
}

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  for_each            = local.target_groups
  alarm_name          = "${local.name}-${each.key}-target-5xx"
  alarm_description   = "Target ${each.key} respondendo 5xx acima do limite."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = aws_lb.this.arn_suffix, TargetGroup = aws_lb_target_group.this[each.key].arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = var.target_5xx_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_topic_arns
  ok_actions          = var.alarm_topic_arns
}

output "alb_arn" { value = aws_lb.this.arn }
output "alb_dns_name" { value = aws_lb.this.dns_name }
output "alb_zone_id" { value = aws_lb.this.zone_id }
output "test_header" { value = local.test_header }
output "target_group_arns" {
  value = { for route in keys(local.routes) : route => { for color in local.colors : color => aws_lb_target_group.this["${route}-${color}"].arn } }
}
output "production_rule_arns" { value = { for route, rule in aws_lb_listener_rule.production : route => rule.arn } }
output "test_rule_arns" { value = { for route, rule in aws_lb_listener_rule.test : route => rule.arn } }
output "alarm_names" {
  value = { for service in keys(local.service_routes) : service => sort(concat([for key, alarm in aws_cloudwatch_metric_alarm.unhealthy : alarm.alarm_name if local.target_groups[key].service == service], [for key, alarm in aws_cloudwatch_metric_alarm.target_5xx : alarm.alarm_name if local.target_groups[key].service == service])) }
}
output "service_routes" { value = local.service_routes }
# Por serviço, um bloco load_balancer do modules/web-service por rota.
output "load_balancers" {
  value = { for service, routes in local.service_routes : service => [for route in routes : {
    blue_target_group_arn  = aws_lb_target_group.this["${route}-blue"].arn
    green_target_group_arn = aws_lb_target_group.this["${route}-green"].arn
    production_rule_arn    = aws_lb_listener_rule.production[route].arn
    test_rule_arn          = aws_lb_listener_rule.test[route].arn
  }] }
}
