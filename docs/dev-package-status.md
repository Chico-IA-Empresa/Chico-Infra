# DEV-PACOTE — execução local em 26/10/2026

001–006 têm implementação e ensaios locais ARM64 executados com Docker Linux/QEMU. **Isso não aprova uma release nem o Gate 02.** 007–008 permanecem pendentes: Felipe restringiu a tarefa ao local, Gate 01/handoff não estão aceitos e cobertura financeira atual não foi comprovada. Sem AWS, push, deploy, alteração de card, DNS, VPS, UAT/Prod ou commit.

Bloqueios adicionais de promoção: suíte global frontend com 19 falhas e audit das dependências de produção com 3 críticas. [Provas atuais e limitações](../../ChicoIA-AWS/evidencias/2026-10-26/pacote-local.md).

## Resultado por ticket

| Ticket | Entrega e prova local | Pendência externa/de promoção |
|---|---|---|
| 001 | Configuração por consumidor; matriz 142 pares e auditoria de imports; boot API/web/migrator; arquivos JSON UID 10001/0400 e senhas bootstrap UID 999/0400; falha por nomes obrigatórios; privilégios SQL positivos/negativos PG16; rotação sintética invalida token antigo e aceita novo login | Helper/allowlist/stores/IAM reais da fase 1 continuam DEV-INFRA-005/009. Nomes default-only-review-required não são grants/injeções aprovados |
| 002 | API/workers ARM64 da mesma árvore e SHA base; layers/checksum de /app iguais, OCI conferidos e UID 10001; 11 entrypoints limitados com mocks, inbox sintética processada e relatórios com fake LLM; testes úteis odds/Sofa contra PG16 | Árvore contém alterações locais não commitadas; ledger distingue SHA base de conteúdo. Commit/revisão/scan de release pendentes. Polls vazios do harness não são ingestão real |
| 003 | Mesmo frontend ARM64 em localhost:18081 e 127.0.0.1:18080 sem rebuild; BACKEND_URL/projeto público distintos em runtime; navegador prova login/leitura/refresh/logout/cookies, tokens cruzados recusados, WS/reconexão, SSE sem buffering, e-mail capturado, image optimizer e SEO não indexável | OAuth/Firebase reais não exercitados. 19 falhas globais e 3 críticas de dependências bloqueiam promoção. Promovibilidade de configuração não é autorização de release |
| 004 | Compose sobe/recria; PG16/Redis/API/web/proxy saudáveis; falha one-off exit 42 bloqueia API; banco e sentinelas files/TLS preservados; Redis reconstruível fica frio; só proxy publica loopback; Redis/LISTEN complementam readiness; recursos amostrados | TLS é sentinela pública, sem HTTPS/certificado. Override Redis QEMU sem AOF/snapshot; base nativa mantém AOF/proteção. Sem prova t4g.small, reboot/EBS/restore AWS ou paths reais do bootstrap |
| 005 | Vazio e baseline odws03eventlg → retire20260926; no-op no head; seed repetido com bcrypt/login e snapshot estável 1 partida/3 odds; lock ocupado/revisão órfã recusados; banco não vazio sem versão bloqueia migração/API | Verificador herdado cobre tabelas, não todo drift de colunas/dados. Rollback de imagem não desfaz schema; fixtures de falha preservadas |
| 006 | Schema/validador, exemplo sintético não promovível, bundle por checksum e ledger real dos três OCI; testes de recusas e preservação de outro componente passam; índice/manifest/config/ID local/build refs/SHAs base/fingerprints separados | Manifesto sintético não vira ECR por inferência. Candidato final exige registry, scan, checks e proveniência aprovados em 007 |
| 007 | **Pendente, nenhuma execução AWS** | Gate 01 e DEV-INFRA-004/005/009 aceitos; autorização AWS explícita; créditos elegíveis/cobertura/reserva atuais; checks/vulnerabilidades e proveniência resolvidos |
| 008 | **Pendente, sem Gate 02** | 007, Gate 01/handoff, AWS-003, autorização/créditos; ensaio por digest no host Terraform ARM64 e revisão do responsável |

