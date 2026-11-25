# Validação do clone PG16 e conversão lógica para Dev

Preparação offline B3, 29/10/2026. Nenhum banco real foi consultado, tratado, exportado ou importado por este pacote. O backup legado continua somente leitura. DNS/TLS público, aplicação e escritores de negócio permanecem fora da execução desta fase.

O contrato permanece AWS-DEV-EXEC-001 v1.1 §9.1: recuperar primeiro o clone físico x86, verificar compatibilidade/isolamento, classificar/tratar dados no clone, exportar logicamente para PostgreSQL16 ARM64 vazio e comprovar novo backup Dev com uma segunda recuperação independente. Staging continua limitado ao lote já aprovado; dados físicos expandidos não garantem que o Dev de 80 GiB comporte dados+WAL+temporários. Nenhum helper amplia capacidade ou lease.

## O que já existe e será reutilizado

`operations/dev-database/backup.py` é a implementação canônica do manifesto. `database_manifest()` já registra encoding/collation/ctype, extensões/versões, tabelas/contagens, colunas/default hashes, views/funções/tipos, large objects, Alembic, índices/constraints e sequências. `exported_snapshot()` mantém a transação exportadora até terminar dump e manifesto. `reconcile()` verifica esses campos e segurança do próximo valor das sequências, incluindo `is_called=false`, ciclo e ownership. Não criar outro manifesto ou usar seed como origem do banco real.

Este pacote adiciona apenas:

- `catalog_preflight.sql`: catálogo de compatibilidade e superfícies executáveis antes de consultar tabelas de aplicação;
- `review.py`: inventário AST do código, ledger de classificação técnica vinculado ao manifesto real, avaliação de riscos e chamada ao comparador existente;
- testes offline e integração sintética PG16 separada. Essa integração não é restauração do legado nem prova AWS.

## 1. Antes de iniciar o cluster físico recuperado

Conferir o resultado B1: imagem/binários PG16/pgBackRest fixados, payloads/cadeia/WAL/control verificados. Container x86 não root, network none, rootfs read-only, sem caps/no-new-privileges, sem socket Docker/IMDS/credenciais AWS e sem volume anônimo. Montar somente cópia RO do repo, arquivo cipher/config individual RO em tmpfs e PGDATA novo RW. Recuperar um banco executa código e configurações provenientes da cópia; um dump lógico também pode conter SQL executável. `--no-owner --no-privileges` não torna esse SQL seguro.

Revisar configurações físicas privadamente **antes** do primeiro `pg_ctl start`: includes, `postgresql.auto.conf`, preload libraries, archive/restore commands, recovery/replication, log destinations e arquivos de configuração. Não mostrar conteúdos/conninfo/passphrases no chat. Impedir que configuração produtiva inicie jobs/background workers. Não “corrigir” isso removendo bibliotecas ou triggers às cegas. Aplicar somente overrides técnicos revisados no clone; manter evidência das diferenças e da origem recuperável, sem modificar S3 legado.

Confirmar major16, arquitetura x86 do clone, extensões/bibliotecas disponíveis e compatíveis, system identifier/control, ponto recuperado e encerramento da recuperação. Não restaurar datafiles x86 diretamente no ARM64. A conversão entre arquiteturas usa `pg_dump`/`pg_restore`16.

## 2. Catálogo inicial sem dados de linhas

Executar `catalog_preflight.sql` com `psql -X -qAt -v ON_ERROR_STOP=1`, conexão privada já revisada e credencial entregue por arquivo/pipe autorizado. Passar SQL por stdin/arquivo; stdout/stderr vão a arquivos privados0600. Nunca interpolar DSN/password em argumentos, ambiente, SSM ou tool call. O script tem transação READ ONLY, search_path pg_catalog e timeout; não lê relations de aplicação nem executa suas funções.

```text
python3 /opt/chico-restore-validation/review.py assess-preflight --catalog /private/clone-catalog.json
```

A saída contém códigos e booleanos. Major incompatível, recuperação incompleta ou divergência entre versão registrada/atual da collation bloqueiam a etapa afetada. Preloads, extensões não revisadas, triggers/event triggers, SECURITY DEFINER, RLS/policies, foreign tables e subscriptions geram revisão técnica explícita. O coletor não lê senhas de roles, `subconninfo`, opções de FDW, comandos de jobs, argumentos de triggers ou corpos de funções. Não exportar esses valores por outra consulta de diagnóstico.

