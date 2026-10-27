# PRD técnico — Terraform e infraestrutura Dev

**ID:** PRD-DEV-INFRA · **Versão:** 1.0 · **Data:** 22/10/2026
**Responsável:** Felipe · **Estado:** especificado para implementação; aceite operacional pendente.
**Referência principal:** PRD de arquitetura v3 e README vigente da migração. Este documento detalha a etapa 01 do roadmap Dev e não substitui suas decisões de arquitetura.

## 1. Problema e resultado esperado

A fundação AWS foi declarada concluída por Felipe, mas o código local ainda não entrega uma infraestrutura Dev integralmente provisionável e operável. A root Dev integra rede e metadados de configuração; o módulo de EC2 tem EIP, EBS e IMDSv2, porém seu bootstrap é um esqueleto. AMI e instance profile são entradas externas, e o workflow autenticado gera apenas plan. As permissões OIDC existentes concentram-se no state. Diretórios e validações locais não comprovam integração ou recursos funcionando na AWS.

Entregar infraestrutura Dev gerenciada por Terraform, reproduzível a partir de revisão versionada, administrável por SSM, com imagens acessíveis, configuração isolada, armazenamento recuperável, HTTPS e sinais operacionais. Ao final, a aplicação pode ser instalada sem criar recursos manualmente para contornar o Terraform.

**Esta fase termina em “infra pronta para receber a aplicação”.** Login, jornada com seed, onze processos de negócio e merge automático da aplicação continuam nas etapas seguintes. O teste desta fase usa containers/fixtures sintéticos isolados e não inicia bots, coletores ou escritores reais.

## 2. Escopo e restrições

- Uma conta AWS existente destinatária dos créditos, região sa-east-1; nenhuma conta adicional ou Organizations.
- Dev: VPC 10.10.0.0/16, subnet pública 10.10.0.0/24 em uma AZ, IGW, EC2 ARM64 t4g.small, EIP, EBS gp3 criptografado. Baseline local: 30 GiB; capacidade e qualquer volume adicional precisam de cotação antes de ativar.
- Docker Compose no host. PostgreSQL 16 e Redis serão containers locais da aplicação; esta fase prepara volumes e ensaia recuperação com fixture sintética.
- Sem NAT Gateway, interface endpoints, ALB, ECS/Fargate, RDS ou ElastiCache no Dev. Não duplicar infraestrutura por app A/B.
- Reutilizar bootstrap/shared existentes por referência ou import controlado, conforme ownership; não criar cópias dos recursos nem mover state às cegas.
- Recursos, states, dados, DNS e aplicação de UAT/Prod/VPS preservados. Alterações shared limitadas às dependências comprovadas do Dev e com aprovação prevista no PRD v3.
- Somente créditos válidos e elegíveis, cobertura integral e reserva de encerramento; nenhum desembolso próprio autorizado. Dados financeiros e destinatários pessoais ficam em evidência privada.
- Este pedido autoriza documentação e publicação de tickets. Não autoriza apply, DNS, novas permissões ou consumo AWS nesta conversa. A execução futura precisa da liberação de execução correspondente e dos gates financeiros/técnicos.

## 3. Histórias de uso

1. **US01** Como operador, quero reconciliar a fundação existente com os states para continuar sem duplicar recursos.
2. **US02** Como mantenedor, quero validar e revisar um plan Dev reproduzível antes de alterar a AWS.
3. **US03** Como operador, quero plan, apply e deploy com funções separadas e sessões temporárias.
4. **US04** Como desenvolvedor, quero administrar o host por SSM, sem SSH público.
5. **US05** Como mantenedor, quero recriar o host com bootstrap idempotente e recuperar os dados.
6. **US06** Como pipeline/host, quero publicar e consumir as três imagens por digest, com scan e permissões adequadas.
7. **US07** Como serviço Dev, quero receber somente minha configuração e credenciais de teste, com rotação verificável.
8. **US08** Como operador, quero um backup sintético recuperável fora do host e retenção/custos conhecidos.
9. **US09** Como usuário de teste, quero acessar um endpoint HTTPS Dev com certificado renovável.
10. **US10** Como operador, quero detectar falhas de host, disco e backup, sem expor segredos nos logs.
11. **US11** Como responsável financeiro, quero medir consumo bruto e encerrar o ambiente antes de comprometer a reserva.
12. **US12** Como responsável por Prod, quero provar que Dev não acessa nem altera seus recursos.
13. **US13** Como responsável pela aplicação, quero receber outputs e runbooks suficientes para instalar o Compose.

## 4. Contratos técnicos

