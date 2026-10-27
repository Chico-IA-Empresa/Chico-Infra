# Execução Dev — preparação local de 22/10/2026

Atualização de execução fase 1: consultar [ondas e recuperação S3](phase1-execution.md) para issuer/chaves/review storage gerenciados, sink Dev, CPU Standard, capacidade até 80 GiB e backup real separado. Seções históricas abaixo não substituem as decisões/aprovações privadas atuais. Nenhuma prova AWS é inferida dos testes locais.

Atualização de 27/10/2026: Felipe autorizou fechar a preparação local e do GitHub. Checks CI sem credenciais e leituras de metadados AWS estão incluídos; provisionamento/alteração AWS permanece uma etapa separada. O conector voltou a responder para leituras. Este runbook prepara a execução futura e não comprova infraestrutura provisionada. Estado vigente: [fechamento local/GitHub](local-github-status.md).

## 1. Reconciliar ownership antes de init autenticado

O remote próprio é `Chico-IA-Empresa/Chico-Infra`, privado, e o branch de preparação é `codex/dev-infra-local-github`. Usar a revisão publicada e verificada pelos checks; não usar o repo frontend, cujo main tem integração com a VPS. GitHub Free foi mantido por decisão de Felipe; proteções indisponíveis bloqueiam OIDC no preflight, sem impedir os checks locais.

| Objeto | Evidência disponível | Owner pretendido | Ação futura |
|---|---|---|---|
| Bucket de backup legado da VPS | Histórico somente leitura de 22/10; não reconferido | Operação legada/VPS | Preservar. Nunca importar para o backup Dev nem alterar prefixos/policies nesta entrega |
| Bucket state, versão/TLS/PAB | Código bootstrap; existência atual não comprovada | bootstrap | Listar metadados, localizar state/import; não criar cópia por presumir fundação ausente |
| Três repos ECR | Código shared; existência atual não comprovada | shared | Get/Describe + tags/state, importar somente com ownership revisado; outputs explícitos para Dev |
| OIDC/roles CI/auditoria/budgets | Código shared, sem prova atual | shared | Revisar plan shared e obter aprovação humana correspondente antes de apply |
| VPC/host/EIP/EBS/S3/logs/SSM Dev | Código preparado; não aplicado | dev | Reconciliar eventual existência, preencher inputs não secretos e plan privado |
| KMS Dev, SNS e autoridade DNS | Referências externas obrigatórias/pendentes | Root proprietária a confirmar | Metadados e policy revisados; implementar/importar na root correta, sem descobrir por nomes ambíguos |
| UAT/Prod | Fora da execução local Dev | uat/prod | Preservar recursos, state, DNS e dados; não executar apply/destroy |

Histórico não é inventário atual. Classificar cada objeto como existente confirmado, código não aplicado, incompleto ou fora de escopo somente após a leitura correspondente. Registrar ARN/owner/root/import sem valores de objetos ou secrets. Nenhum import foi executado.

## 2. Financiamento e primeiro executor

Revalidar créditos/conta/validade/produtos, consumo bruto corrente e exclusões/tributos em evidência privada. Cotar EC2 ARM64, 30 GiB gp3, IPv4, buckets/versões/requests, ECR/scan, logs/Flow Logs/métricas/alarmes, CMKs, Secrets Manager, SNS, auditoria, DNS, tráfego e recursos temporários. Quantificar reserva e data de encerramento, incluindo retenções após parada. Não preencher aprovação com os dados sintéticos de testes. Não existe cotação integral ou reserva comprovada nesta rodada.

Configurar executor temporário humano com MFA/credenciais temporárias para a fundação que cria OIDC. Não usar root operacionalmente nem criar access keys permanentes. Shared apply exige revisão humana do plan shared; aprovação genérica de Dev não substitui esse gate. Aprovar/registrar separadamente KMS, auditoria, repos e backend compartilhados estritamente necessários.

## 3. Init, plan e apply privados