`metadataCompatible=true` indica apenas esse subconjunto de compatibilidade. Nunca autoriza iniciar cluster, exportar ou declarar a revisão das superfícies concluída: `cloneStartAuthorized`, `exportApproved` e `executionSurfaceReviewComplete` permanecem falsos. O CLI termina com1 em incompatibilidade, com2 se houver fila técnica e com0 somente sem esses bloqueios/itens; mesmo exit0 não é aprovação operacional. Exit2 não exige remover objetos para obter0: revisar tecnicamente e registrar a decisão/evidência apropriadas. Não encadear start/export como consequência automática deste comando.

Revisar definitions/configs por processo privado antes de executar consultas de aplicação ou carregar SQL. Corpos já são representados por hashes no manifesto existente; hashes não substituem a revisão de risco. RLS pode chamar funções mesmo em SELECT. Triggers e event triggers podem executar durante tratamento/import/DDL; não desativar integridade/FKs genericamente para fazê-lo passar. FDW/subscriptions/jobs não recebem acesso externo. Extensões de agendamento/linguagem não confiável exigem compatibilidade e contenção específicas. Se a revisão mudar definições, registrar o delta e estabelecer o manifesto da cópia tratada como baseline de importação.

Collation deve ser conferida no clone x86 e destino ARM64: provider, locale/ICU, versão registrada e atual, além de encoding/ctype do manifesto. Ausência de versão para uma locale não prova portabilidade semântica. Divergência exige análise técnica de locale/ordenação/índices; não alterar versão de catálogo, reconstruir índices ou mudar locale automaticamente. Não aplicar migrations para mascarar schema incompatível com o backend.

## 3. Classificação técnica do snapshot

Usar o manifesto da **mesma cópia recuperada**, nunca catálogo de origem viva em outro instante. Após a revisão de execução, manter escritores parados e produzir o manifesto com o helper existente. Revisão de modelos não importa `models`, `core.config`, SQLAlchemy nem aplicação: o scanner usa apenas AST/bytes e não executa defaults/imports.

```text
python3 /opt/chico-restore-validation/review.py classification-template --manifest /private/clone-manifest.json --models /reviewed/backend/models --output /private/classification-pending.json
python3 /opt/chico-restore-validation/review.py check-classification --manifest /private/clone-manifest.json --ledger /private/classification-reviewed.json
```

O template cobre **todas as colunas observadas no clone**, inclui hints por nome/tipo/domínio e hashes dos arquivos dos modelos. Campos existentes somente no backup ficam pendentes; campos novos somente no backend aparecem como incompatibilidade a revisar. O scanner não infere migrations, campos herdados, schema dinâmica ou presença real de tabela pelo ORM. Código atual não é prova do schema do backup de setembro.

Cada entrada registra classificação, decisão, justificativa e SHA do artefato técnico de tratamento quando necessário. `technicalReview` registra reviewer/evidência e pode ser preenchido pelo agente técnico autorizado. Isso **não cria um gate humano por coluna**. Templates começam pendentes para impedir que uma heurística vire aceite automático. Validação do ledger comprova cobertura/revisão técnica; não comprova que tratamento foi aplicado, que dados ficaram seguros ou que export está aprovado. Flags `treatmentApplied`/`exportApproved` continuam falsas na saída.

Colunas de views/materialized views também entram na cobertura. Tratar os dados de origem e revisar definição/refresh; não gerar UPDATE genérico sobre uma view ou refresh que execute função não revisada.

A autorização existente permite tratamento Dev técnico documentado, preservando estrutura e dados de negócio. Decisão humana específica continua necessária se houver exigência de cópia produtiva **sem tratamento**, conflito com preservação do negócio ou delta real de escopo/capacidade/custo. Não pedir aprovação adicional para toda classificação rotineira já autorizada.

## 4. Mapa inicial confirmado somente pelo código

