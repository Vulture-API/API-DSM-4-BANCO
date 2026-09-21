-- Dados mínimos para desenvolvimento no Neon.
--
--   psql "<DATABASE_URL>" -v ON_ERROR_STOP=1 -f setup/seed-dev.sql
--
-- Idempotente, e NÃO usa ids fixos: cada execução só insere o que falta,
-- sem brigar com registros que outro membro do time já tenha criado.

-- Cargo e usuário de desenvolvimento -----------------------------------------
INSERT INTO roles (name, description)
SELECT 'Administrador', 'Acesso total à plataforma'
WHERE NOT EXISTS (SELECT 1 FROM roles WHERE name = 'Administrador');

INSERT INTO users (role_id, name)
SELECT (SELECT id FROM roles WHERE name = 'Administrador'), 'Usuário de Desenvolvimento'
WHERE NOT EXISTS (SELECT 1 FROM users WHERE name = 'Usuário de Desenvolvimento');

-- Propriedades ---------------------------------------------------------------
INSERT INTO properties (name, owner_user_id, location)
SELECT 'Fazenda Santa Clara',
       (SELECT id FROM users WHERE name = 'Usuário de Desenvolvimento'),
       'Piracicaba - SP'
WHERE NOT EXISTS (SELECT 1 FROM properties WHERE name = 'Fazenda Santa Clara');

INSERT INTO properties (name, owner_user_id, location)
SELECT 'Sítio Boa Vista',
       (SELECT id FROM users WHERE name = 'Usuário de Desenvolvimento'),
       'Jacareí - SP'
WHERE NOT EXISTS (SELECT 1 FROM properties WHERE name = 'Sítio Boa Vista');

-- Tipos de sensor ------------------------------------------------------------
INSERT INTO sensor_types (name, unit_of_measure)
SELECT v.name, v.unit
FROM (VALUES
  ('Temperatura', 'C'),
  ('Umidade', '%'),
  ('Pressão', 'hPa'),
  ('Velocidade do Vento', 'km/h'),
  ('Índice Pluviométrico', 'mm')
) AS v(name, unit)
WHERE NOT EXISTS (SELECT 1 FROM sensor_types st WHERE st.name = v.name);

-- Mostra o que ficou disponível ----------------------------------------------
SELECT 'properties' AS tabela, id, name FROM properties
UNION ALL
SELECT 'sensor_types', id, name FROM sensor_types
ORDER BY tabela, id;
