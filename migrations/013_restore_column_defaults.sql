-- Restaura os DEFAULTs das colunas no banco do Neon.
--
-- O schema aplicado no Neon ficou sem os DEFAULT que existem em
-- setup/schema-neon.sql (created_at, active, operational_status...). Resultado:
-- qualquer INSERT que omite essas colunas falha com
--   null value in column "created_at" ... violates not-null constraint
--
-- Idempotente: SET DEFAULT só troca o valor padrão, não mexe em dados.
-- Gerado a partir de setup/schema-neon.sql — manter os dois em sincronia.

BEGIN;

ALTER TABLE IF EXISTS roles ALTER COLUMN created_at SET DEFAULT current_timestamp;
ALTER TABLE IF EXISTS users ALTER COLUMN active SET DEFAULT true;
ALTER TABLE IF EXISTS users ALTER COLUMN created_at SET DEFAULT current_timestamp;
ALTER TABLE IF EXISTS credentials ALTER COLUMN updated_at SET DEFAULT current_timestamp;
ALTER TABLE IF EXISTS properties ALTER COLUMN created_at SET DEFAULT current_timestamp;
ALTER TABLE IF EXISTS stations ALTER COLUMN created_at SET DEFAULT current_timestamp;
ALTER TABLE IF EXISTS sensors ALTER COLUMN operational_status SET DEFAULT true;
ALTER TABLE IF EXISTS sensors ALTER COLUMN created_at SET DEFAULT current_timestamp;
ALTER TABLE IF EXISTS readings ALTER COLUMN data_consistent SET DEFAULT true;
ALTER TABLE IF EXISTS readings ALTER COLUMN created_at SET DEFAULT current_timestamp;
ALTER TABLE IF EXISTS alert_configs ALTER COLUMN active SET DEFAULT true;
ALTER TABLE IF EXISTS alert_configs ALTER COLUMN created_at SET DEFAULT current_timestamp;
ALTER TABLE IF EXISTS triggered_alerts ALTER COLUMN triggered_at SET DEFAULT current_timestamp;
ALTER TABLE IF EXISTS processing_checkpoints ALTER COLUMN updated_at SET DEFAULT current_timestamp;

COMMIT;
