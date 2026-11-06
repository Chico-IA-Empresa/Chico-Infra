# Configuração sintética Dev

Esta allowlist é separada do inventário candidato da aplicação. Não copiar as variáveis produtivas para Dev. Nenhuma versão de secret é gerida por Terraform.

| Nome | Store | Consumidor | Entrega |
|---|---|---|---|
| /chico/dev/api/SYNTHETIC_TOKEN | Secrets Manager, CMK Dev | helper root e consumidor API sintético | resolver asm-exec revisado em memória → arquivo 0600 por lançamento em /run/chico/api/LAUNCH32/synthetic_token |
| /chico/dev/api/FIXTURE_MODE | SSM String, valor `synthetic` | fixture API | GetParameters exato; sem GetParametersByPath |

`fixtures/dev/refresh-config.sh LAUNCH32` fixa a referência dinâmica e exige execução sintética explícita. Instalar/revisar `asm-exec` antes de executar; o binário é dependência externa da skill AWS Secrets Manager, não foi instalado no host nem provado nesta rodada. A implementação fornecida resolve somente argv; o adaptador carrega sua função de resolução em memória por SHA256 exato para evitar plaintext em argumentos. Não presume flags de stdin/environment ausentes. Ver pin, instalação e limitações em `docs/dev-acceptance-recovery.md` §E.

Cada lançamento usa identificador de 32 hex e arquivo novo em tmpfs, com diretório 0700/arquivo 0600, recusando overwrite. `config-consumer.py serve --token-file /run/secrets/synthetic_token` lê somente no lançamento e responde a um controlador privado por stdin apenas com booleanos. A rotação resolve B em outro caminho; o consumidor A mantém seu snapshot. VersionId é conferido por metadata antes/depois sem rotação concorrente; a resolução AWSCURRENT não oferece binding atômico por VersionId.

O arquivo em `/run` é volátil: refazer resolução antes de relançar consumidor após reboot. Montar somente o arquivo do consumidor, como read-only; não montar todo `/run/chico`, socket Docker ou IMDS. Limpar somente o arquivo do lançamento encerrado. Não usar `set -x`, imprimir argumentos resolvidos, `docker inspect` de ambiente com valores, logs de debug ou captura de stdout do resolver. Candidatos A/B não entram em argumentos, environment, payload SSM ou transcript; o controlador os envia por pipe privado.

A fixture Compose PostgreSQL usa outra credencial sintética local, gerada pelo operador no destino `/run/chico/fixture_password`, 0600. Nenhuma credencial de banco real é necessária. O secret acima é para prova isolada de rotação, não credencial financeira ou de produção.

Prova pendente na AWS: operador popula versão aleatória via fluxo privado, executa helper, inicia consumidor com bind somente desse arquivo, registra VersionId e comportamento sem plaintext; troca versão e repete o lançamento. Consumidor anterior não deve mudar silenciosamente. Testar role sem ARN autorizado e CMK indevida com AccessDenied real; registrar request IDs. Testes locais verificam somente o armazenamento sintético e atualização do arquivo, não resolução AWS/CMK/negação real.

As policies de serviço e KMS precisam revisão conjunta: CMK da mesma conta não comprova ser Dev. Conferir ownership/tags e policy real antes do plan final. Runtime do host é a fronteira de confiança dos consumidores: quem controla root/SSM do host consegue ler seus arquivos; não há isolamento IAM por container em um único instance profile. IMDSv2 hop limit 1 e ausência de host networking reduzem acesso direto por containers; comprovar no host.
