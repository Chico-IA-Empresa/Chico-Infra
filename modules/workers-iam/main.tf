variable "env" {
  type = string
  validation {
    condition     = contains(["uat", "prod"], var.env)
    error_message = "Papéis dos workers no ECS só existem em UAT e Prod; Dev roda no Compose."
  }
}
variable "account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "Conta AWS de 12 dígitos."
  }
}
variable "secret_arns" {
  description = "Segredos (Secrets Manager) que as task definitions dos workers referenciam; o papel de execução lê só estes."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.secret_arns : startswith(arn, "arn:aws:secretsmanager:sa-east-1:${var.account_id}:secret:")])
    error_message = "Segredo do Secrets Manager desta conta em sa-east-1; nunca curinga nem outra conta."
  }
}
variable "parameter_arns" {
  description = "Parâmetros (SSM) referenciados pelas task definitions dos workers."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.parameter_arns : startswith(arn, "arn:aws:ssm:sa-east-1:${var.account_id}:parameter/")])
    error_message = "Parâmetro SSM desta conta em sa-east-1."
  }
}
variable "secrets_key_arn" {
  description = "Chave KMS dos segredos/parâmetros, quando não for a chave gerenciada da AWS."
  type        = string
  default     = null
}

locals {
  path    = "/chico/${var.env}/"
  cluster = "chico-${var.env}-workers"

  # Mesma lista do modules/workers: um papel de task POR consumidor.
  services  = ["odds-bsd", "odds-surebetting", "telegram-update"]
  jobs      = ["post-match-stats", "lineups", "match-list", "standings", "team-stats", "round-matches", "match-analysis", "league-reports", "odds-history-purge", "account-deletions", "data-freshness"]
  consumers = concat(local.services, local.jobs)

  # ARNs montados pelo nome (e não lidos dos recursos) para as políticas já
  # serem conhecidas no plan: é o que os testes e o revisor do plano leem.
  role_arn       = "arn:aws:iam::${var.account_id}:role${local.path}"
  execution_role = "${local.cluster}-execution"
  scheduler_role = "chico-${var.env}-scheduler"
  host_role      = "${local.cluster}-host"

  execution_statements = concat(
    [
      { Sid = "EcrAuth", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" },
      { Sid = "EcrPullWorkers", Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], Resource = "arn:aws:ecr:sa-east-1:${var.account_id}:repository/chico-workers" },
      { Sid = "WorkersLogs", Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:sa-east-1:${var.account_id}:log-group:/chico/${var.env}/workers:*" },
    ],
    length(var.secret_arns) > 0 ? [{ Sid = "WorkerSecrets", Effect = "Allow", Action = "secretsmanager:GetSecretValue", Resource = var.secret_arns }] : [],
    length(var.parameter_arns) > 0 ? [{ Sid = "WorkerParameters", Effect = "Allow", Action = "ssm:GetParameters", Resource = var.parameter_arns }] : [],
    var.secrets_key_arn == null ? [] : [{ Sid = "DecryptWorkerSecrets", Effect = "Allow", Action = "kms:Decrypt", Resource = var.secrets_key_arn }],
  )

  scheduler_statements = [
    {
      Sid       = "RunJobTasksOnWorkersCluster"
      Effect    = "Allow"
      Action    = "ecs:RunTask"
      Resource  = [for job in local.jobs : "arn:aws:ecs:sa-east-1:${var.account_id}:task-definition/chico-${var.env}-${job}:*"]
      Condition = { ArnEquals = { "ecs:cluster" = "arn:aws:ecs:sa-east-1:${var.account_id}:cluster/${local.cluster}" } }
    },
    {
      Sid       = "PassOnlyJobRoles"
      Effect    = "Allow"
      Action    = "iam:PassRole"
      Resource  = concat(["${local.role_arn}${local.execution_role}"], [for job in local.jobs : "${local.role_arn}chico-${var.env}-${job}"])
      Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
    },
  ]

  ecs_tasks_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id }, ArnLike = { "aws:SourceArn" = "arn:aws:ecs:sa-east-1:${var.account_id}:*" } }
    }]
  })
}

resource "aws_iam_role" "execution" {
  name               = local.execution_role
  path               = local.path
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role_policy" "execution" {
  name   = "pull-workers-image-logs-and-referenced-secrets"
  role   = aws_iam_role.execution.id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.execution_statements })
}

# Sem política: hoje os workers só falam com Postgres, Redis e APIs externas.
# O papel existe para cada consumidor ter identidade própria (CloudTrail) e ser
# o lugar de uma permissão futura sem estendê-la aos outros.
resource "aws_iam_role" "task" {
  for_each           = toset(local.consumers)
  name               = "chico-${var.env}-${each.key}"
  path               = local.path
  assume_role_policy = local.ecs_tasks_trust
}

resource "aws_iam_role" "scheduler" {
  name = local.scheduler_role
  path = local.path
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

# O envio para a DLQ é concedido pelo modules/schedules, dono da fila.
resource "aws_iam_role_policy" "scheduler" {
  name   = "run-job-tasks-and-pass-job-roles"
  role   = aws_iam_role.scheduler.id
  policy = jsonencode({ Version = "2012-10-17", Statement = local.scheduler_statements })
}

resource "aws_iam_role" "host" {
  name = local.host_role
  path = local.path
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

# Agente do ECS (registrar o host, receber tasks) e SSM (acesso sem SSH, como
# no host Dev). Políticas gerenciadas da AWS: acompanham as versões do agente.
resource "aws_iam_role_policy_attachment" "host" {
  for_each   = toset(["arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role", "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"])
  role       = aws_iam_role.host.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "host" {
  name = local.host_role
  path = local.path
  role = aws_iam_role.host.name
}

output "execution_role_arn" { value = "${local.role_arn}${local.execution_role}" }
output "task_role_arns" { value = { for consumer in local.consumers : consumer => "${local.role_arn}chico-${var.env}-${consumer}" } }
output "scheduler_role_arn" { value = "${local.role_arn}${local.scheduler_role}" }
output "instance_profile_arn" { value = "arn:aws:iam::${var.account_id}:instance-profile${local.path}${local.host_role}" }
