# Configuração sintética Dev

Esta allowlist é separada do inventário candidato da aplicação. Não copiar as variáveis produtivas para Dev. Nenhuma versão de secret é gerida por Terraform.

| Nome | Store | Consumidor | Entrega |
|---|---|---|---|
| /chico/dev/api/SYNTHETIC_TOKEN | Secrets Manager, CMK Dev | helper root e consumidor API sintético | asm-exec → arquivo 0600 em /run/chico/api/synthetic_token |
| /chico/dev/api/FIXTURE_MODE | SSM String, valor `synthetic` | fixture API | GetParameters exato; sem GetParametersByPath |

`fixtures/dev/refresh-config.sh` fixa a referência dinâmica e exige execução sintética explícita. Instalar/revisar `asm-exec` antes de executar; o binário é dependência externa da skill AWS Secrets Manager, não foi instalado no host nem provado nesta rodada. O arquivo em `/run` é volátil: refazer resolução antes de relançar consumidor após reboot. Montar somente o arquivo do consumidor, como read-only; não montar todo `/run/chico`, socket Docker ou IMDS. Limpar arquivo ao parar o consumidor. Não usar `set -x`, imprimir argumentos resolvidos, `docker inspect` de ambiente com valores, logs de debug ou captura de stdout do resolver.

A fixture Compose PostgreSQL usa outra credencial sintética local, gerada pelo operador no destino `/run/chico/fixture_password`, 0600. Nenhuma credencial de banco real é necessária. O secret acima é para prova isolada de rotação, não credencial financeira ou de produção.

Prova pendente na AWS: operador popula versão aleatória via fluxo privado, executa helper, inicia consumidor com bind somente desse arquivo, registra VersionId e comportamento sem plaintext; troca versão e repete o lançamento. Consumidor anterior não deve mudar silenciosamente. Testar role sem ARN autorizado e CMK indevida com AccessDenied real; registrar request IDs. Testes locais verificam somente o armazenamento sintético e atualização do arquivo, não resolução AWS/CMK/negação real.

As policies de serviço e KMS precisam revisão conjunta: CMK da mesma conta não comprova ser Dev. Conferir ownership/tags e policy real antes do plan final. Runtime do host é a fronteira de confiança dos consumidores: quem controla root/SSM do host consegue ler seus arquivos; não há isolamento IAM por container em um único instance profile. IMDSv2 hop limit 1 e ausência de host networking reduzem acesso direto por containers; comprovar no host.
