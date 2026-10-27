# DEV-INFRA — entrega local, 22/10/2026

> Registro histórico. Para implementação, versionamento, checks e bloqueios vigentes em 27/10, consultar [local-github-status.md](local-github-status.md). A preparação atual não concede aceite operacional aos tickets.

**Resultado: preparação local avançada; 0/9 tickets com aceite operacional. Nenhum recurso AWS provisionado ou alterado.**

Felipe autorizou inicialmente execução Dev sujeita a créditos/reserva e gates shared. O conector AWS retornou `UNAUTHORIZED` antes de executar APIs; em seguida Felipe determinou: “não vou conseguir logar na aws, faça tudo localmente”. Toda a implementação e verificação posterior foi local. Não houve acesso à VPS, exposição de secrets, início de bots/coletores/escritores de negócio, commit/push ou execução GitHub Actions. Cards AWS originais preservados.

## Progresso por ticket

| Ticket | Entrega local | Aceite ainda pendente |
|---|---|---|
| DEV-INFRA-001 | Guard de backend Dev antes de init; inputs de exemplo deliberadamente desligados; validações de conta/owner/cost-center/AZ; outputs; matriz de ownership e roteiro de lock/restore | Inventário atual e states reais, imports revisados, cotação integral/créditos/reserva, quota e plan privado; contenção/recuperação S3 |
| DEV-INFRA-002 | Workflow Dev separado, roles plan/apply referenciadas, bucket privado versionado, manifesto por hash/commit/conta/inputs/backend/lockfile, validade 24 h, mesma concorrência sem cancelamento; testes de adulteração | Repo/commit confiável, permissões reais de infra plan/apply e bucket de revisão, Environments/proteções, revisão shared e provas OIDC positivas/negativas |
| DEV-INFRA-003 | Root conecta rede, role/profile Dev e host; AMI Amazon AL2023 ARM64 validada; Compose por versão/checksum; retries limitados; Docker/SSM; diretórios preservados; EBS/EIP e host protegidos contra destroy implícito | Plan/apply real, procedência/AMI disponível, SSM/portas/metadata, bootstrap no Linux ARM64, reboot e snapshot/substituição controlada |
| DEV-INFRA-004 | Gerador build push restrito aos três repos; script build ARM64/push/scan fail-closed; preview de retenção exige inventário completo e protege grafo multiarch | Ownership ECR, scan/custos efetivos, push e pull sob identidades distintas, digest no host e negativas reais; script não executado |
| DEV-INFRA-005 | Policy runtime de ARNs exatos, KMS via serviço/contexto; allowlist sintética; helper com referência asm-exec e arquivo 0600 tmpfs; testes de atualização/rejeição local | CMK/policies reais, instalar/revisar asm-exec, popular fixture privadamente, resolução/rotação e negativas reais; não foi lido secret |
| DEV-INFRA-006 | Bucket exclusivo Dev, PAB/TLS/SSE-S3/versionamento, retenção explicitamente exigida por input; scripts pg_dump/restore/checksum e timer noturno; estratégia root gp3 retido | Cotação/retenção, backup→S3→restore PostgreSQL16 e persistência/reboot/recriação no host; daemon Docker local está parado |
| DEV-INFRA-007 | A record opcional somente dev.DOMINIO, flag adicional e allow_overwrite=false; fixture Caddy staging e estado TLS persistente; contrato de rotas separado | Hostname/autoridade DNS, import/fronteira manual, certificado válido, redirect e renovação reais; nenhum DNS alterado |
| DEV-INFRA-008 | Grupos log/30 dias com CMK referenciada, métricas reais via /proc/df/timestamp, timer, CPU/status, alarmes e Flow Logs Dev com role própria; documento SSM de sessão | Baseline/thresholds cotados, SNS/destino confirmado, alerta/recuperação recebidos, auditoria shared, budgets/tags Billing, acesso S3 e redação/envio de logs proxy; Checkov segue reprovado |
| DEV-INFRA-009 | Outputs não sensíveis, [runbook integrado](dev-execution-runbook.md), [contrato de configuração](dev-configuration-contract.md), exemplos e índice de evidências | Todas as provas anteriores, negativas contra recursos existentes e plan pós-aceite sem drift; não declarar infra pronta para aplicação |

Dependências dos cards foram preservadas. Preparação local não concede aceite ao sucessor nem conclui AWS-015/034 ou qualquer card original.

## Verificação executada

