# RDS independente do cache — DEP-R03

Implementação local de 09/11/2026. Não aplicada, não publicada e sem plan AWS aprovado. Base remota reconciliada: `02c3f6e0770f1b339ad4f404ce8b9087e37531c5`; os arquivos de dados não divergiam dessa revisão antes da alteração. Alterações locais anteriores foram preservadas.

Nas roots Prod/UAT, `rds_enabled` e `cache_enabled` são opcionais. Quando null, cada um herda `data_enabled`, preservando os callers existentes. `provision_enabled` continua sendo obrigatório para instanciar o módulo. Para preparar somente o banco, usar `rds_enabled=true`, `cache_enabled=false`; isso não aprova provisionamento nem financiamento.

O módulo mantém ambos os serviços habilitados por padrão para compatibilidade. Blocos `moved` migram os seis endereços antigos para `[0]`, preservando a identidade dos recursos já gerenciados. Nunca remover esses blocos para contornar um plan. Desabilitar explicitamente um serviço existente pode planejar sua exclusão: recusar destruição não prevista e revisar cada ambiente/state separadamente.

RDS isolado não exige versão, SG ou grupo RBAC do cache. Cache habilitado continua exigindo versão e RBAC. O banco mantém PostgreSQL16, rede privada, TLS, KMS explícita, master gerenciado, logs criptografados, proteção de exclusão e 14 dias de retenção em Prod. Single-AZ preserva a baseline do PRD.

`database_name` permite criar `sofascore` na instância nova. O default null preserva o comportamento anterior. `allocated_storage_gib` e `max_allocated_storage_gib` preservam 40/200, mas aceitam dimensionamento revisado; o teto precisa ser pelo menos 10% maior. O default não certifica espaço para a origem selecionada. O manifesto físico histórico da seleção indica 76.792.938.636 bytes expandidos; medir banco lógico, índices, WAL e temporários antes do plan habilitado. O teste com 120GiB é sintético, não capacidade aprovada.

`postgres_master_secret_arn` retorna somente referência. Valores de secrets não entram no Terraform, plans publicados, argv ou SSM. A importação SQL continua sendo operação separada, em banco vazio, por executor temporário restrito na VPC Prod.

Validação: Terraform1.13.5/provider6.69.1; 10 testes mock passaram, fmt passou e validate passou no módulo e em ambas as roots. Mocks não comprovam ausência de drift/destruição no state real. DEP-R03 permanece em andamento até revisão do plan autenticado.

Antes de aplicar, completar CMK/policy Prod, executor/importador, backend/ownership, capacidade, cobertura/reserva para o lote RDS e restauração independente, checks/revisão de código e saved plan sem destruição inesperada. Nenhum input de aprovação é preenchido automaticamente.
