-- =============================================================================
-- SCRUM-379 — Bateria de benchmark da tabela `readings`
--
--   psql "$DATABASE_URL" -f benchmark/benchmark.sql > resultado.txt
--
-- Rode ANTES e DEPOIS das migrations 010-012 e compare os tempos e o número
-- de partições/páginas lidas em cada plano.
-- =============================================================================

\timing on
\pset pager off

\echo '===== 0. Tamanho ocupado ====='
-- Numa tabela particionada, pg_total_relation_size('readings') devolve 0:
-- o pai não guarda dados. É preciso somar as partições.
SELECT
  pg_size_pretty(COALESCE(sum(pg_total_relation_size(c.oid)), 0)
                 + pg_total_relation_size('readings'))  AS total,
  pg_size_pretty(COALESCE(sum(pg_indexes_size(c.oid)), 0)
                 + pg_indexes_size('readings'))         AS somente_indices,
  count(c.oid)                                          AS particoes,
  (SELECT count(*) FROM readings)                       AS linhas
FROM pg_class c
LEFT JOIN pg_inherits i ON i.inhrelid = c.oid
LEFT JOIN pg_class p ON p.oid = i.inhparent AND p.relname = 'readings'
WHERE p.oid IS NOT NULL;

\echo ''
\echo '===== 1. Histórico de um sensor no último mês (consulta do gráfico) ====='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, value, unix_time
FROM readings
WHERE sensor_id = 1
  AND unix_time >= extract(epoch FROM now() - interval '30 days')::bigint
  AND unix_time <  extract(epoch FROM now())::bigint
ORDER BY unix_time DESC
LIMIT 500;

\echo ''
\echo '===== 2. Última leitura de cada sensor (dashboard em tempo real) ====='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT DISTINCT ON (sensor_id) sensor_id, value, unix_time
FROM readings
ORDER BY sensor_id, unix_time DESC;

\echo ''
\echo '===== 3. Lote do motor de regras (leituras novas por id) ====='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT id, sensor_id, value, unix_time
FROM readings
WHERE id > 0 AND data_consistent = true
ORDER BY id ASC
LIMIT 500;

\echo ''
\echo '===== 4. Agregação por hora de um sensor (relatório) ====='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT
  to_timestamp(unix_time - (unix_time % 3600)) AS hora,
  avg(value)::numeric(10,2) AS media,
  max(value) AS maxima,
  min(value) AS minima
FROM readings
WHERE sensor_id = 1
  AND unix_time >= extract(epoch FROM now() - interval '7 days')::bigint
GROUP BY 1
ORDER BY 1 DESC;

\echo ''
\echo '===== 5. Ingestão: INSERT em lote de 1000 leituras ====='
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
INSERT INTO readings (sensor_id, value, unix_time)
SELECT (g % 10) + 1, 25.0, extract(epoch FROM now())::bigint + g
FROM generate_series(1, 1000) g;

\echo ''
\echo '===== 6. Expurgo: apagar dados com mais de 1 ano ====='
\echo '  ANTES  -> DELETE FROM readings WHERE unix_time < ... (minutos, gera bloat)'
\echo '  DEPOIS -> DROP TABLE readings_pYYYYMMDD via pg_partman (instantâneo, sem bloat)'

\echo ''
\echo '===== 7. Dashboard via materialized view (só existe após a 011) ====='
\echo '  Se a view ainda não existe, este bloco falha — é o esperado no "antes".'
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF)
SELECT sensor_id, value, unix_time FROM mv_latest_readings;
