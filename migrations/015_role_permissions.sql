-- SCRUM-432: catálogo e associação de permissões. Não altera dados de negócio.
-- Bootstrap ocorre somente na criação da tabela de associações.
BEGIN;
DO $migration$
DECLARE
  first_install boolean := to_regclass('role_permissions') IS NULL;
BEGIN
  CREATE TABLE IF NOT EXISTS permissions (
    code varchar(100) PRIMARY KEY,
    description varchar(255) NOT NULL
  );
  CREATE TABLE IF NOT EXISTS role_permissions (
    role_id integer NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
    permission_code varchar(100) NOT NULL REFERENCES permissions(code) ON DELETE RESTRICT,
    PRIMARY KEY (role_id, permission_code)
  );
  INSERT INTO permissions (code, description) VALUES
  ('users.read', 'Consultar usuários'),
  ('users.create', 'Criar usuários'),
  ('users.update', 'Editar usuários'),
  ('users.delete', 'Excluir usuários'),
  ('roles.read', 'Consultar perfis'),
  ('roles.create', 'Criar perfis'),
  ('roles.update', 'Editar perfis'),
  ('roles.delete', 'Excluir perfis'),
  ('stations.read', 'Consultar estações'),
  ('stations.create', 'Criar estações'),
  ('stations.update', 'Editar estações'),
  ('stations.delete', 'Excluir estações'),
  ('sensors.read', 'Consultar sensores'),
  ('sensors.create', 'Criar sensores'),
  ('sensors.update', 'Editar sensores'),
  ('sensors.delete', 'Excluir sensores'),
  ('sensor-types.read', 'Consultar tipos de sensor'),
  ('sensor-types.create', 'Criar tipos de sensor'),
  ('sensor-types.update', 'Editar tipos de sensor'),
  ('sensor-types.delete', 'Excluir tipos de sensor'),
  ('alert-configs.read', 'Consultar configurações de alerta'),
  ('alert-configs.create', 'Criar configurações de alerta'),
  ('alert-configs.update', 'Editar configurações de alerta'),
  ('alert-configs.delete', 'Excluir configurações de alerta'),
  ('properties.read', 'Consultar propriedades'),
  ('monitoring.read', 'Consultar monitoramento e leituras'),
  ('permissions.read', 'Consultar catálogo de permissões'),
  ('triggered-alerts.read', 'Consultar alertas disparados'),
  ('triggered-alerts.acknowledge', 'Reconhecer alertas'),
  ('roles.permissions.update', 'Configurar permissões dos perfis'),
  ('rules-engine.run', 'Executar manualmente o motor de regras')
  ON CONFLICT (code) DO UPDATE SET description = EXCLUDED.description;

  IF first_install THEN
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, p.code FROM roles r CROSS JOIN permissions p
    WHERE r.name = 'Administrador'
    ON CONFLICT DO NOTHING;
  END IF;
END
$migration$;
COMMIT;
