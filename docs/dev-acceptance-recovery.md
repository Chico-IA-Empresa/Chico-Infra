# Aceites Dev após o apply parcial — pacote de execução

Preparado em 28/10/2026 para AWS-DEV-EXEC-001 v1.1. Este pacote organiza as provas das seções 9.1 e 10 do plano aprovado; não comprova execução AWS. O handoff de 28/10 às 19:03 BRT registra compute parcial, bootstrap falho, seis taints e banco real ainda não restaurado. Revalidar cada observação antes de executar. DNS externo e TLS público são etapa posterior.

As autorizações posteriores registradas no handoff prevalecem sobre restrições históricas dos runbooks: root temporário foi autorizado; Dev permite autoaprovação manual; Shared mantém revisão humana específica. A aprovação do compute antigo não cobre novo plan nem reparo de state. Somente o coordenador executa AWS, Terraform, SSM, start/stop/reboot, secret operations, pushes ECR, merges ou alterações GitHub. Este documento não concede novos acessos.

## Ordem e gates

1. Correção do comparador e seis untaints em cópia **local**, PR/checks, validações IAM completas e saved plan Shared privado. Revisão humana específica do Shared e do manifesto exato de reparo; aplicar/reparar somente após as respectivas decisões. Nenhuma substituição/destruição para contornar taints.
2. Novo plan Dev atual, revisão/apply protegido e bootstrap convergido na mesma EC2/root/EIP. Completar controles S3 antes de qualquer backup ou envelope. Confirmar cobertura financeira e custo residual no registro privado.
3. Provas sintéticas de host, rede/IMDS, ECR, configuração, fixture, backup/restore, reboot e observabilidade. Não iniciar aplicação, integrações ou escritores de negócio.
4. Staging x86 aprovado e limitado a 48 h/160 GiB; toolchain validado, origem versionada fixada, recuperação física isolada, classificação/tratamento e manifesto da mesma cópia. Medir capacidade lógica e pico de disco antes de importar no Dev de 80 GiB.
5. Import lógico em destino vazio, reconciliação, backup próprio Dev e segunda restauração independente. Só então instalar timer real; finalizar reboot/durabilidade, alerta, limpeza revisada, custo e drift.

O root de 80 GiB não garante espaço para dados físicos expandidos, SO, WAL, dump e segunda restauração. Se não couber, interromper a operação afetada e preparar delta de capacidade/custo; não apagar histórico, backups ou tabelas para caber. Snapshot/recriação precisa lote específico e capacidade/custo revisados, preservando `prevent_destroy` e o volume original.

## Identidades e evidência

Usar AWS Core como interface principal de consulta. As formas CLI abaixo documentam operações/argumentos para executor privado já autorizado; não substituem o conector quando ele atende ao caso. Nunca devolver credenciais temporárias ou JWT. `GetSecretValue`/`BatchGetSecretValue` e leitura direta do daemon de secrets não são comandos do agente.

Antes de cada lote, fixar em registro privado: conta/região, principal e ARN esperado, commit main efetivo, hash do pacote e do payload, instância/volume/EIP, horário UTC/BRT, aprovação aplicável e referência financeira vigente. Destino Dev observado no handoff: `i-03b97e256bbba039c`, região `sa-east-1`, conta `306915830875`; reconsultar tags, profile e state, sem descobrir outro host por wildcard.

Cada prova registra resultado `passed`, `failed` ou `pending`, comandos/versões, origem (`aws`, `host`, `external` ou `offline`), request/command IDs, observação e referência privada/hash da evidência. Teste offline nunca recebe origem `aws`; simulação IAM não equivale a negativa real. Guardar stdout/stderr integrais privadamente; devolver somente allowlist de IDs, versões/digests, checksums, contagens agregadas e booleanos. Não anexar tfvars, state/plan bruto, credenciais, SQL/dump/TOC, destinatários, logs Caddy brutos, argumentos de processos ou `docker inspect` integral.

Para SSM, preparar o JSON de parâmetros e payload revisado em arquivo privado, conferir SHA256 e a instância exata. Resposta de transporte incerta exige `ListCommands`/`GetCommandInvocation` antes de decidir retry; não reenviar automaticamente. O documento `chico-dev-fixture-status` é status fixo e não executor genérico. Sessão interativa auditada seleciona explicitamente `chico-dev-session`. Scripts em `/opt` são instalados root-owned; o bootstrap replay confere SHA aprovado antes de executar em tmpfs. Não imprimir o userData completo.

