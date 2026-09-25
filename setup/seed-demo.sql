-- =============================================================================
-- Dados de DEMONSTRAÇÃO da plataforma — para ver todas as telas com cara real.
--
--   psql "<URL de um banco LOCAL>" -v ON_ERROR_STOP=1 -f setup/seed-demo.sql
--
-- Cria, sobre o schema-neon.sql + seed-dev.sql:
--   3 cargos, 10 usuários (senha de todos: senha123), 6 propriedades,
--   15 estações (12 comunicando, 2 offline, 1 que nunca comunicou),
--   93 sensores, 7 dias de leituras a cada 10 minutos (~88 mil linhas),
--   20 regras de alerta e os alertas disparados coerentes com as leituras.
--
-- NÃO rodar no Neon compartilhado: é volume de demonstração.
-- Idempotente: se as estações de demonstração já existem, não faz nada.
-- Determinístico: setseed() fixa os números "aleatórios".
-- =============================================================================

DO $seed$
DECLARE
  admin_id integer;
  now_unix bigint := extract(epoch FROM date_trunc('minute', now()))::bigint;
BEGIN
  IF EXISTS (SELECT 1 FROM stations WHERE mac_address LIKE '00:1A:2B:3C:4D:%') THEN
    RAISE NOTICE 'seed-demo: dados de demonstração já existem, nada a fazer';
    RETURN;
  END IF;

  PERFORM setseed(0.42);

  -- Cargos -------------------------------------------------------------------
  INSERT INTO roles (name, description) VALUES
    ('Administrador', 'Acesso total à plataforma'),
    ('Gerente Agrícola', 'Configura alertas e acompanha as estações'),
    ('Cliente', 'Consulta dados e relatórios')
  ON CONFLICT (name) DO NOTHING;

  -- Usuários (senha: senha123, no formato do serviço de usuários) -------------
  WITH novos(nome, email, cargo, ativo) AS (VALUES
    ('Mariana Albuquerque', 'mariana.albuquerque@agritech.dev', 'Administrador', true),
    ('Rafael Nogueira',     'rafael.nogueira@agritech.dev',     'Administrador', true),
    ('Carlos Mendes',       'carlos.mendes@agritech.dev',       'Gerente Agrícola', true),
    ('Juliana Prado',       'juliana.prado@agritech.dev',       'Gerente Agrícola', true),
    ('Tiago Ribeiro',       'tiago.ribeiro@agritech.dev',       'Gerente Agrícola', true),
    ('Fernanda Costa',      'fernanda.costa@agritech.dev',      'Cliente', true),
    ('Lucas Moreira',       'lucas.moreira@agritech.dev',       'Cliente', true),
    ('Beatriz Santos',      'beatriz.santos@agritech.dev',      'Cliente', true),
    ('Paulo Henrique Dias', 'paulo.dias@agritech.dev',          'Cliente', false),
    ('Aline Camargo',       'aline.camargo@agritech.dev',       'Gerente Agrícola', true)
  ), inseridos AS (
    INSERT INTO users (role_id, name, active)
    SELECT r.id, n.nome, n.ativo
    FROM novos n JOIN roles r ON r.name = n.cargo
    WHERE NOT EXISTS (
      SELECT 1 FROM credentials c WHERE c.email = n.email
    )
    RETURNING id, name
  )
  INSERT INTO credentials (user_id, email, password_hash)
  SELECT i.id, n.email,
    'scrypt$16384$8$1$a9c1f00d5eedc0ffee1234567890abcd$4a4033066dcb2a37839f9d82be5a791972bd0361af20e684524da72832d4dcb4df5586de96fcabae8127f709117fa7988e691ff3041b6738141c53b2d5c74b6a'
  FROM inseridos i JOIN novos n ON n.nome = i.name;

  SELECT u.id INTO admin_id
  FROM users u JOIN credentials c ON c.user_id = u.id
  WHERE c.email = 'mariana.albuquerque@agritech.dev';

  -- Propriedades -------------------------------------------------------------
  INSERT INTO properties (name, owner_user_id, location)
  SELECT v.nome, admin_id, v.local
  FROM (VALUES
    ('Fazenda Santa Rita',  'São José dos Campos - SP'),
    ('Fazenda Boa Vista',   'Taubaté - SP'),
    ('Fazenda Esperança',   'Jacareí - SP'),
    ('Sítio Água Limpa',    'Pindamonhangaba - SP'),
    ('Fazenda Três Irmãos', 'Caçapava - SP'),
    ('Sítio Recanto Verde', 'Lorena - SP')
  ) AS v(nome, local)
  WHERE NOT EXISTS (SELECT 1 FROM properties p WHERE p.name = v.nome);

  -- Tipos de sensor ----------------------------------------------------------
  UPDATE sensor_types SET unit_of_measure = '°C'
  WHERE name = 'Temperatura' AND unit_of_measure = 'C';

  INSERT INTO sensor_types (name, unit_of_measure) VALUES
    ('Temperatura', '°C'),
    ('Umidade', '%'),
    ('Pressão', 'hPa'),
    ('Velocidade do Vento', 'km/h'),
    ('Índice Pluviométrico', 'mm'),
    ('Temperatura do Solo', '°C'),
    ('Umidade do Solo', '%')
  ON CONFLICT (name) DO NOTHING;

  -- Estações -----------------------------------------------------------------
  -- ultima_min: minutos desde a última comunicação (NULL = nunca comunicou).
  CREATE TEMP TABLE demo_station (
    n int, nome text, propriedade text, lat numeric, lon numeric,
    ultima_min int, com_solo boolean, instavel boolean
  ) ON COMMIT DROP;

  INSERT INTO demo_station VALUES
    ( 1, 'Estação Sede',            'Fazenda Santa Rita',  -23.1791, -45.8872,   1, true,  false),
    ( 2, 'Estação Pivô Norte',      'Fazenda Santa Rita',  -23.1702, -45.8810,   2, true,  false),
    ( 3, 'Estação Várzea',          'Fazenda Santa Rita',  -23.1855, -45.8951,   1, false, false),
    ( 4, 'Estação Cafezal',         'Fazenda Boa Vista',   -23.0264, -45.5553,   3, true,  true),
    ( 5, 'Estação Represa',         'Fazenda Boa Vista',   -23.0331, -45.5620, 180, false, false),
    ( 6, 'Estação Talhão 7',        'Fazenda Boa Vista',   -23.0198, -45.5487,   2, true,  false),
    ( 7, 'Estação Horta',           'Fazenda Esperança',   -23.3050, -45.9658,   1, true,  false),
    ( 8, 'Estação Pomar',           'Fazenda Esperança',   -23.3122, -45.9701,   4, false, false),
    ( 9, 'Estação Mirante',         'Sítio Água Limpa',    -22.9245, -45.4618,   2, false, false),
    (10, 'Estação Brejo',           'Sítio Água Limpa',    -22.9301, -45.4702, 900, true,  false),
    (11, 'Estação Canavial Leste',  'Fazenda Três Irmãos', -23.1003, -45.7071,   1, true,  false),
    (12, 'Estação Canavial Oeste',  'Fazenda Três Irmãos', -23.1066, -45.7189,   3, true,  true),
    (13, 'Estação Silo',            'Fazenda Três Irmãos', -23.0951, -45.7012,   2, false, false),
    (14, 'Estação Estufa',          'Sítio Recanto Verde', -22.7253, -45.1239,   1, true,  false),
    (15, 'Estação Nova (instalação)','Sítio Recanto Verde', -22.7301, -45.1302, NULL, false, false);

  INSERT INTO stations (property_id, mac_address, name, latitude, longitude, last_communication_at)
  SELECT p.id,
         '00:1A:2B:3C:4D:' || lpad(d.n::text, 2, '0'),
         d.nome, d.lat, d.lon,
         CASE WHEN d.ultima_min IS NULL THEN NULL
              ELSE (now() AT TIME ZONE 'UTC') - make_interval(mins => d.ultima_min) END
  FROM demo_station d JOIN properties p ON p.name = d.propriedade;

  -- Sensores -----------------------------------------------------------------
  -- local_identifier é a chave que a estação manda no payload MQTT.
  CREATE TEMP TABLE demo_sensor_kind (ident text, tipo text, solo boolean) ON COMMIT DROP;
  INSERT INTO demo_sensor_kind VALUES
    ('temp', 'Temperatura', false),
    ('umid', 'Umidade', false),
    ('pressao', 'Pressão', false),
    ('vento', 'Velocidade do Vento', false),
    ('chuva', 'Índice Pluviométrico', false),
    ('temp_solo', 'Temperatura do Solo', true),
    ('umid_solo', 'Umidade do Solo', true);

  INSERT INTO sensors (station_id, sensor_type_id, local_identifier, operational_status)
  SELECT s.id, t.id, k.ident,
         -- Nas estações instáveis, o sensor de vento está em manutenção.
         NOT (d.instavel AND k.ident = 'vento')
  FROM demo_station d
  JOIN stations s ON s.mac_address = '00:1A:2B:3C:4D:' || lpad(d.n::text, 2, '0')
  JOIN demo_sensor_kind k ON (NOT k.solo OR d.com_solo)
  JOIN sensor_types t ON t.name = k.tipo;

  -- Leituras: 7 dias, a cada 10 minutos, até a última comunicação ------------
  -- Curvas plausíveis: temperatura com ciclo diário (pico às 15h), umidade
  -- inversa, pressão quase estável, vento com rajadas, chuva em eventos.
  INSERT INTO readings (sensor_id, value, unix_time, data_consistent)
  SELECT sen.id,
         round(CASE sen.local_identifier
           WHEN 'temp'      THEN 22 + d.n % 4 * 0.6 + 6.5 * sin(2 * pi() * (h - 9) / 24) + (random() - 0.5) * 1.6
           WHEN 'umid'      THEN greatest(28, least(98, 68 - 22 * sin(2 * pi() * (h - 9) / 24) + (random() - 0.5) * 6))
           WHEN 'pressao'   THEN 1013 + 3 * sin(2 * pi() * dia / 7) + (random() - 0.5)
           WHEN 'vento'     THEN greatest(0, 7 + 5 * sin(2 * pi() * (h - 12) / 24) + random() * 6 + CASE WHEN random() < 0.02 THEN 12 ELSE 0 END)
           WHEN 'chuva'     THEN CASE WHEN (dia = 2 AND h BETWEEN 16 AND 19) OR (dia = 5 AND h BETWEEN 2 AND 6)
                                      THEN random() * 4.5 ELSE 0 END
           WHEN 'temp_solo' THEN 21 + 3 * sin(2 * pi() * (h - 11) / 24) + (random() - 0.5) * 0.6
           WHEN 'umid_solo' THEN 38 - dia * 0.8 + CASE WHEN dia >= 5 THEN 6 ELSE 0 END + (random() - 0.5) * 2
         END::numeric, 2),
         g.t,
         -- Estação instável: ~4% das leituras chegam fora da faixa esperada.
         NOT (d.instavel AND random() < 0.04)
  FROM demo_station d
  JOIN stations st ON st.mac_address = '00:1A:2B:3C:4D:' || lpad(d.n::text, 2, '0')
  JOIN sensors sen ON sen.station_id = st.id
  CROSS JOIN LATERAL generate_series(
    now_unix - 7 * 86400,
    now_unix - coalesce(d.ultima_min, 0) * 60,
    600
  ) AS g(t)
  CROSS JOIN LATERAL (
    SELECT extract(hour FROM to_timestamp(g.t) AT TIME ZONE 'America/Sao_Paulo')
           + extract(minute FROM to_timestamp(g.t)) / 60.0 AS h,
           floor((g.t - (now_unix - 7 * 86400)) / 86400.0) AS dia
  ) calc
  WHERE d.ultima_min IS NOT NULL;

  -- Regras de alerta ---------------------------------------------------------
  CREATE TEMP TABLE demo_rule (
    estacao int, ident text, op varchar(2), ref numeric, msg text, gerente text, ativo boolean
  ) ON COMMIT DROP;
  INSERT INTO demo_rule VALUES
    ( 1, 'temp',      '>',  28.5, 'Temperatura alta na sede: risco de estresse térmico', 'carlos.mendes@agritech.dev', true),
    ( 1, 'umid',      '<',  45,   'Umidade do ar baixa: avaliar irrigação',               'carlos.mendes@agritech.dev', true),
    ( 2, 'vento',     '>',  17,   'Rajada forte: suspender pulverização no pivô',        'carlos.mendes@agritech.dev', true),
    ( 2, 'umid_solo', '<',  34,   'Solo seco no pivô norte',                             'carlos.mendes@agritech.dev', true),
    ( 3, 'chuva',     '>',  3,    'Chuva intensa na várzea: risco de alagamento',        'juliana.prado@agritech.dev', true),
    ( 4, 'temp',      '>',  29,   'Cafezal acima de 29 °C',                              'juliana.prado@agritech.dev', true),
    ( 4, 'umid_solo', '<',  33,   'Umidade do solo crítica no cafezal',                  'juliana.prado@agritech.dev', true),
    ( 5, 'chuva',     '>',  2,    'Chuva forte na represa',                              'juliana.prado@agritech.dev', true),
    ( 6, 'temp',      '<',  16.5, 'Madrugada fria no talhão 7: risco de geada',          'tiago.ribeiro@agritech.dev', true),
    ( 7, 'temp_solo', '>',  23.5, 'Solo quente na horta',                                'tiago.ribeiro@agritech.dev', true),
    ( 7, 'umid',      '>',  88,   'Umidade muito alta: risco de fungos',                 'tiago.ribeiro@agritech.dev', true),
    ( 8, 'vento',     '>',  18,   'Vento forte no pomar',                                'tiago.ribeiro@agritech.dev', true),
    ( 9, 'pressao',   '<',  1010.5,'Queda de pressão: frente fria se aproximando',       'aline.camargo@agritech.dev', true),
    (11, 'temp',      '>',  28.8, 'Canavial leste acima de 28,8 °C',                     'aline.camargo@agritech.dev', true),
    (11, 'chuva',     '>',  3.5,  'Chuva intensa no canavial leste',                     'aline.camargo@agritech.dev', true),
    (12, 'umid_solo', '<',  32,   'Canavial oeste com solo seco',                        'aline.camargo@agritech.dev', true),
    (13, 'umid',      '<',  40,   'Silo: umidade do ar baixa',                           'aline.camargo@agritech.dev', false),
    (14, 'temp',      '>',  28,   'Estufa acima de 28 °C: abrir cortinas',               'carlos.mendes@agritech.dev', true),
    (14, 'umid_solo', '<',  35,   'Estufa: irrigar canteiros',                           'carlos.mendes@agritech.dev', true),
    (10, 'temp',      '<',  15,   'Brejo abaixo de 15 °C',                               'juliana.prado@agritech.dev', false);

  INSERT INTO alert_configs (manager_user_id, sensor_id, reference_value, comparison_operator, message, active)
  SELECT c.user_id, sen.id, r.ref, r.op, r.msg, r.ativo
  FROM demo_rule r
  JOIN stations st ON st.mac_address = '00:1A:2B:3C:4D:' || lpad(r.estacao::text, 2, '0')
  JOIN sensors sen ON sen.station_id = st.id AND sen.local_identifier = r.ident
  JOIN credentials c ON c.email = r.gerente;

  -- Alertas disparados -------------------------------------------------------
  -- O que o motor de regras teria gerado: as 12 leituras mais recentes que
  -- violaram cada regra ativa. Quase todos já foram reconhecidos; o último
  -- disparo de cerca de 1/3 das regras fica pendente. No máximo um pendente
  -- por regra, como faz o motor (não dispara de novo enquanto há pendente).
  INSERT INTO triggered_alerts (alert_config_id, reading_id, triggered_at, acknowledged_by, acknowledged_at)
  SELECT x.config_id, x.reading_id, x.lido_em,
         CASE WHEN x.reconhecido THEN x.gerente END,
         CASE WHEN x.reconhecido THEN x.lido_em + interval '25 minutes' END
  FROM (
    SELECT y.*, NOT (y.pos = 1 AND y.sorte < 0.45) AS reconhecido
    FROM (
    SELECT ac.id AS config_id,
           rd.id AS reading_id,
           to_timestamp(rd.unix_time) AT TIME ZONE 'UTC' AS lido_em,
           ac.manager_user_id AS gerente,
           random() AS sorte,
           row_number() OVER (PARTITION BY ac.id ORDER BY rd.unix_time DESC) AS pos
    FROM alert_configs ac
    JOIN sensors sen ON sen.id = ac.sensor_id
    JOIN stations st ON st.id = sen.station_id AND st.mac_address LIKE '00:1A:2B:3C:4D:%'
    JOIN readings rd ON rd.sensor_id = ac.sensor_id AND rd.data_consistent
    WHERE ac.active
      AND CASE ac.comparison_operator
            WHEN '>'  THEN rd.value >  ac.reference_value
            WHEN '<'  THEN rd.value <  ac.reference_value
            WHEN '>=' THEN rd.value >= ac.reference_value
            WHEN '<=' THEN rd.value <= ac.reference_value
            WHEN '='  THEN rd.value =  ac.reference_value
            WHEN '!=' THEN rd.value <> ac.reference_value
          END
    ) y
  ) x
  WHERE x.pos <= 12;

  -- O motor de regras começa depois das leituras de demonstração: sem isso ele
  -- reprocessaria as ~88 mil linhas e dispararia milhares de alertas.
  UPDATE processing_checkpoints
  SET value = (SELECT coalesce(max(id), 0)::text FROM readings), updated_at = now()
  WHERE key = 'rules_engine_last_reading_id';

  RAISE NOTICE 'seed-demo: % estações, % sensores, % leituras, % regras, % alertas',
    (SELECT count(*) FROM stations), (SELECT count(*) FROM sensors),
    (SELECT count(*) FROM readings), (SELECT count(*) FROM alert_configs),
    (SELECT count(*) FROM triggered_alerts);
END
$seed$;
