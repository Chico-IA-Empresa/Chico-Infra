# Revisão técnica delimitada de zlib1g / CVE-2023-45853

Preparação de 29/10/2026. Este pacote não aprova VEX, não aceita risco, não reduz severidade e não altera o gate ou o scan bruto. `zlib_vex_proposal.py` e o coletor compartilhado permanecem inalterados. O novo `zlib_vex_review.py` é uma biblioteca de validação de fatos para integração posterior revisada.

## Fundamento e limite da conclusão

O [tracker primário Debian](https://security-tracker.debian.org/tracker/CVE-2023-45853) explica que o source zlib de bookworm anterior a `1:1.2.13.dfsg-2` não compila/proporciona contrib/minizip. A tabela de **source** pode mostrar vulnerable enquanto a nota exclui os binários produzidos. A conclusão candidata é técnica, `vulnerable_code_not_present`, somente para **`zlib1g 1:1.2.13.dfsg-1 amd64` de bookworm**. Não vale para pacote MiniZip separado, pyminizip, código vendorizado, outra versão/arquitetura/fonte ou toda a imagem.

O [download oficial Debian](https://packages.debian.org/bookworm/amd64/zlib1g/download) publica:

| Artefato público | Valor conferido |
|---|---|
| Arquivo | `pool/main/z/zlib/zlib1g_1.2.13.dfsg-1_amd64.deb` |
| Bytes | 86684 |
| SHA256 da .deb | `d7dd1d1411fedf27f5e27650a6eff20ef294077b568f4c8c5e51466dc7c08ce4` |
| SHA256 do ELF empacotado | `7e2a72b4c4b38c61e6962de6e3f4a5e9ae692e732c68deead10a7ce2135a7f68` |

A preparação leu essa .deb pública por HTTPS, conferiu o digest e validou seus metadados/ELF em memória, sem instalar, executar binários ou extrair arquivos no filesystem. Isso **não** prova qual biblioteca está na imagem CI atual e **não** valida uma cadeia `InRelease → Packages → .deb` assinada. Essas duas provas permanecem pendentes.

## Contrato da nova biblioteca

`review_facts(...)` exige os seguintes dados brutos coletados da **mesma imagem por ID imutável**, não valores inferidos do tag:

- `image_id`: ID `sha256:...` atual;
- `raw_scan_bytes`: JSON Trivy original, sem VEX/filter/rewrite;
- `os_release`: campos observados de `/etc/os-release`, parseados como dados, nunca executados com `source`;
- `package_inventory`: `dpkg-query` com Package, Version, Architecture e Status-Abbrev separados por tab;
- `package_files`: lista integral observada de `dpkg -L zlib1g`;
- `installed_library_bytes`: bytes de `/lib/x86_64-linux-gnu/libz.so.1` nessa mesma imagem;
- `deb_bytes` e `reviewed_deb_sha256`: .deb exata acima e digest revisado. Outro digest é recusado; não basta fornecer o hash de uma .deb arbitrária.

A biblioteca não faz rede, subprocessos, instalação, execução de ELF ou extração em disco. Não precisa confiar em textos de `readelf`; parseia estruturas ELF64 little-endian/amd64 ET_DYN, program/section headers, segmento/tabela dynamic e suas referências runtime, SONAME exato, dependências e símbolos dinâmicos de função **definidos** em seção executável. Exige a API zlib esperada e recusa sinais MiniZip. Um texto NEEDED contendo `libz.so.1` não substitui um SONAME.

Para a .deb, confere SHA256 antes de descompactar, estrutura ar Debian2.0, control Package/Source/Version/Architecture exatos e tar limitado em memória. Não chama `extract/extractall`; recusa traversal, nomes absolutos, duplicatas, hardlinks, dispositivos, links que escapem, membros/tamanhos/compressões não suportados. A biblioteca regular e o symlink SONAME precisam existir no pacote. Compara bytes instalados **exatamente** com os bytes empacotados e compara os paths observados ao inventário desse pacote. Registrar somente SHA não prova integridade; a comparação é obrigatória.

O inventário deve ser único e saudável (`ii ` exato). `iiR`, entradas conflitantes e presença de pacote MiniZip são recusados. O raw scan precisa ter schema conhecido, image ID igual, OS Debian12, resultado OS/debian e exatamente o finding zlib1g/CVE/versão/PURL esperado. O PURL vem desse finding real, com arquitetura/epoch/distro coerentes; não usa a constante de distro da proposta antiga. JSON com chaves duplicadas e qualifiers PURL duplicados são recusados. A severidade original é registrada, sem reinterpretá-la.

Ausência de símbolos é evidência complementar. O fundamento de ausência do código vulnerável é o pacote Debian exato, sua origem revisada e seus bytes íntegros; esta verificação não detecta todo código MiniZip vendorizado em outros componentes.

## Saída que não libera o gate

Mesmo quando todas as verificações passam, a saída tem:

```json
{
  "status": "pending_technical_review",
  "candidateStatus": "not_affected",
  "packageScopeOnly": true,
  "wholeImageNotAffected": false,
  "debianRepositorySignatureVerified": false,
  "ciCollectorProvenanceVerified": false,
  "reviewRequired": true,
  "gateOverrideApplied": false,
  "rawScanModified": false,
  "riskAccepted": false,
  "severityDowngraded": false,
  "realRestoreApproved": false
}
```

Ela também inclui image/PURL, hashes do raw scan/finding/pacote/ELF/inventários e metadados ELF. Não produz um VEX aprovado para consumo automático. `factChecksPassed=true` não equivale a assinatura/proveniência CI nem à revisão técnica final.

## Gates e integração ainda pendentes

1. Corrigir o build atual e gerar nova imagem/prova/scan conhecidos. Não aproveitar facts ou VEX de um digest anterior para um tag novo. O estado de libxml2 e dos demais CVEs é independente e continua bloqueando enquanto não houver remediação/prova pertinentes.
2. Estabelecer proveniência Debian verificável: `InRelease` válido, keyring Debian autorizado/revisado, hashes de `Packages` assinados, stanza `zlib1g` exata com Filename/Version/Architecture/SHA256. Não baixar chave por canal não validado, usar `trusted=yes` ou confiar em grep de texto ainda não autenticado. O digest HTTPS conferido nesta preparação é um pin adicional; não alegar que assinatura foi verificada.
3. Integrar o coletor CI revisado usando o ID imutável para consultas e scanner. Vincular commit/run, ID antes/depois, OS, versão do scanner/base de vulnerabilidades, scan bruto e todos os inputs. Rodar `review_facts` somente depois dessa coleta; não adaptar inputs só para satisfazer o validador.
4. Rodar `python tests/restore-zlib-vex.test.py` no CI. O workflow compartilhado atual chama `tests/restore-toolchain.test.py`; este novo arquivo ainda precisa entrar no comando/paths do workflow por mudança coordenada. Nenhum dispatch ou mudança desse workflow faz parte deste pacote.
5. Revisão técnica final da evidência atual e emissão de eventual VEX aprovado **por finding/pacote/imagem**, com sua própria proveniência. Este helper nunca muda as flags para aprovado. Preservar o scan bruto e sua severidade; qualquer apresentação futura deve distinguir finding bruto, fato técnico aprovado e achados não resolvidos, sem chamar scan bruto crítico de zero.

Os testes offline cobrem os quatro falsos positivos reproduzidos na proposta antiga (NEEDED sem SONAME, ELF incompleto, status iiR e inventário conflitante), máquina/classe/endianness, símbolos indefinidos, MiniZip, bindings runtime, pacote/bytes/paths/digest, arquivos inseguros e drift de imagem/OS/PURL/finding. As .deb dos testes são sintéticas e o pin real é substituído **somente dentro do teste**; não são evidência de imagem real nem um mecanismo de aceitar outro pacote em produção.

Fontes: [Debian CVE tracker](https://security-tracker.debian.org/tracker/CVE-2023-45853), [debian/rules exato](https://sources.debian.org/src/zlib/1%3A1.2.13.dfsg-1/debian/rules/), [download/hash oficial](https://packages.debian.org/bookworm/amd64/zlib1g/download).
