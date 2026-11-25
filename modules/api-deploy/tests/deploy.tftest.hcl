mock_provider "aws" {}
variables {
  env         = "uat"
  account_id  = "123456789012"
  smoke_urls  = ["https://api.uat.example.com/health/ready/release", "https://uat.example.com/"]
  secret_arns = ["arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/api/jwt-AbCdEf"]
}
run "smoke_hook_targets_the_test_lane" {
  command = plan
  assert {
    condition     = aws_lambda_function.smoke.runtime == "python3.12" && contains(aws_lambda_function.smoke.architectures, "arm64") && aws_lambda_function.smoke.handler == "handler.handler"
    error_message = "Smoke em Python 3.12 ARM64, sem dependências fora da biblioteca padrão."
  }
  assert {
    condition     = jsondecode(aws_lambda_function.smoke.environment[0].variables["SMOKE_URLS"])[0] == "https://api.uat.example.com/health/ready/release" && aws_lambda_function.smoke.environment[0].variables["TEST_HEADER"] == "x-chico-deploy-test"
    error_message = "Smoke chama o gate de promoção da API pelo header da regra de teste do ALB."
  }
  assert {
    condition     = aws_lambda_function.smoke.timeout >= 90
    error_message = "Timeout cobre 3 tentativas por URL com 10 s cada e 5 s de espera."
  }
}
run "deploy_roles_are_scoped" {
  command = plan
  assert {
    condition     = jsondecode(aws_iam_role_policy.hook.policy).Statement[0].Resource == "arn:aws:lambda:sa-east-1:123456789012:function:chico-uat-api-smoke" && jsondecode(aws_iam_role_policy.hook.policy).Statement[0].Action == "lambda:InvokeFunction"
    error_message = "O papel do hook só invoca a função de smoke."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.alb.policy_arn == "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers" && jsondecode(aws_iam_role.alb.assume_role_policy).Statement[0].Principal.Service == "ecs.amazonaws.com"
    error_message = "O ECS troca as regras do ALB com o papel de infraestrutura gerenciado."
  }
  assert {
    condition     = alltrue([for statement in jsondecode(aws_iam_role_policy.execution.policy).Statement : statement.Resource != "*" || statement.Action == "ecr:GetAuthorizationToken"])
    error_message = "Curinga de recurso só onde a AWS exige."
  }
  assert {
    condition     = one([for statement in jsondecode(aws_iam_role_policy.execution.policy).Statement : statement.Resource if statement.Sid == "WebSecrets"]) == ["arn:aws:secretsmanager:sa-east-1:123456789012:secret:/chico/uat/api/jwt-AbCdEf"]
    error_message = "Segredos: exatamente a lista recebida."
  }
  assert {
    condition     = length(aws_iam_role.task) == 2 && alltrue([for role in aws_iam_role.task : role.path == "/chico/uat/"])
    error_message = "Papel de task próprio para API e frontend."
  }
}
run "outputs_match_web_service_inputs" {
  command = plan
  assert {
    condition     = output.smoke_hook_arn == "arn:aws:lambda:sa-east-1:123456789012:function:chico-uat-api-smoke" && output.task_role_arns["api"] == "arn:aws:iam::123456789012:role/chico/uat/chico-uat-api"
    error_message = "Saídas no formato que o modules/web-service recebe."
  }
}
run "reject_plain_http_smoke" {
  command = plan
  variables { smoke_urls = ["http://api.uat.example.com/health/ready/release"] }
  expect_failures = [var.smoke_urls]
}
run "reject_secret_from_another_account" {
  command = plan
  variables { secret_arns = ["arn:aws:secretsmanager:sa-east-1:999999999999:secret:/chico/uat/api/x"] }
  expect_failures = [var.secret_arns]
}
