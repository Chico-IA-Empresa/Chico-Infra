mock_provider "aws" {}
variables {
  env                   = "uat"
  vpc_id                = "vpc-test"
  public_subnet_ids     = ["subnet-test1", "subnet-test2"]
  alb_security_group_id = "sg-alb"
  certificate_arn       = "arn:aws:acm:sa-east-1:123456789012:certificate/test-only"
  api_host_names        = ["api.uat.example.com"]
  web_host_names        = ["uat.example.com"]
}
run "tls_only_entrance" {
  command = plan
  assert {
    condition     = aws_lb_listener.https.ssl_policy == "ELBSecurityPolicy-TLS13-1-2-2021-06" && aws_lb_listener.https.default_action[0].fixed_response[0].status_code == "404"
    error_message = "HTTPS com TLS 1.3 e host desconhecido sem serviço."
  }
  assert {
    condition     = aws_lb_listener.http.default_action[0].redirect[0].protocol == "HTTPS" && aws_lb_listener.http.default_action[0].redirect[0].status_code == "HTTP_301"
    error_message = "HTTP só redireciona para HTTPS."
  }
  assert {
    condition     = aws_lb.this.drop_invalid_header_fields && !aws_lb.this.internal && !aws_lb.this.enable_deletion_protection && aws_lb.this.idle_timeout == 120
    error_message = "ALB público, sem header inválido, idle acima do ping do WS/heartbeat do SSE; UAT descartável."
  }
}
run "blue_green_target_groups" {
  command = plan
  assert {
    condition     = length(aws_lb_target_group.this) == 4 && alltrue([for group in aws_lb_target_group.this : group.target_type == "ip" && tostring(group.deregistration_delay) == "30"])
    error_message = "Azul e verde para API e frontend, alvos IP (Fargate) e drenagem de 30 s (API-02)."
  }
  assert {
    condition     = aws_lb_target_group.this["api-blue"].health_check[0].path == "/health/ready" && aws_lb_target_group.this["api-green"].port == 8000 && aws_lb_target_group.this["frontend-blue"].port == 3000
    error_message = "API pelo /health/ready (só Postgres reprova) na 8000; frontend na 3000."
  }
}
run "host_rules_with_a_test_lane" {
  command = plan
  assert {
    condition     = alltrue([for service in ["api", "frontend"] : aws_lb_listener_rule.test[service].priority < aws_lb_listener_rule.production[service].priority])
    error_message = "A regra de teste vem antes da de produção do mesmo host."
  }
  assert {
    condition     = anytrue([for condition in aws_lb_listener_rule.test["api"].condition : length(condition.http_header) > 0 && one(condition.http_header).http_header_name == "x-chico-deploy-test"])
    error_message = "Só quem manda o header de teste cai na cor nova durante o deploy."
  }
  assert {
    condition     = anytrue([for condition in aws_lb_listener_rule.production["api"].condition : length(condition.host_header) > 0 && contains(one(condition.host_header).values, "api.uat.example.com")]) && alltrue([for condition in aws_lb_listener_rule.production["api"].condition : length(condition.http_header) == 0])
    error_message = "API por host próprio, sem reescrita de caminho (API-01.1), e a regra de produção não exige header."
  }
}
run "rollback_alarms_per_service" {
  command = plan
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.unhealthy) == 4 && length(aws_cloudwatch_metric_alarm.target_5xx) == 4
    error_message = "Host não saudável e 5xx para cada target group."
  }
  assert {
    condition     = length(output.alarm_names["api"]) == 4 && alltrue([for name in output.alarm_names["api"] : startswith(name, "chico-uat-api-")])
    error_message = "Cada serviço recebe os alarmes das duas cores para o rollback do web-service."
  }
}
run "prod_protected" {
  command = plan
  variables { env = "prod" }
  assert {
    condition     = aws_lb.this.enable_deletion_protection
    error_message = "ALB de Prod com proteção contra exclusão."
  }
}
run "reject_single_az" {
  command = plan
  variables { public_subnet_ids = ["subnet-test1"] }
  expect_failures = [var.public_subnet_ids]
}
run "reject_dev" {
  command = plan
  variables { env = "dev" }
  expect_failures = [var.env]
}
