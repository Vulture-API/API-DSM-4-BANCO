import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import pg from "pg";

const url = process.env.TEST_DATABASE_URL;
const sql = path => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const migration = sql("migrations/017_telemetry_destinations_and_idempotency.sql");

async function fixture(partitioned, run) {
  const schema = `it_destinations_${randomUUID().replaceAll("-", "")}`;
  const db = new pg.Client({ connectionString: url });
  await db.connect();
  try {
    await db.query(`CREATE SCHEMA ${schema}; SET search_path TO ${schema}`);
    for (const path of ["setup/schema-neon.sql", "migrations/015_role_permissions.sql", "migrations/016_occurrences.sql", "migrations/016_sensor_limits_and_reading_precision.sql"]) {
      await db.query(sql(path));
    }
    await db.query(`
      INSERT INTO roles(id,name) VALUES(1,'test-owner');
            INSERT INTO users(id,role_id,name) VALUES(1,1,'owner');
      INSERT INTO properties(id,name,owner_user_id) VALUES(1,'property',1);
      INSERT INTO stations(id,property_id,mac_address,name) VALUES(1,1,'AA:BB:CC:DD:EE:01','station');
      INSERT INTO sensor_types(id,name,unit_of_measure) VALUES(1,'temperature','C');
      INSERT INTO sensors(id,station_id,sensor_type_id,local_identifier) VALUES(1,1,1,'temp');
    `);
    if (partitioned) {
      // Empty isolated fixture; production conversion is exercised by benchmark/010.
      await db.query(`
        ALTER TABLE readings RENAME TO original_readings;
        ALTER TABLE original_readings RENAME CONSTRAINT readings_pk TO original_readings_pk;
        CREATE TABLE readings(LIKE original_readings INCLUDING DEFAULTS INCLUDING IDENTITY INCLUDING CONSTRAINTS)
          PARTITION BY RANGE(unix_time);
        ALTER TABLE readings ADD PRIMARY KEY(id,unix_time);
        ALTER TABLE readings ADD FOREIGN KEY(sensor_id) REFERENCES sensors(id);
        CREATE TABLE readings_default PARTITION OF readings DEFAULT;
      `);
    }
    await run(db, schema);
  } finally {
    await db.query("ROLLBACK");
    await db.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
    await db.end();
  }
}

for (const partitioned of [false, true]) {
  test(`SCRUM-451 repeatable destinations, exact occurrence and ${partitioned ? "partitioned" : "ordinary"} uniqueness`, { skip: !url }, async () => {
    await fixture(partitioned, async db => {
      await db.query("INSERT INTO readings(sensor_id,value,unix_time) VALUES(1,12.34,1760000000)");
      await db.query("CREATE MATERIALIZED VIEW mv_latest_readings AS SELECT id,value,unix_time FROM readings; CREATE UNIQUE INDEX test_latest_id ON mv_latest_readings(id)");
      const before = (await db.query("SELECT pg_get_viewdef('mv_latest_readings'::regclass) AS definition")).rows[0].definition;
      await db.query(migration);
      await db.query(migration);
      assert.equal((await db.query("SELECT pg_get_viewdef('mv_latest_readings'::regclass) AS definition")).rows[0].definition, before);
      await db.query("REFRESH MATERIALIZED VIEW CONCURRENTLY mv_latest_readings");
      assert.equal((await db.query("SELECT value::text FROM mv_latest_readings")).rows[0].value, "12.34");
      await assert.rejects(db.query("INSERT INTO readings(sensor_id,value,unix_time) VALUES(1,99,1760000000)"), { code: "23505" });
      await assert.rejects(db.query("INSERT INTO readings(sensor_id,value,unix_time) VALUES(999,1,0)"), { code: "23503" });
      const exact = "999999999999.1234567890123456789";
      await db.query("INSERT INTO occurrences(type,station_id,sensor_id,reading_id,value,description) VALUES('OUT_OF_RANGE',1,1,1,$1,'above')", [exact]);
      assert.equal((await db.query("SELECT value::text FROM occurrences")).rows[0].value, exact);
      await assert.rejects(db.query("INSERT INTO occurrences(type,station_id,sensor_id,reading_id,value,description) VALUES('OUT_OF_RANGE',1,1,2,1,'again')"), { code: "23505" });
      const raw = Buffer.from('{"payload":"{invalid\\u0000\\ud800 1e999999999999}","received_at":"original"}');
      const event = (await db.query("INSERT INTO telemetry_events(source_id,stream,entry_id,original_fields) VALUES('source','stream','1-0',$1) RETURNING id", [raw])).rows[0].id;
      await assert.rejects(db.query("INSERT INTO telemetry_events(source_id,stream,entry_id,original_fields) VALUES('source','stream','1-0',$1)", [raw]), { code: "23505" });
      const quarantine = (await db.query("INSERT INTO telemetry_quarantine(event_id,ordinal,reasons) VALUES($1,0,ARRAY['invalid_payload']) RETURNING id", [event])).rows[0].id;
      await db.query("INSERT INTO telemetry_results(event_id,ordinal,destination,reasons,quarantine_id) VALUES($1,0,'quarantine',ARRAY['invalid_payload'],$2)", [event, quarantine]);
      assert.deepEqual((await db.query("SELECT original_fields FROM telemetry_events")).rows[0].original_fields, raw);
      await assert.rejects(db.query("DELETE FROM telemetry_events WHERE id=$1", [event]), { code: "23503" });
      await assert.rejects(db.query("INSERT INTO telemetry_results(event_id,ordinal,destination) VALUES($1,1,'reading')", [event]), { code: "23514" });
      await db.query("BEGIN; UPDATE stations SET last_communication_at='2020-01-01'; DELETE FROM telemetry_results; ROLLBACK");
      assert.equal((await db.query("SELECT count(*)::int AS n FROM telemetry_results")).rows[0].n, 1);
    });
  });
}

test("SCRUM-451 duplicate historical measurements abort without deleting data", { skip: !url }, async () => {
  await fixture(false, async db => {
    await db.query("INSERT INTO readings(sensor_id,value,unix_time) VALUES(1,1,100),(1,2,100)");
    await assert.rejects(db.query(migration), /Duplicate historical readings/);
    await db.query("ROLLBACK");
    assert.equal((await db.query("SELECT count(*)::int AS n FROM readings")).rows[0].n, 2);
    assert.equal((await db.query("SELECT to_regclass('telemetry_events') AS relation")).rows[0].relation, null);
    assert.equal((await db.query("SELECT atttypmod FROM pg_attribute WHERE attrelid='occurrences'::regclass AND attname='value'")).rows[0].atttypmod, 655366);
  });
});
