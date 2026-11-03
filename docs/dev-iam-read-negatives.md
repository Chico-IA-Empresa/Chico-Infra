# Proposta de provas IAM reais somente leitura

Candidato privado preparado em03/11/2026. Não publicado/commitado, sem APIs AWS/SSM, execução OIDC, dispatch, alteração de grants ou aceites. Fonte usada: `resume-review-20261031-0944/source`, main3fef20f0b7e485fdd13da6e0b9adaa89a735b2b7. O coordenador revisa antes de decidir publicação. `scripts/execution-gates.mjs` é cópia byte-identical de suporte para testes locais; já existe na fonte e não é delta a publicar.

## Escopo fixo

O workflow novo `dev-iam-read-negatives.yml` não reutiliza o build nem instala fixture. Permite selecionar somente `build` ou `status`; cada valor seleciona a role CI dedicada e o gate exige ARN exato. Nenhuma seleção desconhecida vira role status. Reutiliza main exclusiva, `infra-apply-dev`, concorrência `infra-dev`, actions pinadas, verificação de branch/proteções/revisores e financiamento/source antes de OIDC, repetidos após a espera de aprovação manual. As duas execuções precisam de releases próprios para a role selecionada. Não lê TF_VARS_JSON, backend, corpos de state/plan, valoresSecrets ou artifacts públicos.

`scripts/dev-iam-negatives.mjs` executa sete probes fixos de metadata, sempre sa-east-1:

1. HeadObject do state Dev corrente.
2. HeadObject da versão pós-apply QJ9Ge81k1PAdRbVIjRPCzFi_.wapbeBK.
3. HeadObject da versão XfJZwBDuAMKse.wEAioiXxwAEOAc5xHY do saved plan41657962157.
4. ListObjectsV2 no prefix state/lock, MaxKeys1.
5. DescribeKey da CMK Secrets Dev existente.
6. DescribeSecret do SYNTHETIC_TOKEN Dev existente.
7. DescribeLogStreams do grupo Sharedaudit existente, limit1.

Roteiro runtime separado: `fixtures/dev/runtime-iam-read-negatives.py`, cinco probes somente1–4e7. DescribeKey/DescribeSecret próprios são allows legítimos runtime e ficam fora dos negativos. Esse arquivo não é disparado pelo workflow; requer revisão do coordenador de bytes/hash, funding vigente, source/inventário, identidade e payload SSM exato antes de qualquer execução. O script limpa AWSenv/profiles/endpoints de origem, usa cadeia padrão instance-profile e confere STS runtime/instância exatos, sem acessar ou imprimir credenciaisIMDS. Não instalar ou executar por este candidato.

Runtime pode ser entregue por SSM revisado sem commitGit: os bytes do script e reviewJSON precisam existir em diretório temporário exclusivo sob `/run/chico`, ambos root0600/regular/sem symlinks e emtmpfs; o próprio Python verifica essas condições. Criar via mktemp sem overwrite e cleanup somente desse diretório temporário cabe ao wrapper coordenado. Não há wrapper/dispatch neste candidato. O Python recebe `--review /run/chico/UNICO/review.json --review-sha256 HASH_BYTES --source-commit MAIN40 --funding-valid-until ISO_REAL --approved true`; esses argumentos são metadados, nunca oJSON ou valoresSecrets. O schema runtime é igual ao CI, mas proof.role é `runtime` e proof também exige `script_sha256` dos bytes efetivos e `probe_set_sha256` do subsetruntime. Verifica source/hash/financiamento/inventário antes de STS e de cada probe. O source3fef atual confirmado pelo coordenador pode ser usado no roteiro SSM com binding adicional do scriptSHA; não transfere essa validade para um futuro commitCI.

## Release mínimo e pré-condições

Novo secret privado separado: `DEV_IAM_NEGATIVES_REVIEW_JSON`. Não sobrescrever DEV_PROOF_REVIEW_JSON do build/status de fixture. Reutilizar vars de roles `BUILD_ROLE_ARN`/`STATUS_ROLE_ARN`, `DEV_EXECUTION_APPROVED` e validade financeira já governadas. Não fabricar aprovação/datas nem propagar metadata financeira sem receipt real.

Schema exato:

```text
{
  account_id, provision_enabled,
  credit_approval: {account_id, all_charges_covered, shutdown_reserve_confirmed,
                    evidence_reference, reviewed_on, expires_on},
  proof: {scope: "synthetic-dev-infra", operation: "iam-read-negatives",
          role: "build" OU "status", source_commit: COMMIT_MAIN_INTEGRADO,
          probe_set_sha256: HASH_EXPORTADO_PELO_MODULO,
          inventory_reference: REFERENCIA_PRIVADA_REAL,
          inventory_checked_at_utc: ISO_UTC_REAL}
}
```

