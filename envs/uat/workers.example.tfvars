# Template only: workers block of envs/uat (workers.tf). Real nonsecret inputs
# go privately in ci.auto.tfvars.json, never in Git. Lido na conta 306915830875
# em 2026-11-25; só a AMI existia. Os demais nascem de outras etapas, abaixo.
#
# Mesmo com tudo preenchido e as duas chaves ligadas, nada roda: serviços em 0
# e schedules DISABLED. A UAT inteira ainda não existe (sem VPC de UAT); ela
# sobe com provision_enabled, que exige credit_approval revisado no funding.

workers_enabled = false

# AMI ECS-optimized AL2023 ARM64 publicada pela AWS. Recomendada em 2026-11-25:
# al2023-ami-ecs-hvm-2023.0.20261119-kernel-6.1-arm64. Reconferir no dia do
# apply: aws ssm get-parameter --name
# /aws/service/ecs/optimized-ami/amazon-linux-2023/arm64/recommended/image_id
workers_ami_id = "ami-0ab63037216e74e9b"

# chico-workers por digest (123456789012.dkr.ecr.sa-east-1.amazonaws.com/chico-workers@sha256:...).
# Não existe: o ECR só tem imagens de fixture e restore. Sai do release-dev do
# backend (Chico-Back #272) quando a role ci-build-backend-dev for aplicada.
workers_image = null

# Segredos por consumidor. valueFrom pode ser o nome em secret_names
# (ex.: { name = "DATABASE_URL", valueFrom = "workers/DATABASE_URL" }): o ARN e
# a lista que o papel de execução lê saem do module.configuration (secrets.tf).
workers_secret_arns = [] # vazio = derivado de workers_secrets
workers_secrets     = {}

# Configuração pública comum (ENVIRONMENT, BSD_WORKER_ENABLED,
# SUREBETTING_WORKER_ENABLED, TELEGRAM_INTEGRATION_ENABLED...). As flags de
# fonte precisam bater entre os serviços de odds e o job data-freshness.
workers_environment = []

# CMK do log group /chico/uat/workers. Não existe chave de UAT na conta
# (só chico/dev/*, chico/prod/data e chico/shared/audit).
workers_logs_key_arn = null

# Tópico SNS cifrado do canal de alerta (MON-01, Felipe), com sns:Publish
# para events.amazonaws.com e cloudwatch.amazonaws.com. Não existe para UAT.
workers_alarm_topic_arns = []
