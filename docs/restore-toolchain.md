# Toolchain sintético de restore PostgreSQL16

Toolchain amd64 para validar PostgreSQL16 e pgBackRest em fixtures sintéticas novas, com pacotes e headers do mesmo fornecedor. O workflow `restore-toolchain.yml` constrói a imagem, executa as provas Linux e publica evidências sintéticas e o scan dos bytes finais. A integração deste código não aprova dados reais, staging, publicação da imagem ou instalação no host; esses usos mantêm revisões e gates próprios.

## Mudança proposta

Usar UbuntuNoble tanto no build quanto no runtime, com PostgreSQL16.15 nativo do arquivo Ubuntu e libxml2 do mesmo fornecedor; compilar pgBackRest2.57.0 contra headersNoble. Isso elimina a mistura de consumidores Bookworm com uma biblioteca Ubuntu em /opt, sem desabilitar XML/SQLXML ou omitir pacotes do scan.

- Base oficialubuntu24.04 amd64: sha256:78d4744ead1f5b19b04d0df558ab182a5300903900755e515b2ca4d10eb2044d. O manifest child e seu SHA256 foram conferidos na revisão. O scan da base não substitui o scan da imagem final com PostgreSQL/pgBackRest, publicado pelo workflow.
- PostgreSQL/client/libpq:16.15-0ubuntu0.24.04.1, pacotes nativosUbuntuNoble. A versão16.13 era pin do candidatoPR16/testes, não requisito do plano canônico, que exigePG16. A troca de minor é explícita e precisa de revisão.
- libxml2/libxml2-dev:2.9.14+dfsg-1.3ubuntu3.10. A [página Ubuntu CVE-2026-6653](https://ubuntu.com/security/CVE-2026-6653) registra correçãoNoble desde3.8; o [pacote atualizado](https://packages.ubuntu.com/noble-updates/libxml2) publica3.10.
- O build oficial[33517303](https://launchpad.net/~ubuntu-security-proposed/+archive/ubuntu/ppa/+build/33517303) do [PostgreSQL16.15](https://packages.ubuntu.com/noble-updates/postgresql-16) usou libxml2 e headers3.8 já corrigidos, libc2.39 eICU74. Não é o binárioBookworm dePR16. O buildlog oficial filtrado fica no diretório de revisão privado.
- PCRE2 runtime: libpcre2-8-0=10.42-4ubuntu2.2, atualização nativa publicada nos pockets Noble Security/Updates do arquivo Ubuntu. O pin explícito atualiza a dependência já presente na base; somente apt-get update não atualizaria o pacote instalado. APT assinado deve confirmar disponibilidade, e o novo scan deve medir os bytes finais.
- pgBackRest mantém sourcecommitd9773a31c97077761ee8e7d06e073b0b0734e26f, archiveSHA25661d3183877da9a809a889e61d3c0bd0dc9b3498e0777aeba1d34aa1c16a16b74 e versão2.57.0.

APT usa HTTPS, CAs públicas do runner registradas por hash e assinaturasUbuntu normais. Pacotes destacados são fixados, demais dependências são inventariadas; não há alegação de build hermético. Não há pacote de fonte externa, assinatura desabilitada, VEX, waiver, severity override ou fake version metadata. APT deve falhar se os pins deixarem de existir.

Runtime cria postgresUID/GID999 explicitamente, bloqueia início de serviços durante instalação e desabilita criação automática de main cluster antes de instalar o servidor. O build recusa qualquer PGDATA/configmain gerado. Mantém entrypointpgBackRest, sem auto-initdb/VOLUME. O harness retém rede none, rootfs read-only, cap-dropALL, no-new-privileges, UID numérico e tmpfs que cobre o caminho de dados. Não remove SQLite/GPG da imagem para alterar findings: começa de imagem oficialUbuntu e instala somente as dependências necessárias, todas escaneadas.

## Testes e gates preservados

O harness continua criando um repositório sintético cifrado novo, full+diff, validando os dois labels, rejeitando corrupção sintética, verificando WAL/control/header e recuperando três linhas. Adiciona XMLPARSE/xpath benignos antes do full e uma consulta XML no cluster recuperado, mais verificação real da opção--with-libxml. Essas consultas não são PoC, fuzz ou testes de exploração e não usam dados reais.

Os helpers VEX antigos permanecem somente como testes históricos específicos deBookworm; o harnessNoble não chama nem generaliza suas conclusões. A coleta nova registra bytes/ELF do zlib e o inventário bruto, sem emitir VEX. O collector de pacotesBookworm deixa de ser executado nesta proposta. O scan da imagem final requer inventárioUbuntu24.04 completo, ImageID exato, ignorefile vazio, unfixed incluído e zeroCRITICAL; findings de outras severidades continuam para revisão. Nenhum scan de base é transferível à imagem com PG/pgBackRest.

## Limites para o restore real

Os [minorPG16 compartilham formato de armazenamento](https://www.postgresql.org/docs/16/upgrading.html), mas isso NÃO prova portabilidade do cluster físico entre distros/arquiteturas/compilações. Este candidato éamd64 para staging; DevARM recebe dump lógico, nunca PGDATA físico copiado deamd64.

Antes do restore real ainda faltam metadados/inventário da seleção fixada: locale, encoding, provider e versões de collation, libc/ICU da origem, extensões/Cbibliotecas e parâmetros físicos relevantes. Noble traz libc2.39/ICU74; isso não equivale à origem desconhecida nem à imagemDevARM. locales-all apenas disponibiliza nomes, não garante regras de ordenação idênticas. Não ignorar warnings, executarALTER COLLATION REFRESH VERSION ou reindexar automaticamente para contornar incompatibilidade. Exigir plano revisado para índices/collations/extensões antes de dados reais; funções/preloads/escritores permanecem inativos.

Só o buildLinux real pode provar resoluçãoAPT, pacotes/headers/libraries finais, SQLXML, backup/WAL/recuperação sintéticos e scan final. Só o staging e a importação reais aprovados podem provar o backup selecionado, equivalência de schema/dados/sequências/constraints, configuração segura e o bancoDev utilizável. Backup próprioDev e segunda recuperação continuam aceites separados. Não há autorização de AWS/state/staging/ECR/host nesta proposta.

## Noble APT maintenance amendment (2026-11-05)

The fresh delivery scan exposed HIGH CVE-2026-109518 in apt and libapt-pkg6.0t64 2.8.3 and stopped before AWS credentials. [Ubuntu USN-8996-1](https://ubuntu.com/security/notices/USN-8996-1) identifies Noble 2.8.4ubuntu0.1 as fixed. Both build and runtime stages now install and verify those exact native package versions before their other dependencies. Every APT invocation explicitly disables download retries, including the initial update and upgrade performed by the inherited client; HTTPS sources, trusted CA and signed package verification remain required. The final fix is the updated packages, with no package removal, waiver, VEX or severity override.

The delivery input manifest retains its original canonical baseline and explicitly names this reviewed amendment; all seven input hashes remain checked. This changes the source/package fingerprints, so older delivery reviews and consumed dispatches cannot authorize publication. A new native build, full synthetic recovery/SQLXML/WAL checks and complete scan of its final bytes are required; a stale scanner that still reports HIGH must continue blocking. No build or runtime installation, ECR publication or real-data processing is authorized by this amendment.
