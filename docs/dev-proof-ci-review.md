# IAM de build e status para as provas Dev

Esta alteração prepara a integração Terraform da proposta privada de 28/10, sobre main `15b8d35ae033c78eece07609560c3895b72aee99`. O reparo remoto de state foi concluído separadamente; não faz parte deste lote. O novo plan Dev que aguarda revisão não autoriza esta mudança Shared. Preparar código/testes não concede autorização de apply, dispatch, ECR push ou SSM.

## Integração preparada

`envs/shared/dev-proof-ci.tf` acrescenta `dev_proof_ci=null` por padrão. Quando provisionamento Shared e opt-in estiverem presentes, cria exatamente duas managed policies em `/chico/shared/`, com dois attachments às roles `ci-build-dev` e `ci-deploy-dev`. Os documentos são iguais aos candidatos existentes de `scripts/dev-permissions.mjs`: build nos três ECR da própria conta, status no documento `chico-dev-fixture-status` e na instância exata, com tags Dev/projeto. Não altera policies/boundaries de plan/apply/runtime/flow, estado, chaves, secrets ou o documento SSM.

As duas roles continuam sendo gerenciadas pelo módulo OIDC existente. Para criá-las é necessário adicionar explicitamente os dois bindings abaixo, preservando os bindings plan/apply atuais e todos os outros inputs privados. Com roles ainda ausentes, o delta esperado é seis criações: duas roles, duas policies e dois attachments. Isso é expectativa de código, não um saved plan autenticado.

```hcl
# Fragmento a mesclar nos inputs privados somente após reconciliar a instância.
dev_proof_ci = {
  instance_id      = "i-ID-REAL-CONFERIDO-PRIVADAMENTE"
  review_reference = "referencia-nao-secreta-da-revisao-tecnica"
}
# Acrescentar ao map oidc_bindings existente, sem substituí-lo:
ci-build-dev = {
  scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra"
  environment = "infra-apply-dev", writable_state = false, state_access = false
}
ci-deploy-dev = {
  scope = "dev", repository = "Chico-IA-Empresa/Chico-Infra"
  environment = "infra-apply-dev", writable_state = false, state_access = false
}
```

O exemplo contém placeholder deliberadamente inválido; não é tfvars utilizável nem aprovação. `review_reference` registra revisão técnica, não inventa um novo gate humano. Preconditions exigem scope/repo/Environment exatos e nenhum acesso a state; subjects customizados divergentes são recusados neste lote. O módulo OIDC mantém `aud=sts.amazonaws.com` e subject exato. `writable_state=false` isoladamente não basta: o novo input também exige `state_access=false`.

O output `dev_proof_ci_review` expõe policies/ARNs e contexto técnico para a revisão privada; não configura variáveis GitHub. Input null deixa o output null e não cria grants. A criação de roles continua subordinada ao map de bindings explícito do módulo existente; por isso não adicionar os bindings separadamente por engano durante um apply anterior.

## Limitações e riscos que precisam constar da revisão

- `ssm:GetCommandInvocation` exige Resource `*`; a condição limita a São Paulo. Essa ação também retorna saída stdout/stderr de outros comandos cujo CommandId/InstanceId o principal conheça na região. **Não há isolamento IAM por comando/instância para essa leitura nesta policy.** Manter logs/payloads SSM sem segredos e a role atrás do Environment protegido; o revisor Shared precisa considerar essa capacidade expressamente. Não usar isso como identidade para ler comandos privados de operações distintas. O limite não pode ser corrigido com ARN fictício ou condição não suportada.
- SendCommand limita a emissão ao único ARN de documento e à instância/tag, mas o ARN não fixa conteúdo/versão. Na execução futura usar `--document-version` numérico, `--document-hash` SHA256 e `--document-hash-type Sha256`, previamente conferidos com a identidade de inventário. Não acrescentar GetDocument à role para contornar o pin. A API recusa conteúdo divergente. O documento Terraform atual não recebe comandos como parâmetro; revisar seu conteúdo/version/hash reais antes da execução, incluindo versões antigas que não devem ser selecionadas.
- O status fixo confere serviços Docker/SSM e lista serviços da fixture. Não prova saúde do banco real, configurações, backup, restore nem um deploy de aplicação. A role chamada `ci-deploy-dev` recebe somente esse status neste lote; não recebe shell arbitrário, Session Manager, instalação, migrações ou ativação de escritores.
- ECR é compartilhado entre ambientes; a permissão PutImage pode publicar em qualquer tag ainda livre dos três repositórios. Não há isolamento IAM por prefixo `fixture-` nesta proposta. Tags imutáveis impedem sobrescrita, mas não fazem da role uma identidade limitada exclusivamente a nomes de fixture. O workflow futuro deve construir apenas o Dockerfile sintético revisado, com base ARM64 por digest e tag própria, sem imagens/dados de negócio. GetAuthorizationToken é global e não concede por si só push em outros repos; GetRegistryScanningConfiguration também exige Resource `*`.
- Reutilizar `infra-apply-dev` é apenas a proposta mínima para estas provas. O subject OIDC limita repo/Environment, não o arquivo YAML específico. Aprovação manual, main exclusiva, revisores autorizados e ausência de bypass devem ser reconferidos antes de solicitar OIDC. Não usar a role infra-apply como fallback de build/status. Bindings separados por Environment exigiriam outro delta coordenado.