- Terraform **1.13.5**, provider AWS **6.69.1**, lockfiles preservados. `fmt -check`, init sem backend e validate no bootstrap, shared/dev/uat/prod e módulos verificados passaram. Nenhuma credencial AWS foi usada.
- **28 runs Terraform mock passaram**, em nove suítes: root Dev, network, funding, OIDC, data, schedules, web-service, dev-box e budgets. Incluem default desligado, origem/escopo, funding ausente/expirado, AMI incorreta, checksum inválido, hostname Prod e registry de outra conta.
- **19 testes Node passaram**: backend com key/conta/lock/TLS de state, binding de plano e rejeição de adulteração/expiração, gates atuais de execução/créditos, policies/PassRole/SSM/build e retenção/scan.
- **6 testes Python passaram**: gravação/atualização sintética e rejeição de referência não resolvida/valor vazio. Quatro deles cobrem allowlist/redação, cursor/rotação e entradas inválidas do proxy. Não equivalem a prova de Secrets Manager, CMK ou entrega CloudWatch.
- Bash: teste comportamental de sucesso após falhas transitórias, limite de tentativas e preservação de arquivo não vazio passou; scripts de bootstrap/fixtures passaram em `bash -n`. O bootstrap completo AL2023 não foi executado nesta estação Windows.
- TFLint **0.59.1** passou. Três workflows passaram em parsing YAML; o workflow não foi executado no GitHub. `docker compose config --quiet` passou com digests sintéticos, sem subir containers.
- Checkov **3.3.29**: **229 checks passaram, 48 falharam, 0 suprimidos e 0 erros de parsing** na varredura do repositório. **Gate reprovado.** A [triagem complementar](dev-infra-security.md) distingue achados e decisões; não há exceção automaticamente aprovada.

Evidências: `reports/dev-infra-validation.txt`, `reports/checkov-dev-infra-local.json` e `reports/checkov-dev-infra-local.stderr.txt`. As saídas Terraform são mocks/validações locais, não um plan contra inventário real. Os outputs só conterão IDs/ARNs reais depois de execução autorizada.

Continuação local: removido o attachment AmazonSSMManagedInstanceCore, cuja leitura global de parâmetros contornava a allowlist Dev. Policy de agente mantém canais/core e região, sem GetParameter/GetParameters; configuração recebe somente ARNs explícitos. A suíte root Dev foi reexecutada e suas quatro runs passaram com asserção dessa separação (`reports/dev-infra-root-tests.txt`). O workflow revalida a metadata de créditos e liberação antes de assumir OIDC, inclusive na aplicação de plano salvo, e remove arquivos privados mesmo se init falhar. Cinco testes novos cobrem expiração após plan, conta/liberação incorreta, cobertura/reserva ausente e datas inválidas (`reports/dev-infra-node-tests.txt`). São verificações locais, não prova de autorização/negação SSM ou disponibilidade de crédito na AWS.

## Desbloqueio necessário para execução futura

1. Acesso AWS temporário/federado com MFA e conector ou CLI autenticada na conta destinatária; nenhuma chave permanente/root necessária ao agente. Reconciliar fundação antes de criar/importar.
2. Evidência privada atual de cobertura integral, exclusões/tributos, orçamento Dev, retenções e reserva/data de encerramento. Não usar aprovações sintéticas de testes.
3. Repositório chico-infra versionado e remote próprio; fechar policies reais de infra plan/apply, Environments e revisão do primeiro executor. Não publicar em frontend/backend para contornar a ausência do repo.
4. Aprovação específica do plan shared necessário: backend/revisão privada, ECR/OIDC/auditoria e ownership de KMS/SNS. Nenhum desses gates foi presumido aceito.
5. Hostname Dev e autoridade DNS; destino de alerta confirmado; policies/CMKs e triagem de segurança revisadas. Docker Linux ARM64/host Dev para rodar as fixtures.
6. Executar as provas operacionais por dependência, revisar novo plan sem drift e só então marcar tickets concluídos. Até lá, não anunciar “infra pronta”.

## Continuação e auditoria — 23/10/2026

Delivery S3 do backup agora exige destino existente Dev explícito e distinto da origem; a policy sugerida para esse destino é output para revisão do proprietário, sem alteração shared automática. O filtro e encaminhador de proxy só exportam método enumerado, status, duração e tamanho, descartando URLs, headers, IPs, corpos e identidades. Timers de logs/métricas são independentes, e o bootstrap gerado passou na verificação de tamanho de user data. Budgets agora rejeitam mapas sem account/shared/dev/uat/prod; três testes mock cobrem completude/consumo bruto. Validação consolidada final: 28 runs Terraform em nove suítes, 19 testes Node, seis Python; Checkov229/48, sem supressões nem erros de parsing. A [auditoria por contrato](dev-infra-completion-audit.md) confirma que o objetivo integral continua sem aceite operacional e depende de acesso/decisões externas.
