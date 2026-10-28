# Janela exclusiva para o reparo das seis flags Dev

Este procedimento complementa a revisão específica do manifesto de reparo. Não registra uma aprovação recebida. O apply antigo não pode ser repetido; remover flags não autoriza substituir recursos nem aplicar um novo plano Dev.

## Declaração humana e bindings

Antes do dispatch, o operador precisa suspender todos os escritores externos de `dev/terraform.tfstate`: sessões Terraform locais, outros executores, automações e alterações manuais do objeto. O grupo GitHub `infra-dev` serializa os workflows participantes; não controla esses escritores externos.

O dispatch exige três campos explícitos, além da versão privada do manifesto e seu SHA256 aprovado:

| Campo | Conteúdo exigido |
|---|---|
| `exclusive_writer_attestation` | Literal `ALL_EXTERNAL_WRITERS_QUIESCED`, informado pelo operador somente depois de suspender os escritores |
| `exclusive_window_start_utc` | Início real em UTC, ISO8601 terminado em `Z` |
| `exclusive_window_end_utc` | Fim real em UTC, posterior ao início e no máximo 30 minutos depois |

A janela não começa automaticamente após a aprovação do Environment e não se renova. Se a fila ou a revisão humana consumir a janela, o job recusa a execução. Um novo dispatch exige nova declaração e janela; o manifesto continua sujeito à sua validade original de 24 horas, ao commit e ao snapshot aprovados. Não copiar datas de fixtures.

Depois do gate humano `infra-apply-dev`, o script cria um recibo privado da declaração e o vincula a:

- actor incluído na lista aprovada de colaboradores/revisores Dev;
- repositório, workflow exclusivo em `main`, commit, run ID e tentativa;
- conta alvo, bucket exato de state, região e key Dev;
- hashes do manifesto e dos bytes reais de backend.

O recibo registra a declaração do operador; não comprova sozinho ausência de escritores e não substitui a aprovação humana do reparo. Mudança de executor, tentativa, commit, metadata, backend ou janela invalida o recibo.

## Ordem de execução

1. Validar gates financeiros/executivos e backend; obter a sessão OIDC protegida.
2. Baixar a versão exata do manifesto privado e inicializar o backend antes da captura final do state.
3. Validar a declaração/janela e gravar seu recibo privado. Capturar state e VersionId atuais; conferir SHA256, lineage, serial, seis endereços/IDs e flags contra o manifesto aprovado.
4. Antes de **cada** passo, baixar novamente o state e comparar SHA256 e VersionId ao snapshot esperado. No primeiro passo ele é o original aprovado; nos demais é o resultado já verificado do passo anterior. Conferir também progresso, IDs/conteúdo, validade do manifesto e janela.
5. Somente após o pré-check, executar `terraform untaint -lock-timeout=0s` para o próximo endereço exato. O lock nativo permanece habilitado; disputa de lock encerra o comando imediatamente.
6. Baixar o novo state. Exigir novo VersionId, avanço exato de serial e preservação integral do conteúdo, aceitando somente as flags previstas e as normalizações de ordenação documentadas. Registrar evidência sanitizada e usar esse snapshot como expectativa do passo seguinte.

Qualquer erro interrompe os próximos passos. Não há retry automático, rollback, `force-unlock`, `state push`, lock artificial ou escrita no state por código próprio. Um resultado parcial exige reconciliação e nova revisão; não rerodar o manifesto original sobre um serial diferente.

## Limite de atomicidade

O Terraform 1.13.5 não oferece a `untaint` uma precondição de SHA256, serial ou VersionId. Seu lock é adquirido dentro de cada comando; existe um intervalo entre o pré-check externo e essa aquisição. A janela exclusiva humana é necessária para cobrir esse intervalo. Revalidação e `-lock-timeout=0s` reduzem o risco e recusam divergências já observáveis, mas não tornam o lote atômico nem impedem um escritor que desrespeite a janela. A pós-verificação detecta divergências depois da escrita; não reverte automaticamente nada.

Se não for possível assegurar essa exclusividade operacional, não executar o reparo com este procedimento. Uma execução individual também pode atravessar o fim da janela; a pós-verificação recusa o resultado e os passos seguintes param, sem alegar conclusão válida.

## Evidências e testes

O runner mantém recibo, logs e snapshots privados com permissões restritas, removendo-os no encerramento. Somente evidências por allowlist vão ao log do run: horário, run/tentativa, hashes, VersionId, serial, contagem concluída e flags de preservação; nenhum atributo de recurso, output, parâmetro ou state bruto. O coordenador deve salvar esses registros sanitizados no diretório privado da execução. Não publicar artifacts contendo os arquivos privados do runner.

Os testes cobrem recusa antes de invocar o escritor em mudança de bytes/VersionId/serial, progresso indevido, expiração e metadata/janela inválidas. A integração executa seis `untaint` nativos em state **local sintético**, com metadata S3 sintética; não comprova um reparo AWS. O ensaio A1 em nova cópia local do state real permanece uma evidência separada, sem autorizar escrita remota.

Fontes: [untaint 1.13.5, flags e sequência de lock/refresh/persist](https://github.com/hashicorp/terraform/blob/v1.13.5/internal/command/untaint.go), [concorrência de workflows GitHub](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
