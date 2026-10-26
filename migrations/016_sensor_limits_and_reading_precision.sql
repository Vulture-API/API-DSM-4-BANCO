-- SCRUM-448: exact telemetry storage and optional sensor limits.
-- Apply in a maintenance window with writers/refresh jobs stopped. No CASCADE.
-- Transactional and repeatable; never reconstructs precision already lost.
BEGIN;
SET LOCAL lock_timeout = '10s';
DO $migration$
DECLARE
  ns text := current_schema();
  readings_oid oid;
  targets oid[];
  target oid;
  mv oid;
  mv_definition text;
  mv_owner text;
  mv_populated boolean;
  mv_indexes text[];
  mv_acl jsonb;
  mv_columns jsonb;
  mv_comment text;
  mv_options text[];
  mv_tablespace text;
  item record;
  permission jsonb;
  column_metadata jsonb;
  template_name text;
  needs_widen boolean;
BEGIN
  readings_oid := to_regclass(format('%I.readings', ns));
  IF readings_oid IS NULL OR to_regclass(format('%I.sensors', ns)) IS NULL THEN
    RAISE EXCEPTION 'SCRUM-448 requires readings and sensors in schema %', ns;
  END IF;
  WITH RECURSIVE relations(oid) AS (
    SELECT readings_oid UNION ALL
    SELECT i.inhrelid FROM pg_inherits i JOIN relations r ON r.oid = i.inhparent
  ) SELECT array_agg(oid) INTO targets FROM relations;

  -- pg_partman's template is independent of the partition parent.
  IF to_regclass('partman.part_config') IS NOT NULL THEN
    EXECUTE 'SELECT template_table FROM partman.part_config WHERE parent_table = $1'
      INTO template_name USING format('%I.%I', ns, 'readings');
    IF template_name IS NOT NULL THEN
      IF to_regclass(template_name) IS NULL THEN
        RAISE EXCEPTION 'Missing pg_partman template %', template_name;
      END IF;
      targets := array_append(targets, to_regclass(template_name)::oid);
    END IF;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute
             WHERE attrelid = ANY(targets) AND attname = 'value'
               AND NOT attisdropped AND atttypid <> 'numeric'::regtype) THEN
    RAISE EXCEPTION 'SCRUM-448 only widens existing NUMERIC values';
  END IF;
  SELECT EXISTS(SELECT 1 FROM pg_attribute WHERE attrelid = ANY(targets)
                AND attname = 'value' AND NOT attisdropped AND atttypmod <> -1)
    INTO needs_widen;
  mv := to_regclass(format('%I.mv_latest_readings', ns));
  IF needs_widen THEN
    -- Unknown views/rules must be reviewed explicitly, including on partitions.
    FOR item IN
      SELECT DISTINCT v.oid, v.relname, v.relnamespace, v.relkind
      FROM pg_depend d JOIN pg_rewrite rw ON rw.oid = d.objid
      JOIN pg_class v ON v.oid = rw.ev_class
      WHERE d.classid = 'pg_rewrite'::regclass
        AND d.refclassid = 'pg_class'::regclass AND d.refobjid = ANY(targets)
        AND (d.refobjsubid = 0 OR d.refobjsubid IN (
          SELECT attnum FROM pg_attribute WHERE attrelid = d.refobjid AND attname = 'value'))
    LOOP
      IF mv IS NULL OR item.oid <> mv OR item.relkind <> 'm' THEN
        RAISE EXCEPTION 'Unknown dependent relation %; review before widening readings.value', item.oid::regclass;
      END IF;
    END LOOP;
    IF mv IS NOT NULL THEN
      IF (SELECT relkind FROM pg_class WHERE oid = mv) <> 'm' THEN
        RAISE EXCEPTION 'mv_latest_readings is not a materialized view';
      END IF;
      SELECT regexp_replace(pg_get_viewdef(mv), ';[[:space:]]*$', ''), pg_get_userbyid(relowner), relispopulated,
             obj_description(mv, 'pg_class'), reloptions,
             (SELECT spcname FROM pg_tablespace WHERE oid = c.reltablespace)
        INTO mv_definition, mv_owner, mv_populated, mv_comment, mv_options, mv_tablespace
        FROM pg_class c WHERE oid = mv;
      SELECT array_agg(pg_get_indexdef(indexrelid) ORDER BY indexrelid)
        INTO mv_indexes FROM pg_index WHERE indrelid = mv;
      SELECT jsonb_agg(jsonb_build_object('role', CASE WHEN a.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(a.grantee) END,
                                        'privilege', a.privilege_type, 'grantable', a.is_grantable))
        INTO mv_acl FROM pg_class c,
          LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a WHERE c.oid = mv;
      SELECT jsonb_agg(jsonb_build_object('name', attname, 'comment', col_description(mv, attnum),
                    'acl', (SELECT jsonb_agg(jsonb_build_object('role', CASE WHEN grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(grantee) END,
                       'privilege', privilege_type, 'grantable', is_grantable)) FROM aclexplode(attacl))))
        INTO mv_columns FROM pg_attribute WHERE attrelid = mv AND attnum > 0 AND NOT attisdropped;
      EXECUTE format('DROP MATERIALIZED VIEW %I.mv_latest_readings', ns);
    END IF;
    -- Parent ALTER propagates to existing partitions. Afterwards only templates
    -- (or any independently constrained descendants) still require ALTER.
    FOREACH target IN ARRAY targets LOOP
      IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = target
                 AND attname = 'value' AND atttypmod <> -1 AND NOT attisdropped) THEN
        EXECUTE format('ALTER TABLE %s ALTER COLUMN value TYPE numeric', target::regclass);
      END IF;
    END LOOP;
    IF mv_definition IS NOT NULL THEN
      EXECUTE format('CREATE MATERIALIZED VIEW %I.mv_latest_readings %s %s AS %s %s', ns,
        CASE WHEN mv_options IS NULL THEN '' ELSE 'WITH (' || array_to_string(mv_options, ',') || ')' END,
        CASE WHEN mv_tablespace IS NULL THEN '' ELSE format('TABLESPACE %I', mv_tablespace) END,
        mv_definition, CASE WHEN mv_populated THEN 'WITH DATA' ELSE 'WITH NO DATA' END);
      FOREACH template_name IN ARRAY coalesce(mv_indexes, ARRAY[]::text[]) LOOP
        EXECUTE template_name;
      END LOOP;
      EXECUTE format('ALTER MATERIALIZED VIEW %I.mv_latest_readings OWNER TO %I', ns, mv_owner);
      -- Remove newly inherited default ACLs before restoring the prior grants.
      FOR item IN SELECT DISTINCT a.grantee FROM pg_class c,
        LATERAL aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
        WHERE c.oid = to_regclass(format('%I.mv_latest_readings', ns))
          AND a.grantee <> c.relowner
      LOOP
        EXECUTE format('REVOKE ALL ON %I.mv_latest_readings FROM %s', ns,
          CASE WHEN item.grantee = 0 THEN 'PUBLIC' ELSE quote_ident(pg_get_userbyid(item.grantee)) END);
      END LOOP;
      FOR permission IN SELECT * FROM jsonb_array_elements(coalesce(mv_acl, '[]')) LOOP
        EXECUTE format('GRANT %s ON %I.mv_latest_readings TO %s %s', permission->>'privilege', ns,
          CASE WHEN permission->>'role' = 'PUBLIC' THEN 'PUBLIC' ELSE quote_ident(permission->>'role') END,
          CASE WHEN (permission->>'grantable')::boolean THEN 'WITH GRANT OPTION' ELSE '' END);
      END LOOP;
      EXECUTE format('COMMENT ON MATERIALIZED VIEW %I.mv_latest_readings IS %L', ns, mv_comment);
      FOR column_metadata IN SELECT * FROM jsonb_array_elements(coalesce(mv_columns, '[]')) LOOP
        EXECUTE format('COMMENT ON COLUMN %I.mv_latest_readings.%I IS %L', ns, column_metadata->>'name', column_metadata->>'comment');
        FOR permission IN SELECT * FROM jsonb_array_elements(coalesce(nullif(column_metadata->'acl', 'null'::jsonb), '[]'::jsonb)) LOOP
          EXECUTE format('GRANT %s (%I) ON %I.mv_latest_readings TO %s %s', permission->>'privilege', column_metadata->>'name', ns,
            CASE WHEN permission->>'role' = 'PUBLIC' THEN 'PUBLIC' ELSE quote_ident(permission->>'role') END,
            CASE WHEN (permission->>'grantable')::boolean THEN 'WITH GRANT OPTION' ELSE '' END);
        END LOOP;
      END LOOP;
    END IF;
  END IF;

  EXECUTE format('ALTER TABLE %I.sensors ADD COLUMN IF NOT EXISTS min_value numeric NULL, ADD COLUMN IF NOT EXISTS max_value numeric NULL', ns);
  -- Also preserve precision when these columns were added manually beforehand.
  FOR item IN SELECT attname, atttypmod, atttypid FROM pg_attribute
    WHERE attrelid = to_regclass(format('%I.sensors', ns))
      AND attname IN ('min_value', 'max_value') AND NOT attisdropped
  LOOP
    IF item.atttypid <> 'numeric'::regtype THEN
      RAISE EXCEPTION 'Sensor limits must already be NUMERIC, not %', item.atttypid::regtype;
    END IF;
    IF item.atttypmod <> -1 THEN
      EXECUTE format('ALTER TABLE %I.sensors ALTER COLUMN %I TYPE numeric', ns, item.attname);
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = to_regclass(format('%I.sensors', ns)) AND conname = 'sensors_limits_valid') THEN
    EXECUTE format($check$ALTER TABLE %I.sensors ADD CONSTRAINT sensors_limits_valid CHECK (
      (min_value IS NULL OR min_value NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)) AND
      (max_value IS NULL OR max_value NOT IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)) AND
      (min_value IS NULL OR max_value IS NULL OR min_value <= max_value))$check$, ns);
  END IF;
END;
$migration$;
COMMIT;
