import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import pg from 'pg';

const url = process.env.TEST_DATABASE_URL;
const sql = path => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8');
const migration = sql('migrations/018_telemetry_recovery_and_replay.sql');

for (const partitioned of [false, true]) {
  test(`SCRUM-530 audit, repeatable migration and ${partitioned ? 'partitioned' : 'ordinary'} preservation`, { skip: !url }, async () => {
    const schema = `it_recovery_${randomUUID().replaceAll('-', '')}`;
    const db = new pg.Client({ connectionString: url });
    await db.connect();
    try {
      await db.query(`CREATE SCHEMA ${schema}; SET search_path TO ${schema}`);
      for (const path of ['setup/schema-neon.sql', 'migrations/015_role_permissions.sql', 'migrations/016_occurrences.sql', 'migrations/016_sensor_limits_and_reading_precision.sql', 'migrations/017_telemetry_destinations_and_idempotency.sql']) await db.query(sql(path));
      if (partitioned) {
        await db.query(`ALTER TABLE readings RENAME TO ordinary_readings;
          CREATE TABLE readings(LIKE ordinary_readings INCLUDING DEFAULTS INCLUDING IDENTITY INCLUDING CONSTRAINTS) PARTITION BY RANGE(unix_time);
          ALTER TABLE readings ADD PRIMARY KEY(id,unix_time);
          CREATE TABLE readings_default PARTITION OF readings DEFAULT;
          CREATE UNIQUE INDEX recovery_sensor_time ON readings(sensor_id,unix_time);`);
      }
      await db.query('CREATE MATERIALIZED VIEW mv_latest_readings AS SELECT id,value,unix_time FROM readings; CREATE UNIQUE INDEX recovery_latest_id ON mv_latest_readings(id)');
      const before = (await db.query("SELECT pg_get_viewdef('mv_latest_readings'::regclass) AS definition")).rows[0].definition;
      const original = Buffer.from('{"payload":"{invalid\\u0000\\ud800 1e999999999999}","received_at":"original"}');
      const event = (await db.query("INSERT INTO telemetry_events(source_id,stream,entry_id,original_fields,completed_at) VALUES('source','stream','1-0',$1,now()) RETURNING id", [original])).rows[0].id;
      const q = (await db.query("INSERT INTO telemetry_quarantine(event_id,ordinal,reasons) VALUES($1,0,ARRAY['unknown_station']) RETURNING id", [event])).rows[0].id;
      await db.query('GRANT SELECT ON telemetry_events TO PUBLIC');
      const privilege = (await db.query("SELECT relacl::text AS acl FROM pg_class WHERE oid='telemetry_events'::regclass")).rows[0].acl;
      await db.query(migration);
      await db.query(migration);
      assert.equal((await db.query("SELECT pg_get_viewdef('mv_latest_readings'::regclass) AS definition")).rows[0].definition, before);
      assert.equal((await db.query("SELECT relacl::text AS acl FROM pg_class WHERE oid='telemetry_events'::regclass")).rows[0].acl, privilege);
      assert.deepEqual((await db.query('SELECT original_fields,legacy_max_id FROM telemetry_events')).rows[0], { original_fields: original, legacy_max_id: null });
      const request = randomUUID();
      await db.query("INSERT INTO telemetry_replay_requests(request_id,quarantine_id,operator_name,justification) VALUES($1,$2,'operator','catalog fixed')", [request, q]);
      await assert.rejects(db.query("INSERT INTO telemetry_replay_requests(request_id,quarantine_id,operator_name,justification) VALUES($1,$2,'operator','again')", [request, q]), { code: '23505' });
      const attempt = (await db.query("INSERT INTO telemetry_replay_attempts(request_id,processor_version) VALUES($1,'test') RETURNING id", [request])).rows[0].id;
      await assert.rejects(db.query("UPDATE telemetry_replay_attempts SET status='SUCCEEDED' WHERE id=$1", [attempt]), { code: '23514' });
      await db.query("INSERT INTO telemetry_replay_results(attempt_id,event_id,ordinal,destination,reasons) VALUES($1,$2,0,'rejected',ARRAY['unknown_station'])", [attempt, event]);
      await db.query("UPDATE telemetry_replay_attempts SET status='REJECTED',finished_at=clock_timestamp() WHERE id=$1", [attempt]);
      const second = (await db.query("INSERT INTO telemetry_replay_attempts(request_id,processor_version) VALUES($1,'test') RETURNING id", [request])).rows[0].id;
      await db.query("INSERT INTO telemetry_replay_results(attempt_id,event_id,ordinal,destination,sensor_id,reading_id,reading_unix_time) VALUES($1,$2,1,'reading',1,1,100)", [second, event]);
      const third = (await db.query("INSERT INTO telemetry_replay_attempts(request_id,processor_version) VALUES($1,'test') RETURNING id", [request])).rows[0].id;
      await assert.rejects(db.query("INSERT INTO telemetry_replay_results(attempt_id,event_id,ordinal,destination,sensor_id,reading_id,reading_unix_time) VALUES($1,$2,1,'reading',1,1,100)", [third, event]), { code: '23505' });
      await db.query("INSERT INTO telemetry_recovery_incidents(source_id,stream,group_name,entry_id,reason,durable_event_id) VALUES('source','stream','g','1-0','missing_stream_content',$1)", [event]);
      await assert.rejects(db.query('DELETE FROM telemetry_quarantine WHERE id=$1', [q]), { code: '23503' });
      await assert.rejects(db.query('DELETE FROM telemetry_events WHERE id=$1', [event]), { code: '23503' });
      await assert.rejects(db.query("INSERT INTO telemetry_replay_requests(request_id,quarantine_id,operator_name,justification) VALUES($1,$2,'','reason')", [randomUUID(), q]), { code: '23514' });
      await db.query(migration);
      assert.equal((await db.query('SELECT count(*)::int AS n FROM telemetry_replay_attempts')).rows[0].n, 3);
      assert.equal((await db.query("SELECT count(*)::int AS n FROM telemetry_recovery_incidents")).rows[0].n, 1);
    } finally {
      await db.query('ROLLBACK');
      await db.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
      await db.end();
    }
  });
}