## Matriz de provas

| Prova | Comando/procedimento concreto | Identidade | Aceite e evidência sanitizada | Recuperação/limite |
|---|---|---|---|---|
| Conta, owner e state | STS `GetCallerIdentity`; EC2 `DescribeInstances/Volumes/Addresses`; versões S3 exatas dos states; confrontar outputs privados | Coordenador/revisor temporário | Conta/região/role corretas; mesmos IDs e tags; serial/versão explicados; nenhuma execução concorrente | Divergência interrompe lote; não importar, restaurar state ou forçar lock por tentativa |
| IaC/compute | CI protegido sobre main integrado; novo saved plan Dev após Shared/reparo | `ci-plan-dev` / `ci-infra-apply-dev` | Plano/hash/versões aprovados, sem replace/delete; buckets completos, docs e metadata conferidos; drift final autenticado | Falha parcial preserva state/versões; replanejar; não reutilizar plan antigo |
| SSM e bootstrap | Probe A abaixo; `chico-dev-fixture-status`; consulta SSM Online; replay por hash se cloud-init não repetir | Operador SSM exato; host usa runtime | AL2023/aarch64, Docker/Compose por checksum, agente ativo, scripts/timers instalados e diretórios preservados | Não formatar/distribuir chown recursivo; preservar root; logs de erro privados |
| Rede externa e host | Probe B; inspeção SG/NACL/rotas e `ss`/Docker/regras host | Sonda externa + operador SSM | HTTP sintético e TLS interno local; 80/443 acessíveis; 22/3000/8000/5432/6379 sem acesso externo; nenhum listener/binding indevido | Parar apenas serviço sintético criado no lote se exposição; não abrir SSH/banco para investigar |
| IMDS/container | Probe C com imagem de curl fixada e rede bridge de egress revisada | Operador SSM | PUT token IMDSv2 não entrega token; GET metadata não entrega conteúdo; sem host network/socket/mounts indevidos | Se token/metadata acessível, falhar e revisar isolamento; nenhum acesso a `/iam/security-credentials/` |
| OIDC/IAM | Assunção legítima real; tentativas sob origem/branch/Environment inadequados; leituras negativas em recursos existentes fora do escopo | Cada role CI/runtime/build/deploy pertinente | CloudTrail/request IDs, subject/aud sem JWT, `AccessDenied` real; zero missing context na simulação preliminar | ARN inexistente/NoSuchKey/NotFound não prova IAM; se não existir Prod, declarar limitação e gate futuro |
| ECR | `fixtures/dev/ecr-proof.sh`; Probe D; negativa runtime de `ecr:PutImage` com manifesto fixture válido | Build publica; runtime só pull | Três repos imutáveis; ARM64; scan COMPLETE e CRITICAL=0 conhecido; pull/run do digest; push runtime negado | Imagem sintética apenas; scan desconhecido bloqueia; não apagar imagens nem criar repo para fabricar negativa |
| Configuração e rotação | Fluxo E; `fixtures/dev/refresh-config.sh LAUNCH32` e `config-consumer.py serve --token-file /run/secrets/synthetic_token` | Processo privado operador + runtime, depois consumidor por arquivo | VersionIds, modo0600/tmpfs, montagem individual RO, comportamento A→B no novo consumidor e A preservado no antigo; negativas ARN/role/CMK | Nunca imprimir valor/digest de segredo; parar consumidor e remover só seu arquivo efêmero; reboot exige nova resolução |
| Fixture PG16/arquivo | Fluxo F; `seed.sql` via stdin; `SHOW server_version_num`; count agregado de `synthetic_records` | Operador SSM, sem writers de negócio | PostgreSQL16, três linhas sintéticas, arquivo/checksum, volume fixture separado, nenhuma porta publicada | Não usar fixture como destino real; cleanup não usa `compose down -v` |
| Backup/restore fixture | `fixtures/dev/backup.sh`, prefixo emitido fixado, `fixtures/dev/restore.sh` | Runtime S3 Dev; operador executa | SHA/download/restore, três linhas/arquivo, duração e prefixo próprios; timestamps não avançam em falha | Restauro remove somente seu container/temp; nenhuma API no bucket legado |
| Reboot/idempotência | Reaplicar bootstrap corrigido por hash; registrar checksums/contagens/volume; `RebootInstances` na EC2 exata e aguardar EC2+SSM | Coordenador; operador SSM após retorno | Mesmo EC2/root/EIP, dados/arquivo/checksum preservados, Docker/SSM/timers voltam; resolução tmpfs refeita privadamente | Não substituir EC2; não reiniciar antes de preparar recuperação das credenciais efêmeras |
| Origem/staging/restore real | PR13 atualizado; cópia somente das versões fixadas; toolchain B1; contrato pgBackRest privado | `chico-dev-restore` temporária; container x86 isolado | Todos objetos/cadeia/WAL verificados; cluster recuperado; versões/control/extensões/collation e ponto temporal registrados | Não usar root/runtime para copiar origem; não escrever/reparar/expirar legado; não selecionar latest |
| Manifesto/tratamento/import | Manifesto no clone do mesmo snapshot; classificação privada; `pg_restore --no-owner --no-privileges --exit-on-error` em destino vazio | Admin/migrator/api/workers Dev próprios | Schema/contagens/índices/constraints/sequências/extensões e consultas de leitura equivalentes; PII/credenciais tratadas; capacidade medida | Nenhuma role global/superuser/password origem; não sobrescrever destino não vazio nem aplicar migration destrutiva |
| Backup real e segunda restauração | Fluxo G / `operations/dev-database` | Runtime Dev + `dev_backup`; prova com `dev_proof` próprio | Commit S3 versionado fixado, dump/manifesto mesmo snapshot, proof independente reconciliado e persistência após reboot | Novo destino sem rede/volume vivo; manter source/backup; limpeza explícita após evidência |
| Logs/auditoria | Fluxo H; `chico-dev-logs`; SSM session; requests sintéticos proxy/S3; trail/Flow Logs | Host runtime + leitor autorizado | Chegada real de bootstrap/backup/SSM/proxy filtrado/Flow Logs/access logs/trail; grupos CMK/30 dias | Não publicar logs brutos; não considerar ACTIVE/DeliverySUCCESS prova suficiente de evento entregue |
| Métricas/alertas/timers | Fluxo I; `chico-dev-metrics`; CloudWatch histórico/SNS | Runtime publica; coordenador consulta; destinatário autorizado recebe | Memória/disco/frescor fixture+real separados; falha→ALARM→SNS→recebimento e recuperação→OK; timers 03:00/03:15 UTC revisados | Guardar/restaurar marcador fixture apenas; não falsificar timestamp real nem alterar thresholds para obter verde |
| Durabilidade, custo, cleanup e drift | Lote snapshot/recriação isolada revisado; inventário de resíduos/lease; revogar grants temporários; novo plan final | Coordenador/revisor; Terraform owner | Recuperação consistente comprovada; cobertura residual; staging/grants encerrados por IDs; zero drift inesperado | Parar EC2 não limpa EBS/IPv4; não deletar auditoria/chaves/state/origem para zerar cobrança |

