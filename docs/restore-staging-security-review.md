# Gate de segurança do staging temporário — 28/10/2026

O CI e `scripts/check-security.ps1` avaliam a root `operations/restore-staging/terraform` separadamente dos gates permanentes. Usam `security/restore-staging-scan.tfvars` somente no Checkov para expandir os blocos habilitados. A fixture tem lease expirado, IDs fictícios e nenhuma aprovação financeira/readiness: nunca deve ser usada no Terraform, nem comprova identidade, IAM ou acesso real.

O Checkov3.3.29 encontrou 31 controles aprovados e dois achados, sem skips ou erros de parsing. `security/restore-staging-exceptions.json` aceita somente esses dois endereços/checks, com motivo, controles, validade e SHA256 normalizado do módulo. Mudança de fonte, achado novo, exceção expirada/obsoleta ou supressão bloqueiam o gate. As 43 exceções dos scopes permanentes continuam separadas. O scan geral de todos os blueprints permanece obrigatório.

| Achado | Decisão técnica e limite |
|---|---|
| CKV_AWS_126 | Manter monitoramento EC2 básico no host temporário, dentro da proposta. [AWS documenta métricas básicas de cinco minutos e monitoramento detalhado de um minuto com cobrança adicional](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/manage-detailed-monitoring.html). Acompanhamento SSM, timer persistente UTC e lease IAM exigem prova no host; a presença do código não comprova seu funcionamento. |
| CKV_AWS_88 | IPv4 temporário oferece saída HTTPS sem novo NAT/interface endpoint. SG não tem ingresso; somente TCP443 de saída. [SSM inicia conexões de saída e não exige portas de entrada](https://docs.aws.amazon.com/systems-manager/latest/userguide/troubleshooting-ssm-agent.html). A regra permite HTTPS para qualquer destino: não comprova allowlist de domínios. PostgreSQL será recuperado sem rede/portas e sem acesso IMDS; essa prova precede o restore. Nenhuma exposição do banco ou da aplicação foi autorizada. |

O scanner não expande/verifica os 178 VersionIds da seleção real nem demonstra leitura efetiva. Os documentos privados reais de acesso temporário ainda devem passar no Access Analyzer e em negativas com a identidade real. A revisão prévia desses candidatos encontrou zero achados estáticos; não substitui as provas do host.

Antes do apply, a revisão privada deve reconciliar os recursos e custos reais (inclusive IPv4, disco parado e limpeza), conta/AMI/VPC, seleção e lease, cadeia de ferramentas/cipher, capacidade, destino Dev e saved plan. O timer para compute; não remove cobrança do EBS. Não importar o bucket legado nem conceder escrita nele. Nenhum recurso é criado por este gate e nenhum resultado sintético concede aceite operacional.
