# Descoberta do grupo de logs pelo SSM Agent

O Run Command terminou, mas a entrega de stdout ao grupo CloudWatch Dev não foi observada. O diagnóstico do host encontrou falhas de autorização em descoberta/criação de grupo antes de qualquer tentativa de criação de stream ou publicação. `CloudWatchOutputEnabled=true` e `GetCommandInvocation=Success` não comprovam entrega.

Este patch acrescenta somente `logs:DescribeLogGroups`, `Resource=*`, com `StringEquals aws:RequestedRegion=sa-east-1`, à inline telemetry de Dev e à runtime boundary gerada para Shared. Os dois lados são necessários porque permissões efetivas são a interseção. Destinos de escrita continuam os quatro grupos Dev já existentes; métricas, Flow Logs, grants CI, key policies, retenções e recursos não mudam. Não concede CreateLogGroup, administração de grupos ou leitura de eventos. A descoberta permite ver metadados de outros grupos da conta em São Paulo; um prefixo informado pelo cliente não restringe essa capacidade em IAM.

O [guia oficial Run Command](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-rc-setting-up-cwlogs.html) exige descoberta de grupos. O coordenador observou a versão instalada **3.3.5390.0** via SSM. A [fonte dessa versão, commit c8fa314](https://github.com/aws/amazon-ssm-agent/blob/c8fa314de8050cd5dcb3740a29c3ce769f533dcd/agent/agentlogstocloudwatch/cloudwatchlogspublisher/cloudwatchlogsservice.go), permite continuar após falha de CreateLogGroup se IsLogGroupPresent confirma grupo existente; essa descoberta usa DescribeLogGroups. Isso sustenta a correção mínima sem criação, mas não substitui sua prova real de entrega. Um grupo ausente exige reconciliar o Terraform; a runtime permanece sem permissão para criá-lo.

O simulador IAM retornou implicitDeny para stream/put via plugin e CLI, inclusive com documentos efetivos e boundary explícitos. Esse resultado diverge da prova real posterior: um comando SSM delimitado, usando a identidade runtime do host, criou um stream no grupo Dev e publicou apenas um marcador público, depois encontrado no CloudWatch. Portanto as permissões de escrita já funcionam no serviço; este patch não as amplia. A divergência do simulador permanece registrada, sem atribuir uma causa ainda não demonstrada. Essa prova manual não comprova a descoberta/entrega automática pelo agente, que continua pendente.

## Validação offline

- Node: ausência original da descoberta reproduzida; documento regional exato, região correta aceita, região estrangeira/vazia/ausente recusada e administração/leitura de eventos ausentes. O hash do conjunto inteiro gerado, removido apenas o novo statement, deve continuar igual ao baseline e42f266 com inventário sintético.
- Terraform mock Dev: ausência original reproduzida; comparação da inline inteira verifica os quatro destinos exatos, nova leitura regional e métricas inalteradas, além dos mesmos casos regionais. Os mocks usam ARNs sintéticos conhecidos para evitar assertions sobre valores desconhecidos.
- As quatro decisões CKV_AWS_338 vinculadas ao arquivo observability.tf foram reavaliadas porque o gate exige hash do arquivo inteiro. A mudança não altera os grupos/CMK/30 dias. Escopo, motivo, recursos e expiração das exceções permanecem iguais; só hash/data/nota técnica são atualizados. Nenhuma exceção nova ou supressão é acrescentada.

Essas verificações inspecionam documentos e escopo offline; não são simulações IAM AWS nem prova de entrega ou aceite operacional.

## Gates ainda abertos

O Shared de seis criações build/status foi aplicado separadamente. Sua aprovação declarava boundaries inalteradas e não autoriza esta alteração. Para planejar o próximo Shared, preservar o baseline de inputs que já inclui as novas roles/bindings e opt-in; não reaproveitar inputs antigos que removeriam essas identidades.

Depois de revisão do patch e CI, o coordenador prepara um novo saved plan Shared privado: expectativa isolada de um update na runtime boundary, zero criações/deleções/substituições e demais documentos inalterados. Confrontar inventário real, Access Analyzer, contexto efetivo e cobertura vigentes, e obter revisão humana específica exigida pelo §4 item8. Apenas o plano real autentica o delta.

Após aprovação/apply Shared e conferência da boundary, preparar novo saved plan Dev para a inline telemetry, revisar todos os deltas reais e obter os gates de apply protegido correspondentes. Não alterar IAM fora do state nem reutilizar o bundle Dev anterior para este código.

Para encerrar, usar comando SSM mínimo com marcador público único, alvo/documento/version/hash conferidos e destino /chico/dev/ssm explícito. Após terminalidade, confirmar o marcador no stream stdout correspondente a CommandId/InstanceId/PluginId, preservando request IDs/timestamps e controles de CMK/retenção. Uma tentativa CreateLogGroup negada pode ser tolerada pelo agente; confirmar continuação e entrega em vez de exigir ausência desse evento. Não publicar payloads antigos ou secrets. Histórico não é declarado reenviado; Session Manager e SNS têm provas próprias.
