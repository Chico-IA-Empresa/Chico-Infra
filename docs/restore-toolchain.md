# Toolchain isolada para restaurar PostgreSQL 16

Pacote de B1 do handoff de 28/10/2026. Os testes desta pasta criam somente dados sintéticos novos, sem AWS, OIDC, credenciais, publicação de imagem ou acesso a `chico-backup`. Uma execução verde não autoriza o staging ou o restore real.

## Fontes e pins

- Base `postgres:16.13-bookworm`, child amd64 `sha256:57c55aefb81a937d21171b7c2266264b5552cb1a4f90459bbdfc417a36883a4d`. Índice multiarch de referência: `sha256:472efd9a66f2b2f1a5aeb18b28de74332e6ef88c2b93a1a5d812fb6db67a5f60`.
- pgBackRest 2.57.0, commit `d9773a31c97077761ee8e7d06e073b0b0734e26f`; archive SHA256 `61d3183877da9a809a889e61d3c0bd0dc9b3498e0777aeba1d34aa1c16a16b74`. Download HTTPS com hash conferido antes de extrair; build Meson com zstd habilitado e SFTP desabilitado.
- Trivy 0.76.1, binário oficial Linux amd64 por HTTPS com SHA256 fixado `c7cbe3137fb8a48a17574bede3dd6beb16742d1e9772929940fc90082c39d9c0`; scan com banco atualizado no runner. Nenhum finding crítico é aceito automaticamente. Findings altos e a compatibilidade das bibliotecas/extensões reais precisam de revisão antes de promover a imagem.

