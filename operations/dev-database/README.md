# Backup real da base Dev restaurada

Este pacote protege **a base Dev já restaurada e tratada**, não o repositório legado pgBackRest. Não exporta novamente a VPS, não resolve credenciais no contexto do agente e não inicia aplicações/consumidores. A transferência/conversão de `chico-backup` segue o runbook da fase; estes scripts nunca recebem esse bucket como destino/origem.

## Contrato no host

- Instalar os arquivos revisados em `/opt/chico-dev-database`, somente root pode alterá-los. A configuração privada `/etc/chico/database-backup.json` segue as três chaves do exemplo: conta, bucket Dev real e database `chico_dev` ou nome derivado `chico_dev...`. Não colocar passwords/DSNs/tokens nesse JSON.
- O container fonte deve se chamar `chico-dev-database`, com labels `org.chico.environment=dev`, `org.chico.role=database`, imagem PostgreSQL16 por digest, sem portas publicadas, modo privileged ou socket Docker. Preservar o PGDATA restaurado; nenhum script formata/distribui permissões recursivamente.
- Criar `dev_backup` como login Dev dedicado, sem SUPERUSER/DDL, com acesso de leitura às tabelas, sequências, schemas e large objects necessários. Rever RLS: não conceder bypass genérico para fazer um dump passar. Se RLS impedir a exportação integral, interromper e revisar privilégios específicos antes de usar o backup.
- Credencial própria deve ser gerada/resolvida por processo privado e montada read-only como `/run/secrets/dev_backup_pgpass`, formato pgpass, modo 0600, legível somente pelo usuário PostgreSQL. O host `/run/chico` é tmpfs. Não montar diretórios inteiros de secrets. Respeitar os metadados/quantidade de secrets aprovados; criar outro secret ou expandir privilégios exige reconciliação antes da escrita.
- AWS CLI no host usa a role runtime Dev, com conta conferida por STS e somente o bucket/prefixo Dev. Grants incluem Get/Put/GetObjectVersion e controle de multipart próprios; nenhum DeleteObject ou acesso permanente à origem legada.

## Dump e upload

Executar no host autorizado:

```text
python3 /opt/chico-dev-database/backup.py backup --config /etc/chico/database-backup.json
```

O script mantém uma transação exportadora REPEATABLE READ READ ONLY até terminar o `pg_dump` e o manifesto. Dump e contagens usam o mesmo snapshot. O manifesto agrega tabelas/contagens, colunas, extensões, encoding/collation, large objects, hashes de definições, índices/constraints e sequências. Não consulta linhas de negócio para os logs nem inclui senhas/roles globais. Falhas imprimem somente códigos controlados; erros SQL brutos não são gravados nos logs encaminhados.

Contadores de sequência não seguem MVCC. A prova compara suas definições e verifica se o próximo valor calculado pode colidir com o extremo de uma coluna associada, sem executar `nextval/setval`. Sequências sem ownership requerem revisão específica; não são declaradas seguras por ausência de tabela associada. O erro histórico `is_called=false`/max(id)=last_value é detectado. Nenhuma correção automática é aplicada à fonte.

O espaço livre precisa cobrir uma cópia conservadora do tamanho físico + 1 GiB para o dump; o host e seus limites já devem estar dimensionados. O upload usa transferência multipart quando necessária e um prefixo único `dev/database/UTC-UUID`. `database.dump` e `manifest.json` são publicados antes de `commit.json`, com bytes/SHA256/VersionIds vinculados. Somente depois de confirmar a versão do commit o marcador `/var/lib/chico/database-last-backup.json` avança. Esse marcador é distinto da fixture.

O sucesso comprova exportação/upload, não recuperabilidade por si só. Falha retém apenas seu diretório privado por execução em `/srv/chico/backups/database/run-UUID`; verificar e remover explicitamente os artefatos falhos pelos paths registrados para evitar acumulação. Execuções concorrentes de backup/proof são recusadas por lock local. Não excluir backups anteriores para abrir espaço.

