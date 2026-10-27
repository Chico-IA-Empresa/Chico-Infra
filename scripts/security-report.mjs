import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
const base = fileURLToPath(new URL('../', import.meta.url));
const report = JSON.parse(readFileSync(`${base}/reports/checkov.json`, 'utf8'));
const rationale = {
  CKV_AWS_252: 'Integração SNS CloudTrail não está preparada; canal de alertas real/ARN e financiamento são AWS-008/009/028.',
  CKV_AWS_338: 'Diferença do PRD: retenção CloudWatch30 dias, não 1 ano; export/retention S3 e custo precisam AWS-028.',
  CKV_AWS_118: 'Enhanced monitoring/role/intervalo não aprovados nem cotados. Concluir escolha com AWS-009/025/031; sem alegar monitoramento operacional.',
  CKV_AWS_161: 'PRD usa master gerenciado e usuários SQL separados, não escolheu IAM DB auth. Revisar credenciais/rotação/TLS antes de ativar AWS-012/025.',
  CKV_AWS_353: 'Configuração condicional Prod/UAT precisa prova efetiva; Standard/PI7 preparado em Prod, desligado UAT conforme PRD. Validar suporte e preço AWS-025/031.',
  CKV_AWS_157: 'Single-AZ é baseline aprovado AWS-005; Multi-AZ permanece decisão/custo específico, não habilitar para satisfazer scanner.',
  CKV_AWS_133: 'UAT descartável sem backup é PRD; Prod configura PITR14, final snapshot e deletion protection. Conferir ambos nos plans reais.',
  CKV_AWS_126: 'Dev sem detailed monitoring pago; avaliar custos e sinais necessários AWS-009/015 antes de ativar.',
  CKV_AWS_260: 'Porta80 somente no edge para redirect/ACME conforme PRD; ALB/proxy ainda precisa demonstrar redirect e ausência de conteúdo sensível em HTTP AWS-015/026.',
  CKV_AWS_136: 'ECR AES256 já criptografa em repouso. CMK ECR não exigida no PRD; cotar se decisão de gestão de chave mudar. Não confundir com dados brutos/sanitizados, que exigem segregação.',
  CKV_AWS_297: 'Schedules sem payload secreto, desabilitados, criptografia AWS-managed; CMK Scheduler é opção de controle/custo a revisar AWS-009/027. Nenhuma chave criada.',
  CKV_AWS_332: 'Fargate1.4.0 fixado explicitamente. Verificar suporte/região/patch corrente antes do ensaio; não inferir versão do serviço em execução.',
  CKV_AWS_333: 'IP público para egress direto é decisão do PRD sem NAT. Inbound só SG do ALB. Conectividade e isolamento precisam prova real AWS-011/026.',
  CKV2_AWS_34: 'SSM String é somente config não secreta revisada; credenciais em Secrets Manager CMK. Inventário candidato não autoriza injetar automaticamente AWS-012.',
  CKV2_AWS_62: 'Notificações de buckets não implementadas nem exigidas por si no PRD; definir detecção de alterações e custo na auditoria AWS-008/028.',
  CKV2_AWS_57: 'Rotação manual de provedores é PRD; master RDS gerenciado. Rotação/novo lançamento com segredo de teste precisa prova AWS-012. Não criar Lambda paga silenciosamente.',
  CKV2_AWS_5: 'Fundação de SGs criada separada de workloads/blueprints ainda não integrados; não comprova recurso implantado nem rede segura. Validar associações nos plans/instâncias AWS-011/015/026/027.',
  CKV2_AWS_11: 'VPC Flow Logs não preparados; avaliar retenção, destino/role e cobertura de custos com AWS-008/009/011/028 antes de provisionar.',
  CKV_AWS_18: 'Access logging dos buckets ainda não preparado; definir destino/retention e custos AWS-008/009. TLS/CMK/versionamento não substituem esse controle.',
  CKV2_AWS_50: 'Valkey de nó único é baseline do PRD. Falha e reconstrução precisam ensaio AWS-025/030; Multi-AZ não autorizado automaticamente.',
  CKV2_AWS_61: 'State e auditoria preservados sem expiração automática para evitar perda prematura. Retenção e reserva financeira/fechamento ainda precisam revisão AWS-007/008/009.',
  CKV_AWS_144: 'Uma conta/região sa-east-1 é decisão aprovada. Sem replicação entre regiões contratada; validar recuperação dos backups/state existentes AWS-007/035.',
  CKV2_AWS_10: 'CloudTrail→CloudWatch Logs não implementado; auditoria S3 multi-region preparada. Integração de alarmes/logs depende AWS-008/028 e cobertura de custo.',
  CKV_AWS_145: 'State SSE-S3 AES256 conforme PRD, não CMK. IAM de state/lock exato e teste de lock continuam AWS-007/034; não confundir com chave de Prod/raw snapshot.',
};
const grouped = new Map();
for (const check of report.results.failed_checks) {
  if (!rationale[check.check_id]) throw new Error(`Untreated finding: ${check.check_id}`);
  const group = grouped.get(check.check_id) ?? { name: check.check_name, resources: new Set() };
  group.resources.add(check.resource); grouped.set(check.check_id, group);
}
writeFileSync(`${base}/docs/security-review.md`, `# Revisão local de segurança — 18/10/2026

Intenção: preparar fundação Terraform revisável, com recursos desligados e gates financeiros/operacionais, preservando PRD v3 e AWS-005. Não é aprovação para produção.

Checkov ${report.summary.checkov_version}: ${report.summary.passed} checks passaram, ${report.summary.failed} achados, ${report.summary.skipped} suprimidos, ${report.summary.parsing_errors} erros de parsing. São resultados de código estático, com repetições por recurso, não contagem de vulnerabilidades exploráveis. **O gate Checkov permanece reprovado e o workflow de segurança deve bloquear merge enquanto a triagem abaixo não for resolvida ou documentada por exceção específica revisada.** Nenhuma supressão global foi adicionada para obter verde.

Foram corrigidos descrições de SG, EBS optimized, CMK de auditoria/secrets/logs/PostgreSQL e permissões KMS por ARN/serviço. Revisão funcional local: states/lockfiles separados, sem grants IAM genéricos para Prod, CI sem apply, schedules desligados, imagens por digest, proteção de releases antigas e preservação de Single-AZ/sem NAT. Blueprints web/schedules ainda não estão integrados às roots; roles adicionais e keys precisam inventário/policy reais.

| Check | Tratamento / pendência |
|---|---|
${[...grouped].map(([id, g]) => `| ${id}: ${g.name} (${g.resources.size} recursos distintos) | ${rationale[id]} |`).join('\n')}

As key policies reais devem conceder CloudTrail GenerateDataKey/DescribeKey com SourceArn/encryption context, CloudWatch Logs com principal regional/contexto do log group e RDS/Secrets com direitos de serviço e consumidores mínimos. Não usar chave Prod para UAT nem conceder decrypt raw a UAT. Esta rodada exige ARNs explícitos e não cria chaves/policies com conta inventada.

Limites da revisão: sem AWS autenticada, GitHub Environments, Docker Linux, app realms/modelo final, tráfego, restore ou teste negativo real. A revisão não declara AWS-006/007/008/009/010/011/012/015/024/025/026/027/031/034/035 concluídas. Antes de ativar: resolver integrações/triagem e executar todos os gates vivos; nenhuma ausência de achado local equivale a esse aceite.
`);
console.log(JSON.stringify(report.summary));