## A. Probe básico SSM sem valores

Executar somente depois da convergência e instalação do pacote revisado. Saída contém versões/booleanos; qualquer log detalhado fica no executor privado.

```bash
set -euo pipefail
umask 077
test "$(uname -m)" = aarch64
source /etc/os-release
test "$ID" = amzn && test "$VERSION_ID" = 2023
systemctl is-active --quiet amazon-ssm-agent docker
docker --version
docker compose version
aws --version
for task_path in /srv/chico/postgres /srv/chico/redis /srv/chico/files /srv/chico/tls /srv/chico/fixture; do
  test -d "$task_path" && test ! -L "$task_path"
done
test "$(findmnt -n -o FSTYPE -T /run/chico)" = tmpfs
test -x /usr/local/sbin/chico-dev-metrics
test -x /usr/local/sbin/chico-dev-logs
systemctl is-active --quiet chico-dev-metrics.timer chico-dev-logs.timer
printf 'host_baseline_passed=true\n'
```

Comparar SHA256 do Compose e dos scripts instalados aos bytes aprovados, não apenas a string de versão. Confirmar montagem/device/UUID de `/srv/chico`, capacidade e espaço livre em registro privado. O probe não comprova banco, IAM, logs entregues ou ausência de aplicação: revisar lista/labels de containers e units sem imprimir ambiente/args.

## B. Rede, proxy local e durabilidade

