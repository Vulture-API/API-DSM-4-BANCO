-- SCRUM-399 (US13): permissões de cadastro, edição e exclusão de propriedades.
--
-- A 015 criou só properties.read. O backend exige properties.create,
-- properties.update e properties.delete nas rotas de /api/properties, e
-- nenhum perfil conseguia gravar propriedades com o controle de acesso ligado.
--
-- Idempotente: só a permissão recém-criada é concedida ao Administrador;
-- reaplicar não devolve uma concessão que o time tenha removido.
BEGIN;

DO $$
BEGIN
  IF to_regclass('permissions') IS NOT NULL THEN
    WITH inserted AS (
      INSERT INTO permissions (code, description) VALUES
        ('properties.create', 'Criar propriedades'),
        ('properties.update', 'Editar propriedades'),
        ('properties.delete', 'Excluir propriedades')
      ON CONFLICT (code) DO NOTHING
      RETURNING code
    )
    INSERT INTO role_permissions (role_id, permission_code)
    SELECT r.id, i.code FROM roles r CROSS JOIN inserted i
    WHERE r.name = 'Administrador'
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

COMMIT;
