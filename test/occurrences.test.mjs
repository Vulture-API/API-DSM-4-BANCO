import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import pg from "pg";

const url = process.env.TEST_DATABASE_URL;
const read = (path) => readFileSync(new URL(path, import.meta.url), "utf8");
const schemaSql = read("../setup/schema-neon.sql");
const permissions = read("../migrations/015_role_permissions.sql");
const migration = read("../migrations/016_occurrences.sql");
const seed = read("../setup/seed-dev.sql");

test("SCRUM-395 migration cria limites, ocorrências e permissões de forma repetível", { skip: !url }, async () => {
  const schema = `it_occurrences_${randomUUID().replaceAll("-", "")}`;
  const client = new pg.Client({ connectionString: url });
  await client.connect();
  try {
    await client.query(`CREATE SCHEMA ${schema}; SET search_path TO ${schema}`);
    await client.query(schemaSql);
    await client.query(permissions);
    await client.query(seed);
    await client.query(migration);
    await client.query(migration);

    const admin = (await client.query("SELECT id FROM roles WHERE name = 'Administrador'")).rows[0];
    const granted = await client.query(
      "SELECT permission_code FROM role_permissions WHERE role_id = $1 AND permission_code LIKE 'occurrences.%' ORDER BY 1",
      [admin.id],
    );
    assert.deepEqual(granted.rows.map((r) => r.permission_code), ["occurrences.read", "occurrences.resolve", "occurrences.run"]);
    await client.query("DELETE FROM role_permissions WHERE role_id = $1 AND permission_code = 'occurrences.run'", [admin.id]);
    await client.query(migration);
    assert.equal((await client.query("SELECT 1 FROM role_permissions WHERE permission_code = 'occurrences.run'")).rowCount, 0);

    const checkpoint = await client.query("SELECT value FROM processing_checkpoints WHERE key = 'occurrences_last_reading_id'");
    assert.equal(checkpoint.rows[0].value, "0");

    const property = (await client.query("SELECT id FROM properties ORDER BY id LIMIT 1")).rows[0];
    const type = (await client.query("SELECT id FROM sensor_types ORDER BY id LIMIT 1")).rows[0];
    const station = (await client.query(
      "INSERT INTO stations (property_id, mac_address, name) VALUES ($1, $2, 'E1') RETURNING id",
      [property.id, randomUUID().slice(0, 17)],
    )).rows[0];
    await assert.rejects(
      client.query("INSERT INTO sensors (station_id, sensor_type_id, local_identifier, min_value, max_value) VALUES ($1, $2, 'x', 10, 5)", [station.id, type.id]),
      { code: "23514" },
    );
    const sensor = (await client.query(
      "INSERT INTO sensors (station_id, sensor_type_id, local_identifier, min_value, max_value) VALUES ($1, $2, 'temp', -10, 50) RETURNING id",
      [station.id, type.id],
    )).rows[0];

    await client.query("INSERT INTO occurrences (type, station_id, description) VALUES ('COMMUNICATION_FAILURE', $1, 'sem comunicação')", [station.id]);
    await assert.rejects(
      client.query("INSERT INTO occurrences (type, station_id, description) VALUES ('COMMUNICATION_FAILURE', $1, 'de novo')", [station.id]),
      { code: "23505" },
    );
    await assert.rejects(
      client.query("INSERT INTO occurrences (type, station_id, sensor_id, description) VALUES ('COMMUNICATION_FAILURE', $1, $2, 'x')", [station.id, sensor.id]),
      { code: "23514" },
    );
    await assert.rejects(
      client.query("INSERT INTO occurrences (type, station_id, description, status) VALUES ('OUT_OF_RANGE', $1, 'x', 'RESOLVED')", [station.id]),
      { code: "23514" },
    );
    await client.query(
      "INSERT INTO occurrences (type, station_id, sensor_id, reading_id, value, description) VALUES ('OUT_OF_RANGE', $1, $2, 1, 80, 'acima')",
      [station.id, sensor.id],
    );
    await assert.rejects(
      client.query(
        "INSERT INTO occurrences (type, station_id, sensor_id, reading_id, value, description) VALUES ('OUT_OF_RANGE', $1, $2, 2, 90, 'acima')",
        [station.id, sensor.id],
      ),
      { code: "23505" },
    );
    await client.query("UPDATE occurrences SET status = 'RESOLVED', resolved_at = now() WHERE station_id = $1", [station.id]);
    await client.query("INSERT INTO occurrences (type, station_id, description) VALUES ('COMMUNICATION_FAILURE', $1, 'nova')", [station.id]);

    await client.query("DELETE FROM stations WHERE id = $1", [station.id]);
    assert.equal((await client.query("SELECT 1 FROM occurrences")).rowCount, 0);
  } finally {
    await client.query("RESET search_path");
    await client.query(`DROP SCHEMA IF EXISTS ${schema} CASCADE`);
    await client.end();
  }
});
