# AWS-035/036/038/040 — runbook de gates

Responsável: Felipe, proprietário da conta AWS. Corte direto com downtime aceito preservado; sem CDC/DMS/dual-run e sem fallback VPS ativo obrigatório. Este documento não autoriza nem executa corte, DNS, desligamento, revogação ou exclusão.

## Gate de prontidão AWS-035

Conferir evidência real dos oito gates PRD §17: readiness DB/cache/LISTEN; rotas no ALB Prod; heartbeats/alarmes de todos os workers/jobs; backup/restore reconciliado; provedores acessíveis sem envio duplicado; rollback blue-green UAT; orçamento de conexões durante duas cores/jobs; isolamento IAM/rede/teardown e quotas. Somar comprovação de créditos cobrindo toda operação/reserva e aprovação de plan Prod. Aceite AWS-005 não substitui esses testes.

Manifesto do ensaio inclui: origem/hash do dump e arquivos; hora UTC e primeira/última escrita; versão PostgreSQL16/extensões/encoding; Alembic e digests; logs sem dados pessoais; contagens críticas no mesmo snapshot; sequences last_value/is_called/max(id); constraints e índices válidos; roles/privilégios; arquivos duráveis/banco; smoke de queries e contas de teste; destino de backup e acesso de recuperação; tempos observados. Rever sequência CRM apontada na AWS-004 somente no destino, sem modificar produção nesta preparação. Não reutilizar evidência 16/10 como prova do backup final futuro.

DNS adiado: Felipe define titular/acesso/hostnames, certificado, prioridade/rewrite ALB e registros antes da ativação. Plano UAT-off HTTPS continua decisão aberta; não usar S3 website como TLS de mesmo hostname. Pagamentos permanecem desligados.

## Sequência para o corte futuro AWS-036

1. Obter autorização específica de Felipe vinculada ao manifesto, gates e conta. Revalidar créditos, credenciais, capacidade e backups recuperáveis. Registrar quem executa e quem verifica.
2. Inventariar comandos atuais reais de deploy/cron/restart/containers e escritores, inclusive integrações externas. Revisar a lista com Felipe; comandos de host antigos não são a fonte da arquitetura AWS. Não emitir `docker compose down` genérico.
3. Desabilitar triggers que religariam a VPS e parar API/frontend/collectors/bots/escritores. Confirmar ausência de novas gravações. Manter PostgreSQL acessível exclusivamente para exportação final.
4. Exportar banco/roles sem senhas e arquivos duráveis; manifestar checksum/contagem consistente e validar cópia fora da VPS. Se falhar, interromper roteiro e preservar origem. Só então parar PostgreSQL/cache/restante da VPS, respeitando serviços de outro proprietário.
5. Restaurar no RDS e arquivos alvo; validar schema/seq/roles/contagens e migrações compatíveis. AWS permanece sem consumidores enquanto restauração falhar. Downtime continua aceito, sem janela máxima inventada.
6. Com domínio/certificado aprovados, ativar API/web e smoke. Apontar DNS conforme procedimento aprovado; habilitar uma única vez três contínuos e oito schedules depois de confirmar fonte desligada. Registrar digests/revisions, contagens, task ARNs e primeira escrita AWS.
7. Antes da primeira escrita AWS, recuperar da cópia final verificada. Depois dela, corrigir para frente ou planejar reconciliação explícita dos dados novos. Nunca religar banco antigo gravável sem reconciliação; nunca dois primários graváveis.

Comandos destrutivos e hostnames não foram embutidos: sem sessão AWS, DNS e manifesto real não há alvos revisáveis nem autorização de corte. Preencher e ensaiar em destino isolado em AWS-035 antes de pedir autorização para executá-los.

## Gates mobile separados

Migração AWS não é lançamento nas lojas. Exigir A/B Android+iOS assinados/canais independentes, política de compatibilidade API/mobile antiga, secure storage/refresh rotation/revocation, mesmas contas email independentes por realm, negativas token/reset/OAuth/dados, migração web explícita, sem identidade vinculada silenciosamente; jornadas contra backend comum e carga combinada; privacidade/exclusão e territórios aprovados; analytics com coorte e denominadores/janelas; disponibilidade UAT para QA/revisão. Push/assinaturas/CDN/Multi-AZ seguem sem ativação automática. Contas/CI de lojas não têm financiamento assumido por créditos AWS.

## Encerramento AWS-038

Só depois de AWS-037: conferir que reboot/merge/cron não religa stack antiga; inventariar chaves por nome e destino; revogar acessos de deploy VPS e remover referências operacionais dos pipelines atuais com autorização específica quando exigida. Testar o novo caminho e recuperação antes de revogar. Não apagar dumps/volumes/conta Hostinger por inferência; retenção final e cancelamento de contrato são decisões distintas. Redis externo redis-bdeu tem dono a identificar antes de qualquer desligamento. Reter backups verificáveis e registrar responsável/destino/prazo/custo residual.

## Medição AWS-040

Após período representativo real, exportar custo bruto por shared/dev/uat/prod e não alocado, créditos/elegibilidade separados em arquivo privado. Comparar cenário Calculator aprovado com consumo medido incluindo sanitização/bake/IPv4/egress e memória/IOPS/cache/WS/IA; separar uso por A/B e funções web retidas. Medir simultaneidade real, não número de cadastros.

Validar alteração de sizing em UAT uma variável por vez e conexão máxima incluindo overlap; registrar plan, métricas antes/depois, rollback e aceite. Aplicar somente pelo processo autorizado. Após cerca de 30 dias estáveis, RI/Savings Plans podem virar proposta de ponto de equilíbrio/validade; nenhum compromisso ou continuidade paga é autorizado. Rever saldo/expiração e encerramento antecipadamente, incluindo backups/storage após compute parado.
