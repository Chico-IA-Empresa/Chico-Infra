# Provas sintéticas protegidas de ECR e status

`dev-synthetic-proof.yml` oferece somente `workflow_dispatch` em main, operações `build` ou `status`. O preflight não recebe OIDC. O job autenticado exige aprovação manual do Environment `infra-apply-dev` e repete as verificações de governança, main atual, source binding e validade financeira antes de solicitar credenciais. Autoaprovação Dev continua sendo a exceção registrada, sem remover o gate manual ou permitir bypass administrativo.

Build usa exclusivamente a role `ci-build-dev` e o Dockerfile sintético em `fixtures/dev`, nos três ECR compartilhados já revisados. Status usa exclusivamente `ci-deploy-dev` para o documento fixo e a instância revisados; nenhuma role infra-apply/root substitui essas identidades. O workflow não lê backend, tfvars/state, Secrets Manager ou dados reais, não instala fixture e não ativa aplicação de negócio.

## Preparação privada pelo coordenador

Depois de merge e checks do main, preparar `DEV_PROOF_REVIEW_JSON` fora do repositório, vinculando seus bytes exatos ao input `review_sha256`. Cadastrar somente o JSON privado mínimo em secret GitHub; jamais usar `TF_VARS_JSON` ou o relatório financeiro completo. A preparação não fabrica aprovação, datas ou cobertura. Reutilizar somente metadados de revisão humana e financeira ainda vigentes:

- `account_id`, `provision_enabled`;
- `credit_approval`: `account_id`, `all_charges_covered`, `shutdown_reserve_confirmed`, `evidence_reference`, `reviewed_on`, `expires_on`;
- `proof`: `scope=synthetic-dev-infra`, `operation` e `source_commit` exato, mais os campos específicos abaixo.

Nenhum valor financeiro, senha, token ou secret operacional pertence a esse JSON. Campos extras são recusados. O gate existente `validateExecutionGates` também exige `DEV_EXECUTION_APPROVED=true` e `FUNDING_REVIEW_VALID_UNTIL` futura. Após espera no Environment, tudo é validado novamente; uma liberação expirada não ganha validade pelo dispatch ou pela aprovação manual.

As vars `BUILD_ROLE_ARN` e `STATUS_ROLE_ARN` devem ser os ARNs exatos das roles aplicadas pelo Shared; qualquer alternativa é recusada. `GH_GOVERNANCE_READ_TOKEN` é o credential read-only de governança já existente, usado somente nos steps de verificação GitHub, sem expor seu conteúdo. Este patch não cadastra secrets/vars, muda proteções ou dispara provas.

## Build ARM64

O JSON privado deve incluir `base_platform=linux/arm64` e `base_image=REGISTRY/REPOSITORY@sha256:DIGEST` efetivamente descoberto/revisado. Não há digest de exemplo utilizável nem tag mutável aceita. Antes de AWS, um runner ARM64 nativo baixa a base, confere arquitetura/sistema e ausência de ONBUILD, e testa `/bin/sh` em container sem rede, somente leitura e sem capabilities. O runner `ubuntu-24.04-arm` consta na [referência oficial GitHub](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).

Depois de OIDC, STS deve confirmar a role build exata. O script existente publica apenas o Dockerfile sintético nos três repositórios com tag `fixture-COMMIT40`, exige registry BASIC/repos IMMUTABLE e scan `COMPLETE` com estrutura conhecida e zero CRITICAL. Digests aceitos são a única saída de build; logs de Docker/scan e config de login ficam temporários e são removidos, sem artifacts públicos. Uma tag já publicada não pode ser sobrescrita: não apagar imagens para rerun. Após falha parcial, registrar quais digests existem e preparar uma retomada revisada; não presumir que novo dispatch é idempotente.

O build/push/scan não comprova pull/run sob runtime, negativas IAM reais ou aceites da fixture. Esses testes são passos posteriores coordenados. Ausência de CRITICAL também não encerra a revisão de outros achados exigida pelo plano.

## Status fixo

Somente após instalar e verificar a fixture local, preparar novo JSON com `fixture_installed=true` e os campos `instance_id`, `document_name`, `document_version`, `document_sha256` iguais ao alvo compilado em `dev-proof-gates.mjs`. O coordenador deve conferir novamente versão/hash reais antes de liberar o JSON. Nenhum comando ou parâmetro shell vem do dispatch/JSON.

O helper confere STS da role status, envia documento numericamente versionado e hash SHA256, com instância exata e CloudWatch output explícito. Faz polling limitado, aceita apenas ausência inicial transitória da invocation e estados não terminais conhecidos. Só passa com Success/código0/sem stderr e os serviços `postgres`, `static`, `proxy-local` em execução, além de Docker/SSM ativos. Não publica stdout/stderr; a saída sanitizada contém CommandId e resultado. Isso não verifica saúde/dados do banco real, configuração, backup/restore ou entrega CloudWatch/SNS.

## Validação e limites

Testes locais cobrem metadata mínima, hash/source/escopo/roles, gates expirados ou incompletos, base por digest/plataforma, pin SSM, polling, falhas/saída parcial e ausência de OIDC/state no preflight. Usam somente dados sintéticos. CI normal não executa esse workflow manual nem acessa AWS.

As limitações aprovadas do Shared continuam: build pode publicar qualquer tag livre dos três repos; GetCommandInvocation pode ler outras saídas conhecidas na região; trust prende repo/Environment, dependendo de main exclusiva nas proteções GitHub. O workflow restringe sua própria execução; não reduz essas capacidades IAM. A correção de descoberta dos logs SSM possui seus próprios planos/gates Shared e Dev, e entrega automática ainda precisa ser comprovada.
