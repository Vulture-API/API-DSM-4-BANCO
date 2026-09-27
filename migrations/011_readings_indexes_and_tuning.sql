-- SCRUM-379 — Índices, tuning de armazenamento e materialized view.
-- Aplicar depois da 010. Racional e números em docs/otimizacoes.md.
--
-- JANELA DE MANUTENÇÃO: aplicar na MESMA janela da 010, com os serviços de
-- escrita parados. O CREATE INDEX da etapa 2 roda sobre o histórico inteiro já
-- copiado e toma lock de escrita partição por partição enquanto constrói.
-- Não dá para usar CREATE INDEX CONCURRENTLY: o Postgres 16 não o suporta em
-- tabela particionada. O caminho alternativo (índice CONCURRENTLY em cada
-- partição, depois CREATE INDEX ON ONLY no pai e ATTACH PARTITION de cada um)
-- só se justifica se um dia for preciso criar índice com a ingestão de pé.

BEGIN;

-- 1. Índice redundante -------------------------------------------------------

-- `idx_readings_time (unix_time DESC)` era redundante com
-- idx_readings_sensor_time, e o recorte temporal puro passou a ser resolvido
-- pelo partition pruning. Ele não é recriado na tabela nova: a 010 o deixou
-- para trás, renomeado, preso à readings_old. Cada índice a menos é uma
-- escrita a menos em toda ingestão.

-- 2. Índice do motor de regras -----------------------------------------------

-- O motor varre `WHERE id > checkpoint ORDER BY id LIMIT n` e só avalia
-- leituras consistentes, então o índice parcial basta e é menor.
--
-- Limitação conhecida: como a chave de partição é unix_time, filtrar só por
-- id não faz pruning e toca todas as partições. Medido em 0,6 ms com 1M de
-- linhas, irrelevante para um ciclo de 15 s. Acrescentar um filtro por
-- unix_time piora (o planner perde o caminho direto pelo índice) — não faça
-- isso sem medir. Ver docs/otimizacoes.md, seção 3.
CREATE INDEX IF NOT EXISTS idx_readings_consistent_id
  ON readings (id)
  WHERE data_consistent = true;

-- 3. Storage parameters nas partições já existentes --------------------------

-- As partições NOVAS herdam isto de partman.template_public_readings (010,
-- etapa 4). Este bloco é a rede de segurança para as que já existem no momento
-- da migração, e para o caso de a versão do pg_partman não replicar reloptions
-- do template. Precisa ser partição por partição: o Postgres recusa storage
-- parameters na tabela particionada.
DO $$
DECLARE
  part record;
BEGIN
  FOR part IN
    SELECT c.oid::regclass AS ident
    FROM pg_class c
    JOIN pg_inherits i ON i.inhrelid = c.oid
    JOIN pg_class parent ON parent.oid = i.inhparent
    WHERE parent.relname = 'readings'
      AND parent.relnamespace = 'public'::regnamespace
      AND c.relkind = 'r'
  LOOP
    EXECUTE format(
      'ALTER TABLE %s SET (
         fillfactor = 100,
         autovacuum_vacuum_scale_factor = 0.01,
         autovacuum_vacuum_threshold = 10000,
         autovacuum_analyze_scale_factor = 0.005,
         autovacuum_analyze_threshold = 5000
       )',
      part.ident
    );
  END LOOP;
END;
$$;

-- 4. Índices do caminho quente de alertas ------------------------------------

CREATE INDEX IF NOT EXISTS idx_alert_configs_sensor_active
  ON alert_configs (sensor_id)
  WHERE active = true;

CREATE INDEX IF NOT EXISTS idx_triggered_alerts_pending
  ON triggered_alerts (triggered_at DESC)
  WHERE acknowledged_at IS NULL;

-- 5. Última leitura por sensor -----------------------------------------------

-- Esta é a única consulta que PIORA com o particionamento: o DISTINCT ON
-- precisa combinar todas as partições. A materialized view é a contrapartida
-- (medido: 645 ms -> 0,05 ms).
--
-- O dashboard deve consultar mv_latest_readings, NÃO readings.
-- Atualização: ver 012 (roda junto com a manutenção do pg_partman).
--
-- Avaliado e descartado: pg_ivm (incremental view maintenance, disponível no
-- Neon) manteria a view atualizada sozinha e eliminaria o REFRESH. Não serve
-- aqui porque `DISTINCT ON` está na lista de construções que o pg_ivm não
-- suporta. Reescrever como `max(unix_time) GROUP BY sensor_id` seria suportado,
-- mas min/max em IMMV são recomputados a cada DELETE — e o expurgo de partição
-- não dispara trigger, o que deixaria a view furada sem aviso. Fica a
-- materialized view com REFRESH explícito, que falha alto.
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_latest_readings AS
SELECT DISTINCT ON (sensor_id)
  sensor_id,
  id AS reading_id,
  value,
  unix_time,
  data_consistent,
  created_at
FROM readings
ORDER BY sensor_id, unix_time DESC;

-- Índice único é requisito do REFRESH CONCURRENTLY.
CREATE UNIQUE INDEX IF NOT EXISTS mv_latest_readings_sensor_idx
  ON mv_latest_readings (sensor_id);

COMMIT;
