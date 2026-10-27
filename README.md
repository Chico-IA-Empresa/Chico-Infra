# chico-infra

## Estado atual — 27/10/2026

Repositório privado: [Chico-IA-Empresa/Chico-Infra](https://github.com/Chico-IA-Empresa/Chico-Infra). O commit inicial `256c664` contém o README; a implementação foi reunida no branch `codex/dev-infra-local-github` para revisão e checks no GitHub.

O trabalho autorizado nesta rodada é fechar preparação local e GitHub. Não houve apply, criação de recursos, alteração de DNS ou início de workloads AWS. Leituras de metadados reconfirmaram a conta e a ausência das dependências necessárias; validação estática IAM não equivale a prova operacional.

- [Fechamento e requisitos pendentes](docs/local-github-status.md)
- [Permissões CI e boundaries](docs/dev-ci-permissions.md)
- [Revisão das exceções específicas de segurança](docs/security-exceptions-review.md)
- [Contrato técnico da fase — cópia para consulta no GitHub](docs/contracts/dev-infra-prd.md)

Checks sem credenciais: fmt/validate, testes Terraform mock, Node/Python/Bash, TFLint e Checkov com gate explícito para bootstrap/shared/Dev. Scans brutos não são suprimidos; exceções locais expiram e ficam vinculadas ao hash do código. Actions são fixadas por commit SHA. Plans/state, relatórios privados e arquivos reais de backend/inputs não entram no Git.

Felipe decidiu manter GitHub Free. A API recusou proteção de branch no repositório privado. O preflight bloqueia OIDC antes de solicitar credenciais quando faltam proteções; `DEV_EXECUTION_APPROVED=false`. Este bloqueio está registrado, sem contratação de plano ou mudança de visibilidade. Referências reais ausentes na AWS continuam pendentes, sem ARNs fictícios.

**As seções abaixo são histórico de 18–26/10 e não descrevem o estado atual de commit, remote, Docker ou GitHub.** Use os documentos de fechamento acima para a situação vigente.

## DEV-PACOTE — implementação local de 23/10/2026

Pacote em `package/`: Compose isolado, contratos de configuração/volumes, bootstrap SQL da fixture, schema/manifesto sintético e ferramenta de build OCI local. Backend/frontend recebem os deltas de runtime correspondentes. [Estado por ticket](docs/dev-package-status.md) · [runbook](docs/dev-package-runbook.md). Docker Desktop indisponível impede concluir as provas em containers; validação offline não é aceite ARM64/AWS. Nenhum recurso AWS ou card original foi alterado.

## DEV-INFRA — execução local de 22/10/2026

Por instrução de Felipe após falha de autenticação do conector, esta rodada ficou exclusivamente local. Foram preparados integração root Dev→host/profile/backup/logs/alarmes/Flow Logs/SSM/DNS opcional, bootstrap AL2023 ARM64, workflow privado de plan/apply e fixtures. **Não houve provisionamento, plan AWS autenticado ou aceite operacional dos nove tickets.** O [runbook de execução](docs/dev-execution-runbook.md) registra ownership, gates e provas pendentes; o [relatório local](docs/dev-infra-local-status.md) reúne resultados. O repositório ainda não possui commit ou remote; nenhuma publicação GitHub/CI ocorreu.

Fundação local da migração. Referência: `../ChicoIA-AWS/README.md` e PRD v3 §1.1 (dois apps mobile, backend compartilhado e identidades isoladas). Uma conta existente em sa-east-1. Felipe é responsável pela implementação e operação. Nenhum recurso foi provisionado.

Reconferência somente leitura de 22/10/2026: [guia atualizado](../ChicoIA-AWS/destravar-aws.html) e [relatório atual](../ChicoIA-AWS/evidencias/2026-10-22/reconferencia-aws.md). Conta destinatária, saldos, validade e principais produtos elegíveis confirmados por API; dados financeiros privados fora do repositório. Quotas de pico, cotação integral/reserva, IAM e integrações permanecem pendentes. Nenhuma configuração AWS nem .tf foi alterada nesta rodada.

Terraform 1.13.5 e AWS provider 6.69.1 fixados. Bootstrap persistente separado; roots shared/dev/uat/prod com backend S3 parcial e lock nativo. Não usar workspaces para separar ambientes.

Andamento por task: [relatório central](../ChicoIA-AWS/evidencias/2026-10-18/execucao-felipe.md). O [gate de segurança](docs/security-review.md) permanece com achados triados e sem supressão global; infraestrutura não está pronta para apply/ativação.

## Validar localmente

`terraform fmt -check -recursive`, depois `terraform init -backend=false` e `terraform validate` em bootstrap e nos quatro roots. `terraform test` nos módulos com testes mock não chama AWS. `node --test tests/*.test.mjs` valida gates locais. `node scripts/inventory.mjs` gera inventários somente de nomes do código, sem importar a aplicação ou ler .env.

## Solução preparada para a quota EC2

[Procedimento EC2 Standard L-1216C47A](docs/ec2-vcpu-quota-solution.md): pedido revisável de 12 vCPUs totais em sa-east-1, com payload, justificativa, critério de liberação e alternativa de preparação local. Quota aplicada ainda 5; nenhum pedido enviado ou recurso alterado.

## Provisionamento futuro

1. Conferir sessão temporária, identidade e conta destinatária dos créditos; reautenticar se necessário. O acesso root observado em 22/10 não substitui a definição de acesso humano/CI por função. Não assumir account ID ou saldo.
2. Conferir em Billing saldo, validade, serviços/cobranças elegíveis, previsão integral e reserva de encerramento. Completar evidência privada conforme `docs/funding.md`. Alertas não impedem cobrança.
3. Configurar `account_id`, owner/cost-center, AZs, buckets únicos, destinatário de alertas e os repositórios exatos. Definir federação humana/MFA e recuperação. Testar antes de restringir administradores.
4. Revisar plan bootstrap. Aplicar somente com cobertura comprovada; mover seu state local para armazenamento persistente protegido e documentar recuperação. Não guardar state no Git.
5. Copiar o backend de exemplo de cada root para backend.hcl, preencher bucket/account ID e executar `terraform init -backend-config=backend.hcl`. Não desabilitar allowed_account_ids nem usar -lock=false.
6. Revisar os plans separados. Shared/Prod exigem aprovação do PRD. Nenhum workflow deste pacote executa apply. Flags de recursos vêm desligadas por padrão; preencher aprovação financeira não habilita workloads, DNS ou corte.

O código é preparação revisável. Login OIDC, locks S3 concorrentes, conectividade, restore, carga, negativa IAM, scan/push/pull e blue-green reais continuam pendentes. A presença de diretórios não comprova repositório GitHub publicado nem proteções de Environment configuradas.

Módulos de rede e dados não recebem uat_enabled: a raiz separa a fundação persistente do módulo de dados descartável. Prod mantém proteção contra exclusão e consumidores desligados. Dois aplicativos instalados não correspondem a dois serviços Next.js.