O primeiro CI foi recusado na inicialização porque `aquasecurity/setup-trivy` não integra a allowlist de Actions. A correção mantém a allowlist e instala somente o binário oficial conferido, em `RUNNER_TEMP`, sem sudo nem execução de script remoto. A release inicialmente proposta 0.67.2 retornou HTTP404 nos endpoints API/download de assets em 28/10/2026. O coordenador autorizou usar 0.76.1 disponível; essa alteração atinge apenas o scanner, mantendo os pins de PG/pgBackRest. A [API oficial da release](https://api.github.com/repos/aquasecurity/trivy/releases/tags/v0.76.1) e o [manifesto de checksums](https://github.com/aquasecurity/trivy/releases/download/v0.76.1/trivy_0.76.1_checksums.txt) concordam com o hash do tarball efetivamente baixado em memória (52.676.794 bytes). SHA256 do próprio manifesto: `885debc41b570179e81af560e5f393a66be29b9ff8c52915674f3eb2304c535d`. O runner também registra o hash do binário extraído.

As dependências APT usam HTTPS e têm versões registradas na imagem, junto de hashes dos binários e `ldd`. Elas ainda não estão fixadas por snapshot/versão. Portanto esse build tem source/base fixados, mas **não é hermético nem reproduzível bit a bit**. Após o primeiro build/scan aceito, arquivar o digest resultante e inventário exato, revisar dependências e usar somente esse digest na execução real; um rebuild exige nova prova/scan. Não chamar esta base de última versão ou scan aprovado antes da evidência.

A base fixada não traz o bundle de CAs do sistema. Antes de qualquer APT HTTPS, os dois stages recebem explicitamente o bundle público do runner Ubuntu, copiado em `runner-ca.crt` pelo workflow. O SHA256 desse bootstrap de confiança é registrado no runner e na imagem; depois instala-se `ca-certificates` da distribuição via TLS validado. Não há HTTP fallback, `insecure`, desativação de certificado ou script remoto. Esse bundle do runner também faz parte da proveniência não hermética; o arquivo gerado é ignorado pelo Git e é o único arquivo extra permitido no contexto Docker.

## Contratos executáveis

`operations/restore-toolchain/isolated_run.py` produz o comando Docker com imagem imutável, UID numérico não root, rede `none`, rootfs read-only, todas as capabilities removidas e no-new-privileges. Monta `/tmp` e `/run` como tmpfs. Cobre explicitamente o VOLUME herdado `/var/lib/postgresql/data` com tmpfs, evitando volume anônimo e neutraliza o entrypoint de auto-initdb da imagem upstream.

O repo e a configuração entram read-only; o destino vazio e evidências são os únicos mounts de escrita. O executor não monta socket Docker, credenciais ou IMDS nos containers. O Docker daemon permanece somente no runner de teste; não se inicia/reseta Docker Desktop por esta preparação. Não usar comandos `docker run` avulsos que omitam a cobertura do VOLUME ou o isolamento.

`verify_report.py` aceita somente o relatório `--output=text --verbose` com console desligado: stanza exata, status `ok`, label explícito por execução, contagens positivas checked=valid e quatro contagens de erro zero em cada seção de backup/WAL. Também exige o stderr detalhado separado (`--log-level-stderr=detail`), vinculado à versão/label/comando e ao resumo idêntico. Somente os ranges WAL saudáveis e contadores JSON do comando são permitidos além de begin/report/end; fallback de metadata, checksum divergente de `.copy`, WARN/ERROR e diagnóstico desconhecido reprovam. Rejeita duplicatas, relatórios truncados, campos desconhecidos e cadeia diferente. O resultado sempre mantém `restoreApproved=false` e `independentWalValidated=false`. Seu teste unitário usa a gramática upstream e não se apresenta como saída observada do binário. Diagnósticos brutos reais ficam privados e nunca devem ser publicados como artifacts.

O workflow `restore-toolchain.yml` compila o binário real em Linux, cria repositório local cifrado AES256CBC com full+diff PG16 e verifica os dois labels separadamente. Corrompe um payload da cópia sintética e exige que o relatório real de falha seja rejeitado, mesmo que o processo retorne zero. Corrompe individualmente os principais e cópias de `backup.info`, `archive.info` e manifestos full/diff: oito casos devem emitir resumo `ok`, mas ser recusados pelos diagnósticos privados. Publica somente o resultado sanitizado desses casos, sem stderr bruto. Depois recupera o diff em PGDATA vazio, valida o WAL requerido via `archive-get`, identidade/header contra `pg_controldata`, `pg_waldump` PG16 e confere três linhas sintéticas no cluster recuperado sem rede. Os comandos `stanza-create` e `backup` existem somente nessa fixture nova; nunca são operações permitidas sobre a seleção legada.

```text
python tests/restore-toolchain.test.py
bash -n operations/restore-toolchain/fixture_prepare.sh
cp /etc/ssl/certs/ca-certificates.crt operations/restore-toolchain/runner-ca.crt
docker build --platform=linux/amd64 --tag chico-restore-toolchain:synthetic operations/restore-toolchain
sudo python tests/restore-toolchain-integration.py --image sha256:ID_IMUTAVEL --evidence /caminho/novo/evidencia
```

O diretório da integração deve ser novo; contém apenas a fixture gerada. A pipeline publica allowlist de resumo sintético, relatórios verify, inventário/hashes e scan. Não publica repo, PGDATA, cipher/configuração ou dumps. A integração não aceita fixtures herdadas nem caminhos da seleção real.

## Gates que permanecem para o restore real

1. Build Linux e integração com saída do binário real, scan conhecido/revisado, hashes de binário e digest resultante. Preparação/offline não fecha B1.
2. Completar Shared/compute, provas Dev/fixture e lote de staging com plano e gates humanos/financeiros próprios.
3. Copiar exatamente as versões da seleção fixa para staging novo; verificar os bytes cifrados e a cadeia full/diff sem resolver `latest`. Entregar o cipher pelo envelope privado e gerar configuração em tmpfs sem stdout/env secreto.
4. Rodar verify de todos os labels necessários. A implementação 2.57.0 tem reconciliação WAL incompleta, portanto validar separadamente a cobertura inteira requerida, identidade/control/segment-size e WAL com ferramentas PG16. A integração sintética suporta um segmento requerido e recusa ranges diferentes; não reutilizá-la como verificador genérico da seleção real.
5. Conferir arquitetura física, bibliotecas/extensões/collation, configurações restauradas e capacidade antes de subir clone real. Isolar preloads/jobs/replicação/chamadas externas; somente Unix socket privado. Não importar roles/hashes da origem como credenciais Dev.
6. Manifesto SQL do mesmo snapshot, classificação/tratamento de dados, export lógico para ARM64 e capacidade medida. A imagem não comprova essas propriedades.
7. Backup Dev e segunda recuperação independente, seguidos da revogação/limpeza revisada.

Referências primárias: [verify.c 2.57.0](https://github.com/pgbackrest/pgbackrest/blob/d9773a31c97077761ee8e7d06e073b0b0734e26f/src/command/verify/verify.c), [testes upstream](https://github.com/pgbackrest/pgbackrest/blob/d9773a31c97077761ee8e7d06e073b0b0734e26f/test/src/module/command/verifyTest.c), [opções de build](https://github.com/pgbackrest/pgbackrest/blob/d9773a31c97077761ee8e7d06e073b0b0734e26f/meson_options.txt), [contrato de comandos nessa versão](https://github.com/pgbackrest/pgbackrest/blob/d9773a31c97077761ee8e7d06e073b0b0734e26f/src/build/config/config.yaml), [PostgreSQL 16 WAL tools](https://www.postgresql.org/docs/16/pgwaldump.html).