| Área e fontes em `backend/models` | Risco a revisar no clone | Diretriz técnica sem DML automático |
|---|---|---|
| `users/user.py` | email/username/full_name, telefones, tax_id/cellphone, avatar/bio, google_id, reset token; hashed_password e poderes de conta | Pseudônimos únicos e consistentes; credenciais Dev próprias; não reutilizar hashes/tokens produtivos. `hashed_password` é NOT NULL: não propor NULL sem avaliar constraints. Poderes de conta são configuração de acesso, não evidência de autorização Dev. |
| `auth/{refresh_token,password_reset_token,email_verification_token}.py` | token/token_hash, expiração e revogação/uso | Tornar material produtivo inutilizável no clone com regras coerentes de token/expiração/flags. Preservar constraints/links; não truncar tabelas por conveniência. Verificar campos reais, pois os três modelos não têm as mesmas flags. |
| `telegram/{telegram_binding,telegram_conversation,telegram_update_inbox}.py` | IDs/username/chat privados, mensagens, inbox/payloads, correlação por usuário | Manter links de negócio consistentes e impedir entrega/retentativa externa. Hash/ID de plataforma não é anonimização por si só. Não iniciar inbox/worker nem bot. |
| `chat/chat.py`, `betting/betting_analysis.py` | mensagens, conteúdo livre, contexto de ferramentas | Revisão privada do conteúdo e pseudonimização necessária; não publicar exemplos de linhas. Conteúdo livre pode repetir dados presentes em outras colunas. |
| `crm/crm.py` | leads/creators: contatos/redes/geo/notas; activities/objections e ligações a usuários | Tratar contato/textos sem apagar histórico do funil, atribuições e dados de negócio. IDs consistentes e campos únicos exigem mapeamento determinístico privado. |
| `payments/*`, `affiliates/affiliate.py`, `crm/finance.py` | identificadores de pagador/provedor/Pix, payloads, ledger e dados financeiros privados | Preservar fatos/valores/relacionamentos de negócio; pagamentos/afiliados permanecem desligados. Não inferir “limpar financeiro” de conter PII e não divulgar números privados. |
| `payments/payment_creation_intent.py` | ciphertext, nonce/auth_tag, wrapped_data_key, fingerprint e versões de chaves | Não copiar chaves produtivas nem tentar descriptografar no contexto do agente. Planejar tratamento do envelope sem violar invariantes/links ou tornar payload produtivo executável; não manter ciphertext e afirmar ausência de PII automaticamente. |
| `admin/audit_log.py`, eventos/outbox/observações | old_value/new_value/reason, JSONs e snapshots históricos | Audit/ledger são append-only no produto; preservar a origem intocada. O clone Dev precisa regra documentada para PII replicada nesses snapshots, sem reescrever fatos de negócio por tentativa. |
| `matches/odds/teams/competitions/statistics/sofascore` | dados esportivos, histórico, JSON bruto e associações | Candidatos a preservação do negócio; não truncar odds_history nem reduzir período para caber. JSON bruto e nomes semelhantes a credenciais ainda exigem classificação contextual. |

Esses são candidatos de revisão, não decisões finais inferidas por regex. Não classificar todo `market_key` como chave secreta nem todo `payload` como descartável. Não migrar globals/roles/senhas superusuárias para configuração operacional.

## 5. Tratamento, roles e export/import

Antes de DML técnico: fixar manifesto original, revisão, regras e hashes; medir impacto/capacidade; manter fonte selecionada reproduzível e quaisquer evidências privadas necessárias. Executar somente no clone sem escritores/rede, com regras sobre campos efetivamente presentes. Preservar PK/FK/uniqueness, contagens/histórico e fatos de negócio; documentar deltas esperados e rejeitar efeitos não previstos. Nenhum arquivo deste pacote executa tratamento DML, lê conteúdo de linha ou produz valores substitutos.

Depois do tratamento, criar baseline tratado novo e registrar vínculo `origem/ponto recuperado → manifesto original → artefato/revisão de tratamento → manifesto tratado → dump`. Comparar original e tratado serve para explicar impactos; **não** exigir igualdade de valores que foram tratados nem usar essa diferença para ocultar perda de negócio. Comparar import Dev e segunda recuperação contra o baseline tratado exato.

Roles operacionais próprias no destino:

| Role proposta | Privilégios a revisar por necessidade real |
|---|---|
| `dev_admin` | Administração restrita ao banco Dev por operador; sem assumir superuser herdado como rotina. Papel bootstrap/owner separado e uso excepcional registrado quando necessário. |
| `dev_migrator` | DDL no schema autorizado/ownership adequado, somente quando migrations futuras forem aprovadas; não aplicar migrations nesta conversão por tentativa. |
| `dev_api`, `dev_workers` | CONNECT/USAGE e DML/EXECUTE mínimos por objetos efetivamente usados; sem CREATE ROLE/DB, REPLICATION, BYPASSRLS, grants globais ou acesso a outras bases. Ainda sem processos de aplicação ativos. |
| `dev_backup` | Leitura/dump das relações, sequências e large objects necessários conforme contrato existente; resolver RLS especificamente, sem BYPASS genérico. |
| `dev_proof` | Destino isolado novo para segunda recuperação, sem poderes globais ou conexão à base viva. |

Senhas são geradas/resolvidas privadamente e entregues por arquivo0600 em tmpfs, montado individualmente RO. Não usar valores em DSN, argv, environment, Terraform/state/logs. Revisar PUBLIC, memberships, schema owner, default privileges e grants por objeto; `--no-owner --no-privileges` requer aplicação deliberada dos grants Dev. Não restaurar `pg_dumpall --globals-only` ou passwords da origem. Bibliotecas/extensions que exijam privilégio bootstrap precisam passo delimitado pelo coordenador.

