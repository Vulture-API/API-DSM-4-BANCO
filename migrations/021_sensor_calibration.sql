-- SCRUM-600 (US18): calibração dos sensores.
--
-- A estação envia a leitura bruta e o sistema converte para a unidade do tipo:
--   valor = bruto × fator × ganho + offset
-- Fator é a conversão padrão do tipo (mudança de unidade, por exemplo). Ganho
-- e offset são a calibração: os do sensor valem no lugar dos do tipo. Campo
-- nulo não altera a leitura.
--
-- Fator e ganho deixam de ter duas casas decimais: um ganho de 0,0008 (ADC de
-- 12 bits para volts) era gravado como 0,00.
--
-- Zero em fator ou ganho era aceito porque o campo não tinha efeito. Como passa
-- a multiplicar a leitura, os zeros já gravados viram nulo.
--
-- Idempotente: reaplicar não altera valores já configurados.
BEGIN;

ALTER TABLE sensor_types
  ALTER COLUMN factor TYPE numeric,
  ALTER COLUMN gain TYPE numeric,
  ADD COLUMN IF NOT EXISTS offset_value numeric NULL;

ALTER TABLE sensors
  ADD COLUMN IF NOT EXISTS gain numeric NULL,
  ADD COLUMN IF NOT EXISTS offset_value numeric NULL,
  ADD COLUMN IF NOT EXISTS model varchar(100) NULL;

UPDATE sensor_types SET factor = NULL WHERE factor = 0;
UPDATE sensor_types SET gain = NULL WHERE gain = 0;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sensor_types_calibration_valid'
      AND conrelid = 'sensor_types'::regclass
  ) THEN
    ALTER TABLE sensor_types
      ADD CONSTRAINT sensor_types_calibration_valid CHECK (
        (factor IS NULL OR factor NOT IN (0, 'NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)) AND
        (gain IS NULL OR gain NOT IN (0, 'NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)) AND
        (offset_value IS NULL OR offset_value NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)));
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sensors_calibration_valid'
      AND conrelid = 'sensors'::regclass
  ) THEN
    ALTER TABLE sensors
      ADD CONSTRAINT sensors_calibration_valid CHECK (
        (gain IS NULL OR gain NOT IN (0, 'NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)) AND
        (offset_value IS NULL OR offset_value NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)));
  END IF;
END;
$$;

COMMIT;