## Testes e revisão atuais

- Três builds/imports OCI ARM64, hashes de índice/manifest/config/layers e identidade carregada conferidos. API/workers compartilham layers e árvore. Artefatos grandes fora dos contextos/Git; nenhum push.
- 14 testes Python offline, 40 Node infra e 98 testes PG16 de workers passam. Build Next concluiu compilação, lint/tipagem e standalone ARM64. Provedores fake, sem SQLite/create_all. Estado final: [10 containers saudáveis](../reports/package-runtime-state-20261026.json), com ambiente privado omitido; [revisão](../reports/package-review-20261026.json).
- Suíte completa frontend repetida: 108 suítes, 98 passam/10 falham; 807 testes, 788 passam/19 falham, mesmos totais de 23/10. Sem baseline limpo separado, não atribuir todas as falhas ao estado anterior. Casos focados runtime/WS/chat/contact/auth passaram.
- Audit npm produção: 8 moderadas, 11 altas, 3 críticas (next, protobufjs, websocket-driver). Não é scan ECR/imagem. Sem upgrades forçados.
- Revisão code-reviewer corrigiu tmpfs, UID Redis, leitura de senhas pelo PG, PID/temp Nginx, bridge de ingresso, e-mail sintético rejeitado e migrações dependentes do ORM corrente/recriação implícita de odds. Uma fixture Sofa recebeu o Team exigido pelo FK real do PG16.
- [Ledger OCI](../reports/package-oci-20261026.json), [navegador/rotação](../reports/package-browser-20261026.json), [offline](../reports/package-offline-validation-20261026.json), [suíte frontend](../reports/package-frontend-suite-20261026.json), [audit](../reports/package-npm-audit-20261026.json), [recursos](../reports/package-resources-20261026.json).

Pagamentos, bots, coletores e escritores reais seguem desligados. [Runbook](dev-package-runbook.md). O incidente Docker abaixo é histórico e foi superado no laboratório.

<details>
<summary>Histórico de 23/10/2026 — não representa o estado atual</summary>

## Estado em 23/10/2026

Escopo autorizado: todas as modificações locais, sem ligar o plugin AWS. Fontes: README/PRD v3 e etapa 02; overview, oito tickets e cards vinculados consultados somente para leitura. Não há commit/push ou mudança em workflows de deploy, Terraform, secrets reais, dados existentes, DNS, VPS, UAT/Prod ou status dos cards. Pagamentos/Pix/preflight e onze escritores reais continuam desligados.

**Resultado: implementação local parcial com validação offline; 001–006 não têm aceite integral. 007–008 pendentes por gates externos e ausência de autorização AWS. Gate 02 permanece pendente.**

Auditoria de continuidade: o mesmo impedimento Docker foi confirmado em três turnos consecutivos. As duas primeiras rodadas produziram código/evidências; a terceira conferiu novamente o log de encerramento do backend, timeout do servidor, 33 hashes das fontes e hashes do bundle atual. Não há build/job de aplicação em andamento para aguardar. Os aceites restantes exigem Docker Linux local funcional com ARM64; nenhuma recuperação destrutiva/reset de volumes está autorizada por inferência. O objetivo integral permanece não alcançado e depende dessa mudança externa. Registro: [package-blocked-audit.json](../reports/package-blocked-audit.json).

## Entrega e pendências por ticket

