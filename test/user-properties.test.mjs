import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import test from "node:test";
import pg from "pg";

const migration = readFileSync(new URL("../migrations/022_user_properties.sql", import.meta.url), "utf8");
test("SCRUM-608: backfill único, PK, índice e cascatas dos vínculos", { skip: !process.env.TEST_DATABASE_URL }, async () => {
  const client = new pg.Client({ connectionString: process.env.TEST_DATABASE_URL });
  const schema = `it_links_${randomUUID().replaceAll("-", "")}`;
  await client.connect();
  try {
    await client.query(`CREATE SCHEMA ${schema}; SET search_path TO ${schema};
      CREATE TABLE users(id integer PRIMARY KEY);
      CREATE TABLE properties(id integer PRIMARY KEY, owner_user_id integer REFERENCES users);
      INSERT INTO users VALUES(10),(20);
      INSERT INTO properties VALUES(1,10),(2,20);`);
    await client.query(migration);
    assert.equal((await client.query("SELECT * FROM user_properties")).rowCount, 2);
    await assert.rejects(client.query("INSERT INTO user_properties VALUES(10,1)"), { code: "23505" });
    await assert.rejects(client.query("INSERT INTO user_properties VALUES(999,1)"), { code: "23503" });
    await assert.rejects(client.query("INSERT INTO user_properties VALUES(10,999)"), { code: "23503" });
    await client.query("DELETE FROM user_properties WHERE user_id=10");
    await client.query(migration);
    assert.equal((await client.query("SELECT * FROM user_properties WHERE user_id=10")).rowCount, 0);
    assert.equal((await client.query("SELECT 1 FROM pg_indexes WHERE schemaname=$1 AND indexname='idx_user_properties_property'", [schema])).rowCount, 1);
    await client.query("INSERT INTO user_properties VALUES(10,2); DELETE FROM properties WHERE id=2");
    assert.equal((await client.query("SELECT * FROM user_properties")).rowCount, 0);
    await client.query("INSERT INTO user_properties VALUES(20,1); DELETE FROM users WHERE id=20");
    assert.equal((await client.query("SELECT * FROM user_properties")).rowCount, 0);
  } finally {
    await client.query("ROLLBACK");
    await client.query(`DROP SCHEMA ${schema} CASCADE`);
    await client.end();
  }
});


test("SCRUM-608: atualiza demo antigo uma vez e preserva revogação ao reaplicar", { skip: !process.env.TEST_DATABASE_URL }, async () => {
  const client = new pg.Client({ connectionString: process.env.TEST_DATABASE_URL });
  const schema = `it_demo_links_${randomUUID().replaceAll("-", "")}`;
  const read = path => readFileSync(new URL(path, import.meta.url), "utf8");
  await client.connect();
  try {
    await client.query(`CREATE SCHEMA ${schema}; SET search_path TO ${schema}`);
    for (const script of ["../setup/schema-neon.sql", "../migrations/015_role_permissions.sql", "../migrations/019_property_permissions.sql", "../setup/seed-dev.sql"])
      await client.query(read(script));
    const seed = read("../setup/seed-demo.sql");
    // Mesmo SQL da massa antiga: ainda não existiam tabela nem bootstrap de vínculos.
    await client.query(seed.split("-- SCRUM-608: inicialização única dos vínculos")[0]);
    await client.query(migration);
    const links = async () => (await client.query(`SELECT c.email, p.name FROM user_properties up
      JOIN credentials c ON c.user_id=up.user_id JOIN properties p ON p.id=up.property_id
      WHERE c.email IN ('carlos.mendes@agritech.dev','fernanda.costa@agritech.dev') ORDER BY c.email`)).rows;
    assert.deepEqual(await links(), []);
    await client.query(seed);
    assert.deepEqual(await links(), [
      { email: "carlos.mendes@agritech.dev", name: "Fazenda Santa Rita" },
      { email: "fernanda.costa@agritech.dev", name: "Fazenda Boa Vista" },
    ]);
    await client.query("DELETE FROM user_properties WHERE user_id=(SELECT user_id FROM credentials WHERE email='carlos.mendes@agritech.dev')");
    await client.query(seed);
    assert.deepEqual(await links(), [{ email: "fernanda.costa@agritech.dev", name: "Fazenda Boa Vista" }]);
    assert.equal((await client.query("SELECT * FROM processing_checkpoints WHERE key='demo_user_properties_v1'")).rowCount, 1);
  } finally {
    await client.query("ROLLBACK");
    await client.query(`DROP SCHEMA ${schema} CASCADE`);
    await client.end();
  }
});
