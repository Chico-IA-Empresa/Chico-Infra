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
    condition     = length(aws_lb_target_group.this) == 8 && alltrue([for group in aws_lb_target_group.this : group.target_type == "ip" && tostring(group.deregistration_delay) == "30"])
    error_message = "Azul e verde para as quatro rotas (api, api-site, contact, frontend), alvos IP (Fargate) e drenagem de 30 s (API-02)."
  }
  assert {
    condition     = aws_lb_target_group.this["api-blue"].health_check[0].path == "/health/ready" && aws_lb_target_group.this["api-green"].port == 8000 && aws_lb_target_group.this["frontend-blue"].port == 3000 && aws_lb_target_group.this["frontend-blue"].health_check[0].path == "/robots.txt" && aws_lb_target_group.this["contact-green"].health_check[0].path == "/robots.txt"
    error_message = "API pelo /health/ready (só Postgres reprova) na 8000; frontend na 3000."
  }
}
run "host_rules_with_a_test_lane" {
  command = plan
  assert {
    condition     = alltrue([for route in ["api", "contact", "api-site", "frontend"] : aws_lb_listener_rule.test[route].priority < aws_lb_listener_rule.production[route].priority])
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
    condition     = length(aws_cloudwatch_metric_alarm.unhealthy) == 8 && length(aws_cloudwatch_metric_alarm.target_5xx) == 8
    error_message = "Host não saudável e 5xx para cada target group."
  }
  assert {
    condition     = length(output.alarm_names["api"]) == 8 && alltrue([for name in output.alarm_names["api"] : startswith(name, "chico-uat-api-")]) && length(output.alarm_names["frontend"]) == 8
    error_message = "Cada serviço recebe os alarmes das duas cores para o rollback do web-service."
  }
}
run "site_routes_follow_the_aws003_contract" {
  command = plan
  assert {
    condition = (
      aws_lb_listener_rule.production["contact"].priority < aws_lb_listener_rule.test["api-site"].priority &&
      aws_lb_listener_rule.production["api-site"].priority < aws_lb_listener_rule.test["frontend"].priority
    )
    error_message = "No site, /api/contact vence /api/*, que vence o resto: rota mais específica primeiro, nas duas pistas."
  }
  assert {
    condition = alltrue([for lane in [aws_lb_listener_rule.test, aws_lb_listener_rule.production] :
      anytrue([for c in lane["api-site"].condition : length(c.path_pattern) > 0 && toset(one(c.path_pattern).values) == toset(["/api/*", "/ws/*"])]) &&
      anytrue([for c in lane["api-site"].condition : length(c.host_header) > 0 && contains(one(c.host_header).values, "uat.example.com")])
    ])
    error_message = "/api/* e /ws/* do host do site vão para a API, nas duas pistas."
  }
  assert {
    condition = alltrue([for lane in [aws_lb_listener_rule.test, aws_lb_listener_rule.production] :
      one(lane["api-site"].transform).type == "url-rewrite" &&
      one(one(one(lane["api-site"].transform).url_rewrite_config).rewrite).regex == "^(/api)?(/.*)$" &&
      one(one(one(lane["api-site"].transform).url_rewrite_config).rewrite).replace == "$2"
    ])
    error_message = "A API recebe o caminho sem /api, como o nginx fazia: /api/auth/login vira /auth/login e /api/ws/odds vira /ws/odds."
  }
  assert {
    condition = alltrue([for route in ["api", "contact", "frontend"] : length(aws_lb_listener_rule.production[route].transform) == 0]) && anytrue([
      for c in aws_lb_listener_rule.production["contact"].condition : length(c.path_pattern) > 0 && one(c.path_pattern).values == toset(["/api/contact"])
    ])
    error_message = "Só a rota do site para a API reescreve; /api/contact fica com o Next."
  }
  assert {
    condition     = jsonencode(output.service_routes) == jsonencode({ api = ["api", "api-site"], frontend = ["contact", "frontend"] }) && length(output.load_balancers["api"]) == 2 && length(output.load_balancers["frontend"]) == 2
    error_message = "Cada serviço recebe um load_balancer por rota para o web-service."
  }
}
run "reject_three_site_hosts" {
  command = plan
  variables { web_host_names = ["a.example.com", "b.example.com", "c.example.com"] }
  expect_failures = [var.web_host_names]
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
