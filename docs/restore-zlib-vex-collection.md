# Coleta benigna do pacote zlib no CI

`operations/restore-toolchain/zlib_vex_collect.py` coleta fatos da imagem atual e chama o validador separado `zlib_vex_review.py`. Não executa PoC, payload, função do zlib, restore, shell na imagem ou teste de exploração. Não altera o scan nem aplica exceção. Todo resultado continua `pending_technical_review`, com `gateOverrideApplied=false`, `riskAccepted=false`, `severityDowngraded=false` e `realRestoreApproved=false`.

O CLI exige Linux/GitHub Actions, commit/run/attempt/repositório/workflow presentes e ID `sha256:`. Faz inspect limitado a ID/arquitetura/OS antes e depois. Usa esse mesmo ID para ler `/etc/os-release`, inventário dpkg completo, lista de paths do pacote, ownership da biblioteca e seus bytes reais. Cada leitura usa container novo, `--pull=never --network=none --read-only --user=999:999 --cap-drop=ALL --security-opt=no-new-privileges`, limites de memória/CPU/PIDs e tmpfs limitados em `/tmp`, `/run` e no VOLUME herdado `/var/lib/postgresql/data`. Não monta host, credenciais, socket nem passa variáveis do runner. Entry point e argumentos são fixos. Não inicializa PostgreSQL. Nenhum log bruto do subprocesso é exposto em falhas.

A biblioteca instalada precisa pertencer a zlib1g e ser byte a byte igual à biblioteca contida na `.deb` exata revisada. O validador confere o ELF real, inventário saudável/único, paths, OS/PURL/finding e versão. Essa conclusão cobre exclusivamente o pacote Debian zlib1g, nunca bibliotecas vendorizadas, MiniZip separado, outros CVEs ou a imagem inteira.

## Cadeia Debian implementada

1. Ler o keyring Debian do base público imutável `postgres@sha256:57c55aefb81a937d21171b7c2266264b5552cb1a4f90459bbdfc417a36883a4d`, com os mesmos controles de container. O CI precisa disponibilizar previamente esse digest exato; BuildKit pode não deixá-lo no image store. Não baixar chave isolada nem usar o keyring do runner por conveniência.
2. Buscar somente os três URLs HTTPS fixos: `https://deb.debian.org/debian/dists/bookworm/InRelease`, `https://deb.debian.org/debian/dists/bookworm/main/binary-amd64/Packages.xz` e `https://deb.debian.org/debian/pool/main/z/zlib/zlib1g_1.2.13.dfsg-1_amd64.deb`. Redirecionamentos são recusados. Timeout por resposta 30s; limites 1MiB/16MiB/86684 bytes.
3. `/usr/bin/gpgv`, com homedir temporário novo e somente o keyring acima, verifica InRelease. Exigir sucesso e VALIDSIG com digest SHA2; rejeitar estados de assinatura inválida/expirada/revogada/desconhecida. Usar a saída clara autenticada de gpgv, nunca texto extraído antes da verificação. Registrar fingerprints, digest do keyring, base, InRelease e binário verificador. O runner e gpgv são parte da base de confiança do CI; gpgv não consulta revogação online e esse coletor não constitui atestado criptográfico independente do runner.
4. Validar Origin/Label Debian, Codename bookworm, arquitetura amd64 e componente main; hash e tamanho de Packages.xz dentro da seção SHA256 assinada. Descomprimir com limites de memória/saída e recusar streams extras. Exigir uma stanza zlib1g/amd64 exata: Source zlib, Version `1:1.2.13.dfsg-1`, Filename fixo, Size 86684, SHA256 `d7dd1d1411fedf27f5e27650a6eff20ef294077b568f4c8c5e51466dc7c08ce4`. Validar também os bytes `.deb` contra esse pin. O arquivo é examinado em memória; não instalado/executado/extraído no filesystem.
5. Validar Date assinado sem data futura; se houver Valid-Until, recusar expiração e intervalo inválidos. **Limitação concreta:** o InRelease de bookworm/main consultado não publica Valid-Until. Nessa situação a assinatura/integridade pode ser verificada, mas `repositoryFreshnessVerified=false`, `validUntil=null` e `freshnessLimitation=bookworm_main_release_has_no_signed_valid_until`. Não substituir isso por um prazo inventado, alegar anti-replay completo ou mudar o gate. O pin da `.deb` reduz substituição do pacote; não prova atualização de todo o repositório.

