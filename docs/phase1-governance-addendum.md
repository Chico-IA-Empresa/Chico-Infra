# Adendo de governança — fase 1, 27/10/2026

Felipe confirmou na sessão de execução que retirou a exigência de aprovação de PR em `main` porque há somente um desenvolvedor. Esta decisão posterior altera somente esse gate do plano AWS-DEV-EXEC-001 v1.1. O plano original e seu hash permanecem preservados.

`security/main-review-policy.json` registra a exceção explícita, limitada a este repositório e à revisão de PR em `main`. O preflight mantém revisão obrigatória por padrão quando não recebe essa decisão. Não restaura a configuração que Felipe alterou nem concede bypass administrativo.

Checks `Infra validation`/`Terraform security` continuam obrigatórios e strict, com enforcement para administradores e bloqueio de force push/delete. Environments conservam branch exclusiva `main`, revisores, proibição de self-review e de bypass. Aprovação financeira, plan salvo/hash/validade, revisão específica shared e demais gates AWS permanecem vigentes. Esta exceção não autoriza UAT/Prod, DNS ou escritores de negócio.
