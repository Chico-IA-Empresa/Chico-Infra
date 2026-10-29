# Candidato benigno de manutenção libxml2

Preparado sobre PR16 head `45909f8b2c2f239cc148bc8e5b94a6dcaefeb7c9`, em checkout privado separado. Este pacote compara uma biblioteca fonte corrigida pelo fornecedor com o baseline; **não substitui a biblioteca default, não remedia uma imagem por declaração e não autoriza restore real**. Nenhum Docker Desktop local, build Linux, publicação, scan novo ou execução AWS foi feito nesta preparação. A pasta de pesquisa anterior não aprovada não foi consultada nem reutilizada.

## Fonte oficial completa selecionada

Ubuntu [USN-8456-1](https://ubuntu.com/security/notices/USN-8456-1) e [status da CVE](https://ubuntu.com/security/CVE-2026-6653) identificam a correção Noble `2.9.14+dfsg-1.3ubuntu3.8`. O [Sources.xz oficial de noble-security](https://security.ubuntu.com/ubuntu/dists/noble-security/main/source/Sources.xz) atualmente oferece `2.9.14+dfsg-1.3ubuntu3.10`, de 06/10/2026, que inclui essa correção e atualizações posteriores da mesma série. O changelog/series do pacote completo confirma a inclusão; não se reutiliza um patch avulso ou uma reprodução da falha. A [Debian](https://security-tracker.debian.org/tracker/CVE-2026-6653) ainda registra Bookworm `2.9.14+dfsg-1.3~deb12u6` como vulnerável/postponed; migrar para outra libc/base ou introduzir binários Noble não integra esta proposta.

Os três arquivos completos, tamanhos e SHA256 estão fixados em `operations/restore-toolchain/libxml-maintenance/source-pins.json`: orig tar de 2351200 bytes, Debian tar de 61552 bytes e `.dsc` de 3083 bytes. Os bytes do Debian tar e seus metadados foram conferidos via HTTPS nesta preparação; não houve autenticação local do InRelease, extração/execução de corpus ou alegação de cadeia assinada já observada.

`acquire.py` prepara a cadeia **InRelease → Sources.xz → os três arquivos completos** no Linux CI. Usa `/usr/bin/gpgv` e exclusivamente o keyring Ubuntu já provisionado no runner Ubuntu; não baixa chave arbitrária nem usa uma chave do pacote para confiar no próprio pacote. O verificador compartilhado exige assinatura forte/saída clara autenticada e rejeita erros. Confere Origin/Label/Suite/Codename, hash/tamanho do índice assinado, stanza/versão/directory/file set exatos e os pins de todos os arquivos. Os URLs HTTPS são fixos, sem redirect, timeout de 30s e limites de entrada/descompressão. Mudança de versão publicada faz falhar, sem selecionar latest ou atualizar pins automaticamente.

A política técnica de frescor exige Date assinado com idade máxima de sete dias e sem data futura. Valid-Until, quando presente, também deve ser válido; a evidência distingue sua presença do limite local de Date, sem inventar uma expiração assinada. Registra fingerprints e hashes do keyring/índice/InRelease/pins. A fonte é gravada somente em diretório novo, sem overwrite, após autenticar e conferir todos os arquivos. A pasta gerada é ignorada pelo Git.

## Build de comparação, sem substituir o runtime

`prepare_context.py` confere SHA256 `27af00c45b4918f22d4f9b8993e42766d7b85f8b9791f908677573c49fce6413` do Dockerfile baseline, normalizando apenas CRLF. Acrescenta um alias à sua última instrução FROM e anexa os stages do candidato. Não edita o original nem depende de tag de baseline mutável. Isso também evita confundir image config ID com registry manifest digest no FROM do BuildKit. A base PostgreSQL `16.13-bookworm` continua no child amd64 `57c55aef...36883a4d`; pgBackRest continua 2.57.0, com todos os pins e controles originais.

O compilador usa o próprio baseline Bookworm. Instala headers Debian da **mesma versão exata** da libxml2 baseline e recusa se a biblioteca original mudar; indisponibilidade desse pacote no mirror bloqueia o build, sem fallback para bibliotecas de outro sistema. A versão de compilador/dependências e configure.log são registrados. Os arquivos originais completos são novamente conferidos por SHA256 no build, e `dpkg-source` aplica a série oficial. `--no-check` nesse passo desativa apenas a verificação da assinatura do uploader `.dsc`: a autorização dos bytes vem da cadeia de repositório verificada antes, não de uma assinatura omitida silenciosamente.

Compila somente o alvo `libxml2.la` e instala somente a biblioteca em `/opt/chico-libxml-candidate/lib`. Não chama make check/test/runtest/testapi/fuzz nem executa corpus/regressões upstream. Os arquivos de teste que integram a distribuição oficial completa não são usados nem exportados. Não há payload próprio, XML malformado, DTD/entidades externas, exploração, reprodução ativa ou fuzzing. Os flags normais mantêm ICU, lzma, zlib e história, sem Python, com PIC/stack protector/RELRO/NOW. Não se faz instalação de `.deb` Ubuntu, troca de libc, rename de versão ou edição da base de pacotes para obter um scan verde.

O stage final deriva do baseline e copia somente `/opt/chico-libxml-candidate`. O loader default e o pacote libxml2 original permanecem. Hashes de **libc e do binário PostgreSQL são idênticos** ao baseline por assertion do build. Não há ENV LD_LIBRARY_PATH global, ldconfig ou substituição do SONAME original. Esta imagem serve exclusivamente para comparação sintética; executar seu entrypoint default continua usando a biblioteca antiga e não constitui remediação.

## Comparações e testes normais

- Inventários SHA256 de todos os headers públicos antes/depois; tamanhos e offsets de onze probes de `xmlEntity`, `xmlParserInput`, `xmlParserCtxt`, `xmlNode`, `xmlDoc` e `xmlSAXHandler`. Uma amostra igual não prova ABI completa; mudanças das estruturas públicas são esperadas na correção e precisam de análise própria.
- Símbolos dinâmicos definidos com versões, SONAME, DT_NEEDED e requisitos GLIBC da candidata versus versões oferecidas pela libc baseline. Símbolo removido, dependência nova ou GLIBC indisponível fica explícito. Hashes das duas bibliotecas e inventário do compilador são preservados.
- Um único documento XML pequeno e bem-formado com dois itens: parsing NONET, XPath e canonicalização. `dladdr` confirma que a função veio de `/opt/chico-libxml-candidate/lib`.
- PostgreSQL 16.13 sem rede/listener TCP/preloads: XMLPARSE, xpath_exists, XMLTABLE e XMLSERIALIZE em três linhas sintéticas novas. `ldd` precisa resolver libxml2 da candidata tanto para PostgreSQL quanto para pgBackRest.
- pgBackRest 2.57.0: repositório posix novo, backup full offline e restore desse label exato em destino novo, seguidos das mesmas consultas SQLXML. Não há teste de corrupção nessa integração nem acesso à seleção real. A fixture usa auth local trust somente no socket privado do container isolado; não é configuração operacional Dev.

O harness `tests/restore-libxml-maintenance-integration.py` exige opt-in explícito, Linux, UID do operador CI necessário para criar diretório novo 0700 pertencente ao UID999 e imagem por ID imutável. Usa o runner existente: rede none, usuário999, rootfs read-only, caps removidas, no-new-privileges e tmpfs cobrindo inclusive o VOLUME herdado. Nenhum mount de socket/credenciais/IMDS. O nome do container é único e há cleanup após timeout/falha. Logs integrais ficam apenas no diretório sintético privado.

O relatório sempre retorna `blocked_pending_abi_and_scan_review`, `fullABICompatibilityProven=false`, `defaultLibraryReplaced=false`, `packageVersionChanged=false`, `gateOverrideApplied=false`, `rawScanModified=false`, `riskAccepted=false`, `realRestoreApproved=false`, mesmo com smoke verde. Não existe override, VEX novo ou alteração de severidade. O scan bruto atual continua bloqueando, inclusive porque a biblioteca antiga permanece presente. Uma eventual atualização definitiva exigirá revisão de ABI completa de todos os consumidores, empacotamento/proveniência próprios, novo build e o mesmo gate existente, sem afirmar fix com base no nome da versão.

## Preparação para CI, somente após revisão coordenada

Nenhum workflow foi alterado ou disparado. Em runner Ubuntu revisado, depois dos checks offline, a coordenação pode preparar os comandos abaixo em job separado de manutenção **sem OIDC/credenciais AWS**. Não incorporá-los ao deploy/plan enquanto main/bundle Dev estiverem congelados.

```bash
python tests/restore-libxml-maintenance.test.py
bash -n operations/restore-toolchain/libxml-maintenance/build.sh
bash -n operations/restore-toolchain/libxml-maintenance/normal-smoke.sh
task_context=operations/restore-toolchain/libxml-maintenance
test -s /usr/share/keyrings/ubuntu-archive-keyring.gpg
python "$task_context/acquire.py" --destination "$PWD/$task_context/verified-sources"
install -m 0644 /etc/ssl/certs/ca-certificates.crt "$task_context/runner-ca.crt"
python "$task_context/prepare_context.py"
docker build --platform=linux/amd64 --pull -f "$task_context/Dockerfile.combined" \
  -t chico-libxml-maintenance:synthetic "$task_context"
task_image=$(docker image inspect chico-libxml-maintenance:synthetic --format '{{.Id}}')
sudo --preserve-env=GITHUB_REPOSITORY,GITHUB_SHA,GITHUB_RUN_ID,GITHUB_RUN_ATTEMPT \
  env CHICO_LIBXML_MAINTENANCE=true "$(command -v python)" \
  tests/restore-libxml-maintenance-integration.py --image "$task_image" \
  --evidence "$RUNNER_TEMP/libxml-maintenance-new"
```

O scan existente deve ser executado também sobre esse ID, com banco/versão conhecidos e relatório bruto preservado, **sem mudar sua regra de CRITICAL**. Publicar, se revisado, somente o relatório sintético sanitizado/proveniência/hashes por allowlist; não repo/PGDATA/logs de SQL/configure indiscriminadamente. Falhas de assinatura, APT, build, ABI ou comportamento não autorizam trocar base/libc/PG, relaxar gate ou ativar dados reais.

Validação local realizada: 10 testes novos offline, 17 testes existentes da toolchain e Bash syntax/diff-check. Assinatura real com keyring do runner, build C/ELF e integração normal aguardam Linux CI; o Windows local não oferece a cadeia Ubuntu/base executável necessária sem iniciar Docker, o que não foi feito. A proposta entrega candidato e instrumentos de comparação, não comprovação de compatibilidade ou remediação.

## Integração CI preparada pelo coordenador em29/10

Após revisão independente dos14arquivos sem achados P0–P2, foi preparado o workflow separado `libxml-maintenance.yml`, com pull_request limitado aos paths necessários e workflow_dispatch, contents:read e nenhuma credencial/OIDC AWS. Ele executa apenas a aquisição autenticada, build de comparação, testes normais acima e scan Trivy0.76.1 oficial pinado. Scan deve corresponder ao ID imutável/OS Debian e ter resultado de pacotes do SO; a regra CRITICAL continua falhando. O relatório permanece bloqueado mesmo se o smoke passar. A publicação usa allowlist de report/proveniência/pins/hashes/scan e dados do scanner, sem PGDATA, repos, fontes completas ou logs brutos. O código será publicado como draft empilhado sobre PR16, sem integrar main ou liberar restore. Preparação/revisão não comprovam execução Linux; resultados reais devem ser registrados separadamente.
