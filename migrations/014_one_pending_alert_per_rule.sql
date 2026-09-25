-- No máximo um alerta pendente por regra.
--
-- O motor de regras (API-DSM-4-ALERTAS) não dispara de novo uma regra que já
-- tem alerta pendente (acknowledged_at IS NULL): antes disso, uma condição que
-- persistia gerava um alerta por leitura, um por minuto por estação.
--
-- O índice único parcial garante isso no banco, inclusive com mais de uma
-- instância do motor rodando ao mesmo tempo (a checagem só na aplicação tem
-- corrida). Ele também serve a consulta "esta regra tem pendente?".
--
-- Antes de criar o índice, os pendentes duplicados que já existem são
-- fechados: fica pendente só o disparo mais antigo de cada regra (o início da
-- ocorrência); os demais recebem acknowledged_at = agora, sem usuário
-- (acknowledged_by NULL = fechado pelo sistema).
--
-- Idempotente. Gerado junto com setup/schema-neon.sql; manter os dois em sincronia.

BEGIN;

UPDATE triggered_alerts ta
SET acknowledged_at = now() AT TIME ZONE 'UTC'
WHERE ta.acknowledged_at IS NULL
  AND EXISTS (
    SELECT 1
    FROM triggered_alerts older
    WHERE older.alert_config_id = ta.alert_config_id
      AND older.acknowledged_at IS NULL
      AND (older.triggered_at, older.id) < (ta.triggered_at, ta.id)
  );

CREATE UNIQUE INDEX IF NOT EXISTS uq_triggered_alerts_pending_per_config
  ON triggered_alerts (alert_config_id) WHERE acknowledged_at IS NULL;

COMMIT;
