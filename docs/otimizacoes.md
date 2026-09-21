# SCRUM-379 — Otimização da persistência para alto volume de dados

Documento técnico das otimizações aplicadas no Postgres para suportar a recepção
massiva de dados do IoT em tempo real.

## 1. O problema

`readings` é a tabela que cresce sem parar na plataforma. Com 50 sensores
enviando uma leitura por minuto, são **~2,2 milhões de linhas por mês**. Em um
ano, 26 milhões. Nesse tamanho, quatro coisas quebram:

| Sintoma | Causa |
| --- | --- |
| Consultas do gráfico ficam lentas | Os índices deixam de caber em memória; toda consulta vira I/O de disco |
| Ingestão desacelera | Cada índice extra é escrito a cada `INSERT` |
| `VACUUM`/`ANALYZE` demoram | Varrem a tabela inteira; estatísticas envelhecem e o planner erra |
| Apagar dado antigo trava o banco | `DELETE` em massa gera bloat e concorre com a ingestão |

## 2. O que foi feito

| Migration | Otimização |
| --- | --- |
| `010_readings_partitioning.sql` | Particionamento de `readings` por RANGE em `unix_time`, uma partição por mês, gerenciado por **pg_partman** |
| `011_readings_indexes_and_tuning.sql` | Índice parcial para o motor de regras, autovacuum agressivo, `fillfactor 100`, materialized view da última leitura |
| `012_partition_maintenance.sql` | Configuração da manutenção e o alarme da partição `DEFAULT` |
| `neon/maintenance.ts` | Job agendado que roda a manutenção e o refresh da view |

### 2.1 Particionamento por mês

Ganhos: *partition pruning* (a consulta por período lê só as partições
relevantes), índices por partição muito menores, `VACUUM` partição a partição, e
expurgo por `DROP TABLE` em vez de `DELETE`.

Duas consequências a conhecer:

- **A PK passou de `(id)` para `(id, unix_time)`** — o Postgres exige a chave de
  partição na PRIMARY KEY.
- **A FK `triggered_alerts.reading_id → readings(id)` foi removida.** Com a PK
  composta, a FK simples deixa de ser possível. A alternativa seria carregar
  `unix_time` também em `triggered_alerts` e fazer FK composta; optamos por não
  fazer isso para não encarecer o caminho quente da ingestão. A integridade fica
  na aplicação: o motor de regras só insere alerta a partir de uma leitura que
  acabou de ler.
- **A FK `readings.sensor_id → sensors(id)` continua existindo.** Desde o PG12
  uma tabela particionada pode ser o lado que referencia. Só a FK *para*
  `readings` se perde.
- **Partição `DEFAULT`** existe como rede de segurança: sem ela, uma leitura com
  `unix_time` fora de todas as faixas causaria erro de `INSERT` e derrubaria a
  ingestão.

### 2.2 Quem cria e apaga as partições: pg_partman

Esta é a única parte do desenho que falha **em silêncio**. Se ninguém criar a
partição do mês que vem, o `INSERT` não quebra: a leitura cai na `DEFAULT`, o
pruning para de acontecer e ninguém fica sabendo. Por isso o ciclo de vida das
partições é delegado ao `pg_partman` em vez de uma função caseira:

```sql
SELECT partman.create_parent(
  p_parent_table    => 'public.readings',
  p_control         => 'unix_time',
  p_interval        => '1 month',
  p_epoch           => 'seconds',
  p_premake         => 4,
  p_default_table   => true
);
```

- **`p_epoch => 'seconds'`** é o que faz o pg_partman entender que `unix_time` é
  epoch em segundos e ainda assim fatiar por **mês de calendário**. Sem isso
  seria preciso trocar a coluna por `timestamptz`.
- **`p_premake => 4`** cria quatro meses à frente. Se a manutenção falhar, há
  quatro meses de folga antes de qualquer leitura chegar na `DEFAULT`.
- **Retenção de 24 meses** com `retention_keep_table = false`: a partição vencida
  sofre `DROP`, não `DELETE`.

As partições nascem com nome `readings_pYYYYMMDD` (ex.: `readings_p20260901`), e
não `readings_YYYY_MM` como na versão anterior desta migration.

### 2.3 Índices

