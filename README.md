# API-DSM-4-BANCO

Migrations de otimização e scripts de benchmark do banco da plataforma AgroClima 360 (Equipe Vulture — 4º DSM).

| Task Jira | Entrega |
| --- | --- |
| SCRUM-379 | Otimizar persistência para alto volume de dados |

## Conteúdo

```
setup/
  apply.mjs                              # aplica os SQL sem precisar de psql
  schema-neon.sql                        # schema completo, idempotente
  seed-dev.sql                           # dados mínimos de desenvolvimento
  seed-demo.sql                          # dados de demonstração (NÃO rodar no Neon compartilhado)
migrations/
  010_readings_partitioning.sql          # particionamento mensal de readings
  011_readings_indexes_and_tuning.sql    # índices, autovacuum, fillfactor, MV
  012_partition_maintenance.sql          # criação e expurgo automático de partições
  013_restore_column_defaults.sql        # restaura os DEFAULT das colunas no Neon
  014_one_pending_alert_per_rule.sql     # no máximo 1 alerta pendente por regra (fecha duplicados)
  015_role_permissions.sql               # catálogo e associações de permissões (SCRUM-432)
  016_occurrences.sql                    # ocorrências de falhas e limites dos sensores (SCRUM-395)
benchmark/
  seed_readings.sql                      # massa sintética
  benchmark.sql                          # bateria de consultas com EXPLAIN ANALYZE
  run.sh                                 # roda antes/depois e salva os resultados
docs/
  otimizacoes.md                         # decisões, resultados medidos e plano de aplicação
```

## Resumo dos ganhos

Medidos com 1M de leituras, 50 sensores, 12 meses (PostgreSQL 16):

- Histórico de um sensor: **5,9× mais rápido**
- Agregação por hora: **3,7× mais rápido**
- Ingestão em lote: **2,0× mais rápido**
- Dashboard de última leitura (via materialized view): **~12.900× mais rápido**
- Expurgo de dados antigos: **143× mais rápido**, sem bloat

Duas consultas regrediram de propósito, com contrapartida — detalhes em [`docs/otimizacoes.md`](docs/otimizacoes.md).

## Preparar o banco no Neon

```bash
npm install
npm run db:setup
```

Detalhes em [`setup/README.md`](setup/README.md).

## Rodar o benchmark

Num Postgres **descartável**, nunca no Neon:

```bash
docker run -d --name bench-postgres -e POSTGRES_PASSWORD=postgres -p 5440:5432 postgres:17-alpine
./benchmark/run.sh "postgresql://postgres:postgres@localhost:5440/postgres"
```

Para aplicar em produção, siga o passo a passo da seção 5 de [`docs/otimizacoes.md`](docs/otimizacoes.md). **É uma migração com movimentação de dados — exige janela de manutenção e backup.**

### Telemetria e precisão (SCRUM-448)

A migration 016 adiciona limites opcionais nos sensores e amplia as leituras para
NUMERIC sem escala fixa. Instruções, testes, manutenção e limitações das APIs em
[setup/README.md](setup/README.md#scrum-448--limites-e-precisão-da-telemetria).
A alteração preserva precisão no banco; não recupera histórico arredondado nem
altera o contrato HTTP do BACKEND.

### Recuperação e replay (SCRUM-530)

A migration 018 acrescenta auditoria de solicitações/tentativas/resultados de
replay e incidentes de conteúdo ausente no Stream. Preserva origens/rejeições,
protege campos já aceitos e registra o corte legado para novos eventos.
Setup aplica 018 antes do seed. Contrato, permissões e operação em
[setup/README.md](setup/README.md#scrum-530--auditoria-de-recuperação-e-replay).
A execução permanece optativa no tratamento; implantação continua na SCRUM-531.