### R01 — Ownership, estado e identidade da execução

Inventariar por metadados os recursos e backends efetivamente existentes. Registrar origem, root proprietária, import necessário e dependências Dev. Classificar cada item como existente confirmado, código não aplicado, incompleto ou não necessário. A declaração de fundação concluída não exige refazer bootstrap; divergências viram pendências explícitas.

Manter roots bootstrap/shared/dev/uat/prod e states separados; sem workspaces para ambientes. Backend Dev com bucket real, key dev/terraform.tfstate, lock nativo S3, região e allowed_account_ids. Versionamento, criptografia, bloqueio público e TLS do bucket precisam de evidência; preservar a escolha SSE-S3 do state. Runtime não lê state. Consumidores recebem somente outputs não sensíveis estritamente necessários, sem leitura ampla de remote state que exponha outros conteúdos.

Provar contenção no mesmo key e independência entre keys. Ensaiar recuperação de versão em cópia isolada; nunca sobrescrever state ativo para testar. Force-unlock só com procedimento para comprovar ausência de execução legítima.

### R02 — Inputs, outputs e versões

Preservar as versões fixadas no código (Terraform 1.13.5 e provider AWS 6.69.1), com lockfiles revisados; upgrade não é pré-requisito implícito. CI usa versões iguais às locais. Inputs devem validar conta, região, AZ, owner/cost-center, nomes únicos, AMI ARM64, referências a roles/keys, parâmetros permitidos e flags de ativação. Não aceitar credenciais como inputs Terraform.

Outputs mínimos: VPC/subnet/SG, instance ID, allocation ID/IP do EIP, volumes e mount contract, ARNs de runtime/SSM, URLs/ARNs ECR, ARNs de metadados de secrets, grupos de logs, bucket/prefixo Dev e hostname quando definido. Outputs não contêm valores secretos. Dependências shared são passadas explicitamente e não por descoberta ambígua de nomes.

### R03 — Plano, apply e gates

PR executa fmt, validate, testes locais/mocks, TFLint e Checkov sem credenciais AWS. Plan autenticado roda apenas sobre revisão confiável em main e Environment protegido. Completar o caminho de revisão privada: o workflow atual descarta o plan ao terminar e não constitui um fluxo de apply utilizável.

Plan/apply do mesmo scope compartilham exclusão mútua, sem cancelar apply em andamento. Vincular revisão a commit, scope, conta, lockfile, inputs não secretos, resumo revisável e hash do plan. Aplicar o plano salvo efetivamente revisado, em sessão privada controlada; se expirou, mudou input/commit/state ou perdeu integridade, gerar outro plan e revisar novamente. Não exportar plan/state em artefato público nem imprimir conteúdo sensível.

O primeiro apply pode exigir executor humano temporário para criar a própria infraestrutura de OIDC: registrar esse caminho, gates e transição, sem circularidade “role precisa de si mesma para existir”. Shared exige aprovação prevista no PRD; o fluxo Dev registra quem libera a execução. Um workflow completo não implica que a liberação já ocorreu. Falha parcial de apply exige reconciliação; Terraform não oferece rollback automático de recursos.

### R04 — IAM, OIDC e SSM

Separar função humana temporária, ci-plan-dev, ci-infra-apply-dev, build/push e ci-deploy-dev. Runtime EC2 usa instance profile próprio; não recebe state, administração IAM ou permissão de deploy em outro host. Revisar ações de descoberta sem ARN separadamente das ações que aceitam escopo por recurso; não conceder AdministratorAccess para desbloquear pipeline.

Trust OIDC limita audiência e subject efetivo dos repositórios/Environments. Conferir formato real de subject, inclusive IDs imutáveis quando aplicáveis, sem registrar token no relatório. Restrição de branch/workflow também depende das proteções GitHub; Environment no subject não prova sozinho a branch. Testar origem autorizada e origem indevida.

PassRole limitado aos ARNs de roles Dev necessários e serviço esperado. Função de deploy aceita somente documento SSM revisado e host Dev autorizado; SendCommand arbitrário equivale a controle do host. Comandos usam instance profile apenas para dados permitidos. Testar negativas Dev→Prod/shared protegidos e positivas no próprio Dev. Se Prod ainda não existir, registrar evidência parcial e gate futuro; ARN inexistente não prova isolamento real.

### R05 — Rede e host

Uma AZ Dev verificada na conta. Sem peering/rotas para dados UAT/Prod. SG default fechado; entrada externa só 80/443 no edge. Sem 22, 3000, 8000, 5432 ou 6379 públicos. O Docker não publica portas internas e suas regras de rede precisam ser incluídas nos testes, não apenas o SG Terraform.

