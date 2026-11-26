# Publicação de imagens do Chico-Back por OIDC

`envs/shared/backend-release-ci.tf` dá ao workflow `release-dev.yml` do Chico-Back
uma identidade própria que **só publica imagens**: push e leitura em
`chico-api` e `chico-workers`, mais as duas ações que a AWS só aceita com
Resource `*` (`ecr:GetAuthorizationToken` e `ecr:GetRegistryScanningConfiguration`).
Não há state, SSM, ECS, segredos nem `chico-frontend`. Deploy é outra
identidade, decidida depois.

## Como ligar (inputs privados do Shared)

```hcl
backend_release_ci = { review_reference = "referencia-nao-secreta-da-revisao" }
# Acrescentar ao map oidc_bindings existente, sem substituí-lo:
ci-build-backend-dev = {
  scope = "dev", repository = "Chico-IA-Empresa/Chico-Back"
  environment = "release-dev", writable_state = false, state_access = false
}
```

Delta esperado: três criações (role, policy, attachment). Precondition recusa
outro repositório, outro Environment, scope diferente de `dev`, acesso a state
e subject customizado divergente de
`repo:Chico-IA-Empresa/Chico-Back:environment:release-dev`.

## Do lado do Chico-Back

1. Criar o Environment `release-dev`, restrito à branch `main`.
2. Variáveis de repositório (o `if` do job não enxerga as de Environment):
   `AWS_RELEASE_ROLE_ARN` (output `backend_release_ci_review.role_arn`) e
   `ECR_REGISTRY`.
3. Sem `AWS_RELEASE_ROLE_ARN` o job de release é pulado.

## Limites

- `PutImage` vale para qualquer tag livre dos dois repositórios; tags imutáveis
  impedem sobrescrita, mas não restringem o nome. O workflow usa o SHA do commit.
- O subject limita repositório e Environment, não o arquivo YAML. A proteção do
  Environment (só `main`) é o que impede uma branch qualquer de publicar.

## Chico-Front

`envs/shared/frontend-release-ci.tf` é o par do front: role
`ci-build-frontend-dev`, subject
`repo:Chico-IA-Empresa/Chico-Front:environment:release-dev`, push e leitura só
em `chico-frontend`. Liga com `frontend_release_ci = { review_reference = "..." }`
e o binding abaixo; mesmas preconditions e mesmos limites.

```hcl
ci-build-frontend-dev = {
  scope = "dev", repository = "Chico-IA-Empresa/Chico-Front"
  environment = "release-dev", writable_state = false, state_access = false
}
```

## Adoção dos recursos criados à mão (2026-11-26)

Os 6 recursos (2 roles, 2 policies, 2 attachments) foram criados pela API antes
do apply do Shared, iguais ao código. `envs/shared/release-ci-imports.tf` tem
blocos `import` que os adotam no primeiro plan com os opt-ins ligados: o plan
deve mostrar **6 to import, 0 to add, 0 to change** nesses recursos. Nenhum
`terraform import` manual é necessário. Numa conta onde eles não existem, usar
`release_ci_import_existing = false`.
