# Solução para EC2 Standard On-Demand — L-1216C47A

Fontes: ChicoIA-AWS/README.md e PRD v3, inclusive §1.1 e gate §17. A arquitetura permanece em uma conta, sa-east-1, três ambientes isolados e hosts ARM64. Esta entrega prepara a solução; **não altera AWS**.

## Solução principal: aumentar a quota para 12 vCPUs totais

| Campo | Valor |
|---|---|
| Conta conferida | 306915830875 |
| Região | sa-east-1 |
| Serviço | Amazon EC2 / ec2 |
| Quota | Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances |
| Código | L-1216C47A |
| Aplicada em 22/10/2026, 17h26 BRT | 5 vCPUs |
| Uso observado | Nenhuma instância EC2 retornada |
| Valor total solicitado no rascunho | 12 vCPUs |
| Histórico desta quota na consulta | Sem pedidos retornados |
| Envio do pedido | **Não executado — AWS somente leitura** |

O valor 12 é o **novo limite total**, não incremento de 12 sobre 5. Não mudar o tipo de instância, conta, região ou arquitetura para contornar esse limite. CPUs configuradas abaixo do padrão não reduzem a contagem da quota.

## Dimensionamento do pedido

| Cenário | Hosts t4g.small equivalentes | vCPUs |
|---|---:|---:|
| Dev + worker UAT + worker Prod | 3 | 6 |
| Baseline + substituição de um worker host | 4 | 8 |
| Baseline + substituição dos dois worker hosts | 5 | 10 |
| Pico anterior + um host temporário equivalente | 6 | 12 |

Cada t4g.small tem 2 vCPUs padrão, confirmado por DescribeInstanceTypes. Os hosts extras são **folga de quota**, não recursos aprovados, capacidade contratada nem consumo contínuo. O temporário é uma hipótese conservadora para recuperação/sanitização; implementação e custos ainda precisam de revisão. Não implica criar uma segunda produção.

Este modelo tem limite de dois hosts de substituição e um temporário; não presumir que suporta qualquer paralelismo. O pico real de ASG/deploy/recuperação deve caber no valor aplicado, somado aos demais consumidores da conta.

## Material já preparado

- [Payload JSON da solicitação](requests/ec2-standard-vcpu-sa-east-1.json): somente os parâmetros ServiceCode, QuotaCode e DesiredValue. Região e conta devem ser conferidas na sessão.
- [Justificativa para eventual chamado](requests/ec2-standard-vcpu-sa-east-1.txt): texto revisável, sem dados financeiros.

Nenhum arquivo executa pedido, stop/start, deploy ou apply automaticamente.

## Como Felipe conclui pelo console

1. Abrir [Service Quotas em São Paulo](https://sa-east-1.console.aws.amazon.com/servicequotas/home?region=sa-east-1) e conferir conta 306915830875.
2. Selecionar Amazon EC2 e localizar o código L-1216C47A.
3. Verificar se surgiu pedido recente para a mesma quota, evitando duplicidade.
4. Escolher Request quota increase e informar **12** como novo valor total.
5. Enviar, guardar request ID/status e acompanhar o chamado se a AWS abrir um.
6. Se a AWS pedir justificativa, usar o texto preparado. Não contratar suporte pago.
7. Depois da decisão, reconsultar **a quota aplicada**. Pedido aberto, status aprovado ou número de chamado sozinho não comprovam que o novo limite já está efetivo.

O envio altera o estado da AWS e não foi feito nesta sessão por causa da restrição de somente leitura. O aumento em si não gera cobrança nem inicia recursos; o uso posterior de serviços é cobrado e permanece condicionado a créditos elegíveis, reserva e gates.

## Critério para encerrar este bloqueio

- Identidade confirma conta/região corretas.
- GetServiceQuota para ec2 / L-1216C47A em sa-east-1 retorna Value >= 12 para o modelo de pico proposto.
- Uso corrente + pico planejado cabe no limite aplicado.
- Registrar evidência e só então atualizar o status de bloqueio no guia.
- Nenhum recurso é criado para testar a quota.

Se a AWS conceder apenas 8 ou 10, comparar explicitamente com a tabela, restringir/submeter o paralelismo de substituição/temporários a revisão e provar folga antes de mudar o aceite. Não tratar aprovação parcial como cobertura automática de 12. Se negar/demorar, guardar a razão e continuar a preparação local sem aumentar consumo.

## Alternativa enquanto aguarda

Código, imagens ARM64, Terraform sem backend remoto, políticas e testes locais podem continuar. Não é necessário manter três EC2 para preparar a migração.

Manter o baseline alvo do PRD. Não parar/reduzir Dev produtivo, mudar para x86, mover ambiente de conta/região ou usar Spot por inferência. Uma eventual operação alternada Dev/UAT seria uma exceção temporária à disponibilidade Dev e precisaria de decisão própria; com dois hosts já ligados, o limite atual também não suporta um terceiro host de substituição.

A quota EC2 não inclui a quota Fargate. Este pedido não resolve L-3032A538, não fecha cotação/reserva e não autoriza provisionamento.

## Verificação somente leitura nesta entrega

GetCallerIdentity, GetServiceQuota, ListRequestedServiceQuotaChangeHistoryByQuota, DescribeInstances e DescribeInstanceTypes. A quota seguia em 5, ajustável, com nenhum pedido/instância retornado. Nenhuma operação de escrita AWS foi executada.

## Referências oficiais

- [Solicitar aumento de quota EC2](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-resource-limits.html).
- [Aumentos não são cobrados; utilização de recursos é cobrada](https://repost.aws/knowledge-center/manage-service-limits).
- [Contagem pelas vCPUs padrão](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/instance-optimize-cpu.html).