Egress pelo EIP/IGW para SSM, ECR, S3, configuração, updates e provedores de teste; nenhum NAT ou interface endpoint adicionado silenciosamente. SSM Agent precisa de acesso, role e conectividade. Bootstrap deve tolerar o intervalo entre boot e associação do EIP com retries limitados e falha observável.

AMI ARM64 com procedência/versão registradas; validar SSM, arquitetura e pacotes. IMDSv2 obrigatório; manter proteção de metadata existente. O helper do host resolve configuração e fornece ao runtime; containers não dependem de acesso irrestrito à metadata. Docker/Compose/agent instalados e versões registradas; unidades e diretórios persistentes preparados, reboot e reexecução do bootstrap testados. Não iniciar aplicação real no user data.

### R06 — ECR e configuração de runtime

Reutilizar chico-api, chico-workers e chico-frontend na conta. Tags imutáveis, imagens identificadas por digest. Build tem push; host tem pull somente dos repos necessários; permissão de token do registry tratada como ação de escopo próprio. Provar com fixtures de imagem que não acionem negócio. Builds ARM64 da aplicação e manifesto real pertencem a AWS-013/014/016.

Conferir modo efetivo de scan/custo. Falha/resultado desconhecido bloqueia uso; scan aprovado não é só recurso Terraform declarado. Retenção preserva digests em uso/rollback e referências multiarch; preview antes de limpeza, sem apagar imagens nesta preparação.

Secrets Manager recebe apenas metadados via Terraform; valores ficam fora de state, tfvars, user data, logs e tickets. Parameter Store String somente para configuração não secreta revisada. CMK Dev, policies e consumidores estritos conforme contrato vigente. Fornecer configuração por consumidor com arquivo protegido em tmpfs ou mecanismo equivalente revisado; permissões, limpeza e rotação explícitas. A prova usa credencial sintética por resolução em runtime, sem retornar plaintext ao agente. Rotação é observada por versão/comportamento, não pelo valor. Credenciais financeiras e de Prod excluídas.

### R07 — Dados duráveis e recuperação

Documentar paths/mounts, UID/GID, ownership, formato de backup e contrato Compose. EBS retido após exclusão não comprova remontagem nem recuperação. Antes do plan final, escolher e registrar estratégia de dados/reanexação usando o baseline ou volume dedicado cotado; nenhum volume adicional por conveniência sem cobertura financeira.

Nunca formatar disco não vazio em reexecução de bootstrap. S3 Dev privado, criptografado, TLS obrigatório, prefixo e IAM exclusivos de escrita/leitura de recuperação; lifecycle alinhado ao PRD, sem aplicar regra sobre backups legados. pg_dump noturno será conectado à aplicação; nesta fase provar agendamento, checksum, envio, erro observável e restore em PostgreSQL 16 sintético isolado. Testar arquivos duráveis com fixture. Medir tempo/perda no ensaio; objetivos Prod não são resultados comprovados de Dev.

Recriação do host não pode perder silenciosamente dados, EIP ou certificado. Documentar destino e custeio de EBS/S3/IPs/logs após parada/substituição. Destruir root Dev inteira não é procedimento de recuperação.

### R08 — DNS e TLS Dev

Fechar hostname e autoridade DNS com Felipe antes da execução correspondente. Reutilizar zona autoritativa; definir propriedade do registro no state e import quando necessário. Evitar criar zona paralela ou alterar delegação/records Prod. Se DNS estiver fora do Terraform, registrar fronteira e evidência, sem fingir automação completa.

Caddy ou nginx/certbot no host, Let's Encrypt, redirecionamento HTTP→HTTPS e renovação automatizada. Porta 80 somente redirect/ACME. Ensaiar com endpoint estático Dev sem dados de usuários; persistir estado necessário ao certificado e usar staging no ensaio apropriado. Contrato de proxy preserva /api/contact→web, /api/*→API com prefixo tratado, /ws/*→API e fallback web; jornadas/WS/SSE completos ficam na publicação da aplicação.

### R09 — Observabilidade, auditoria e consumo

Integrar logs do bootstrap, SSM/execução, proxy e backup, com retenção explicitada (referência do PRD: 30 dias), sem dados secretos. Coletar uso de memória/disco por mecanismo que realmente produza métricas, além de CPU/status. Não assumir que métricas padrão EC2 incluem memória. Definir limite a partir do baseline observado e registrar thresholds antes de ativar alertas. Executar falha sintética e confirmar recebimento no destino autorizado.

