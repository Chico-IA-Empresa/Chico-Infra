import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { tasks } from '../../ChicoIA-AWS/planejamento/tasks.mjs';
const base = fileURLToPath(new URL('../', import.meta.url));
const selected = JSON.parse(readFileSync(`${base}/reports/trello-scope.json`, 'utf8')).cards;
const securitySummary = JSON.parse(readFileSync(`${base}/reports/checkov.json`, 'utf8')).summary;
const results = {
  'AWS-006': ['Provider/schema conferido; blueprint blue-green e testes de gate; estudo de handover e HTTPS UAT-off.', 'docs/platform-proof.md; modules/web-service', 'AWS-003, código de singleton AWS-019, ensaio real e decisão HTTPS/DNS adiada.'],
  'AWS-007': ['Git local inicializado sem commits/push; bootstrap e quatro roots separados, lockfiles do provider e validação; workflows sem apply.', 'bootstrap; envs; modules/state; .github/workflows', 'Conta/bucket reais, créditos, revisão de plan e teste concorrente S3. Repositório GitHub/proteções ainda não publicados/configurados.'],
  'AWS-008': ['Trust OIDC por repo/environment exatos, state/lock por scope; CloudTrail protegido; geradores de permissões e matriz de negativas.', 'modules/oidc; modules/audit; scripts/policies.mjs; docs/access.md', 'Federação humana/MFA/recuperação, provedor OIDC e ARNs reais, permissões completas revisadas, Environments protegidos e execução/auditoria AWS.'],
  'AWS-009': ['Budgets bruto 80/100%, UAT60; checklist privado de créditos/cotação/quotas e reserva.', 'modules/budgets; modules/funding; docs/funding.md', 'Conector UNAUTHORIZED/reautenticação; sem prova de saldo/validade/elegibilidade, quotas ou preços do cenário mobile. Nenhum consumo autorizado.'],
  'AWS-010': ['ECR imutável/scan e untagged7d; planejador de retenção preserva releases ativas e 30 builds, gate bloqueia scan desconhecido/crítico.', 'modules/registry; scripts/policies.mjs; tests/policies.test.mjs', 'AWS-008/009, inventário real de digests/rollback e manifests multiarch; preview, push/pull e scan AWS reais.'],
  'AWS-011': ['VPCs 10.10/20/30, AZs, SGs, IGW/S3 gateway, dados privados sem internet, sem NAT; testes mock Dev/UAT/Prod.', 'modules/network', 'Account/AZs reais, créditos, plan revisado e provas reais de conectividade/isolamento.'],
  'AWS-012': ['Inventário estático de 266 nomes, exclusões financeiras, contêineres Secrets sem versões/valores e SSM revisado; contratos de roles/TLS/rotação/A-B.', 'reports/configuration-inventory.json; modules/configuration; docs/access.md', 'Revisão por consumidor, credenciais de teste fora de state, roles SQL, rotação real e AWS-022 para autenticação nativa/realms. Inventário candidato não é allowlist completa.'],
  'AWS-015': ['Blueprint Dev t4g/EIP/EBS/IMDSv2/SSM e contrato Compose por digest/seed/backup.', 'modules/dev-box; envs/dev/compute.tf; docs/environment-readiness.md', 'AWS-009/010/011/012/013/014; AMI/profile/seed, memória e restore reais. Docker Linux local indisponível; DNS adiado.'],
  'AWS-024': ['1.120 colunas candidatas inventariadas por hash de fonte, todas pendentes de revisão; gates de seed sintético e sanitização A/B.', 'reports/sanitization-inventory.json; docs/environment-readiness.md', 'Catálogo SQL/column review, sanitizador e seed completos, Docker/PG16, realms AWS-022, KMS/snapshot/negativas reais. Nenhum dado foi declarado sanitizado.'],
  'AWS-025': ['Módulo RDS/Valkey privado/TLS, ARN sanitizado e KMS explícito; testes de snapshot bruto negado e baseline Prod.', 'modules/data; envs/uat/data.tf', 'AWS-024/011/012, descoberta de versões/quotas, RBAC/cliente TLS/SQL/pools e restore/smoke AWS reais.'],
  'AWS-026': ['Blueprint Fargate ARM/digest, desiredCount0, hook pré-tráfego, TGs distintas, bake10/rollback; teste de latest negado.', 'modules/web-service; docs/environment-readiness.md', 'AWS-003/006/014/021/025; ALB/ACM/WAF/rotas/hook/roles reais e autorização DNS; WS/SSE/mobile direto/negative realms e rollback reais. Blueprint não está ligado às roots.'],
  'AWS-027': ['Blueprint dos oito schedules UTC/revision fixa/Fargate público, desabilitados e gate de prova; matriz de comandos e falhas.', 'modules/schedules; docs/environment-readiness.md', 'AWS-018/019/020/025; host ECS bridge/capacity provider/locks/heartbeats/roles e execução real. league-reports ainda sem --run-once; match-analysis pode capturar erro e sair zero, precisa AWS-018.'],
  'AWS-031': ['Root Prod separada e dados candidatos t4g.medium/gp3/PITR14/proteção; consumidores em blueprint desligados; checklist dos dois apps.', 'envs/prod; modules/data; docs/environment-readiness.md', 'AWS-009/017/030, aprovação de infra, snapshots semanais/mensais/monitoramento e restore PITR reais; sem plan/apply Prod ou credenciais definitivas.'],
  'AWS-034': ['Geradores por ARN/scope, testes locais de rejeição de escopo e matriz de negativas/teardown/auditoria.', 'scripts/policies.mjs; docs/access.md', 'AWS-008/029/031/032; AccessDenied real com positivo de controle e CloudTrail; ciclo UAT e inventários antes/depois. Mock não prova IAM implantado.'],
  'AWS-035': ['Runbook de prontidão/restore final, sequences/contagens/schema/arquivos, recuperação e separação de gates AWS/mobile.', 'docs/activation-and-closure.md', 'AWS-023/030/031/033/034, restore ensaiado, domínio/certificado e checklist real de Felipe. Sem aprovação de corte implícita.'],
  'AWS-036': ['Sequência de corte e recuperação documentada, sem comandos destrutivos com alvo não verificado.', 'docs/activation-and-closure.md', 'AWS-035 completo e autorização específica de Felipe para corte/DNS/desligamento. Nada executado em produção.'],
  'AWS-038': ['Checklist de revogação, retenção, workflows/restarts e Redis externo com ownership pendente; preservação de backups.', 'docs/activation-and-closure.md', 'AWS-037/aceite operacional e autorização das intervenções reais; não revogadas chaves, removidos dados ou cancelado Hostinger.'],
  'AWS-040': ['Plano de comparação bruto/créditos, métricas A/B/WS/IA, sizing UAT e propostas financeiras separadas.', 'docs/funding.md; docs/activation-and-closure.md', 'AWS-037 e uso real representativo; sem direitos de compra/RI/Savings Plans/continuidade paga.'],
};
const byId = new Map(tasks.map(t => [t.id, t]));
const ordered = [], seen = new Set();
function visit(id) { if (seen.has(id)) return; seen.add(id); for (const dep of byId.get(id)?.deps ?? []) visit(dep); ordered.push(id); }
for (const card of selected) visit(card.id);
const execution = ordered.filter(id => results[id]).map(id => {
  const [progress, evidence, blockers] = results[id];
  const card = selected.find(c => c.id === id), task = byId.get(id);
  return { ...card, status: 'Preparação parcial; aceite pendente', dependencies: task.deps, progress, evidence, blockers, mobileRequirements: task.steps.filter(s => /mobile|apps|A\/B|realm|identidades/i.test(s)), complete: false };
});
writeFileSync(`${base}/reports/execution-status.json`, JSON.stringify({ dateBRT: '2026-10-18', selected: selected.length, completedThisRun: 0, awsIdentityVerified: false, creditsVerified: false, productionChanged: false, execution }, null, 2));
const evidenceDir = fileURLToPath(new URL('../../ChicoIA-AWS/evidencias/2026-10-18/', import.meta.url));
mkdirSync(evidenceDir, { recursive: true });
const md = `# Execução das tasks de Felipe — 18/10/2026 (BRT)

Foram consultados todos os 40 cards abertos do CHICOFELIPE, incluindo os concluídos. Seleção: etiqueta azul ou atribuição a Felipe Hora; membros dos cards não azuis conferidos e vazios. Resultado: **18 pendentes azuis**, quatro azuis já concluídos preservados (001/002/004/005). Correção da contagem inicial comunicada de 19. Nenhuma nova task encerrada: todos os aceites restantes exigem evidência externa/AWS ou gates de produção ainda ausentes.

Fonte principal: README/PRD v3 §1.1 desta pasta. Dois produtos mobile Android/iOS, backend comum e identidades isoladas; web Next.js retida. AWS-005 permanece aprovada e intacta. Implementação/operação: Felipe. Créditos exclusivamente, DNS adiado, produção/VPS preservadas.

## Entregas locais

Repositório Git local [chico-infra](../../../chico-infra/README.md), branch codex/aws-foundation, sem commit/push ou repositório remoto criado. Bootstrap e roots shared/dev/uat/prod; módulos de state, rede, OIDC, auditoria, budgets, configuração, RDS/cache, Dev box e blue-green/schedules como blueprints ainda sem integração completa. Workflows de validação e plan protegido, nenhum apply. Inventários estáticos de nomes/colunas sem ler valores .env. Nenhum recurso AWS criado, cobrança iniciada ou DNS/produção alterado.

Validações e limites: [log Terraform/TFLint/Node](../../../chico-infra/reports/validation.txt), [schedules](../../../chico-infra/reports/schedules-tests.jsonl), [blue-green](../../../chico-infra/reports/web-service-tests.jsonl), [Checkov](../../../chico-infra/reports/checkov.json) e [triagem de segurança](../../../chico-infra/docs/security-review.md). Checkov: ${securitySummary.passed} checks passaram, ${securitySummary.failed} achados sem supressão, ${securitySummary.parsing_errors} erros de parsing; gate permanece reprovado. Testes mock não chamam AWS. Nenhuma prova de runtime, lock S3, push/pull, OIDC, conectividade, créditos ou restore AWS foi inferida desses testes.

## Ordem de avanço por dependências

Dependências fora do lote também foram preservadas; autorização para atuar nos cards azuis não declara as tasks verdes/amarelas concluídas.

| Task | Avanço parcial | Evidência em chico-infra | Pendências / bloqueios |
|---|---|---|---|
${execution.map(t => `| [${t.id}](${t.url}) | ${t.progress} | ${t.evidence} | ${t.blockers} |`).join('\n')}

## Intervenções consolidadas de Felipe

1. Reconectar AWS: STS retornou UNAUTHORIZED/reautenticação, sem identidade ou conta verificadas. Disponibilizar sessão temporária, confirmar conta existente destinatária e acesso de leitura Billing/quotas/inventário. Não enviar chaves/segredos no chat.
2. Comprovar privadamente saldo/validade/elegibilidade/cobertura integral dos créditos e reserva para encerramento/residuais. Validar cotação e quotas do cenário combinado A/B antes de qualquer recurso cobrado. Nenhum desembolso próprio/compromisso/continuidade paga autorizado.
3. Configurar federação humana/MFA/recuperação, repos/Environments/branches/aprovadores e OIDC; informar owner/cost-center/destinatários, buckets/ARNs/AZs reais. Revisar planos separados; shared/Prod seguem aprovação do PRD. Não fornecer valores de secrets ao agente.
4. Retomar os contratos de autenticação/migração web/API/compatibilidade mobile e tasks técnicas dependentes de outras cores (003/013/014/018/019/020/021/022/023/029/030/032/033/037). Code review do escopo mobile precisa contas A/B independentes, refresh nativo e versões antigas.
5. Disponibilizar Docker Linux/PostgreSQL16 isolado para ensaios locais: CLI existe, daemon respondeu pipe inexistente. AMI ARM, imagens/release e grupos cache/roles SQL precisam revisão antes do deploy.
6. Quando chegar ao gate, resolver DNS/TLS e UAT-off HTTPS; confirmar QA/revisão de lojas sem conflito de auto-down. Frameworks/nomes/package IDs/distribuição/analytics e eventuais serviços externos seguem decisões específicas; custos de lojas/CI não têm cobertura AWS presumida.
7. Autorizar separadamente planos/execução de infraestrutura conforme gates e, somente após AWS-035 comprovada, DNS/corte/desligamento/revogação. Identificar dono do Redis externo; cancelamento Hostinger ou exclusões não autorizados.

## Preservação

Nenhum arquivo de aplicação existente foi alterado. Mantidos untracked e alterações preexistentes, incluindo deploy-backend.sh no workspace pai. Sem deploy, commit/push, encerramento de recursos, leitura de valores secretos ou mudanças nas decisões AWS-005. Documentação de preparação não é aceite AWS nem publicação dos dois apps.
`;
writeFileSync(`${evidenceDir}/execucao-felipe.md`, md);
console.log(JSON.stringify({ selected: selected.length, completedThisRun: 0, ordered: execution.map(t => t.id) }));
