-- SCRUM-379 — Massa sintética para medir o efeito das otimizações.
--
--   psql "$DATABASE_URL" -v rows=1000000 -v months=12 -v sensors=50 \
--        -f benchmark/seed_readings.sql
--
-- As leituras são distribuídas uniformemente no período que TERMINA AGORA.
-- Isso importa: o benchmark consulta "últimos 30 dias" e "últimos 7 dias", e
-- uma massa que termina no passado devolveria zero linhas e mediria nada.

-- Sensores de benchmark. readings.sensor_id tem FK para sensors, e o seed de
-- desenvolvimento não cria nenhum sensor: sem isto, o INSERT abaixo falha em
-- qualquer banco limpo. Idempotente (reaproveita o que já existir).
INSERT INTO stations (property_id, mac_address, name, created_at)
SELECT (SELECT MIN(id) FROM properties), 'BE:0C:00:00:00:00', 'Estacao de benchmark', current_timestamp
WHERE NOT EXISTS (SELECT 1 FROM stations WHERE mac_address = 'BE:0C:00:00:00:00');

INSERT INTO sensors (station_id, sensor_type_id, local_identifier, operational_status, created_at)
SELECT (SELECT id FROM stations WHERE mac_address = 'BE:0C:00:00:00:00'),
       (SELECT MIN(id) FROM sensor_types),
       'BENCH-' || lpad(n::text, 3, '0'),
       true,
       current_timestamp
FROM generate_series(1, :sensors) n
ON CONFLICT (station_id, local_identifier) DO NOTHING;

INSERT INTO readings (sensor_id, value, unix_time, data_consistent)
SELECT
  -- Distribui pelos ids reais dos sensores de benchmark (não assume 1..N).
  (SELECT array_agg(s.id ORDER BY s.id)
     FROM sensors s JOIN stations st ON st.id = s.station_id
    WHERE st.mac_address = 'BE:0C:00:00:00:00')[(g % :sensors) + 1],
  20 + (random() * 25)::numeric(10,2),
  extract(epoch FROM now())::bigint
    - ((:rows - g) * (:months * 2629746 / :rows)),
  -- ~1% chega inconsistente, como no mundo real
  random() > 0.01
FROM generate_series(1, :rows) g;

ANALYZE readings;
