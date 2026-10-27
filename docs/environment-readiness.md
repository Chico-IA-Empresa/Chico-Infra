# AWS-015/024/025/026/027/031 — preparo e gates

## Dev

Módulo dev-box prepara t4g.small/EIP/EBS criptografado e persistente, IMDSv2, sem key pair/SSH. Exige AMI ARM64 verificada e instance profile SSM real. Bootstrap vem sem aplicação; instalar Docker/Compose/SSM/patch window depois de validar AMI e role. Não executar deploy enquanto imagens API/workers ARM64 e frontend promovível (AWS-013/014) não existirem por digest. Nenhum host foi criado e não há URL Dev.

Contrato Compose: três digests do mesmo manifesto aprovado; PostgreSQL16 e Redis locais em rede interna sem publish 5432/6379; somente proxy 80/443 exposto; migration one-off antes da API; seed sintético reproduzível; três contínuos e oito loops Dev. Configuração e secrets por serviço via arquivo temporário protegido em tmpfs fora do Git; nunca secrets no user_data. Provar jornada login, recursos/memória da instância de 2GiB incluindo kernel, Docker e sobreposição. Não assumir folga por soma das reservas. DNS/Let's Encrypt aguardam domínio/acesso adiado por Felipe.

Backup Dev: role da instância pode escrever somente bucket/prefixo Dev revisado. pg_dump noturno com checksum, exportação fora do host, lifecycle de backup conforme PRD e verificação de restauração isolada. Não habilitar backup no novo S3 antes da comprovação de cobertura. EBS retido continua cobrando após encerramento; incluir na reserva/cleanup.

## Primeiro UAT e sanitização

Começar com seed inteiramente sintético PostgreSQL16; nenhum dump produtivo no UAT. Relacionar tabela/coluna à decisão de sanitização. reports/sanitization-inventory.json é lista estática de candidatos, sem cobertura garantida: todas as entradas vêm reviewed=false/NOT_IMPLEMENTED. Reconciliar com information_schema antes de criar SQL. Não publicar snapshot com este estado.

Cobrir dados estruturados, tokens/reset/refresh/OAuth, hashes de senha, emails/telefones/documentos/Pix, IDs Telegram/cliente, chat/prompts/respostas, JSON/payloads, avatars/blobs/anexos/campos livres e sessões/devices/analytics A/B quando implementados. FKs e unicidade preservadas; logins de teste separados por realm; nenhum vínculo automático A↔B. Bloquear qualquer envio real. AWS-022 precisa concluir contrato de identidades e sandboxes; estes dados ainda não estão modelados por este pacote.

Role sanitizadora isolada é a ponte controlada. Chave exclusiva para snapshot tratado; role UAT não lê raw/Prod key. Publicar apenas snapshot aprovado `uat-sanitized-*`, ARN da conta e sa-east-1, manifesto do seed, hash de SQL revisado e resultado das negativas. Prefixo de ARN em Terraform não prova que os dados foram tratados. Testar dados sintéticos antes de tratar dados reais; rotina semanal real só após AWS-036.

## Dados UAT e Prod

Módulo data prepara RDS PostgreSQL16 privado, master gerenciado, force_ssl, pg_stat_statements e log de queries lentas; Valkey micro privado com TLS obrigatório/at-rest e grupo RBAC obrigatório. Minor PostgreSQL, versão Valkey, chave KMS e grupos vêm de descoberta/revisão real da conta; não inventados. Baseline Single-AZ aprovado preservado. Host workers deve usar primeira AZ, a mesma do RDS. Multi-AZ continua proposta separada com custo coberto.

Prod: t4g.medium, gp3 40→200GiB, PITR14, deletion protection e identificador obrigatório de snapshot final. UAT: t4g.small, restaurar somente snapshot sanitizado aprovado, sem backup automático/final. Separar chave Prod de chave sanitizada, secrets e identidades SQL api/workers/migrator. Budget de conexões deve medir duas cores, oito jobs, LISTEN, sanitização e migração com clientes A/B contra um backend comum; não tomar 300 conexões do alarme histórico como capacidade disponível.