No host, iniciar somente `postgres static proxy-local` pelo profile `local`, com imagens ARM64 por digest. Não combinar com profile `tls`. `curl --fail --silent http://127.0.0.1/` deve retornar apenas `chico-dev-synthetic`. Para HTTPS, obter a CA interna do Caddy de forma controlada (certificado público, sem private key), conferir fingerprint e usar `curl --cacert ARQUIVO_CA --resolve localhost:443:127.0.0.1 https://localhost/`. Não usar `-k` como prova de confiança TLS.

Na máquina externa, testar TCP no EIP reconfirmado, com timeout limitado por porta. Registrar timestamp/origem da sonda, bool de conexão e 80/443. Em PowerShell, `Test-NetConnection -ComputerName EIP_RECONFIRMADO -Port PORTA -InformationLevel Quiet` fornece o booleano; não inferir porta fechada de um único timeout sem revisar caminho de rede. O certificado interno não prova confiança pública; negociar 443 e testar conteúdo local com CA são provas distintas.

Inspecionar privadamente `ss -H -lnt`, Docker port mappings e regras `DOCKER-USER`/nftables/iptables. Divulgar só portas/classificação de bind e booleanos de privilégio/host-network/socket/metadata; não retornar `ps aux`, environment ou inspect completo. Antes/depois do reboot, comparar checksum de arquivo sintético em `/srv/chico/files`, count fixture e manifesto real quando presente; registrar boot-id/instância/volume e retorno SSM. Reexecutar bootstrap não altera dados existentes. Preparar antes a recriação privada dos arquivos tmpfs e relaunch dos consumidores.

## C. IMDS em container

Uma rede `--network none` ou Compose `internal` falhar por ausência geral de egress não isola o efeito do hop limit. Usar uma rede bridge de egress revisada e uma imagem ARM64 de curl já aprovada por digest; validar primeiro acesso HTTPS sintético conhecido. Não publicar portas/montar host/network/socket. Exemplo de cada requisição, com stdout descartado:

```bash
docker run --rm --read-only --cap-drop ALL --security-opt no-new-privileges \
  --network REDE_BRIDGE_REVISADA IMAGEM_CURL_ARM64_POR_DIGEST \
  --noproxy '*' --silent --output /dev/null --write-out '%{http_code}\n' \
  --connect-timeout 2 --max-time 5 -X PUT \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
  http://169.254.169.254/latest/api/token
```

Executar também GET em `/latest/meta-data/instance-id` sem token. Nenhuma resposta 2xx é aceita; registrar status/exit/timeout, sem capturar token/corpo. GET401 prova exigência de token, mas não prova que um container não consegue obtê-lo: o PUT é obrigatório. Não consultar caminho de credenciais IAM.

## D. ECR por digest e negativas reais

Antes da publicação, revisar grants/trust build/deploy e Access Analyzer; não usar root para mascarar falta da role build. `fixtures/dev/ecr-proof.sh` exige `CHICO_SYNTHETIC_ONLY=true`, conta, `FIXTURE_BASE` por digest e tag `fixture-COMMIT40`. Executar no runner Linux/ARM64 revisado; ele publica nos três repos, exige BASIC/IMMUTABLE e aguarda scan COMPLETE/CRITICAL=0. Guardar relatório e severidades conhecidas. CRITICAL=0 sozinho não decide aceitabilidade das demais findings: registrar a revisão.

No host, usar `DOCKER_CONFIG` temporário0700 e trap de limpeza; login via pipe `get-login-password | docker login --password-stdin`, suprimindo stdout/stderr privado. Pull das três referências por digest aceito. `docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges IMAGEM_DIGEST` deve emitir somente o marcador ARM64 da fixture.

Para negativa de push, o coordenador fixa manifesto válido da imagem sintética existente e tag de prova única, chama `PutImage` sob runtime e exige `AccessDenied` com request ID. `LayersNotFound`, `ImageAlreadyExists` ou manifesto inválido não provam IAM. Sucesso inesperado interrompe a prova e gera achado; não apagar imagem automaticamente nem repetir gravação. Negativa de pull em repo fora da allowlist precisa repo **existente** autorizado para teste; sem tal recurso, registrar lacuna em vez de criar outro repo ou usar nome fictício.

## E. Configuração e rotação privadas