Reutilizar auditoria compartilhada e comprovar eventos das ações Dev; Dev não pode desativá-la ou apagar seus registros. Resolver lacunas de Flow Logs/acesso S3/SNS e demais controles aplicáveis com custo e decisão registrada. Revisão anterior tinha gate de segurança reprovado: tratar achados ou exceções específicas revisadas; nenhuma supressão global nem alteração de Single-AZ/NAT para satisfazer scanner.

Cotação privada cobre EC2, EBS, IPv4, backup/storage/requests, logs/métricas/alarmes, KMS, secrets, auditoria, DNS, tráfego e recursos temporários dos ensaios, incluindo exclusões/tributos. Reutilizar evidência válida de créditos sem publicar valores. Tags project/env/owner/cost-center e budgets de consumo bruto por conta/Dev com alertas 80/100%, sem inventar teto Dev. Limites dependem da cotação coberta; alarmes não são trava financeira. Incluir custos não alocados e plano de encerramento/reserva.

### R10 — Segurança, testes e evidências

Reusar testes mock Terraform de funding/network/OIDC e testes Node de policies/retention. Adicionar testes nas interfaces root→módulo e no resultado do bootstrap que protejam cenários de erro: input inválido, scope errado, flags desligadas, consumidor indevido, mount não vazio e retry de conectividade. Evitar testes que apenas reproduzam texto do HCL.

Provas reais usam somente Dev e fixtures: identidade/SSM, push→scan→pull, configuração/rotação, backup→restore, HTTPS, alerta e rede/negativas. Registrar revisão, versões, scope, horário UTC/BRT, comando/operação sem payload secreto, resultado esperado/obtido e localização da evidência. State/plan integrais, secrets e finanças permanecem em armazenamento privado. Novo plan após aceite sem drift inesperado; mudanças reconhecidas devem estar justificadas.

## 5. Marcos, dependências e tickets

Publicar os tickets DEV-INFRA abaixo como detalhamento deste PRD, vinculados às tasks AWS existentes. Não fechar, mover ou substituir os cards de origem. “Pronto para implementar” não significa “autorizado a provisionar”. Todos começam no Backlog; sem datas ou assignees presumidos.

| ID | Entrega verificável | Depende de | Relação AWS |
|---|---|---|---|
| DEV-INFRA-001 | Plan Dev reproduzível sobre fundação reconciliada | nenhuma | 007/009 |
| DEV-INFRA-002 | Plan→revisão→apply por OIDC com segregação | 001 | 007/008 |
| DEV-INFRA-003 | Host Dev com rede, IAM e bootstrap gerenciados, acessível por SSM | 002 | 008/011/015 |
| DEV-INFRA-004 | Imagem sintética passa por push→scan→pull no host | 003 | 010 |
| DEV-INFRA-005 | Consumidor Dev recebe configuração e prova rotação isolada | 003 | 012 |
| DEV-INFRA-006 | Dados sintéticos sobrevivem a restart/recriação e restore | 003/005 | 015/023 |
| DEV-INFRA-007 | Endpoint HTTPS Dev com registro e renovação definidos | 003 + domínio/acesso DNS | 015 |
| DEV-INFRA-008 | Falha Dev produz alerta, evidência de auditoria e consumo rastreável | 003 | 008/009; recorte Dev |
| DEV-INFRA-009 | Aceite integrado da infra e handoff para aplicação | 004/005/006/007/008 | 015/034; recorte Dev |

Dados de implementação podem ser preparados em paralelo. As dependências acima bloqueiam o aceite operacional de cada slice. Cobertura de créditos, gates de segurança e autorização de execução bloqueiam qualquer provisionamento, inclusive os primeiros recursos usados para validar OIDC.

## 6. Aceite global

- [ ] Inventário/ownership e state Dev reconciliados; lock concorrente e recuperação isolada comprovados.
- [ ] Checks aplicáveis aprovados e exceções revisadas individualmente; nenhuma supressão global.
- [ ] Plan/apply vinculados à revisão e conta corretas, com funções segregadas e evidência de revisão.
- [ ] Host ARM64 administrável por SSM, sem SSH e sem exposição de DB/cache/portas internas.
- [ ] Bootstrap idempotente após reboot, sem formatar disco com dados ou iniciar negócio real.
- [ ] Três repos ECR acessíveis conforme papéis; fixture por digest passa pelo scan e pull.
- [ ] Configuração por consumidor e rotação sintética aprovadas, sem plaintext em state/logs/docs.
- [ ] Backup externo e restore PostgreSQL 16/arquivos sintéticos comprovados; estratégia de volumes definida.
- [ ] Hostname HTTPS Dev e renovação validados, sem alteração de domínio produtivo.
- [ ] Falha gera alerta recebido; auditoria registra execução; métricas/retention e consumo estão definidos.
- [ ] Positivas/negativas de IAM e rede aprovadas no escopo existente; limites de prova de Prod ausente explícitos.
- [ ] Plan pós-execução sem drift inesperado; runbooks/outputs entregues para AWS-013/014/015/016.

