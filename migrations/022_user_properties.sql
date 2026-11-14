-- SCRUM-608: vínculos N:N de acesso, independentes do responsável cadastral.
BEGIN;
DO $$
BEGIN
  -- O backfill ocorre somente na criação. Reaplicar não restaura acesso revogado.
  IF to_regclass('user_properties') IS NULL THEN
    CREATE TABLE user_properties (
      user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      property_id integer NOT NULL REFERENCES properties(id) ON DELETE CASCADE,
      PRIMARY KEY (user_id, property_id)
    );
    CREATE INDEX idx_user_properties_property ON user_properties(property_id);
    INSERT INTO user_properties(user_id, property_id)
    SELECT owner_user_id, id FROM properties WHERE owner_user_id IS NOT NULL
    ON CONFLICT DO NOTHING;
  END IF;
END;
$$;
COMMIT;