- **Removido** `idx_readings_time (unix_time DESC)` — redundante com
  `idx_readings_sensor_time` e com o próprio pruning. Cada índice a menos é uma
  escrita a menos em toda ingestão.
- **Adicionado** `idx_readings_consistent_id`, parcial
  (`WHERE data_consistent = true`), para o lote do motor de regras.
- Os índices são declarados **na tabela particionada**, não em cada partição — o
  Postgres os propaga automaticamente para toda partição nova.

### 2.4 Parâmetros de armazenamento

O Postgres recusa storage parameters em tabela particionada
(`cannot specify storage parameters for a partitioned table`), então eles não
podem ficar no pai. A solução é a **tabela template** do pg_partman
(`partman.template_public_readings`): o que estiver nela é replicado em cada
partição criada. Verificado: as 18 partições do teste nasceram com os valores
corretos.

- `fillfactor = 100` — `readings` é append-only, nunca sofre `UPDATE`. Reservar
  espaço na página só desperdiça I/O.
- `autovacuum_*_threshold` absolutos — o padrão de 20% da tabela é longe demais
  quando ela tem milhões de linhas.

### 2.5 Materialized view `mv_latest_readings`

A consulta "última leitura de cada sensor" é a do dashboard em tempo real, e é a
que **piora** com particionamento: o `DISTINCT ON` precisa combinar todas as
partições. A materialized view resolve — ver os números abaixo.

**Avaliado e descartado: `pg_ivm`.** A extensão de *incremental view maintenance*
existe no Neon e eliminaria o `REFRESH`, mas `DISTINCT ON` está na lista de
construções que ela não suporta. Reescrever como `max(unix_time) GROUP BY
sensor_id` seria suportado, porém `min`/`max` em IMMV são recomputados a cada
`DELETE`, e o expurgo de partição é um `DROP TABLE`, que não dispara trigger — a
view ficaria furada sem aviso. Fica a materialized view com `REFRESH` explícito,
que falha alto.

## 3. Resultados medidos

Ambiente: PostgreSQL 16.15, **1.000.000 de leituras** distribuídas em 12 meses,
50 sensores, ~1% marcadas como inconsistentes, pg_partman 5.0.1.

| Consulta | Antes | Depois | Ganho |
| --- | ---: | ---: | ---: |
| Histórico de um sensor no último mês | 2,66 ms | **0,45 ms** | **5,9×** |
| Agregação por hora de um sensor (7 dias) | 2,04 ms | **0,69 ms** | **2,9×** |
| Ingestão de lote (1.000 linhas) | 8,57 ms | 8,83 ms | — |
| Última leitura por sensor (`DISTINCT ON`) | 372,02 ms | 518,68 ms | 0,7× ⚠️ |
| Última leitura por sensor (via materialized view) | 372,02 ms | **0,02 ms** | **~20.700×** |
| Lote do motor de regras (500 leituras) | 0,16 ms | 0,48 ms | 0,3× ⚠️ |
| Expurgar 1 mês de dados | `DELETE` 88 ms + 66k linhas mortas | **`DROP` 2,5 ms**, zero bloat | — |
| Tamanho total (índices) | 187 MB (114 MB) | **177 MB (103 MB)** | −5% |

### Correção em relação à versão anterior deste documento

A versão anterior reportava **2,0× de ganho na ingestão** (11,62 ms → 5,70 ms).
**Esse número não se reproduziu.** Na medição atual a ingestão ficou empatada
(8,57 ms → 8,83 ms), o que faz sentido: antes e depois a tabela tem dois índices,
então não há escrita a menos por `INSERT`. O ganho antigo foi provavelmente ruído
de medição. O particionamento continua valendo pelos outros motivos — consulta,
vacuum e expurgo —, mas **não prometa ganho de ingestão.**

### As duas regressões, explicadas

**`DISTINCT ON` ficou 1,4× mais lento.** É o custo esperado do particionamento
para uma consulta que varre toda a linha do tempo: em vez de um índice só, o
planner combina 17 partições. É exatamente por isso que a materialized view
existe. **Ação: o dashboard deve consultar `mv_latest_readings`, não `readings`
diretamente.**