1. Validar backend com `node scripts/backend-guard.mjs envs/dev/backend.hcl ACCOUNT_ID`: bucket revisado, key `dev/terraform.tfstate`, sa-east-1, allowed_account_ids, encrypt e use_lockfile. O workflow faz isso antes do init. Inputs reais ficam fora do Git.
2. Proteger `infra-plan-dev` e `infra-apply-dev`: main, workflow confiável, revisores e separação de funções. Conferir subject real (inclusive IDs imutáveis) e aud; nunca capturar JWT. O módulo aceita subject exato revisado por binding.
3. Gerar e revisar os candidatos de plan/apply conforme [permissões CI](dev-ci-permissions.md), com inventário real. A root shared agora tem o input de grants/boundaries e a root Dev exige boundaries exatas. O gerador exige VPC/SG reconciliados do primeiro executor e CMKs/buckets reais; policies candidatas não comprovam autorização efetiva. Não executar OIDC enquanto faltarem proteções, revisão e provas correspondentes.
4. Configurar bucket privado de revisão existente, versionado, criptografado, bloqueio público e TLS com acesso restrito plan→Put / apply→GetObjectVersion / revisor→Get. Runtime não acessa state nem planos. Provisionar/importar essa dependência na root proprietária sob gate shared; não criar via script de workflow.
5. Configurar conta/roles, inputs e backend privados, bucket de revisão, gate `DEV_EXECUTION_APPROVED=true` e `FUNDING_REVIEW_VALID_UNTIL` somente após revisão efetiva. São controles operacionais, não prova de fundos por si.
6. Disparar operação plan de `dev-reviewed-plan-apply.yml` em main confiável. O bundle privado contém plano salvo e manifesto; sem artifact público. Baixar as versões exatas em sessão privada, examinar `terraform show` e conferir mudanças/destroys, scope, custos, inputs e hash. Registrar revisor, decisão e versões sem conteúdo sensível.
7. Operação apply usa mesmo commit, run ID do plan, versões S3 e hash aprovado do manifesto. O verificador exige os mesmos inputs/backend/lockfile e validade de 24 h. Terraform rejeita state obsoleto sob lock. Se qualquer item mudou/expirou, gerar novo plan e revisar. Mesmo grupo de concorrência `infra-dev`, sem cancelamento de execução em andamento.
8. Falha parcial: preservar state/versões, levantar recursos realmente criados, diagnosticar em sessão privada, reconciliar import/inputs e gerar novo plan. Não há rollback automático; não rodar destroy geral nem force-unlock sem comprovar ausência de execução legítima.

Plan/state/logs integrais permanecem privados. Logs do runner são efêmeros; uma falha precisa reprodução/inspeção em sessão privada autorizada. Nenhum resultado autenticado foi obtido nesta entrega.

Antes de assumir OIDC, `execution-gates.mjs` verifica liberação externa e os campos atuais de crédito nos inputs. Assim um plano ainda dentro das 24 h não permite apply após o expires_on da aprovação financeira. A verificação valida metadata, não o saldo/elegibilidade reais: a revisão financeira privada continua obrigatória. Este workflow exige provision_enabled=true; encerramento/destroys usam o procedimento separado, sob revisão específica.

## 4. Lock e recuperação de state

Criar key de prova isolada sob prefixo explicitamente autorizado, com nenhum objeto legado. Fazer duas sessões Terraform sobre o mesmo key com lock mantido: a segunda deve esperar/falhar; outra key isolada deve funcionar. Registrar IDs e tempos. Não escrever lock artificial sobre o state ativo. Para recuperação, copiar uma versão histórica a outra key de prova e validar serial/lineage no destino; não sobrescrever state ativo. Remover apenas fixtures após conferir owner, paths e reserva. Esta prova exige AWS e continua pendente.

## 5. Host, dados e configuração

AMI deve ser Amazon Linux 2023 ARM64 disponível, selecionada por ID/owner Amazon e revisão de procedência. Compose requer versão fixa e SHA256 oficial do binário aarch64; nenhum `latest` é instalado silenciosamente. Bootstrap tem retries limitados para associação tardia do EIP, Docker/SSM, diretórios sem formatação, unidades de telemetria e nenhum workload de negócio.

