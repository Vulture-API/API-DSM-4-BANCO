import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import pg from "pg";

const url = process.env.TEST_DATABASE_URL;
const sql = path => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const migration = sql("migrations/023_telemetry_ignored_fields.sql");

test("SCRUM-623 registra campo sem sensor cadastrado como ignorado, sem leitura nem quarentena", { skip: !url }, async () => {
  const schema = `it_ignored_${randomUUID().replaceAll("-", "")}`;
  const db = new pg.Client({ connectionString: url });
  await db.connect();
  try {
    await db.query(`CREATE SCHEMA ${schema}; SET search_path TO ${schema}`);
    for (const path of [
      "setup/schema-neon.sql",
      "migrations/015_role_permissions.sql",
      "migrations/016_occurrences.sql",
      "migrations/016_sensor_limits_and_reading_precision.sql",
      "migrations/017_telemetry_destinations_and_idempotency.sql",
    ]) {
      await db.query(sql(path));
    }
    await db.query(`
      INSERT INTO roles(id,name) VALUES(1,'test-owner');
      INSERT INTO users(id,role_id,name) VALUES(1,1,'owner');
      INSERT INTO properties(id,name,owner_user_id) VALUES(1,'property',1);
      INSERT INTO stations(id,property_id,mac_address,name) VALUES(1,1,'AA:BB:CC:DD:EE:01','station');
      INSERT INTO sensor_types(id,name,unit_of_measure) VALUES(1,'temperature','C');
      INSERT INTO sensors(id,station_id,sensor_type_id,local_identifier) VALUES(1,1,1,'temp');
      INSERT INTO readings(id,sensor_id,value,unix_time) VALUES(10,1,23.4,1794100000);
    `);
    const event = (await db.query(
      "INSERT INTO telemetry_events(source_id,stream,entry_id,original_fields) VALUES('source','stream','1-0',$1) RETURNING id",
      [Buffer.from('{"payload":"{}"}')],
    )).rows[0].id;
    const ignored = "INSERT INTO telemetry_results(event_id,ordinal,destination,reasons) VALUES($1,$2,'ignored',$3)";

    await assert.rejects(db.query(ignored, [event, 2, ["unknown_sensor"]]), { code: "23514" });

    await db.query(migration);
    await db.query(migration);

    await db.query(
      "INSERT INTO telemetry_results(event_id,ordinal,destination,sensor_id,reading_id,reading_unix_time) VALUES($1,1,'reading',1,10,1794100000)",
      [event],
    );
    await db.query(ignored, [event, 2, ["unknown_sensor"]]);
    assert.deepEqual(
      (await db.query("SELECT ordinal,destination,sensor_id,reading_id,quarantine_id,reasons FROM telemetry_results WHERE destination='ignored'")).rows,
      [{ ordinal: 2, destination: "ignored", sensor_id: null, reading_id: null, quarantine_id: null, reasons: ["unknown_sensor"] }],
    );

    await assert.rejects(db.query(ignored, [event, 3, []]), { code: "23514" });
    await assert.rejects(db.query(ignored, [event, 0, ["unknown_sensor"]]), { code: "23514" });
    await assert.rejects(
      db.query("INSERT INTO telemetry_results(event_id,ordinal,destination,sensor_id,reasons) VALUES($1,4,'ignored',1,ARRAY['unknown_sensor'])", [event]),
      { code: "23514" },
    );
    await assert.rejects(
      db.query("INSERT INTO telemetry_results(event_id,ordinal,destination,reasons) VALUES($1,5,'reading',ARRAY['x'])", [event]),
      { code: "23514" },
    );
    await assert.rejects(
      db.query("INSERT INTO telemetry_results(event_id,ordinal,destination,reasons) VALUES($1,6,'descartado',ARRAY['x'])", [event]),
      { code: "23514" },
    );
  } finally {
    await db.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
    await db.end();
  }
});
