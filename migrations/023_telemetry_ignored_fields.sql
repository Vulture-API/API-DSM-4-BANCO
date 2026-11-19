-- SCRUM-623 (US18): campo do payload sem sensor cadastrado na estação.
--
-- O datalogger envia todos os canais da placa (SCRUM-621), inclusive os que
-- não têm sensor ligado. O tratamento registra esses campos como 'ignored':
-- sem sensor, leitura nem quarentena, com o motivo. O payload original
-- continua em telemetry_events.
--
-- Idempotente: reaplicar recria as mesmas regras.
BEGIN;

ALTER TABLE telemetry_results
  DROP CONSTRAINT IF EXISTS telemetry_results_destination_check,
  DROP CONSTRAINT IF EXISTS telemetry_results_destination;

ALTER TABLE telemetry_results
  ADD CONSTRAINT telemetry_results_destination_check
    CHECK (destination IN ('reading','inconsistent','duplicate','quarantine','ignored')),
  ADD CONSTRAINT telemetry_results_destination CHECK (
    (destination='quarantine' AND quarantine_id IS NOT NULL AND reading_id IS NULL
      AND reading_unix_time IS NULL AND cardinality(reasons)>0)
    OR (destination='ignored' AND quarantine_id IS NULL AND sensor_id IS NULL
      AND reading_id IS NULL AND reading_unix_time IS NULL AND ordinal>0
      AND cardinality(reasons)>0)
    OR (destination IN ('reading','inconsistent','duplicate') AND quarantine_id IS NULL
      AND sensor_id IS NOT NULL AND reading_id IS NOT NULL AND reading_unix_time IS NOT NULL
      AND ordinal>0)
  );

COMMIT;
