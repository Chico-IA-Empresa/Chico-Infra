# Refresh Dev: completar leituras de metadata do provider fixado

O coordenador informou que o plan Dev run `40924319319` falhou no refresh após a revisão humana. Os eventos CloudTrail de 29/10/2026, 17:59:19–20 UTC, identificaram negativa de `s3:GetBucketCORS` em ambos os buckets Dev e de `ec2:DescribeNetworkAcls` sob `ci-plan-dev`. Esta preparação não consultou nem alterou AWS/state. O diagnóstico abaixo distingue os erros relatados da revisão estática independente do provider AWS **6.69.1**.

## Causa e leituras seguintes já previsíveis

`resourceBucketRead` consulta os campos de configuração antigos de `aws_s3_bucket` mesmo quando não foram declarados no HCL ou são gerenciados por recursos separados. Ausência de configuração pode ser tratada como estado vazio, mas AccessDenied nessas consultas termina a leitura com erro. Portanto, corrigir só CORS deixaria as próximas leituras de Website, Accelerate e Replication sem grant. Isso não justifica habilitar esses serviços ou acrescentar suas APIs de escrita.

| Caminho do provider | Ação IAM | Situação anterior |
|---|---|---|
| `findBucket` / região por HeadBucket | `s3:ListBucket` | Já presente nos dois buckets próprios |
| Policy e ACL | `s3:GetBucketPolicy`, `s3:GetBucketAcl` | Já presentes |
| CORS | `s3:GetBucketCORS` | Negativa relatada; acrescentada |
| Website | `s3:GetBucketWebsite` | Próxima lacuna estática; acrescentada |
| Versioning | `s3:GetBucketVersioning` | Já presente |
| Accelerate | `s3:GetAccelerateConfiguration` | Lacuna estática; acrescentada |
| Request payment, logging e lifecycle | `s3:GetBucketRequestPayment`, `s3:GetBucketLogging`, `s3:GetLifecycleConfiguration` | Já presentes |
| Replication | `s3:GetReplicationConfiguration` | Lacuna estática; acrescentada |
| Encryption e object lock | `s3:GetEncryptionConfiguration`, `s3:GetBucketObjectLockConfiguration` | Já presentes |
| Interceptor de tags | `s3:GetBucketTagging` | Já presente; fallback explícito após negativa de ListTagsForResource |

O interceptor tenta ListTagsForResource e aceita fallback a GetBucketTagging para a negativa específica documentada no código. Não acrescentar ListTagsForResource/ABAC por reflexo. Não há consulta de objeto nesse caminho. Public access block/ownership controls e outras leituras dos recursos S3 separados já estão em `BackupConfiguration`; não são removidas.

No VPC, `resourceVPCRead` usa DescribeVpcs e `resourceVPCFlatten` usa DescribeVpcAttribute para três atributos (DNS hostnames, DNS support e network address usage metrics), todos já cobertos. Depois consulta NACL default por DescribeNetworkAcls, route table principal por DescribeRouteTables e SG default por DescribeSecurityGroups. Somente DescribeNetworkAcls faltava. **A negativa da NACL é tratada como warning nessa função, não como diagnóstico fatal**; não atribuir a ela, sem logs privados, a causa terminal do run. Ela ainda precisa ser corrigida para leitura completa do VPC. Tags vêm da resposta VPC; DescribeTags já existe no bloco de metadata.

## Delta mínimo preparado

- `BackupConfiguration`: acrescenta exatamente GetBucketCORS, GetBucketWebsite, GetAccelerateConfiguration e GetReplicationConfiguration, somente nos ARNs dos dois buckets próprios informados pelo inventário. Sem wildcard novo, objeto, bucket legado, state ou review bucket.
- `Ec2Metadata`: acrescenta exatamente DescribeNetworkAcls ao bloco existente Resource `*`, mantendo `aws:RequestedRegion=sa-east-1`. A API não oferece resource-level scoping; o filtro de VPC do provider não é uma barreira IAM. Essa leitura permite metadata de NACLs da região, nunca criação/alteração de regras ou associação.
- Plan e apply reutilizam as mesmas leituras. Writes, grants KMS/secrets/state, boundaries runtime/Flow Logs e inputs permanecem iguais. O split das managed policies deve ser regenerado e revisado, pois acréscimos de caracteres podem deslocar a distribuição de statements sem mudar seu conteúdo.