A saída nova é criada exclusivamente, modo 0600, e contém hashes/metadados, sem ELF, keyring, inventário inteiro, ambiente da imagem ou dados privados. Releitura final do scan exige bytes idênticos; o coletor não grava nele. A evidência vincula commit/run/attempt/workflow e horário de coleta; autenticidade do job e revisão técnica continuam pendentes no resultado interno do validador. `repositorySignatureVerified=true` no envelope significa somente a cadeia executada, não aprovação VEX.

## Fragmento a integrar pelo coordenador

Não modificar o passo que falha em findings CRITICAL. Incluir os testes abaixo no passo offline e os paths correspondentes no trigger. Depois do scan, antes do upload, inserir este passo (nenhum `continue-on-error` nem manipulação da conclusão do scan):

```yaml
- name: Collect current package evidence without changing scan gate
  if: always()
  timeout-minutes: 10
  shell: bash
  run: |
    set -euo pipefail
    test -s "$RUNNER_TEMP/restore-toolchain-public/scan.json"
    test -s "$RUNNER_TEMP/restore-toolchain-image-id"
    test -x /usr/bin/gpgv
    # Explicit public immutable base for the archive keyring, no arbitrary key download.
    timeout 180 docker pull --platform=linux/amd64 postgres@sha256:57c55aefb81a937d21171b7c2266264b5552cb1a4f90459bbdfc417a36883a4d
    python operations/restore-toolchain/zlib_vex_collect.py \
      --image-id "$(cat "$RUNNER_TEMP/restore-toolchain-image-id")" \
      --scan "$RUNNER_TEMP/restore-toolchain-public/scan.json" \
      --evidence "$RUNNER_TEMP/restore-toolchain-public/zlib-package-evidence-review.json"
```

Usar esse mesmo ID para a invocação Trivy existente, sem trocar formato ou política. Se o build/scan não existir ou se o finding esperado estiver ausente, a coleta falha explicitamente, sem fabricar atestado. A falha original de scan permanece falha mesmo que a coleta passe. Acrescentar apenas `zlib-package-evidence-review.json` à allowlist de upload existente; os hashes referenciam `scan.json` e `scanner.json` já preservados. Não publicar inputs temporários indiscriminadamente. Pins de Actions/scanner existentes continuam aplicáveis.

```bash
python tests/restore-zlib-vex.test.py
python tests/restore-zlib-vex-collector.test.py
```

## Validação e pendências de evidência

Os 11 testes do coletor são offline, com pacote/ELF sintéticos e Docker/rede/gpgv simulados. Conferem isolamento, binding antes/depois, cleanup do container de nome único após falha/timeout, ownership, versão/arquitetura/paths/hash/tamanho, negativa de assinatura/hash fraco, saída clara ausente, metadados duplicados, data/expiração, URL/redirect e limite de descompressão. Pins são substituídos exclusivamente dentro dos testes sintéticos. Um ensaio adicional com os três arquivos públicos reais confirmou compatibilidade do parser, hash/tamanho/stanza do pacote e ausência de Valid-Until; nesse ensaio o corpo InRelease **não** foi autenticado, portanto ele não prova assinatura nem proveniência. Não houve inicialização do Docker Desktop local. A execução real da cadeia com o keyring extraído do base e a imagem remediada aguarda Linux CI: esses inputs reais não estão disponíveis localmente sem iniciar Docker. A integração preparada não constitui evidência já obtida. Permanecem revisão técnica da evidência/finding atual, confiança/proveniência do CI e qualquer conclusão formal VEX; nada aprova libxml2 ou libera restore.

Fontes primárias: [InRelease de bookworm](https://deb.debian.org/debian/dists/bookworm/InRelease), [manual gpgv](https://www.gnupg.org/documentation/manuals/gnupg/gpgv.html), [CVE no tracker Debian](https://security-tracker.debian.org/tracker/CVE-2023-45853), [pacote/hash Debian](https://packages.debian.org/bookworm/amd64/zlib1g/download).