**O lote do motor de regras ficou 0,32 ms mais lento.** Buscar por
`id > checkpoint` não faz partition pruning, porque a chave de partição é
`unix_time` — o planner toca todas as partições. Em valor absoluto, 0,48 ms por
ciclo é irrelevante (o ciclo roda a cada 15 s), então **não vale mudar nada
agora**. Se um dia a base crescer a ponto de isso incomodar, o caminho é
particionar em duas dimensões ou manter uma fila separada de leituras pendentes —
não um filtro extra por `unix_time`, que testamos e ficou pior.

## 4. Como rodar o benchmark

```bash
docker build -t bench-postgres -f benchmark/Dockerfile.postgres benchmark/
docker run -d --name bench-postgres -e POSTGRES_PASSWORD=postgres -p 5432:5432 bench-postgres

./benchmark/run.sh "postgresql://postgres:postgres@localhost:5432/postgres"
```

A imagem oficial do Postgres não traz o `pg_partman`; o `Dockerfile.postgres`
apenas o instala por cima. O `run.sh` checa a extensão **antes** de gastar o
tempo do seed.

## 5. Como aplicar em produção

> Migração com movimentação de dados. **Janela de manutenção obrigatória.**

1. Validar em homologação com massa equivalente à de produção.
2. `pg_dump -t readings -t triggered_alerts "$DATABASE_URL" > backup.sql`
3. Parar os serviços que escrevem em `readings` (ingestão e motor de regras).
4. Aplicar `010`, `011` e `012` em ordem, com `-v ON_ERROR_STOP=1`.
   A `012` **não** pode rodar dentro de transação: ela chama uma procedure que
   dá `COMMIT` internamente.
5. `ANALYZE readings;`
6. Subir os serviços e conferir `/health`.
7. Publicar o job agendado (`neon/README.md`).
8. Monitorar por alguns dias. Só então: `DROP TABLE readings_old;`

### Agendamento da manutenção

**Escolhido: Neon Scheduled Function Triggers** (`neon/maintenance.ts`), porque
disparam mesmo com a compute em scale-to-zero.

**Descartado: `pg_cron`.** Existe no Neon, mas os jobs só rodam enquanto a
compute está ativa. Com scale-to-zero ligado o job simplesmente não acontece — e
sem erro. Trocaria uma falha silenciosa por outra.

**Descartado: background worker do pg_partman.** Exige
`shared_preload_libraries = 'pg_partman_bgw'`, que não é configurável no Neon.

## 6. Monitoramento

```sql
-- Nenhuma linha deve estar na partição DEFAULT. Esta função levanta exceção
-- se houver — é o que o job agendado chama para falhar alto.
SELECT assert_readings_default_empty();

-- Configuração do particionamento.
SELECT parent_table, partition_interval, retention, premake, epoch
FROM partman.part_config WHERE parent_table = 'public.readings';

-- Tamanho por partição.
SELECT c.relname, pg_size_pretty(pg_total_relation_size(c.oid))
FROM pg_class c
JOIN pg_inherits i ON i.inhrelid = c.oid
JOIN pg_class p ON p.oid = i.inhparent
WHERE p.relname = 'readings'
ORDER BY 1;

-- Índices que nunca são usados — candidatos a remoção.
SELECT relname, indexrelname, idx_scan
FROM pg_stat_user_indexes
WHERE idx_scan = 0
ORDER BY relname;
```

## 7. Alternativas avaliadas e descartadas

**TimescaleDB.** Seria o único jeito de ter criação de chunk no próprio
`INSERT`, sem agendador nenhum. Descartada por três motivos: no Neon só a edição
**Apache-2** está disponível, ou seja, sem retention policy, sem continuous
aggregate e sem compressão — exatamente as features que justificariam a troca; a
hypertable sobre coluna inteira só aceita chunk de **N segundos fixos** (30 dias,
não mês de calendário), enquanto `p_epoch => 'seconds'` do pg_partman preserva o
mês; e jogaria fora o particionamento nativo já construído e medido. A própria
documentação da Neon recomenda pg_partman como a opção in-platform para série
temporal.

**`pg_ivm` para a materialized view.** Ver seção 2.5.

**Compressão de partições antigas.** Exigiria TimescaleDB TSL (indisponível no
Neon) ou `pg_squeeze`. Fora do escopo enquanto o volume for este.

**Réplica de leitura para o dashboard.** Separaria a carga analítica da ingestão;
faz sentido quando a plataforma sair do MVP.