| Ticket | Entrega local | Evidência obtida | Para cumprir integralmente o aceite |
|---|---|---|---|
| 001 | `backend/core/package_runtime.py`; matriz com 142 pares nome/consumidor, 11 processos; arquivos separados; identidades SQL bootstrap/API/workers/migrator/seed; sem dotenv no pacote; loader valida nomes/obrigatórios | 7 testes de runtime/guards passam; rotação sintética por recarga e rejeição cross-consumer; revisão SQL estática | Boot API/web/migrator, privilégios positivos/negativos e rotação contra PG16; verificar owners/modos reais; auditoria estática do grafo entregue com 910 pares nome/consumidor (523 ocorrências financeiras excluídas); caminhos dinâmicos e adaptação do helper/allowlist de fase 1 continuam pendentes. A matriz cobre essenciais e overrides explícitos, não substitui auditoria de todos os defaults/imports |
| 002 | Dockerfile dependencies/base/api/workers, mesmo contexto backend, não root 10001; export OCI ARM64 preparado; exclusões de contexto; harness dos onze entrypoints | Bases oficiais consultadas por digest com ARM64; 11 imports em Python Windows 3.13 com conexão socket bloqueada, sem dotenv; topologia/paths dos módulos conferidos | Build de ambos targets e wheels, inspeção OCI e boot real/emulado; ciclo útil de todas as famílias com mocks e banco descartável. O harness preparado usa polls vazios e substitui processamento de league-reports; não é prova de ingestão. AWS-018/019 mantêm one-shot/locks/loops |
| 003 | Node24 fixado por digest, browser /api, BACKEND_URL runtime sem injeção next.config; SITE_URL/SEO/Firebase público runtime; WS relativo preservando jitter; health HTTP; indexação/analytics desligados nas fixtures | 36 testes focados passam (runtime/WS/chat/contact/auth services); typecheck limpo com config temporária; proxies email/chat existentes testados com mocks | Mesma imagem ARM64 nas duas origens sem rebuild; login/refresh concorrente/logout/cookies e WS/SSE reais no navegador; SSR/config pública/Firebase mock, inspeção do bundle e image optimizer em execução. Testes unitários não são ensaio dessas jornadas |
| 004 | Compose de app separado, rede interna e loopback, PG16/Redis/proxy fixados, mounts parametrizados, health/dependencies/timeouts/limites/logs, manutenção bloqueia API, topologia de negócio desligada | 4 testes offline de contratos passam; `docker compose config --quiet` exit 0 | Subida real, inspeção de UID/GID/portas, falhas simuladas, recreates e contagens/checksums dos quatro paths; medir recursos, Redis e LISTEN. Bootstrap/paths reais ainda dependem DEV-INFRA-006/009; limites não comprovam capacidade da t4g.small |
| 005 | Migrator one-off com advisory lock, upgrade/authority sem stamp; guarda de destino; seed idempotente proposto, bcrypt, IDs/datas fixos e guardas de colisão; DB16 apenas | Testes de estados vazio/conhecido/órfão/sem versão e destinos fictícios passam, sem conexão; head estático `retire20260926` | Executar PG16 vazio → head, revisão conhecida → head, dupla migração/seed e falhas; login/leitura API; conferir contagens/checksums estáveis. Nenhuma migração, seed, conexão PG ou jornada autenticada foi executada. Verificador herdado cobre tabelas, não toda divergência de coluna |
| 006 | JSON Schema, validador offline, fixture marcada não promovível, hashes de 7 arquivos e envelope, relação de digest/SHAs/build/evidência e helper de atualização preservando outro componente | 21 testes novos do manifesto passam; conjunto Node infra 40/40; geração e validação do bundle sintético | Vincular builds/heads realmente observados. Estrutura sintética validada não supre dependências de 002–005; candidato ECR real, checks/scan e proveniência são 007. Validação offline não é liberação de publicação |
| 007 | Bloqueios e contrato preparados, sem script de push executado | Cards/readmes locais mantêm Gate 01/handoff pendentes; nenhuma chamada AWS | Gate 01 aceito, autorização explícita AWS, financiamento elegível/cobertura/reserva atual, DEV-INFRA-004/005/009 aceitos; daí publicar três imagens reais nos repos existentes, aguardar scan e conferir digests/pull |
| 008 | Handoff e roteiro de ensaio definidos, sem execução no host | Nenhum SSM/deploy/host/DNS alterado | 007, Gate 01/DEV-INFRA-009, AWS-003, liberação AWS e créditos; host Terraform ARM64/SSM recebido, paths/owners/config aprovados e ensaio isolado por digest com revisão do responsável |