O hash de dispatch é SHA256 dos bytes exatos do secretJSON; é distinto do probe_set_sha256, SHA256 da lista canônica fixa no módulo. Inventário não pode ser futuro ou ter8h de idade. Verificar com leitura coordenada a existência, versão exata e owner de cada alvo; a metadata atestada pelo gate não faz essa consulta pelo coordenador. Nenhum recurso é criado para testar. Se a versão/source/probes mudar, nova revisão e hashes. Depois de publicar, o source_commit deve ser o SHA de main integrado; não manter main3fef20f por conveniência se a publicação mudou o commit. Validar financiamento/inventário após a espera e novamente antes de cada probe.

Não há JSON real de release/aprovação neste candidato. Os valores booleanos/datas dos testes são fixtures e não podem ser cadastrados como liberação.

## Resultado e proteção da saída

STS deve confirmar conta e assumed-role exatas antes do primeiro acesso. Cada probe usa AWSCLI com stdout/stderr privados somente em memória; nunca imprime rawresponse/stacktrace e não gera rawartifacts. A chamada HEAD não recebe corpo; se uma leitura indevida for permitida, o processo descarta sua resposta e interrompe antes da próxima chamada. Nada é corrigido ou limpo na AWS. Tempo/rede/erro de validação/404/NoSuchKey não contam como AccessDenied.

São aceitos `AccessDenied`/`AccessDeniedException`. HEAD pode retornar erroCLI403+Forbidden; só é classificado assim para HeadObject exato, sob owner/version já verificados. A decoração literal opcional `(reached max retries: 0)` entre `operation` e `: Forbidden` é aceita porque AWS_MAX_ATTEMPTS1 pode acrescentá-la. O diagnóstico real únicoHEAD af48e442-d89e-4d94-ba90-f6c0058f6abf confirmou esse formato, identityVerified/errorCode403/semallowinesperado; o guard-onlyc2777539-f5ec-4e1b-a0e3-05fed14bb84b passou antes. O lote anteriorb67f31ae-0932-4428-8c43-1c6366085074 falhou no parser antigo, sem aceitar negativas nem provar allow. Os receipts históricos não são sobrescritos. Não aceitar403genérico, NetworkError,404, wrongoperation, decoração comoutrocontador ou mensagemextra. Esse403 comprova a negativa efetiva dessa requisição; não identifica qual camada/policy causou a negativa. Um owner errado também poderia causar403, por isso a existência/owner do inventário é pré-condição concreta e não um comentário opcional. Sucesso inesperado ou resultado ambíguo dá exit1 com mensagem genérica, sem dados. Sucesso integral publica apenas role, ids fixos dos probes, classificação, contagem e hash do conjunto.

## Limites do aceite

HEAD corrente/versionado prova somente a leitura correspondente. ListBucket do prefix não comprova Put/Delete de locks. DescribeKey não prova Decrypt; DescribeSecret não prova GetSecretValue. DescribeLogStreams não prova negação de writes. O candidato não chama GetSecretValue/BatchGetSecretValue nem daemonSMA, ECRpush, SSMSendCommand, PassRole, writes de state/lock ou IAM. Não contém EC2DryRun: esse caso ficou fora do conjunto estritamente somente leitura pedido.

Os aceites runtimepush, lockwrite, PassRole, secretvalues e SSMyam/doc/instância/região/tag errados continuam lacunas, sem fakeARNs ou grants novos. Nenhuma negativa de Prod/UAT é declarada com recurso inexistente. Seguir o relatório privado `iam-real-negatives-offline-review.md` corrigido para essas limitações.

## Verificação e futura integração

- Node sintaxe+13testes: schema/contexto/role/source/bytehash, metadata inválida/expirada, allowinesperado interrompe, respostas não autorizativas não passam, probes fixos e subsetruntime, invariantes do workflow, recheck antes de cada probe e formatoSDKHEAD403decorado/controlesnegativos.
- Python13testes: identidade runtime exata, cinco requests mockadas, abort em allow, classificação403/negativas incluindo formatoSDKdecorado/controlesnegativos, limpeza do environment, source/script/bytehash/inventário/financiamento, recheck porprobe e guards de arquivo root0600/tmpfs/regular/sem symlink. Limites distintos: JSON8192bytes e Python32768bytes; teste cobre os bytes reais do script, cada limite exato e limite+1. A revisão anterior usava8192paraambos e recusaria o próprio script; corrigida antes de qualquer dispatch.
- Nenhum teste local usa credenciais ou chama AWS.

Na integração futura, os novos Node tests entram no glob existente `node --test tests/*.test.mjs`. Uma cópia candidata de validate.yml adiciona somente `python tests/runtime-iam-read-negatives.test.py` depois do teste de databasebackup, mantendo o restante dos bytes da fonte canônica. Nenhum checkout foi alterado. Renovar CI completo e revisão do diff antes de merge. Não existe dispensa de gate manual de execução nem autorização de merge/dispatch por esse documento.
