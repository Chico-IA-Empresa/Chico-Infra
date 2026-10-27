# Governança do repositório público — 27/10/2026

Felipe alterou `Chico-IA-Empresa/Chico-Infra` para público. Essa decisão substitui a exigência anterior de repositório privado e permite configurar as proteções disponíveis no GitHub Free público. Os documentos anteriores preservam o diagnóstico histórico; esta atualização registra a nova fronteira.

## Proteções

Main deve exigir PR com uma aprovação, descarte de revisões após novos pushes, aprovação do último push, checks `Infra validation` e `Terraform security` atualizados, aplicação das regras aos administradores, histórico linear e resolução das conversas. Force push e exclusão permanecem proibidos. A configuração inicial é concluída após integrar esta adaptação testada; mudanças futuras seguem o fluxo protegido.

Environments `infra-plan-dev`, `infra-apply-dev`, `infra-plan-shared`, `infra-plan-uat` e `infra-plan-prod` usam branch exclusiva `main`, sem deploy por tags, sem bypass administrativo e sem aprovação pelo próprio executor. Revisores elegíveis são os dois administradores já existentes: FelipeTorresHora e Chico-ia. Configurar revisores não solicita revisão de um deploy nem inicia qualquer execução.

## Preflight e dados privados

`github-readiness.mjs` consulta somente metadados públicos da API GitHub, com timeout e falha fechada em erro/rate limit. Não precisa de `GH_GOVERNANCE_READ_TOKEN`. Ele verifica identidade/visibilidade do repositório e as proteções efetivas antes de liberar o job com OIDC.

Código público não torna planos/state/configuração públicos: os workflows autenticados usam backend e bucket privado de revisão, sem upload de artifacts públicos. `reports/`, arquivos reais de backend/inputs, chaves e `.env` ficam ignorados. PRs executam checks sem credenciais AWS. `DEV_EXECUTION_APPROVED=false` continua vigente; este trabalho não provisiona AWS.

## PRs de atualização

Tornar público não fecha PRs automaticamente. Os PRs Dependabot #2 (setup-python), #3 (setup-terraform) e #4 (setup-node) foram revisados e integrados após checks aprovados. Eles alteram Actions fixadas por SHA; preservam Python 3.12, Terraform 1.13.5 e Node 24 usados pelo projeto. A execução em main verifica o conjunto integrado.

Referências: [proteção de branches](https://docs.github.com/en/rest/branches/branch-protection), [Environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments).