## Validações

- 3 testes Python adicionais da auditoria de configuração passaram, cobrindo extração apenas de nomes, imports relativos/package initializers e exclusão financeira. O relatório estático não é allowlist aprovada na AWS.
- 7 testes Python novos de runtime, rotação sintética, revisão e guardas de destino; 4 testes novos de contrato Compose, todos passaram.
- Node infra: 40 testes passaram, incluindo 21 do manifesto.
- Frontend focado: 36 testes em cinco suítes passaram. Tipagem do código passou com `tsconfig.package-check.json` temporário excluindo `.next`; o `npm run typecheck` original falhou por tipos antigos gerados de páginas já ausentes. O arquivo temporário foi removido após a verificação.
- Suíte completa frontend executada uma vez: 108 suítes, 98 passaram/10 falharam; 807 testes, 788 passaram/19 falharam. Exemplos: CardCheckoutModal com formatação de data mockada, MatchStatsModule com copy diferente, leagueReportSection e feedCompactDesign apontando arquivo ausente. Não foi feito baseline separado para atribuir todas as falhas; a suíte global continua reprovada. Nenhum pagamento/provedor real foi acionado pelos mocks desses testes.
- Corrigido teste existente de WS: o limite de um for dependia de `scheduled.length`, que aumentava durante o próprio loop e testava mais falhas do que dizia. Limite agora fixo em três; produção preserva política de reconexão existente.
- Sintaxe Python/JSON/PowerShell e Compose: ver índice das evidências. Não foi usada a suíte backend baseada em SQLite/create_all como prova de PG16/Alembic. O PostgreSQL instalado nativo é 18 e não foi usado como substituto de PG16.

## Bloqueio local do Docker

Docker CLI 29.4.3/buildx 0.33.0 disponíveis, contexto desktop-linux; pipe Linux inicialmente ausente. `docker desktop start` fez o backend falhar em `starting services: initializing Inference manager ... dockerInference ... The file cannot be accessed by the system`. Reinício restrito repetiu o erro. Tentativa de renomear/preservar o socket foi recusada pelo Windows; nenhuma remoção/reset de fábrica/reinstalação de Docker, distro ou volumes foi feita. A aplicação Docker Desktop foi relançada. O endpoint do engine continua sem prova funcional. Não há imagens da aplicação, digests OCI locais, containers, medições, restore ou smoke ARM64 desta execução.

Não há bloqueio de plugin AWS a resolver nesta tarefa: o usuário explicitamente restringiu a execução ao local. A necessidade imediata para concluir os aceites locais é um Docker Linux funcional com ARM64, seguida das provas que faltam acima. AWS continua fora do escopo autorizado.

## Revisão e handoff

Revisão local com a skill code-reviewer: corrigidos isolamento de contexto, versão de base indisponível, URL relativa no servidor, guarda do migrator antes de conectar, privilégio CREATE limitado ao banco de teste para pg_trgm, diferenças de privilégios workers/API e imports de scripts que disparavam bootstrap desnecessário. Itens sem prova executável permanecem pendentes nesta tabela; código preparado não foi declarado seguro para promoção por inferência.

[Runbook e contratos de volumes/rotas/configuração](dev-package-runbook.md) · [Evidências sanitizadas](../../ChicoIA-AWS/evidencias/2026-10-23/pacote-local.md). Etapa 03 preserva HTTPS/jornada pública/integrações/capacidade; etapa 04 CI/SSM/rollback; etapa 05 saúde profunda/heartbeats/recuperação. Gates AWS e cards originais preservados.

</details>