Revisar/instalar `asm-exec` e seu backend/credenciais antes de executar `refresh-config.sh`; comando inexistente ou metadata de secret não comprova resolução. Usar apenas referência dinâmica `/chico/dev/api/SYNTHETIC_TOKEN`, sem fetch de valor pelo agente. População/rotação aleatórias são realizadas por processo privado, com saída limitada a VersionId/metadata. Conferir key policy e a role runtime, além de IAM.

O arquivo real `references/asm-exec` do plugin foi inspecionado: seu `main()` resolve somente argumentos, apesar de a descrição anunciar suporte a environment. Não há flags de stdin/arquivo implementadas. O adaptador `config-consumer.py deliver` carrega **em memória** a função `resolve_string` desse source exato, sem executar o `main` que repassa segredo no argv. Pin obrigatório SHA256 `38399ce2a9a2b5e69fc9179815d90669e80612ea1dfc4dc2d399db9608488035`; instalar os bytes revisados em `/usr/local/bin/asm-exec` root-owned, executável e sem escrita por grupo/outros em nenhum ancestral. Não instalar outro pacote de mesmo nome e presumir equivalência. Mudança do resolver exige nova revisão/pin; essa dependência de função interna é deliberada e falha fechada se divergir.

O adaptador exige Linux/root, `CHICO_SYNTHETIC_ONLY=true`, região sa-east-1 e mount tmpfs visível no destino; recusa override de endpoint SMA/MCP. A checagem do mount rejeita camadas no mesmo caminho ancestral, IDs/ciclos inválidos e descendente lexical pertencente a subtree oculto por overmount, conferindo a cadeia real de parents do mount selecionado. Resolve somente a referência fixa sintética e entrega `/run/chico/api/LAUNCH32/synthetic_token`,0600, diretório0700. `LAUNCH32` é identificador público aleatório de32hex, diferente por lançamento; `refresh-config.sh LAUNCH32` rejeita lançamento existente. Não atualiza inode/path anterior. A saída é apenas `delivered=true` e launchId. Ainda faltam instalação/revisão do backend, credenciais/conectividade e execução real no host; testes com resolver fake não comprovam isso.

`config-consumer.py serve --token-file /run/secrets/synthetic_token` é o consumidor persistente. Ele lê arquivo regular0600 apenas no lançamento, exige owner igual ao UID do processo e recusa symlink/hardlink. Emite `{"ready":true}`; recebe linhas JSON privadas via stdin no formato de **uma única chave** `candidate` e responde somente `{"matches":true|false}`. Não fornece endpoint de leitura, não devolve hash/valor e recusa entradas inválidas/longas com erro fixo. O controlador privado lê candidatos A/B dos arquivos autorizados e os envia por pipe diretamente ao stdin; nunca interpolar candidato em linha de shell, argumentos, environment, payload SSM, tool call ou transcript. Não registrar stdin. Usar tokens aleatórios de alta entropia próprios da fixture; este oráculo de igualdade é somente de teste, sem rede.

Protocolo de rotação a executar pelo coordenador:

1. Processo privado popula A e registra VersionId por metadata, resolve lançamentoA e inicia consumidorA usando apenas esse arquivo montado RO. Imagem Python ARM64 por digest revisado; rootfs read-only, network none, sem caps/no-new-privileges, stdin privado, código revisado montado RO, sem socket/volume de dados/credenciais AWS. Selecionar UID compatível com owner0600; arquivo root-owned exige processo0 no container isolado. Não afrouxar arquivo para0644 para suportar outro UID.
2. Controlador privado envia A por pipe; consumidorA responde matches=true. Guarda somente o booleano/VersionId/launchId.
3. Processo privado cria/promove B, registra VersionId e resolve lançamentoB em outro arquivo. Controlador envia B ao consumidorA: matches=false; A ainda retorna true. Nenhum refresh toca seu arquivo anterior.
4. Inicia consumidorB com mount somente do arquivoB. Envia B: true; A: false. Registra a matriz `A/A=true`, `A/B=false`, `B/A=false`, `B/B=true`, sem valores ou hashes dos tokens.
5. Para ambos, confirmar mounts individuais RO e ausência de env/argv contendo valores mediante verificador privado que só retorna booleanos; não imprimir inspect bruto. Encerrar os dois consumidores/pipes e remover apenas os dois paths tmpfs deste lote após evidência revisada.

