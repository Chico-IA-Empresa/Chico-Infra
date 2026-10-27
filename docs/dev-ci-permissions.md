# Permissões de infraestrutura Dev

`scripts/dev-infra-permissions.mjs` gera candidatos privados para plan, apply e duas permissions boundaries. Não cria nem anexa policies na AWS. A entrada deve conter conta, buckets state/revisão/backup reconciliados, AMI, CMKs reais e IDs do VPC Dev/default SG confirmados no inventário.

```powershell
node scripts/dev-infra-permissions.mjs reports/private/dev-inventory.json reports/private/dev-policies
node scripts/verify-iam-actions.mjs reports/private/dev-inventory.json
```

O primeiro executor humano temporário estabelece/reconcilia o VPC Dev e o SG default antes de habilitar o CI. O gerador exige estes IDs porque o SG default e a ENI primária são recursos implícitos e não podem depender somente de tags de criação. Ele não autoriza criar VPCs arbitrários, importar o VPC default da conta, ou retaggear um SG de outro ambiente. Confirmar que o SG informado pertence ao VPC informado antes de gerar a entrada. Primeiro apply e import continuam ações AWS separadas.

## Documentos gerados

- `plan.json`: descoberta regional de metadados, leitura somente do state Dev, escrita do lock Dev e upload do bundle privado. Não lê valores de Secrets Manager nem escreve infraestrutura.
- `apply.json`: leitura anterior, escrita do state Dev, leitura da versão aprovada do plano e mutações limitadas aos recursos Dev. Não concede mutação das próprias roles CI, criação/alteração de managed policies ou remoção de boundaries. PassRole limita runtime→EC2 e flow→VPC Flow Logs.
- `runtimeBoundary.json`: teto de permissões do host para canais SSM, pull dos três ECR, logs/métricas Dev, prefixo de backup sintético e configuração Dev. Não concede state ou administração IAM. As policies inline continuam mais estreitas por consumidor.
- `flowBoundary.json`: teto exclusivo de delivery nos streams de `/chico/dev/flow`, além de descoberta regional de grupos.
- `shared-policy-inputs.json`: documentos para o input `dev_ci_policy_documents` da root shared. O apply é dividido em três managed policies nos testes atuais, respeitando a quota de 6.144 caracteres. Revisar os documentos gerados para o inventário final antes de aplicar shared.

As boundaries ficam em `/chico/shared/`; o apply Dev não pode alterá-las. A root shared exige bindings `ci-plan-dev` e `ci-infra-apply-dev`, scope Dev, repositório `Chico-IA-Empresa/Chico-Infra`, Environments separados e escrita de state apenas no apply. Seus outputs alimentam `permissions_boundary_arns` da root Dev. O host não pode ser habilitado sem este input.

## Evidência e limites

Em 27/10/2026, 166 nomes exatos de ações foram conferidos na [Service Authorization Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/service-reference.html). Candidatos com inventário de fixture foram submetidos a `AccessAnalyzer.ValidatePolicy`; referências redundantes e um operador de condição booleano foram corrigidos. A validação final está registrada no relatório de fechamento local.

Os testes verificam segregação de state, mutações proibidas, exigência de boundaries, divisão sem perda de statements e rejeição de wildcards/contas/chaves indevidas. Isto não prova autorização efetiva. IDs de fixture não podem ser usados para provisionar nem provar isolamento de Prod.

Antes de usar: gerar a partir dos metadados reais, validar novamente no Access Analyzer e provar plan/apply/PassRole positivos e negativos sob as roles reais. Acesso a CloudWatch/Secrets exige também key policies efetivas revisadas. State e plans ficam privados.

## Dependência do GitHub

O workflow autenticado executa `github-readiness.mjs` antes de solicitar OIDC. Ele requer proteção de main com os checks `Infra validation` e `Terraform security`, revisão de PR, bloqueio de force push/deleção e Environments com revisor independente, sem bypass administrativo e com branch única main.

O token de governança `GH_GOVERNANCE_READ_TOKEN` deve ser somente leitura, limitado ao repositório e às APIs de administração/environments usadas no preflight, preferencialmente emitido por GitHub App. O token padrão do Actions não substitui essas permissões. Não inserir token de escrita administrativa ou credenciais AWS permanentes.

GitHub Free privado não oferece as proteções exigidas; Felipe decidiu manter Free e registrar o bloqueio em 27/10. Nenhuma role ARN, configuração de backend ou aprovação financeira fictícia foi publicada para contornar isso. `DEV_EXECUTION_APPROVED=false` permanece no repositório. Os checks sem credenciais podem rodar normalmente.

Fonte de disponibilidade: [GitHub Environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments). Required reviewers em repositórios privados têm restrição adicional de plano; não presumir que migrar para Team, sozinho, satisfaz todo o contrato.