## Segunda restauração isolada

Antes da prova, preparar um container novo `chico-dev-database-proof-HEX12`, sem rede (`--network none`), sem portas, sem privilégios/socket Docker, usuário PostgreSQL não root, root filesystem read-only, tmpfs para `/tmp` e `/var/run/postgresql`. PGDATA novo deve ser bind mount exclusivo `/srv/chico/restore-proof/HEX12/pgdata`, inicializado pelo processo privado com UID/GID verificados da imagem, sem chown em dados existentes. Secrets individuais read-only ficam sob `/run/chico/database-proof-HEX12/` no host; montar somente os arquivos necessários. Nada monta o volume vivo da fonte.

Criar database vazio com login próprio `dev_proof` e montar seu pgpass 0600 como `/run/secrets/dev_proof_pgpass`. Usar o mesmo digest PostgreSQL16 do dump e habilitar apenas bibliotecas/extensions revisadas. O caminho atual admite plpgsql/pg_trgm/pg_stat_statements; outra extensão interrompe a prova até revisão específica. Credenciais reais são geradas privadamente; não copiar os logins superusuários da fixture de CI para o contrato operacional.

Inspecionar o dump/TOC/SQL privadamente antes da restauração e registrar o SHA256 revisado. A saída de `pg_restore --file` pode conter dados e não deve aparecer no chat/CI/logs públicos. Referenciar o marcador versionado de backup, sem selecionar “latest” novamente durante retries:

```text
python3 /opt/chico-dev-database/backup.py proof --config /etc/chico/database-backup.json --reference /var/lib/chico/database-last-backup.json --proof-container chico-dev-database-proof-HEX12 --reviewed-dump-sha256 SHA256_REVISADO
```

A prova verifica ownership/isolamento e destino vazio, baixa versões exatas, confere SHA256/tamanho, usa `pg_restore --no-owner --no-privileges --exit-on-error` e reconcilia o manifesto. Não usa `--clean`, não sobrescreve uma base existente, não restaura roles globais e não aplica migrations. Conta/role, tratamento de dados, privilégios de aplicação, consultas de negócio, reboot e IAM efetivo continuam provas operacionais adicionais da fase.

Somente depois da reconciliação é escrito `database-last-restore-proof.json`, vinculado ao mesmo commit/versão. O script deixa o container e seu PGDATA para inspeção; a remoção é explícita por ID/path do lote após validar a recuperação. O diretório privado de download da execução bem-sucedida é limpo; uma execução falha é preservada. A fonte e os backups S3 não são removidos.

## Timer e telemetria separados

Depois do primeiro backup/proof reais conferidos, executar o instalador no host autorizado com `CHICO_DEV_DATABASE_APPROVED=true`. Ele exige prova vinculada ao mesmo commit antes de instalar o timer diário **03:15 UTC / 00:15 Brasília**, independente da fixture às 03:00 UTC. Os scripts não criam essa configuração, credencial ou timer automaticamente por estarem no repositório.

`DatabaseBackupAgeHours` e `FixtureBackupAgeHours` são medidos separadamente. Quando a configuração real está instalada, `BackupAgeHours` usa a maior idade dos dois, mantendo o alarme já existente sem criar sexto alarme. Marker ausente, corrompido ou futuro da base real falha fechado; backup novo da fixture não mascara falha da base restaurada. `DatabaseBackupEnabled` distingue configuração real ausente. A instalação/rotação dos arquivos e entrega de métricas/alerta recebido precisam prova no host.

Os testes Python cobrem falhas de commit, version binding, adulteração, drift de schema/contagens, sequências e timestamps. A integração CI usa somente PostgreSQL16 sintético sem rede e storage fake: comprova SQL/snapshot/dump/restore, não S3, ARM64, dados reais ou aceite AWS. Nenhuma dessas evidências substitui a segunda restauração real exigida pelo plano.
