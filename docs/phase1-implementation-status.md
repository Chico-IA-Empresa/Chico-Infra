# Preparação da execução AWS fase 1 — 27/10/2026

Esta revisão fecha dependências de IaC da fase Dev. Não foi executado provisionamento, plan autenticado, restore, ativação da aplicação ou alteração de DNS. Aprovações/destinatários e a revisão financeira ficam fora deste repositório público. `DEV_EXECUTION_APPROVED` permanece desligado até os gates aplicáveis serem comprovados.

| Área | Implementado nesta revisão | Prova/etapa restante |
|---|---|---|
| OIDC | Criação/reuso explícito do issuer shared; audience exata; sem thumbprint inventado | Inventário renovado e login positivo/negativo |
| CMKs e SNS Dev | Quatro chaves com rotação/proteção, grants por contexto/origem, tópico operacional e assinatura privada | Policies efetivas, entrega de logs/CloudTrail e alerta recebido |
| Planos privados | Bucket AES256/versionado/TLS/PAB, sink separado e lifecycle de sete dias | Acesso plan/apply/revisor e versão vinculada ao plan real |
| Sink Dev | Root Dev pode criar o destino exclusivo com prefixo de delivery/lifecycle correto | Provar chegada de access log |
| State bootstrap | Template backend parcial privado e procedimento de migração/recuperação | Apply local, migração e provas lock/versão isoladas |
| State CI | Build/deploy com state desligado; grant permitido apenas a nomes de plan/apply de infraestrutura | Revisar todas as policies reais das roles e provar negativas |
| Grants Dev | Gerador inclui sink reconciliado e backups reais separados; mantém boundaries fora do apply Dev | IDs reais de VPC/SG/CMKs e Access Analyzer/negativas efetivas |
| EC2 | Créditos Standard e capacidade validada entre 30 e 80 GiB, preservando criptografia/retention | Medir expansão/WAL/workspace, revisar plan e provar reboot/recuperação |
| ECR | Limpeza automática desligada por padrão; repos imutáveis/basic scan | Build ARM64, scan conhecido e push/pull por digest |
| Banco restaurado | Prefixo/retention IAM/S3 `dev/database/` e procedimento pgBackRest separado da fixture | Validar conjunto/versões/WAL/cifra/arquitetura, staging se necessário, credenciais/tratamento Dev, restore e reconciliação |
| Backup real | Lifecycle de 14 dias, multipart limitado ao bucket Dev, dump/manifesto no mesmo snapshot, commit versionado e prova isolada; timer/frescor distintos da fixture | Instalação e credenciais privadas, capacidade, backup real/segunda restauração, métricas e alerta recebidos |
| DNS | Mantido como etapa externa posterior, sem necessidade para restore | Proxy local/SSM, handoff EIP e HTTPS público após apontamento |

Validações locais: 45 runs Terraform mock aprovados, 57 testes Node, 20 Python, Bash, fmt/validate e TFLint. Checkov 3.3.29: zero parsing errors/skips; gate bootstrap/shared/Dev aprovado com 40 decisões específicas revisadas. O scan completo inclui UAT/Prod futuros e mantém seu inventário bruto de achados; não dá aceite operacional a esses ambientes. A revisão técnica local não substitui revisão humana de código/plan. Os testes de Compose verificam que DNS é opcional e somente 80/443 são publicados no profile local; não iniciam containers nem comprovam Caddy/ARM64 em execução.

A integração CI de banco exercita PostgreSQL16 sintético por digest, snapshot com writer concorrente, dump, restauração isolada e reconciliação, sem chamadas AWS. Recusa hash não revisado e destino existente; não comprova a cópia S3 real, ARM64, S3/IAM efetivo ou aceite operacional. O processo de backup real e seu contrato estão em [operations/dev-database](../operations/dev-database/README.md).

O preflight confirmou main e Environments plan/apply Dev protegidos: revisão obrigatória, checks obrigatórios, sem bypass administrativo/self-review/force push/delete. Nenhuma proteção foi alterada. O executor local Terraform 1.13.5 existe; sua sessão AWS ainda precisa estar disponível por autenticação segura. A conexão do plugin não fornece uma sessão local automaticamente.

Continuar pelo [runbook de ondas e restore](phase1-execution.md). Antes de apply, atualizar evidência privada de cobertura/consumo, sessão, plans concretos e revisão shared. Não tratar os mocks ou esta página como evidência de recurso existente ou backup recuperado.
