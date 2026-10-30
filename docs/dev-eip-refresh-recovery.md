# EIP associado e drift da flag de IP público no refresh

O diagnóstico privado do run Dev `40937717657`, preservado pelo coordenador, identificou um único atributo que forçava replacement da EC2: `associate_public_ip_address=true -> false`. A alteração `user_data_replace_on_change=true -> false` não era ForceNew. `prevent_destroy` bloqueou corretamente a proposta de substituição. Não houve apply desse plano nem reparo/mutação de state por esta correção.

No provider AWS **6.69.1**, `associate_public_ip_address` é Optional/Computed/**ForceNew** no schema. Na leitura, a função de flatten da instância atribui `primaryNetworkInterface.Association != nil` à flag, incluindo associação de EIP; não registra exclusivamente a decisão de IP efêmero tomada no lançamento. Já o caminho de criação usa `GetOkExists` e passa o booleano explícito para `NetworkInterfaceSpecification.AssociatePublicIpAddress`. Por isso manter false no HCL é necessário para o contrato de criação, mas comparar literalmente false com uma presença true posterior ao EIP provoca replacement indevido.

Fonte primária: [ec2_instance.go v6.69.1](https://github.com/hashicorp/terraform-provider-aws/blob/v6.69.1/internal/service/ec2/ec2_instance.go), funções `resourceInstanceSchema`, `buildNetworkInterfaceOpts` e `flattenInstance`; SHA256 do raw source auditado `8293ee11bb56a99461e90a7c7193fcd56917e0405111f032315b8b4184129aa6`. O CustomizeDiff de user_data só usa ForceNew quando `user_data_replace_on_change` é true. A função Update mantém seu caminho de stop/start para user data, sujeito a IAM/execução real.

## Correção delimitada

O único campo ignorado em `aws_instance.this` é `associate_public_ip_address`. A configuração de lançamento continua **false**. `prevent_destroy` da EC2 e do EIP, volume criptografado/retido, AMI, subnet/SG/profile, tags, IMDSv2 e user data continuam gerenciados. Não há `ignore_changes=all`, ignore de user data/AMI/discos/rede/tags, postcondition EC2→EIP ou mudança no recurso EIP.

Lifecycle ignore considera a configuração na criação, mas desconsidera mudanças desse atributo em updates, conforme o [contrato Terraform](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#ignore_changes). O EIP permanece associado pelo recurso `aws_eip.this.instance = aws_instance.this.id`, sem ciclo de dependência. Não se cria uma postcondition que exija EIP já associado durante a criação da EC2 anterior à criação do próprio EIP.

A limitação é explícita: o ignore não distingue a procedência de qualquer associação pública. Portanto ele também deixa de detectar, por essa flag isolada, uma alteração externa de IP efêmero. O reviewer e os aceites precisam conferir subnet `MapPublicIpOnLaunch=false`, ENI primária, allocation/association/instance do EIP gerido e a ausência de endereço efêmero indevido. O coordenador confirmou esses vínculos ao vivo antes desta proposta; esta implementação não chamou APIs AWS e não apresenta essa observação como teste próprio. O EIP deve continuar sendo reconciliado pelo seu recurso separado.

Mudar launch para true autorizaria IP efêmero não previsto; omitir o atributo delegaria o comportamento à configuração futura da subnet; migrar para blocos de ENI ou outro provider ampliaria o delta. Essas alternativas não integram esta correção. Não falsificar state para devolver a flag a false: o próximo refresh voltaria a reportar presença true.

## Provas locais significativas

`tests/dev-box-lifecycle.test.mjs` exige a lista exclusiva de ignore, lançamento false, user data gerenciado/in-place e as proteções EC2/root/EIP. O primeiro teste falhou antes da correção e passou depois. O mock Terraform existente também confirma lançamento false, retenção/criptografia e `user_data_replace_on_change=false`.

`tests/dev-box-lifecycle-integration.mjs` usa **Terraform1.13.5 e o provider AWS6.69.1 reais** para seis plans, sem apply. O diretório/backend/state são locais, novos e integralmente sintéticos. Usa `-refresh=false`, credenciais falsas, metadata desabilitada e endpoints EC2/STS em `127.0.0.1:1`, com retries zero: eventual chamada de serviço inesperada falha localmente. Remove credenciais/variáveis CLI/proxies herdados desse processo; nenhum backend S3 ou state da conta é lido. O lookup AMI é a única seam: no harness, é substituído por metadata sintética AL2023 ARM64. O recurso EC2 e lifecycle testados vêm do módulo real; EIP separado não integra esse state sintético, sendo conferido pelo guard de fonte e pelo mock/aceite ao vivo.

| Caso nativo local | Resultado exigido |
|---|---|
| Config false, state com presença true após associação | No-op; conserva true observado sem planejar substituição |
| Mesmo state/config, removendo só o ignore na cópia de teste | Falha prevent_destroy; flag de associação aparece explicitamente como causa ForceNew |
| User data muda e estratégia antiga true passa a false | Update, sem replace_paths; ID, criptografia e retenção preservados |
| AMI muda | Falha prevent_destroy; AMI aparece explicitamente como causa ForceNew |
| State sintético com root sem criptografia, config exige true | Falha prevent_destroy; encrypted aparece explicitamente como causa ForceNew |
| Criação sem state anterior, com ignore presente | Create com associate_public_ip_address=false |

O teste não comprova stop/start real, reboot, preservação operacional ou um saved plan autenticado. Também não afirma que prevent_destroy bloqueia toda atualização in-place de volume: tamanho e outros atributos continuam gerenciados, sujeitos às validações/limites existentes e ao comportamento AWS. Ele comprova que replacements de AMI/root não foram mascarados pelo ignore.

```text
node --test tests/dev-box-lifecycle.test.mjs
node tests/dev-box-lifecycle-integration.mjs
terraform -chdir=modules/dev-box init -backend=false -input=false -lockfile=readonly
terraform -chdir=modules/dev-box test
```

O workflow de validação executa o ensaio nativo depois de inicializar os providers/roots sem credenciais. O relatório sanitizado local fica em `reports/private/dev-eip-lifecycle-last.json`; o diretório temporário contendo state/plans sintéticos é removido com verificação de caminho.

## Segurança e próxima revisão

A exceção source-bound **CKV_AWS_126**, somente do bloco EC2, teve hash/data/racional novamente revisados, mantendo check, recurso, motivo de monitoramento padrão e vencimento `2027-01-25`. Nenhuma exceção nova, skip ou validade ampliada. O ignore não altera métricas nem ativa detailed monitoring. Rodar o gate Dev com o scan completo e a mesma allowlist revisada continua obrigatório.

Publicar/revisar o patch e checks pelo coordenador; depois gerar **novo plan Dev** com commit/inputs/backend/state atuais. O plan falho não deve ser reutilizado. Revisar ausência de delete/replacement e exclusividade do delta antes da aprovação/aplicação protegida, mantendo todos os gates. Não alterar grants, state, root volume/EIP, launch para true ou prevent_destroy para contornar a falha. Shared, DNS/TLS público e escritores de negócio não recebem novas permissões por esta correção.
