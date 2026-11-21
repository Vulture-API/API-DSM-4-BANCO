-- SCRUM-587 (US18): frequência de coleta do datalogger, por estação.
--
-- O backend expõe e altera o valor em /api/stations/:id/collection; o limite
-- superior real depende do tempo para considerar a estação offline e é
-- validado lá. Aqui fica só a faixa que qualquer configuração precisa
-- respeitar. 60 s é o intervalo que o simulador já usa.
--
-- Idempotente: reaplicar não altera valores já configurados.
BEGIN;

ALTER TABLE stations
  ADD COLUMN IF NOT EXISTS collection_interval_seconds integer NOT NULL DEFAULT 60;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'stations_collection_interval_range'
      AND conrelid = 'stations'::regclass
  ) THEN
    ALTER TABLE stations
      ADD CONSTRAINT stations_collection_interval_range
      CHECK (collection_interval_seconds BETWEEN 10 AND 3600);
  END IF;
END;
$$;

COMMIT;