## 7. Fora de escopo e riscos

Fora de escopo: implementação de negócio/realms A/B, build final de imagens da aplicação, deploy automático por merge da aplicação, ativação de bots/collectors, pagamentos, dados Prod, publicação mobile, recursos UAT/Prod e corte/desligamento VPS. Este PRD não conclui AWS-015 integralmente: entrega seu pré-requisito de infraestrutura.

Riscos principais: 2 GiB não comportarem aplicação real (medir na etapa seguinte); bootstrap sem internet até associação do EIP; privilégio indireto via PassRole/SSM/instance profile; volumes retidos sem roteiro de montagem; scan desconhecido; demora de DNS/quotas; planos sensíveis descartados antes da revisão; consumo residual após compute parado. Cada risco tem gate nos requisitos correspondentes. Aumentar capacidade, abrir acessos ou criar serviços adicionais exige plan e cobertura revisados.

## 8. Fontes e manutenção

- [README da migração](README.md), [PRD v3](chicoai-aws-architecture-prd.md), [roadmap Dev](roadmap-dev.html).
- Código local e relatórios de chico-infra consultados em 22/10/2026; sem nova auditoria AWS nesta redação. O status no Trello pode divergir de implementação/aceite e deve ser reconciliado pela evidência, sem encerramento automático.
- [Terraform S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3): lock nativo e versionamento.
- [Terraform apply](https://developer.hashicorp.com/terraform/cli/commands/apply): plano salvo e comportamento de falha parcial.
- [GitHub OIDC em AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws): trust, Environments e subjects efetivos.
- [Configuração Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-getting-started.html): pré-requisitos e controle de sessão.

Os tickets carregam escopo, aceite e evidência suficientes para execução independente. O índice de publicação registra URLs reais do Trello e a cópia local; caminhos locais não são apresentados como links públicos.

## 9. Publicação no Trello

Publicado e conferido no Backlog do CHICOFELIPE: [card do PRD](https://trello.com/c/fvVO9RPb). A versão do Trello é uma síntese de consulta; este arquivo mantém o contrato integral.

| Ticket | Entrega |
|---|---|
| [DEV-INFRA-001](https://trello.com/c/StRNZ7qa) | Reconciliar a fundação e gerar um plan Dev reproduzível |
| [DEV-INFRA-002](https://trello.com/c/WwlLiZEs) | Entregar plan e apply Dev por OIDC com revisão vinculada |
| [DEV-INFRA-003](https://trello.com/c/wk7UaCbG) | Provisionar um host Dev reproduzível e administrável por SSM |
| [DEV-INFRA-004](https://trello.com/c/pHlWZDHH) | Provar push, scan e pull de imagens por digest no Dev |
| [DEV-INFRA-005](https://trello.com/c/LAtrfVXW) | Entregar configuração Dev isolada com prova de rotação |
| [DEV-INFRA-006](https://trello.com/c/NxE8zR9p) | Provar persistência e recuperação de dados sintéticos do Dev |
| [DEV-INFRA-007](https://trello.com/c/9vFgfpSC) | Entregar endpoint HTTPS Dev com DNS e renovação definidos |
| [DEV-INFRA-008](https://trello.com/c/xWUOn9sn) | Detectar falhas Dev e rastrear auditoria e consumo |
| [DEV-INFRA-009](https://trello.com/c/Mm3HurDy) | Aceitar a infraestrutura Dev e entregar o contrato à aplicação |

[Descrições publicadas e dependências](planejamento/dev-infra-tickets.md) · [Registro de sincronização](planejamento/dev-infra-trello-sync.json). Os cards AWS originais foram preservados. Nenhum recurso AWS foi alterado nesta publicação.
# Proveniência desta cópia

Cópia de consulta capturada em 27/10/2026 de `ChicoIA-AWS/prd-terraform-infra-dev.md`, para revisão no repositório de infraestrutura. A fonte canônica continua sendo a pasta ChicoIA-AWS e o PRD de arquitetura v3, conforme AGENTS.md. Os links relativos do texto original referem-se à pasta de origem. Estado de execução e divergências conhecidas estão em [local-github-status.md](../local-github-status.md).
