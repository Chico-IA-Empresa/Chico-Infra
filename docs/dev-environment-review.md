# Aprovação manual dos Environments Dev

Em 28/10/2026, Felipe informou que não há outro revisor disponível e autorizou retirar a exigência de aprovação por outro usuário, permitindo que qualquer usuário aprove. A implementação inclui todos os quatro colaboradores atuais do repositório como revisores e permite autoaprovação em `infra-plan-dev` e `infra-apply-dev`.

O GitHub exige uma lista de até seis pessoas ou equipes com acesso ao repositório; não oferece um revisor público curinga. A lista aprovada está em `security/dev-environment-review-policy.json`. Ao mudar os colaboradores, reconciliar essa lista e os dois Environments antes da próxima execução. Não conceder acesso ao repositório ou criar equipes para contornar esse limite.

Uma aprovação manual continua obrigatória para cada job protegido. Bypass administrativo permanece desabilitado; somente a branch `main` pode executar. Checks obrigatórios, strict status checks, enforcement para administradores, proibição de force push/exclusão e bindings privados do plano permanecem exigidos. Shared/UAT/Prod continuam exigindo outro revisor.

O run anterior `40730610381` deve estar cancelado antes de mudar os settings. Publicar e validar o preflight atualizado, então gerar um novo plan no commit vigente. Nunca reaproveitar um bundle de outro commit ou autoaprovar um apply sem revisar seu plano concreto.

Referências: [GitHub Environments](https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments), [API de Environments](https://docs.github.com/en/rest/deployments/environments#create-or-update-an-environment). Os settings efetivos devem ser conferidos pela API; este documento não comprova sua aplicação.
