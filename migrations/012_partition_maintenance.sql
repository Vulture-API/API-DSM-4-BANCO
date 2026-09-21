-- SCRUM-379 — Manutenção das partições de `readings`.
--
-- Quem cria a partição do mês que vem e quem apaga a de 24 meses atrás é o
-- pg_partman, via `partman.run_maintenance_proc()`. Este arquivo configura a
-- manutenção e entrega a checagem que torna a falha VISÍVEL.
--
-- ATENÇÃO: sem BEGIN/COMMIT de propósito. `run_maintenance_proc` é uma
-- PROCEDURE que dá COMMIT internamente e não roda dentro de bloco de transação.

-- 1. Sanidade da configuração ------------------------------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM partman.part_config WHERE parent_table = 'public.readings') THEN
    RAISE EXCEPTION 'public.readings não está registrada no pg_partman. Aplique a 010 antes desta migration.';
  END IF;
END;
$$;

-- 2. Alarme da partição DEFAULT ----------------------------------------------

-- Esta é a falha que não dá erro: se a manutenção parar de rodar, em algum mês
-- as leituras passam a cair na DEFAULT e todo o ganho de pruning some em
-- silêncio. A função abaixo transforma esse silêncio em exceção, para ser
-- chamada pelo mesmo job que roda a manutenção.
CREATE OR REPLACE FUNCTION assert_readings_default_empty()
RETURNS bigint
LANGUAGE plpgsql
-- search_path fixo: a função é chamada por um job externo, cujo search_path não
-- controlamos. Sem isto, `readings_default` poderia resolver para outra tabela.
SET search_path = public, pg_temp
AS $$
DECLARE
  linhas bigint;
BEGIN
  IF to_regclass('public.readings_default') IS NULL THEN
    RETURN 0;
  END IF;

  EXECUTE 'SELECT count(*) FROM public.readings_default' INTO linhas;

  IF linhas > 0 THEN
    RAISE EXCEPTION
      'readings_default tem % linha(s). A manutenção do pg_partman não está rodando, ou chegou leitura com unix_time fora de qualquer faixa prevista.', linhas;
  END IF;

  RETURN linhas;
END;
$$;

-- 3. Heartbeat: quem vigia o vigia -------------------------------------------

-- O alarme da etapa 2 só dispara se o job rodar. Se o agendamento for
-- desabilitado, apagado ou nunca publicado, nada roda — e nada reclama. Este
-- heartbeat registra cada execução bem-sucedida, para que a ausência de
-- execução vire um fato observável no banco, e não um silêncio.
CREATE TABLE IF NOT EXISTS maintenance_heartbeat (
  job         text NOT NULL,
  ran_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT maintenance_heartbeat_pk PRIMARY KEY (job)
);

CREATE OR REPLACE FUNCTION record_maintenance_heartbeat(p_job text)
RETURNS timestamptz
LANGUAGE sql
SET search_path = public, pg_temp
AS $$
  INSERT INTO maintenance_heartbeat (job, ran_at)
  VALUES (p_job, now())
  ON CONFLICT (job) DO UPDATE SET ran_at = now()
  RETURNING ran_at;
$$;

-- Estado da manutenção, para o /health do serviço de consulta e para a daily.
-- `atrasado` fica true se a manutenção não roda há mais de 7 dias — com
-- premake = 4, isso ainda é muito antes de qualquer leitura cair na DEFAULT.
CREATE OR REPLACE VIEW vw_maintenance_status AS
SELECT
  h.job,
  h.ran_at,
  now() - h.ran_at          AS desde,
  (now() - h.ran_at) > interval '7 days' AS atrasado
FROM maintenance_heartbeat h;

-- 4. Rotina completa de manutenção -------------------------------------------

-- O job agendado deve executar, nesta ordem:
--
--   CALL partman.run_maintenance_proc();
--   SELECT assert_readings_default_empty();
--   SELECT record_maintenance_heartbeat('partman');
--
-- A manutenção do pg_partman é barata e idempotente: pode rodar diariamente.
-- Com p_premake = 4, rodando todo dia, seriam necessários 4 meses seguidos de
-- falha para alguma leitura chegar na DEFAULT.
--
-- O REFRESH da materialized view tem cadência própria (ver seção 4): o
-- dashboard quer dado de minuto, a manutenção de partição não.

-- 5. Agendamento -------------------------------------------------------------
--
-- ESCOLHIDO: Neon Scheduled Function Triggers.
--   É o agendador nativo da plataforma e dispara mesmo com a compute em
--   scale-to-zero. A função está em `neon/maintenance.ts`, e o agendamento
--   em `neon/README.md`.
--
-- DESCARTADO: pg_cron.
--   Existe no Neon, mas os jobs só rodam enquanto a compute está ativa — num
--   projeto com scale-to-zero ligado, o job simplesmente não acontece, e sem
--   erro. Trocaria uma falha silenciosa por outra. Só seria opção com
--   scale-to-zero desativado, o que custa compute ligada 24h.
--
-- DESCARTADO: background worker do pg_partman.
--   Exige `shared_preload_libraries = 'pg_partman_bgw'`, que não é configurável
--   no Neon.
--
-- ALTERNATIVA se a plataforma mudar: workflow agendado no GitHub Actions
--   chamando os três comandos via psql. Menos acoplado ao Neon, porém depende
--   de guardar a DATABASE_URL como secret do repositório.

-- 6. Primeira execução -------------------------------------------------------

CALL partman.run_maintenance_proc();
SELECT assert_readings_default_empty();
SELECT record_maintenance_heartbeat('partman');