Monitoramento preparado: Database Insights standard explícito, Performance Insights habilitado somente Prod com retenção7 e CMK; logs PostgreSQL em grupo KMS com retenção30. Compatibilidade de classe/versão/região e custo continuam exigindo descoberta e cotação reais. Referência: [RDS Standard mode](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DatabaseInsights.TurningOnStandard.html). Não habilita modo Advanced.

Pendente: quotas/versões disponíveis, preço, key policies de logs/CloudTrail/RDS/Secrets, usuários SQL/rotação, contas de teste, cache auth cliente, restore e smoke reais. Não provisionar sem fechar essas dependências. Política de snapshots semanais/mensais aceita em AWS-005 ainda exige implementação/restore/financiamento, além de PITR14.

## ALB e web services

Módulo web-service é blueprint validável, ainda sem chamada nas roots. Define ARM64 Fargate 0,5vCPU/1GiB, awsvpc/IP público/SG, digests, timeout 120s, duas TGs, hook POST_TEST_TRAFFIC_SHIFT, bake10 e rollback por alarmes. desired_count=0 por padrão. Precisa de ALB/TGs/listener rules/test access, hook/roles, ACM/WAF e readiness real antes da integração. IAM task/execution/logs permanece revisão por inventário.

AWS-003 precisa fechar tráfego REST/WS/SSE/cookies/forwarded IP e aliases antigos. Ordem alvo: /api/contact frontend; /api/* API com remoção do prefixo; /ws/* API; fallback frontend. Testar query string, URLs codificadas, streaming, reconexão/backoff/jitter, drenagem, frames grandes e WAF. Não habilitar CDN por inferência. Mobile acessa backend HTTPS versionado diretamente, sem proxy Next.js. Testar clientes antigos e negativas A/B.

## Workers e schedules

ECS EC2 ARM/bridge em ASG/capacity provider, mesmo AZ RDS. Host SSM/IMDSv2, SG workers, sem SSH. Três serviços 100/200, candidato saudável aguardando lock e SIGTERM≤120s; aplicação precisa AWS-018/019/020. Não adicionar quarto worker live BSD, financeiros ou Pix probe. Deixar consumidores desativados em Prod até corte específico.

| Job | Comando direto esperado (sem shell loop UAT/Prod) | Cadência PRD |
|---|---|---|
| match-list | python workers/sofascore_match_list_worker.py | rate(30 minutes) |
| lineups | python workers/sofascore_lineups_worker.py | rate(20 minutes) |
| post-match-stats | python workers/sofascore_post_match_statistics_worker.py | rate(15 minutes) |
| standings | python workers/sofascore_standings_worker.py | rate(12 hours) |
| team-stats | python workers/sofascore_team_statistics_worker.py | rate(12 hours) |
| round-matches | python workers/sofascore_round_matches_worker.py | rate(1 day) |
| league-reports | python workers/worker_league_reports.py --run-once (depende AWS-018) | ~12h; divergência 06h BRT atual precisa fechamento |
| match-analysis | python workers/worker_match_analysis.py --run-once | rate(12 hours) |

Timezone Scheduler explícito UTC; rates não exigem hora civil. Task definition ARN com revisão fixa e imagem por digest, Fargate ARM awsvpc IP público + SG jobs. Retry de invocação limitado e PassRole só das roles alvo, observando task ARN/exit/heartbeat separado. Não ativar schedules antes de locks e one-shot comprovados. Não gerar comando com flag não suportada como se estivesse testado.

## UAT teardown e produção preparada

Desligar apenas recursos descartáveis do root UAT; preservar rede/secrets/parâmetros/snapshot aprovado/state/auditoria e Dev/Prod. Módulo de rede não é condicionado a data_enabled. Não implementar auto-down sem respeitar keep-until de QA/lojas. Ciclo real é AWS-029, fora das tasks azuis deste lote. Não remover serviços VPS nem mudar workflows atuais para testar UAT.

Em Prod, desiredCount=0, schedules DISABLED e nenhum bot/worker/inbound público ativado até AWS-035 e autorização específica do corte. Plan revisado, restauração PITR isolada com evidência e AWS-030 de carga/rollback são pré-requisitos. Preparação de módulos não cumpre aceite AWS-031.