## Próximos passos concretos do coordenador

1. Preservar main e bundle Dev vigente durante seu gate. Uma integração de código muda o commit que vincula futuros plans; não reutilizar plan antigo sob outro commit/inputs. Nenhum apply Shared está autorizado por aprovações anteriores.
2. Revalidar inventário real: roles eventualmente existentes e ownership, três ECR imutáveis/scan BASIC, instância/perfil/tags, subject real do repo e conteúdo/version/hash do documento fixo. Não importar ou anexar a recurso estranho por suposição.
3. Gerar o novo saved plan Shared privado, com inputs atuais acrescidos do opt-in e bindings, cobertura vigente e nenhum outro delta. Comparar seus dois JSONs resolvidos aos geradores existentes/proposta e submeter ao Access Analyzer. Simular contextos completos: build PutImage próprio/foreign, runtime push negado, SendCommand requer documento **e** instância autorizados, tags ausentes/erradas negadas, documento AWS-RunShellScript e instância alheia negados, região errada na leitura de invocation negada, state/lock/review bucket/secrets/KMS/IAM negados. O teste positivo do simulador não substitui execução real.
4. Preparar revisão humana específica desse Shared saved plan, hash, bindings e limitações acima. Só então aplicar pelo coordenador. Inputs defaults deste patch continuam desligados; não há mutação de Environment ou cadastro de role ARN aqui.
5. Após apply, configurar ARNs separados build/status e preparar workflow manual protegido. Preflight sem OIDC deve usar as verificações de governança existentes, main exclusiva, revisão/funding vigente e escopo sintético. Job autenticado usa Environment protegido e somente a role específica; nunca disponibiliza backend/tfvars/state ao build/status. Fixar documento/version/hash/instância no status; polling limitado, terminalidade explícita, saída pública sanitizada. A role de status não pode instalar a fixture ausente; isso depende do operador/host convergido.
6. Executar provas reais positivas/negativas e preservar request IDs, digests/scan e CloudTrail sem tokens/plaintext. Build ARM64→push→scan conhecido→pull por digest no host continua pendente. As negativas devem usar recursos reais existentes; ARN inventado não prova isolamento. Nenhum workflow AWS foi criado/disparado por este patch.

## Validação local

Terraform 1.13.5/provider 6.69.1, `init -backend=false -lockfile=readonly`, `validate`, `test` Shared e OIDC, `fmt -check`, Node dos geradores e gate Checkov Shared. Todos os dados dos testes são sintéticos. As novas assertions verificam políticas inteiras, roles/attachments, defaults, gating, foreign repo/scope/Environment/subject, binding ausente, ID wildcard e state read/write negados. Os comandos CI existentes já executam os testes Terraform das duas raízes/módulos; não é necessário acrescentar um workflow de escrita.

Fontes: [ECR Service Authorization Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecr.html), [SSM Service Authorization Reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ssm.html), [SendCommand e document hash/version](https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_SendCommand.html), [GetCommandInvocation e saídas](https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_GetCommandInvocation.html).
