variable "env" {
  type = string
  validation {
    condition     = contains(["uat", "prod"], var.env)
    error_message = "Deploy blue-green da API só em UAT e Prod."
  }
}
variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Conta AWS de 12 dígitos."
  }
}
variable "smoke_urls" {
  description = "URLs que o smoke chama na cor nova, pelo header de teste (ex.: https://api.<domínio>/health/ready/release e a home do site)."
  type        = list(string)
  validation {
    condition     = length(var.smoke_urls) > 0 && alltrue([for url in var.smoke_urls : startswith(url, "https://")])
    error_message = "Ao menos uma URL, sempre HTTPS (o ALB só redireciona HTTP)."
  }
}
variable "test_header" {
  description = "Header da regra de teste do ALB (saída test_header do modules/alb)."
  type        = string
  default     = "x-chico-deploy-test"
}
variable "secret_arns" {
  description = "Segredos que as task definitions da API e do frontend referenciam; o papel de execução lê só estes."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.secret_arns : startswith(arn, "arn:aws:secretsmanager:sa-east-1:${var.account_id}:secret:")])
    error_message = "Segredo do Secrets Manager desta conta em sa-east-1."
  }
}
variable "secrets_key_arn" {
  type    = string
  default = null
}
variable "logs_key_arn" {
  description = "CMK do log group da Lambda de smoke."
  type        = string
  default     = null
}

locals {
  path     = "/chico/${var.env}/"
  role_arn = "arn:aws:iam::${var.account_id}:role${local.path}"
  services = ["api", "frontend"]
  smoke    = "chico-${var.env}-api-smoke"

  # Nomes fixos; ARNs montados pelo nome para as políticas serem conhecidas no plan.
  execution_role = "chico-${var.env}-web-execution"
  alb_role       = "chico-${var.env}-ecs-load-balancers"
  hook_role      = "chico-${var.env}-ecs-deploy-hook"
  smoke_role     = "${local.smoke}-function"
  smoke_arn      = "arn:aws:lambda:sa-east-1:${var.account_id}:function:${local.smoke}"

  execution_statements = concat(
    [
      { Sid = "EcrAuth", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      { Sid = "EcrPullWeb", Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = ["arn:aws:ecr:sa-east-1:${var.account_id}:repository/chico-api", "arn:aws:ecr:sa-east-1:${var.account_id}:repository/chico-frontend"] },
      { Sid = "WebLogs", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = [for service in local.services : "arn:aws:logs:sa-east-1:${var.account_id}:log-group:/chico/${var.env}/${service}:*"] },
    ],
    length(var.secret_arns) > 0 ? [{ Sid = "WebSecrets", Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = var.secret_arns }] : [],
    var.secrets_key_arn == null ? [] : [{ Sid = "DecryptWebSecrets", Effect = "Allow", Action = "kms:Decrypt", Resource = var.secrets_key_arn }],
  )

  ecs_tasks_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = "arn:aws:ecs:sa-east-1:${var.account_id}:*" } }
    }]
  })
  ecs_service_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

# ── Papéis das tasks ─────────────────────────────────────────────────────────

resource "aws_iam_role" "execution" {
  name               = local.execution_role
  path               = local.path
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role_policy" "execution" {
  name   = "pull-web-images-logs-and-referenced-secrets"
  role   = aws_iam_role.execution.id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.execution_statements })
}

# Sem política: a API fala com Postgres, Valkey e provedores externos; o papel
# dá identidade própria a cada serviço e recebe permissão futura sem estendê-la.
resource "aws_iam_role" "task" {
  for_each           = toset(local.services)
  name               = "chico-${var.env}-${each.key}"
  path               = local.path
  assume_role_policy = local.ecs_tasks_trust
}

# ── Blue-green nativo do ECS ─────────────────────────────────────────────────

# O ECS troca os pesos das regras do ALB entre azul e verde com este papel.
resource "aws_iam_role" "alb" {
  name               = local.alb_role
  path               = local.path
  assume_role_policy = local.ecs_service_trust
}

resource "aws_iam_role_policy_attachment" "alb" {
  role       = aws_iam_role.alb.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonECSInfrastructureRolePolicyForLoadBalancers"
}

# O ECS invoca o smoke com este papel; ele só pode invocar essa função.
resource "aws_iam_role" "hook" {
  name               = local.hook_role
  path               = local.path
  assume_role_policy = local.ecs_service_trust
}

resource "aws_iam_role_policy" "hook" {
  name   = "invoke-api-smoke-only"
  role   = aws_iam_role.hook.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = local.smoke_arn }] })
}

# ── Lambda de smoke (POST_TEST_TRAFFIC_SHIFT) ───────────────────────────────

resource "aws_iam_role" "smoke" {
  name = local.smoke_role
  path = local.path
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "smoke" {
  name   = "write-own-logs-only"
  role   = aws_iam_role.smoke.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:sa-east-1:${var.account_id}:log-group:/aws/lambda/${local.smoke}:*" }] })
}

resource "aws_cloudwatch_log_group" "smoke" {
  name              = "/aws/lambda/${local.smoke}"
  retention_in_days = 30
  kms_key_id        = var.logs_key_arn
}

# Código versionado em smoke.zip (scripts/build-smoke-hook.py): o CI do Terraform
# não tem o provider archive. tests/api-smoke-hook.test.py reprova zip
# desatualizado em relação a smoke/handler.py.
resource "aws_lambda_function" "smoke" {
  function_name    = local.smoke
  role             = aws_iam_role.smoke.arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  architectures    = ["arm64"]
  filename         = "${path.module}/smoke.zip"
  source_code_hash = filebase64sha256("${path.module}/smoke.zip")
  memory_size      = 128
  # Pior caso: 3 tentativas por URL, 10 s de timeout e 5 s de espera.
  timeout = 120
  environment {
    variables = {
      SMOKE_URLS        = jsonencode(var.smoke_urls)
      TEST_HEADER       = var.test_header
      ATTEMPTS          = "3"
      RETRY_DELAY_S     = "5"
      REQUEST_TIMEOUT_S = "10"
    }
  }
  depends_on = [aws_cloudwatch_log_group.smoke, aws_iam_role_policy.smoke]
}

output "execution_role_arn" { value = "${local.role_arn}${local.execution_role}" }
output "task_role_arns" { value = { for service in local.services : service => "${local.role_arn}chico-${var.env}-${service}" } }
output "alb_management_role_arn" { value = "${local.role_arn}${local.alb_role}" }
output "hook_execution_role_arn" { value = "${local.role_arn}${local.hook_role}" }
output "smoke_hook_arn" { value = local.smoke_arn }