O host usa o root gp3 criptografado de 30 GiB retido. Instance e EIP têm prevent_destroy: substituições exigem plano explícito, backup/snapshot e revisão da proteção. Snapshot/restauração do root retido em outro host é a estratégia escolhida; não há volume extra autorizado. Não confundir disco retido com prova de reanexação. Antes de substituir: verificar backup externo/restore, snapshot criptografado, registrar UUID/device mapping/ownership, pausar apenas fixture Dev, restaurar root a partir da imagem/snapshot revisado, remontar sem mkfs e reassociar EIP. Não montar simultaneamente filesystem de um volume em duas instâncias. Registrar custos residuais do volume antigo antes de qualquer exclusão autorizada.

`/srv/chico/postgres`, `redis`, `files`, `tls` e `fixture` são reservados. A fixture PostgreSQL usa volume Docker nomeado no mesmo root retido, separado do banco da aplicação. UID/GID da imagem por digest devem ser verificados antes de inicializar bind mounts da aplicação; bootstrap não faz chown recursivo em dados existentes. Certificado Caddy usa `/srv/chico/tls`; dados de teste não entram em paths de Prod.

Depois de SSM online: registrar identidade/arquitetura/versões; reboot e reexecução preservam checksum de arquivo sintético. Testar externamente 80/443 e negar 22/3000/8000/5432/6379; inspecionar também listeners, Docker port mappings e regras DOCKER-USER. Containers não recebem host networking, socket Docker ou acesso livre ao IMDS. Leitura de metadata de dentro da fixture deve falhar. Usar documento `chico-dev-session` explicitamente para sessões auditadas. O documento de deploy/status não aceita shell parametrizado.

A policy do agente SSM é inline e separada de configuração: evita os grants globais GetParameter/GetParameters presentes em AmazonSSMManagedInstanceCore. Não reanexar essa managed policy para resolver falha do agente sem revisar o efeito na allowlist. Validar positivamente o agente/patch/SSM e negativamente parâmetros de outro ambiente usando recursos existentes. Nenhuma dessas negativas AWS foi demonstrada localmente.

Seguir `dev-configuration-contract.md` para secret sintético, resolução via asm-exec, arquivo 0600 tmpfs e rotação por novo lançamento. Política CMK real e ownership Dev ainda precisam prova; ARN da conta não é suficiente.

## 6. Fixtures e provas

Não iniciar Docker Desktop nesta estação sem avaliar seus containers existentes. Nesta rodada o daemon está parado. `docker compose config --quiet` apenas valida o modelo, não restaura dados nem prova ARM64.

No host Dev futuro: instalar somente o pacote `fixtures/dev` revisado em `/opt/chico-dev-fixture`, setar imagens ARM64 por digest e `CHICO_SYNTHETIC_ONLY=true`, gerar credencial aleatória protegida em `/run/chico/fixture_password` sem imprimir. `compose up -d postgres static` não publica portas; executar seed.sql via stdin e comprovar três registros. Reboot/reexecução deve preservar registros/arquivo. Não usar compose da aplicação real.

Executar `ecr-proof.sh` pela identidade build: verificar BASIC/immutability, push nas três URLs, aguardar scan COMPLETE com CRITICAL conhecido/zero. Depois runtime faz login/pull somente e executa digest aprovado em ARM64 com `--network none`, sem portas/volumes. Testar negativas de push sob runtime e de pull de repo não permitido usando recurso existente de prova. Retenção é apenas preview local com inventário completo e grafo multiarch; nenhuma exclusão.

`backup.sh` exporta apenas DB fixture PostgreSQL16 e arquivo sintético, faz SHA256 e upload em prefixo único `dev/fixtures/`. `install-backup-timer.sh` prepara execução noturna 03:00 UTC; `/etc/chico/fixture.env` contém apenas configuração não secreta. `restore.sh` baixa um prefixo explícito, valida checksum, restaura em container temporário sem rede/portas e exige três registros; cleanup remove somente seu container/diretório temporário. Medir duração e perda; não anunciar RPO/RTO Prod. Falha de upload impede avançar o timestamp de sucesso.