Não coletar `/proc/*/environ`, command lines ou logs debug do resolver. Para negativas role/ARN/CMK, o fluxo privado só devolve código/request ID e confirmação de nenhum valor entregue. Reboot remove arquivos `/run`; resolver novamente antes de relançar. Se SMA/MCP não estiver alcançável sob o profile aprovado, revisar integração sem inventar fallback de CLI `get-secret-value`. Metadados de VersionId são consultados separadamente: o resolver fixo usa AWSCURRENT, portanto coordenar a rotação sem escrita concorrente e conferir a versão atual antes/depois de cada resolução; ainda não há binding atômico de VersionId pelo adaptador.

## F. Fixture e backup sintético

Instalar `fixtures/dev` em `/opt/chico-dev-fixture` root-owned e `/etc/chico/fixture.env` apenas com configuração não secreta. Preparar credencial aleatória no destino em `/run/chico/fixture_password`0600 sem saída; não colocar valor em ambiente/args Docker. Imagens PG16/static/Caddy por digest revisado. Executar seed somente com `docker compose -p chico-dev-fixture -f /opt/chico-dev-fixture/compose.yaml exec -T postgres psql -U fixture -d fixture -v ON_ERROR_STOP=1 < /opt/chico-dev-fixture/seed.sql`; verificar PG16 e count=3 sem linhas.

O arquivo de senha é tmpfs: planejar sua recuperação/rotação privada antes do reboot. Um arquivo novo aleatório não equivale à senha persistida no cluster existente. O contrato deve manter a credencial coerente sem recriar volume ou registrar valor; o Compose atual não resolve esse ciclo por si só.

Executar `backup.sh` sob runtime com bucket Dev exato reconciliado e controles completos. Fixar o prefixo emitido e usá-lo como `BACKUP_PREFIX` em `restore.sh`; não escolher o mais recente. Conferir S3 metadata/criptografia e entrega de access log. O restore é fixture pequena em tmpfs, PostgreSQL16 sem rede/portas, três linhas/arquivo/checksum. Não adaptar esse script para o banco real. Após primeiro restore comprovado e horários confirmados, instalar timer fixture **03:00 UTC / 00:00 Brasília**, observando delay aleatório de até300s.

## G. Base real e segunda recuperação

Seguir [operations/dev-database](../operations/dev-database/README.md) somente após restore/import/tratamento e capacidade aprovados. Contrato: container `chico-dev-database`, PG16 por digest, labels Dev/database, sem porta/network host/socket; login `dev_backup` próprio e pgpass0600 montado individualmente. RLS/extensões/large objects precisam revisão específica; não conceder superuser/bypass genérico.

```text
python3 /opt/chico-dev-database/backup.py backup --config /etc/chico/database-backup.json
python3 /opt/chico-dev-database/backup.py proof --config /etc/chico/database-backup.json --reference /var/lib/chico/database-last-backup.json --proof-container chico-dev-database-proof-HEX12 --reviewed-dump-sha256 SHA256_REVISADO
```

Preparar novo container proof/PGDATA vazio e conta `dev_proof` conforme README; fixar a referência antes de retries. Inspecionar TOC/SQL em fluxo privado e passar SHA real revisado. Dump+manifesto usam snapshot compartilhado; sequências exigem checagem adicional por não serem MVCC. Aceite exige commit/version binding, equivalência pré/pós e consultas read-only sem dados de linhas, além da persistência do banco após reboot. Instalar timer real somente depois de backup+proof reais vinculados ao mesmo commit, com `CHICO_DEV_DATABASE_APPROVED=true`: **03:15 UTC / 00:15 Brasília**, delay até300s, separado da fixture. Não excluir artefatos de falha/PGDATA prova automaticamente; inventariar IDs/paths e limpar após revisão.

## H. Entrega de logs e auditoria

Gerar evento sintético sem dados de usuário em cada fonte; observar chegada e timestamp no destino, sem devolver mensagem bruta. Bootstrap e backup usam `/usr/local/sbin/chico-dev-logs` com cursor; proxy passa por `/usr/local/lib/chico/proxy-events.py` e deve conter apenas type/método/status/duração/tamanho. Conferir que URL/IP/header/cookie/corpo não são exportados. Sessão SSM auditada exige o documento correto e logging criptografado. Comandos RunShellScript com saída CloudWatch não substituem a prova da sessão auditada.

Gerar tráfego sintético na ENI Dev para Flow Logs; request S3 fixture para access log; chamada AWS Dev esperada para CloudTrail. Consultar streams/objetos/eventos recentes com leitor autorizado e correlacionar tempo/request IDs. Permitir atraso de entrega documentado; estado ACTIVE ou configuração de logging não comprova chegada. Preservar logs de auditoria. Não disparar consultas tarifadas sem cobertura vigente e não colocar dados de linha em filtros.

