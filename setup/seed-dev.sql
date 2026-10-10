-- Dados mínimos para desenvolvimento no Neon.
--
--   psql "<DATABASE_URL>" -v ON_ERROR_STOP=1 -f setup/seed-dev.sql
--
-- Idempotente, e NÃO usa ids fixos: cada execução só insere o que falta,
-- sem brigar com registros que outro membro do time já tenha criado.

-- Cargo e usuário de desenvolvimento -----------------------------------------
-- Somente o administrador recém-criado recebe concessões; seeds repetidos
-- não restauram permissões que o time tenha removido.
WITH inserted AS (
  INSERT INTO roles (name, description)
  VALUES ('Administrador', 'Acesso total à plataforma')
  ON CONFLICT (name) DO NOTHING
  RETURNING id
)
INSERT INTO role_permissions (role_id, permission_code)
SELECT i.id, p.code FROM inserted i CROSS JOIN permissions p;

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