## 7. DNS, TLS, sinais e encerramento

Hostname/autoridade seguem sem decisão de Felipe. Terraform cria somente A de `dev.DOMINIO`, em zona existente explicitamente informada e com flag adicional; `allow_overwrite=false`. Se DNS externo, registrar fronteira manual e prova; não criar zona ou mudar delegação. Importar registro existente só após ownership/plan. O profile TLS da fixture exige hostname aprovado, Caddy por digest e Let's Encrypt staging inicialmente. Depois validar HTTP→HTTPS, cadeia/validade, reboot preservando estado e renovação apropriada; certificado público de produção requer decisão correspondente. Contrato futuro `/api/contact`→web, `/api/*` com strip→API, `/ws/*`→API e fallback web está em arquivo separado, sem ativação de negócio.

Telemetria coleta memória real de /proc, disco via df e idade do último backup; namespace Chico/Dev e InstanceId. CPU/status vêm do EC2. Thresholds 85% memória, 80% disco/CPU, 26 h backup são provisórios, sujeitos a baseline/custo antes de ativação. Logs bootstrap/backup têm encaminhador com cursor e sessão SSM tem documento de logging; proxy tem arquivo persistente, mas o envio/redação do log de proxy ainda exige integração revisada. Flow Logs Dev usam role própria, SourceAccount/SourceArn, grupo criptografado e 30 dias. Reutilização CloudTrail shared, alertas recebidos/SNS, budgets brutos e tags Billing precisam de prova e gates. Não alegar entrega de alerta por haver alarme declarado.

Encerramento futuro: parar somente fixtures/host Dev após novo backup verificado, guardar state/versionamento e plano de retomada; inventariar custos remanescentes de EBS/snapshots, EIP mesmo desassociado, S3/versões, ECR, logs, CMKs, Secrets e auditoria. Reservar cobertura até exclusão autorizada ou fim de retenção. Parar compute não zera cobrança. Não executar destroy geral, excluir backup legado, desativar auditoria ou alterar Prod/UAT/VPS.

## Complementos locais de 23/10/2026

`access_log_bucket_name` é referência obrigatória a sink Dev já existente/reconciliado, distinto do backup, na mesma conta/região e com SSE-S3. Confirmar ausência de Object Lock/default retention e Requester Pays, entrega autorizada por logging.s3.amazonaws.com e retenção/cobertura. O output `access_log_delivery_review` propõe somente o statement delimitado por SourceArn/SourceAccount/prefixo; não concede acesso nem muda bucket shared. A AWS exige configuração do destino para entrega programática: https://docs.aws.amazon.com/AmazonS3/latest/userguide/enable-server-access-logging.html. Provar chegada de um acesso sintético no prefixo, sem ler dados legados; configuração source declarada não é prova de entrega.

O encaminhador `proxy-events.py` agora filtra os registros locais Caddy e exporta somente método enumerado/status/duração/tamanho; não exporta URLs, IPs, headers, corpos ou identidades. `proxy-logs.sh` usa cursor por inode/device/offset e só o confirma após envio sem rejeição. Timers de logs e métricas são independentes. O parágrafo anterior que apontava encaminhamento/redação como lacuna de código passa a ser pendência de validação no host/CloudWatch; nenhuma entrega real foi demonstrada. O arquivo bruto de Caddy ainda fica no host, deve permanecer protegido e receber política de retenção/rotação na publicação da aplicação; não copiar seus registros brutos para tickets.

O módulo budgets agora exige os cinco envelopes account/shared/dev/uat/prod; nenhum teto Dev real é defaultado. Mocks usam números sintéticos e não constituem cotação ou aprovação. Não aplicar shared para satisfazer esse contrato sem revisão do plan e dos valores reais.