## I. Métricas, alarme e recebimento

Revisar baseline e configuração real: CPU80%/3x300s, host-status>0/2x300s, custom memória85%/disco80%/backup26h em2x300s; obter statistic/comparison/treatMissing reais do plan/conta. Custom namespace `Chico/Dev`, dimensão `InstanceId` exata. Não aceitar thresholds apenas porque os defaults estão no código. Observar `FixtureBackupAgeHours`, `DatabaseBackupEnabled`, `DatabaseBackupAgeHours` e `BackupAgeHours`; com banco real configurado, a maior idade deve prevalecer, sem fixture mascarar falha real.

Primeiro provar estado saudável após backup fixture, assinatura Confirmed no ARN exato `chico-dev-operations` e ações ALARM/OK reais. Se PendingConfirmation, preparar reenvio controlado para o destinatário já registrado e solicitar confirmação da mensagem concreta, sem publicar endereço. Publish manual não comprova cadeia.

Ensaio controlado recomendado **antes do banco real**: suspender somente timer backup fixture durante o lote, guardar o marcador `/var/lib/chico/last-backup-success` em path privado exclusivo no mesmo filesystem e remover o marcador ativo de forma reversível; não inventar timestamp. Manter metrics timer ativo: coletor deve produzir age99999, CloudWatch avaliar o alarme após a janela real, SNS enviar e o destinatário confirmar recebimento. Registrar horário/IDs e não duplicar eventos. Se outro backup recriar o marcador, interromper a prova e reconciliar; não sobrescrever sucesso novo.

Restaurar o marcador original somente se nenhum backup concorrente o recriou, reativar o timer anterior e executar coletor/backup fixture válido. Aguardar estado OK e recuperação entregue conforme configuração. Fazer cleanup/recuperação mesmo se a espera de alerta falhar; usar janela operacional e watchdog definidos pelo coordenador, sem bloquear sessão em sleeps longos. Não usar `SetAlarmState`/`PutMetricData` manual para fingir falha do coletor. Com a base real instalada, testar seu frescor/falhas por lote próprio sem manipular marcador real ou perder backup; registrar a prova separadamente.

## Lacunas concretas de saída

Na preparação deste pacote, nenhum comando AWS/SSM foi executado. Além da correção Shared/state/Dev ainda pendente, precisam de evidência efetiva: grants/trust build/deploy, negativa OIDC/fora de escopo em recursos existentes, scan/pull ARM64, backend asm-exec e prova do consumidor persistente no host, recuperação privada dos arquivos tmpfs após reboot, primeiro backup/restore fixture, chegada de todas as fontes de logs, confirmação SNS/recebimento, toolchain/cadeia/WAL/restauração real, medição do pico de disco e segunda restauração real. Recriação isolada depende de lote revisado. As evidências históricas já realizadas permanecem válidas apenas para a revisão/estado registrados.

Verificação offline desta preparação: `node --test tests/dev-fixture-config.test.mjs` passou2testes de modelo Compose sem engine; `python tests/proxy-events.test.py` passou4testes de filtragem/cursor; `python tests/dev-database-backup.test.py` passou14testes de contrato/erros. `python tests/config-consumer.test.py` passou19testes e teve1skip POSIX no Windows: imutabilidade, snapshot persistente A/B, subprocesso/protocolo sem plaintext, rejeição de input, pin/interface do resolver com fake offline, endpoints e tmpfs (inclusive stacked mounts/overmounts/parent graph e raiz namespace com auto-parent). O teste POSIX de modo/symlink/hardlink é obrigatório no CI Linux já existente. Bash `-n` passou individualmente nos seis scripts listados em D/E/F/G. Não foram iniciados containers, PostgreSQL, jobs CI ou recursos AWS. Esses resultados não liberam gates operacionais e não comprovam resolução real SMA/MCP ou os controles Linux omitidos no Windows.

Entrega final inclui hashes/IDs não secretos e referência privada das provas, inventário de resíduos, acessos temporários revogados, plan final e instrução de EIP/portas para DNS externo. Registrar literalmente: **DNS e TLS público pendentes — etapa posterior**. Não marcar aplicação Dev ou jornada de negócio como publicada nesta fase.