Os testes novos falharam antes da correção com os nomes GetBucketCORS e DescribeNetworkAcls, e passam depois. Cobrem o caminho S3 completo acima, os dois ARNs exatos, metadata regional EC2, ausência de writes CORS/Website/Acceleration/Replication/NACL e ausência dessas novas ações nas duas boundaries. Os testes existentes preservam o contrato de state, KMS, secrets, writes e quotas/divisão sem perda de statements.

Uma comparação offline adicional com o gerador de main `15b8d35` removeu somente as cinco novas ações dos candidatos e obteve igualdade integral com os JSONs anteriores de plan/apply. As duas boundaries já eram idênticas sem transformação. Com inventário sintético de quatro CMKs e nomes de buckets do mesmo comprimento dos reais, plan passou de 5304 para 5436 caracteres; apply continuou em três partes (5601/5547/5319), todas abaixo de 6144. Esses números não substituem a geração com os metadados privados reais.

## Próximo lote e limites da prova

Gerar novamente os candidatos privados usando inventário real atualizado, comparar semanticamente contra os candidatos aplicados, conferir tamanho/split/attachments, validar no Access Analyzer e simular contextos completos. Espera-se somente adicionar as cinco leituras nos documentos de plan/apply, sem alteração nas duas boundaries; quantidades exatas de updates dependem do split real. Esta revisão não prova grants efetivos nem todos os caminhos de todos os recursos do provider.

Shared precisa de **novo saved plan privado e aprovação humana específica**, com hash/inputs/commit atuais. Os quatro updates aplicados anteriormente não autorizam este delta. O run Dev falho não deve ser reaplicado/reexecutado para contornar a negativa; após a alteração IAM aprovada, gerar novo plan Dev protegido com commit/inputs/state atuais. Não fazer reparo de state, recriar buckets/VPC ou afrouxar locks/gates. DNS/TLS público e aplicação de negócio continuam fora desta correção.

O coordenador prepara separadamente preservação de diagnóstico privado de **falha do passo plan**, usando apenas o PutObject já existente em `dev/commit/run/diagnostics/`. O conteúdo pode conter inputs privados e não deve aparecer em Actions/chat ou artifact público; só chave/VersionId são receipts. Esse mecanismo não preserva falhas de init nem de apply e não muda a identidade/grants para tentar fazê-lo. Não tratar ausência de receipt como prova de ausência de erro ou de sucesso do plan.

## Fontes primárias e versão auditada

- [bucket.go, resourceBucketRead e helpers](https://github.com/hashicorp/terraform-provider-aws/blob/v6.69.1/internal/service/s3/bucket.go#L865-L1233), SHA256 `96b8a602b95d9737792a29a1e153b71f95944a777cceef0b23d813002ff5e193`.
- [s3/tags.go e fallback de tags](https://github.com/hashicorp/terraform-provider-aws/blob/v6.69.1/internal/service/s3/tags.go#L168-L187), SHA256 `6105935e9941920c0dc8fb9d6a8840b315d38a3f83387ad7fa81414f61cc0cf0`.
- [vpc_.go, Read e Flatten](https://github.com/hashicorp/terraform-provider-aws/blob/v6.69.1/internal/service/ec2/vpc_.go#L262-L309), SHA256 `3871f541c15839bcb0d4dd8098887bc2b9816ac0eb753399c79d3f65d3ad6727`.
- [ec2/find.go, helpers do VPC/NACL](https://github.com/hashicorp/terraform-provider-aws/blob/v6.69.1/internal/service/ec2/find.go#L1685-L2015), SHA256 `d8a9427a50d2f9289ba7fb4d98c1fb714dee7f7b95f8f593d8cc785eacff9e4f`.
- [S3: API→ação IAM e recursos](https://docs.aws.amazon.com/service-authorization/latest/reference/list_s3.html) e [EC2: DescribeNetworkAcls](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ec2.html).

As cinco ações e seus tipos de recurso foram também conferidos no endpoint programático oficial `servicereference.us-east-1.amazonaws.com/v1/{service}/{service}.json`. Fonte Go pública foi lida para auditar o provider; não houve execução desse código nem inferência de policy de aplicação SDK. Os testes usam somente metadados sintéticos e não substituem um refresh autenticado.
