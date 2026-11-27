# Liga os segredos do module.configuration às task definitions sem copiar ARN.
# valueFrom aceita o ARN completo (com sufixo :CHAVE:: de JSON, se houver) ou o
# nome revisado em secret_names (ex.: "workers/DATABASE_URL"). A lista que cada
# papel de execução pode ler sai das próprias referências: workers não leem
# segredo da API e vice-versa. A variável *_secret_arns explícita sempre vence.
locals {
  config_secret_arns = var.config_secret_arns

  workers_secrets_resolved = { for consumer, refs in var.workers_secrets : consumer => [
    for ref in refs : { name = ref.name, valueFrom = startswith(ref.valueFrom, "arn:") ? ref.valueFrom : local.config_secret_arns[ref.valueFrom] }
  ] }
  api_secrets_resolved = { for service, refs in var.api_secrets : service => [
    for ref in refs : { name = ref.name, valueFrom = startswith(ref.valueFrom, "arn:") ? ref.valueFrom : local.config_secret_arns[ref.valueFrom] }
  ] }

  workers_secret_refs = flatten([for refs in values(var.workers_secrets) : [for ref in refs : ref.valueFrom]])
  api_secret_refs     = flatten([for refs in values(var.api_secrets) : [for ref in refs : ref.valueFrom]])

  # ARN do segredo = as 7 primeiras partes; o resto é chave JSON/versão.
  workers_secret_arns = length(var.workers_secret_arns) > 0 ? var.workers_secret_arns : distinct(concat(
    [for ref in local.workers_secret_refs : local.config_secret_arns[ref] if !startswith(ref, "arn:")],
    [for ref in local.workers_secret_refs : join(":", slice(split(":", ref), 0, 7)) if startswith(ref, "arn:aws:secretsmanager:")],
  ))
  api_secret_arns = length(var.api_secret_arns) > 0 ? var.api_secret_arns : distinct(concat(
    [for ref in local.api_secret_refs : local.config_secret_arns[ref] if !startswith(ref, "arn:")],
    [for ref in local.api_secret_refs : join(":", slice(split(":", ref), 0, 7)) if startswith(ref, "arn:aws:secretsmanager:")],
  ))
}
