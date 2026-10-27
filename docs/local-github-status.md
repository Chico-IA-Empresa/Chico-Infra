# Preparação local e GitHub — 27/10/2026

> Atualização posterior: Felipe tornou o repositório público. O bloqueio GitHub Free privado descrito abaixo é histórico. A adaptação e as proteções estão registradas em [public-repository-governance.md](public-repository-governance.md). As dependências de recursos AWS continuam pendentes.

Objetivo: fechar os cinco itens levantados na conversa sobre a fase 1. Esta página registra evidência atual e impedimentos; não reduz o objetivo à existência de arquivos e não concede aceite AWS.

| Requisito | Implementação / evidência | Pendência real |
|---|---|---|
| Revisão de segurança local | Correções state/auditoria, teste de delivery, gate bootstrap/shared/Dev e 28 exceções específicas com controles, validade e hash. Scanner completo preservado. Gate também aprovado no runner GitHub. | Aceite operacional e segurança de UAT/Prod permanecem etapas próprias; os checks sempre devem ser lidos na revisão corrente. |
| Permissões de plan/apply | Gerador de candidatos a partir de inventário, managed policies divididas por quota, ligação shared→roles CI e boundaries exigidas pela root Dev. Nomes de ações verificados na AWS; Access Analyzer usado com fixture. | Regerar/validar com VPC/SG/CMKs/buckets reais após primeiro executor e provar autorização sob roles reais. |
| Configuração real | Conta `306915830875` e AZ `sa-east-1a` verificadas em leitura; owner Felipe e cost-center Chico-IA. Inputs locais privados mantêm provisionamento/compute desligados e aprovação financeira ausente. | Backend state/review não existem; CMKs, SNS, ECR, VPC/SG Dev, retenções cotadas, hostname/DNS e cobertura atual ainda dependem da fase AWS. Sem UUIDs/ARNs inventados. |
| GitHub | Remote privado próprio, branch de preparação, workflows sem credenciais, Actions fixadas por SHA, allowlist de fornecedores, token padrão somente leitura e aprovação de PR pelo Actions desabilitada. Variáveis de conta e `DEV_EXECUTION_APPROVED=false` conferidas. | Proteção de branch e Environments exigidos indisponíveis no GitHub Free privado. Felipe decidiu manter Free e registrar o bloqueio. OIDC não está habilitado para contornar esta limitação. |
| Documentação e checks finais | README e runbook atualizados; relatórios históricos identificados; contrato espelhado para consulta no GitHub; testes independentes do checkout backend; gitattributes LF e exclusão de dados privados. Publicação e primeira rodada Linux aprovadas no PR #1. | Verificar os checks do commit corrente antes de integrar mudanças posteriores. |

## Inventário AWS observado nesta rodada

Somente leituras e validação estática de policies; nenhum apply/import/destroy ou alteração de DNS.

- STS: conta `306915830875`; identidade conectada root. Não utilizada para provisionar.
- IAM: três service-linked roles, sem roles Chico e sem OIDC providers.
- S3: somente bucket legado `chico-backup`, preservado; nenhum bucket de state/review/backup Dev encontrado.
- ECR: nenhum repositório em sa-east-1.
- KMS: ListKeys confirmou zero keys em sa-east-1. ListAliases retornou somente aliases de serviços AWS, sem TargetKeyId no retorno. Nenhum ARN de CMK Dev existe no inventário consultado.
- SNS: nenhum tópico em sa-east-1. Route53: nenhuma hosted zone na conta.
- EC2: nenhuma instância; apenas VPC default no inventário de sa-east-1. As AZs a/b/c estavam disponíveis.
- AMI fixada nos inputs locais: `ami-07196136b80c5c5c0`, Amazon owner `137112412989`, AL2023 `2023.12.20261026.1`, kernel 6.1, ARM64, EBS/HVM, disponível. Revalidar antes de plan AWS.
- Compose fixado: `v5.6.1`, SHA256 aarch64 `42cfa75f51ad0ccf290bad37899e0038a8c10a0069e85233ecc1d53e3ff1347d`, conferido no digest do release GitHub e no arquivo oficial de checksum.

Este inventário contrasta com a premissa histórica de fundação operacional pronta. Antes de qualquer execução, reconciliar estados fora da conta/caminho consultados e executar o primeiro executor temporário conforme o contrato, preservando o bucket legado. Não importar o VPC default como Dev.

## Bloqueio de governança confirmado

A API de proteção de main retornou HTTP 403: “Upgrade to GitHub Pro or make this repository public to enable this feature”. A organização informou plano Free, repositório privado e sem Environments configurados. Felipe escolheu manter Free; nenhuma assinatura ou mudança de visibilidade foi realizada.

O preflight verifica proteções reais pela API antes do OIDC. Aprovação por input/variável não substitui revisão protegida. Required reviewers em repositórios privados também possuem restrição de plano; consultar [documentação GitHub](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).

## Reprodução dos checks

```powershell
./scripts/verify.ps1 -Terraform CAMINHO_TERRAFORM -Tflint CAMINHO_TFLINT
node --test 'tests/*.test.mjs'
python tests/config-consumer.test.py
python tests/proxy-events.test.py
bash tests/bootstrap.test.sh
./scripts/check-security.ps1 -Python CAMINHO_PYTHON -CheckovScript CAMINHO_CHECKOV
```

Usar Terraform 1.13.5, provider AWS 6.69.1, TFLint 0.59.1 e Checkov 3.3.29. Os arquivos de lock entram no Git. `reports/` fica fora do histórico; saídas privadas não devem ser coladas em PRs.

O workflow `Infra local checks` reproduz as verificações em Ubuntu. Os checks nomeados para futura proteção são `Infra validation` e `Terraform security`.

Publicação: [PR #1](https://github.com/Chico-IA-Empresa/Chico-Infra/pull/1). O [run 40519551797](https://github.com/Chico-IA-Empresa/Chico-Infra/actions/runs/40519551797) aprovou ambos os jobs no commit `ff0a88c`, incluindo correção dos hashes oficiais Linux/Windows do provider. A revisão posterior acrescenta validação de quota/inputs e ordenação do destino de logs; acompanhar os [checks correntes](https://github.com/Chico-IA-Empresa/Chico-Infra/actions/workflows/validate.yml).

Verificações locais acumuladas: 36 runs Terraform mock em roots/módulos, 52 testes Node, seis testes Python, Bash e TFLint. O checkout isolado comprovou independência dos testes de manifesto em relação aos diretórios irmãos backend/frontend. O inventário bruto do run acima registrou 289 checks aprovados, 53 achados no repositório completo, zero supressões e zero erros de parsing; o gate Dev/fundação trata apenas as 28 exceções explícitas, sem declarar UAT/Prod seguros ou operacionais.

## Auditoria do objetivo

O objetivo integral continua aberto até todos os requisitos estarem comprovados. Código/validação local podem ser concluídos sem recursos AWS; referências inexistentes e proteções indisponíveis não podem ser declaradas configuradas. Manter a distinção entre preparação local, configuração efetiva GitHub, autorização AWS e aceite operacional.
