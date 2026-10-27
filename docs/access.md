# AWS-007/008/010/012/034 — segurança e verificações

## State e acesso humano

Bootstrap separado contém bucket com versionamento, SSE-S3, bloqueio público, TLS obrigatório e prevent_destroy. Não entra no state UAT. Backend partial exige bucket real, allowed_account_ids, região fixa e use_lockfile. Mesmo admin pode alterar configuração; prevent_destroy não é retenção imutável. Proteger as permissões reais e testar recuperação de versão. Não usar force-unlock sem comprovar que o processo anterior terminou.

Prova pendente de concorrência: iniciar plan com lock mantido em sessão isolada; segundo plan no mesmo key deve falhar/aguardar; outro scope deve continuar. Registrar request IDs sem state. Após uat-down autorizado, comparar buckets/auditoria/Dev/Prod antes/depois. Não usar destroy geral nem excluir o root UAT para desligar workloads.

Felipe define provedor federado humano, exige MFA e testa recuperação/root MFA. Não criar Organizations nem outras contas. Identity Center account instance não fornece permission sets de acesso à conta. CI não recebe access key permanente.

## OIDC e permissões

Trust limita aud e subject exato repo:ORG/REPO:environment:ENV. Proteger cada Environment no GitHub com branch main/workflow permitido e revisores; subject de Environment não contém branch. A role sozinha não comprova essa proteção. Usar bindings distintos ci-plan-SCOPE / ci-infra-apply-SCOPE e ci-deploy-ENV nos três repos exatos. Criar/importar provedor token.actions.githubusercontent.com depois de conferir se já existe. Não duplicar por ambiente.

Neste preparo, roles OIDC só recebem state do próprio scope e lockfile; não recebem AdministratorAccess, gestão de IAM, secrets de outros scopes ou deploy genérico. As permissões adicionais de plan/apply são pendentes do inventário de ARNs/revisão. Não ampliar para * para fazer pipeline passar. Geradores em scripts/policies.mjs produzem PassRole e execução com inventário explícito para revisão; não aplicam policies. Aplicação runtime não recebe leitura de state.

Workflow PR faz apenas verificações sem credenciais. Plan autenticado é manual, só main e protegido por infra-plan-SCOPE, sem publicação de plano/state. Esta restrição evita executar código de PR não confiável com leitura do state; autorização de revisão dos PRs precisa ser configurada antes de automatizar plan autenticado em PR. Shared e Prod apply exigem gate humano; nenhum apply workflow foi criado. Arquivos efêmeros do runner não são exportados como artefatos. Não imprimir conteúdo de TF_VARS_JSON/plan.

CloudTrail multi-region escreve bucket protegido com SourceArn, validação de logs e versionamento. Segregar chaves/raw snapshots/Secrets de Prod; negar à UAT leitura/decrypt do dado bruto e alteração de IAM/auditoria. Bucket policy de TLS e prevent_destroy não impedem sozinhos administrador. Auditoria de eventos recebidos continua sem prova.

## ECR

Três repos imutáveis com basic scan on push, sem habilitar Inspector pago. Antes de usar, verificar a configuração efetiva de scanning do registry e elegibilidade; não modificar registry compartilhado sem revisão. Promotion gate falha fechado se scan não COMPLETE ou CRITICAL não conhecido/zero.

Lifecycle automática cobre só untagged com 7 dias. Retenção SHA de 30 imagens usa inventário completo: task definitions ativas, manifesto Dev/UAT/Prod, releases de rollback e manifests multiarch. scripts/policies.mjs preserva digests ativos mesmo com mais de 30 novos builds; não executa exclusões. Preview real obrigatório e bloqueio de limpeza se inventário incompleto. Nunca remover tag de release em uso para torná-la untagged.

## Configuração e banco

reports/configuration-inventory.json contém somente nomes candidatos e consumidores observados em 16/10. Reconciliar leituras fora de core/config.py e configurações dinâmicas. Não injetar todas as 266 variáveis automaticamente. Nomes sensíveis são candidatos ao Secrets Manager; SSM String apenas após revisão. Terraform cria contêineres de Secrets, nunca secret_version; população/rotação por operador autorizado fora do estado/logs. Pagamentos e afiliados seguem desligados.

Execution role lê somente ECR, logs e ARNs de secrets/parâmetros necessários no lançamento. Task role lê somente recursos que o código usa; não confundir as duas. Secrets injetados exigem novo lançamento após rotação. Provar com secret de teste: task nova vê versão nova, task antiga não, consumidor indevido recebe AccessDenied. Não publicar o valor no relatório.

RDS master gerenciado, usuários api/workers/migrator distintos, sem importar SUPERUSER da VPS. api/workers sem DDL; migrator possui schema. Autenticação A/B precisa realm em unicidade, JWT aud, refresh/reset/OAuth/exclusão/device e dados privados/cache; não basta header app_id. A migração web precisa decisão explícita, sem atribuir contas automaticamente aos dois apps.

Postgres com sslmode=verify-full e CA RDS confiável. Cache TLS rediss com verificação de CA/hostname e RBAC; não aplicar ssl_cert_reqs=none. Escolher auth compatível com cliente atual antes de injetar REDIS_URL. Nenhum segredo real em binários mobile. Negativas por realm dependem AWS-022.

## Matriz de provas AWS-034

Para cada role Dev/UAT: negar GetSecretValue Prod; S3 Get/Put de state/lock Prod; Describe/Restore raw snapshot + KMS decrypt Prod; iam:PassRole de Prod; ecs:UpdateService Prod; ssm:SendCommand host Prod; PutRolePolicy/AssumeRole/StopLogging/DeleteTrail e exclusão de audit logs. Registrar ação, ARN, role, decisão, request ID e evento CloudTrail sem conteúdo. Esperar AccessDenied; erro de ARN inexistente/credencial inválida não comprova negativa. Testar também o acesso permitido ao próprio scope para evitar falsa prova. Simulação IAM local não substitui chamada real. Exceções administrativas documentadas por Felipe.

Fontes: [GitHub OIDC AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws), [PassRole](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_passrole.html), [CloudTrail bucket policy](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html).
