# Triagem complementar DEV-INFRA — 22/10/2026

> Registro histórico anterior às correções de 27/10. O gate local vigente e suas exceções específicas estão em [security-exceptions-review.md](security-exceptions-review.md). Scans brutos continuam disponíveis; aceite AWS permanece pendente.

Checkov 3.3.29, reconferido em 23/10/2026: 229 passed / 48 failed / 0 skipped / 0 parsing errors; `reports/checkov-dev-infra-local.json`. **Sem aprovação para apply ou declaração de gate verde.** A varredura inclui módulos de UAT/Prod/shared preparados anteriormente; não houve mudança em seus recursos AWS. O [relatório anterior](security-review.md) mantém a triagem por ID dos controles pré-existentes.

| Controle | Situação no recorte Dev |
|---|---|
| CKV_AWS_338, retenção anual | Código segue 30 dias do PRD. Registrar exceção específica/revisão de retenção e custo antes do aceite; não alongar por um scanner |
| CKV_AWS_126, detailed monitoring EC2 | Coleta padrão CPU/status mais coletor próprio memória/disco. Detailed monitoring pago não foi ativado; baseline/cotação e revisão explícita ainda necessários |
| CKV_AWS_18, S3 access logs | Root Dev agora configura delivery do backup em destino explícito, exclusivo e distinto da origem; a falha estática dessa origem foi resolvida. Ownership/policy/custo/retention do destino e chegada de logs continuam sem prova. Nenhuma policy shared foi alterada; os achados pré-existentes de shared continuam |
| CKV_AWS_145, CMK S3 | Backup sintético usa SSE-S3; contrato exige criptografia, mas não define CMK Dev S3. Revisar decisão específica/custo. State preserva SSE-S3 por requisito expresso; não misturar essa decisão com keys de secrets/logs |
| CKV_AWS_144, replicação entre regiões | PRD usa sa-east-1. Não criar cópia entre regiões por inferência; recuperação externa/restore deve ser provada antes de exceção revisada |
| CKV2_AWS_62, eventos de bucket | Sem notificação de cada objeto por padrão. Falha/frescor de backup terão métricas próprias; revisar cobertura de detecção com auditoria e custo |
| CKV2_AWS_11, Flow Logs | Integração Dev está na root com grupo criptografado, role própria, SourceAccount/SourceArn e retenção de 30 dias. O módulo reutilizado também é analisado isoladamente/UAT/Prod; erro do scanner não é motivo para supressão global. Conferir grafo do plan real e fluxo recebido |
| CKV2_AWS_5, SG associado | Host Dev recebe SG explicitamente da root; verificar associações no plan/host. Demais módulos ainda não aplicados não provam exposição ou isolamento |
| CKV2_AWS_34/57, config/rotação | SSM String somente allowlist não secreta; secret_version ausente. Credencial sintética/rotação runtime ainda exige prova e revisão de policies |
| CloudTrail/SNS/Logs shared | Não declarar corrigido pela criação de alarmes Dev. Reutilizar/importar auditoria e revisar integrações sob aprovação shared; negativas Dev→auditoria precisam execução real |

As demais falhas pré-existentes de RDS, cache, Fargate e schedules estão fora do apply Dev e continuam tratadas no relatório anterior; não foram corrigidas por alterações silenciosas em Prod/UAT. Os 48 achados atuais permanecem no relatório bruto. Nenhuma supressão ou aprovação automática foi inserida no CI.

Limitações locais adicionais: roles de infra plan/apply ainda dependem de inventário/revisão e grants reais; key policies, bucket de acesso e destino SNS são referências externas não comprovadas; log proxy tem encaminhador com allowlist localmente testado, mas precisa prova de entrega no host/CloudWatch; sessão SSM deve usar documento configurado e provar entrega. Usuário com root no host controla seus consumidores; isso não é isolamento IAM por container. `prevent_destroy` exige procedimento explícito para substituição do host e não substitui retenção imutável ou backup comprovado.

O filtro proxy exporta somente tipo, método enumerado, status, duração e tamanho; URLs, headers, corpos, IPs e identidades são descartados. Cursor considera inode/device/offset e só avança após envio sem rejeição reportada. Timers de métricas e logs são independentes, para falha de métrica não impedir logs. Quatro testes cobrem dados proibidos, campos inválidos, registro parcial/rotação e linhas grandes/malformadas. O teste de user data cobre o limite de 16 KiB do bootstrap gerado. Nenhum desses checks locais prova entrega ou comportamento de systemd no host.

Correção local posterior: o attachment AmazonSSMManagedInstanceCore foi substituído por policy inline de canais/core sem leitura global de parâmetros. Isso impede que o grant managed GetParameter/GetParameters em Resource=* se some à allowlist estreita de configuração. A asserção do plano mock cobre a composição das duas policies; a funcionalidade do agente e o isolamento efetivo continuam sujeitos à prova AWS. Fonte da composição managed: https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html.
