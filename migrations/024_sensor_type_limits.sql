-- SCRUM-630 (US18): limites físicos por tipo de sensor.
--
-- Sem mínimo e máximo no sensor, um valor impossível (chuva negativa, umidade
-- acima de 100 %) era gravado como leitura consistente. O tipo passa a ter
-- limites que valem para os sensores dele. O tratamento usa os limites do
-- sensor quando ele tem algum; senão, os do tipo. Fora da faixa, a leitura é
-- gravada como inconsistente.
--
-- Os tipos existentes recebem limites pela unidade quando ainda não têm:
-- % de 0 a 100; mm, km/h, m/s, hPa, W/m² e lux com mínimo 0.
--
-- Idempotente: reaplicar não altera limites já configurados nem apagados.
BEGIN;

-- Os limites padrão entram só quando as colunas são criadas: um limite que o
-- administrador apagou depois não volta ao reaplicar.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = current_schema() AND table_name = 'sensor_types' AND column_name = 'min_value'
  ) THEN
    ALTER TABLE sensor_types
      ADD COLUMN min_value numeric NULL,
      ADD COLUMN max_value numeric NULL;

    UPDATE sensor_types SET min_value = 0, max_value = 100
    WHERE btrim(unit_of_measure) = '%';

    UPDATE sensor_types SET min_value = 0
    WHERE lower(replace(btrim(unit_of_measure), ' ', '')) IN ('mm', 'km/h', 'm/s', 'hpa', 'w/m²', 'w/m2', 'lux', 'lx');
  END IF;
END;
$$;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sensor_types_limits_valid'
      AND conrelid = 'sensor_types'::regclass
  ) THEN
    ALTER TABLE sensor_types
      ADD CONSTRAINT sensor_types_limits_valid CHECK (
        (min_value IS NULL OR min_value NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)) AND
        (max_value IS NULL OR max_value NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)) AND
        (min_value IS NULL OR max_value IS NULL OR min_value <= max_value));
  END IF;
END;
$$;

COMMIT;