Manter transação exportadora REPEATABLE READ READ ONLY aberta, capturar `pg_export_snapshot()` em processo privado, usar `pg_dump16 -Fc --no-owner --no-privileges --snapshot=SNAPSHOT` e `database_manifest(database, snapshot)` antes de encerrar a transação. O helper existente já implementa esse contrato para backup Dev. Para export do staging, adaptar somente o transporte/identidade no executor privado revisado; não usar Storage S3 do runtime nem mentir que o staging é o container Dev. Não passar snapshot entre servidores, não reutilizar snapshot após fechar a transação, e manter DDL/sequências/escritores quiescentes. Contadores de sequência não são MVCC.

Fixar SHA/tamanho do dump e baseline tratado. Inspecionar TOC/SQL privadamente antes de restaurar; nenhum SQL completo aparece no chat. Destino vazio, PG16 e extensões/locale/ownership/grants revisados, `pg_restore --no-owner --no-privileges --exit-on-error`, sem `--clean`, sem importar roles globais e sem comandos de negócio. Medir pico real de disco no staging e no Dev; streaming só com hashes/conclusão privados verificáveis e evidência de capacidade, nunca por presumir que economiza espaço suficiente.

## 6. Equivalência e segunda recuperação

```text
python3 /opt/chico-restore-validation/review.py compare --expected /private/treated-manifest.json --actual /private/dev-import-manifest.json --reviewed-expected-sha256 SHA256_REVISADO
```

O comando chama `reconcile()` existente. Igualdade de catálogo/contagens e segurança das sequências são verificadas; igualdade byte a byte de linhas **não** é provada. A saída mantém `rowContentEquivalent=false` e `businessQueriesPending=true`. Preparar consultas agregadas de negócio específicas para as tabelas do snapshot/release, sem resultados de linhas, antes do aceite: integridade referencial efetiva, distribuição/intervalos de histórico esportivo, agrupamentos por estado/mercado, valores/tipos/constraints, e invariantes do domínio preservadas pelo tratamento. Tais consultas precisam selecionar relações/colunas reais, não nomes presumidos do backend atual. Seus resultados privados devem ser comparados no clone tratado, Dev importado e segunda recuperação da mesma cópia.

Confirmar Alembic e compatibilidade com a release prevista sem `stamp`, seed ou migrations destrutivas. Verificar roles/privilégios, ausência de escritores/portas, persistência após reboot e atualização correta de sequências sem avançá-las na inspeção. Reboot exige reemissão privada coerente dos arquivos tmpfs.

Executar **novo backup Dev e segunda restauração isolada** usando `operations/dev-database/README.md`: snapshot compartilhado, prefixo `dev/database/`, commit/VersionIds/SHA fixados, base proof/PGDATA novos e manifesto tratado reconciliado. Fixture PG16, restore físico e backup do banco Dev são três provas distintas. Não limpar staging/grants/cipher/artefatos necessários antes das provas e do lote de limpeza revisado; não apagar origem ou auditoria.

## Testes preparados e limites

`python tests/restore-validation.test.py` cobre AST sem import, associação Table, cobertura de campos desconhecidos/ausentes, revisão técnica explícita pendente, bindings, privacidade de erros, comparação pelo manifesto existente e metadata de riscos. Nenhuma chamada AWS/DB.

`.github/workflows/restore-validation.yml` prepara um teste Linux PG16 por digest: catálogo real com trigger/RLS/SECURITY DEFINER sintéticos, snapshot compartilhado, dump/import em outra base sintética, reconciliação e count drift rejeitado. Container novo não root, network none, rootfs read-only, caps removidas e todos os dados em tmpfs; trust é exclusivo da fixture descartável, não template de role operacional. Nenhum workflow foi despachado por este pacote. SQL/integração PG16 permanecem pendentes de execução CI; Python local de outra versão de PostgreSQL ou mocks não equivalem a essa prova.

Fontes primárias: [PG16 pg_database/locale provider](https://www.postgresql.org/docs/16/catalog-pg-database.html), [pg_dump e portabilidade lógica/snapshot](https://www.postgresql.org/docs/16/app-pgdump.html), [snapshots administrativos](https://www.postgresql.org/docs/16/functions-admin.html), [pg_trigger](https://www.postgresql.org/docs/16/catalog-pg-trigger.html), [pg_restore e risco de SQL do dump](https://www.postgresql.org/docs/16/app-pgrestore.html).
