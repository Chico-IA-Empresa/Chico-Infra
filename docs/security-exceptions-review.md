# Revisão técnica de segurança — 27/10/2026

O gate desta fase cobre `bootstrap`, `envs/shared` e `envs/dev`, incluindo os módulos locais referenciados. O scanner completo do repositório continua executado para inventariar também os blueprints UAT/Prod. O aceite destes ambientes permanece fora da fase Dev.

Não há supressões Checkov, baseline automático nem soft-fail global. O scan bruto continua registrando as falhas. `security/dev-exceptions.json` contém 38 decisões específicas por scope, check e recurso, revisadas tecnicamente nesta implementação, subordinadas ao PRD. Esta revisão não representa aprovação humana de um plan nem aceite operacional AWS.

Na preparação da fase 1, dez decisões foram acrescentadas para review storage e os sinks próprios de planos/backup Dev: SSE-S3 compatível com o workflow/log delivery, ausência de replicação inter-regional não contratada, ausência de notificação por objeto não requerida e ausência de logging recursivo no sink Dev. Cada entrada identifica seu recurso/hash; não há exceção global. Os quatro arquivos alterados com decisões anteriores foram revistos individualmente: validação/prefixo do sink, CPU Standard/capacidade do host, limpeza ECR opt-in e prefixo/retention do banco real. Grants de backup não dão acesso à origem legada. CMKs/policies de serviço e entrega real ainda exigem revisão do plan e prova AWS.

Cada decisão inclui justificativa, controle compensatório, referência, revisor técnico, revisão em 27/10/2026, expiração em 25/01/2027 e hash SHA256 do arquivo de origem (texto normalizado para LF). Mudança no código coberto, achado novo, supressão no scanner, parsing incompleto, entrada duplicada, decisão obsoleta ou vencida bloqueia o gate. Revisões posteriores devem reavaliar a decisão; não atualizar o hash automaticamente para obter verde.

| Controle | Decisão e verificação |
|---|---|
| CKV_AWS_338 | Logs mantêm 30 dias do PRD R09. Criptografia e retenção constam do código; comprovação de entrega e cotação continuam na AWS. |
| CKV_AWS_126 | CPU/status usam coleta padrão de cinco minutos. Memória, disco e frescor de backup têm coletores e timers próprios. Detailed monitoring pago não foi acrescentado. |
| CKV_AWS_260 | Porta 80 serve ao ACME/redirect do edge, conforme R08. Somente 80/443 públicas; redirect real ainda deve ser demonstrado. |
| CKV_AWS_136 | Registry usa AES256, tags imutáveis e digests. CMK para ECR não foi exigida; keys de secrets e CloudWatch permanecem CMK. |
| CKV2_AWS_34 | Parameter Store String é configuração não secreta revisada. Credenciais seguem em Secrets Manager; Terraform não cria secret versions. |
| CKV2_AWS_57 | Rotação sintética manual é observada pelo consumidor; Lambda paga de rotação não integra o baseline. Testes locais cobrem atualização/rejeição; prova AWS permanece obrigatória. |
| CKV2_AWS_62 | Notificar cada objeto não é requisito do PRD. State/auditoria têm access logs, backup tem checksum/frescor; sinks possuem policy de origem estrita. |
| CKV2_AWS_61 | Expiração automática de state/auditoria poderia destruir evidências/recuperação. Versionamento, proteção de destruição e encerramento explícito são preservados; retenção precisa cobertura financeira. |
| CKV_AWS_18 | Exceção somente nos buckets de destino de access logs. Logging no próprio sink causaria recursão; origens possuem delivery e destinos têm conta/origem/prefixo restritos. |
| CKV_AWS_145 | SSE-S3 atende ao contrato de state, backup sintético e sinks. TLS, PAB, versionamento e IAM restrito complementam o controle. |
| CKV_AWS_144 | Uma conta/região é baseline aprovado. Restore e recuperação isolada são gates AWS; não há replicação inter-regional contratada. |
| CKV2_AWS_5 | Falso positivo na ligação modular do SG Dev. `compute.tf` repassa o SG de `module.network` ao `module.dev_box`, cuja EC2 recebe explicitamente esse SG. Testes verificam os dois lados; portas reais permanecem gate AWS. |

As falhas anteriores de access logging de state/auditoria e CloudTrail→CloudWatch/SNS foram tratadas em código. Foram acrescentados destinos privados exclusivos, retenção exigida por input, role de delivery e policy SNS limitada ao trail. Nenhum recurso foi criado; policies efetivas de KMS, custo e recebimento ainda precisam validação AWS.

As exceções não dão autorização para apply. A identidade conectada encontrada em 27/10 era root; esta rodada só fez leituras/validação de policy. Primeiro executor e CI continuam exigindo funções temporárias, revisão financeira, revisão shared e evidências reais.

Referências: [PRD da fase](contracts/dev-infra-prd.md), [CloudTrail/SNS](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-permissions-for-sns-notifications.html), [permissões CI](dev-ci-permissions.md).
